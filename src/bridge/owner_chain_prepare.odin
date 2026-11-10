#+feature dynamic-literals
package main

// One-step coordinator conversation (POST /chats create_owner_chain): the Hub
// asks this Bridge, with the `owner_chain_prepare` runtime command, for a new
// Bridge-created chain before it launches the coordinator into it.
//
// The chain is created with this Bridge's own owner key (as agent
// `task-chain create` does, owner_agent_chain_create.odin) and recorded as
// PENDING for the named agent. The first instance launched into it boots with
// the coordinator role (bridge_owner_launch_role consults the pending map), so
// no restart is needed; once that instance is a live child here a worker
// thread binds it with owner.bind_created_coordinator (which needs the live
// child) and republishes the registry. No client polling, bind or restart.
//
// Lock order is the owner one: bridge_owner_mutex -> bridge_startup_io_mutex
// -> bridge_local_token_mutex. The pending map's mutex is a leaf: nothing is
// locked while it is held. Launch paths only touch the leaf.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// chain -> the agent its coordinator runs ('' after a Bridge restart: the
// first instance launched into the chain) and, once launched, the instance.
// binding: a post-live bind is running; a relaunch of the claimed instance
// starts another only when none is (a failed or timed-out bind is retried).
Owner_Pending_Coordinator :: struct { agent, instance: string, binding: bool }

bridge_owner_pending_mutex: sync.Mutex
bridge_owner_pending: map[string]Owner_Pending_Coordinator
// The post-live bind; tests replace it (and run it on the calling thread).
bridge_owner_pending_bind_effect: proc(chain, instance, agent: string)
bridge_owner_pending_sync_effects: bool

bridge_owner_pending_set :: proc(chain, agent: string) {
    context.allocator=runtime.default_allocator()
    sync.mutex_lock(&bridge_owner_pending_mutex);defer sync.mutex_unlock(&bridge_owner_pending_mutex)
    if bridge_owner_pending==nil do bridge_owner_pending=make(map[string]Owner_Pending_Coordinator)
    bridge_owner_pending_clear_locked(chain)
    bridge_owner_pending[strings.clone(chain)]=Owner_Pending_Coordinator{agent=strings.clone(agent)}
}

bridge_owner_pending_clear :: proc(chain: string) {
    sync.mutex_lock(&bridge_owner_pending_mutex);defer sync.mutex_unlock(&bridge_owner_pending_mutex)
    bridge_owner_pending_clear_locked(chain)
}

@(private="file")
bridge_owner_pending_clear_locked :: proc(chain: string) {
    if !(chain in bridge_owner_pending) do return
    key,old:=delete_key(&bridge_owner_pending,chain)
    context.allocator=runtime.default_allocator()
    delete(key);delete(old.agent);delete(old.instance)
}

// A Bridge-created chain found unbound in the store (refresh): pending for
// whichever instance launches into it first, unless already pending.
bridge_owner_pending_adopt :: proc(chain: string) {
    context.allocator=runtime.default_allocator()
    sync.mutex_lock(&bridge_owner_pending_mutex);defer sync.mutex_unlock(&bridge_owner_pending_mutex)
    if bridge_owner_pending==nil do bridge_owner_pending=make(map[string]Owner_Pending_Coordinator)
    if chain in bridge_owner_pending do return
    bridge_owner_pending[strings.clone(chain)]=Owner_Pending_Coordinator{}
}

// The launch of `instance` into a pending chain: (is_coordinator, bind). The
// first instance launched claims the pending slot; a relaunch of that same
// instance stays the coordinator; any other instance is not. bind: start the
// post-live bind (the claim, or a relaunch while no bind is running).
bridge_owner_pending_claim :: proc(chain, instance: string) -> (agent: string, coordinator, bind: bool) {
    sync.mutex_lock(&bridge_owner_pending_mutex);defer sync.mutex_unlock(&bridge_owner_pending_mutex)
    p,found:=&bridge_owner_pending[chain]
    if !found do return
    if p.instance=="" do p.instance=strings.clone(instance,runtime.default_allocator())
    if p.instance!=instance do return strings.clone(p.agent,context.temp_allocator),false,false
    bind=!p.binding
    p.binding=true
    return strings.clone(p.agent,context.temp_allocator),true,bind
}

// The bind for `chain` ended without binding: a later relaunch retries it.
bridge_owner_pending_bind_failed :: proc(chain: string) {
    sync.mutex_lock(&bridge_owner_pending_mutex);defer sync.mutex_unlock(&bridge_owner_pending_mutex)
    if p,found:=&bridge_owner_pending[chain];found do p.binding=false
}

// A pending chain's boot role for `instance` (no bound coordinator yet). The
// claim, or a relaunch with no bind running, starts the post-live bind.
bridge_owner_pending_launch_role :: proc(chain, instance: string) -> bool {
    agent,coordinator,bind:=bridge_owner_pending_claim(chain,instance)
    if bind do bridge_owner_pending_bind_start(chain,instance,agent)
    return coordinator
}

bridge_owner_pending_bind_start :: proc(chain, instance, agent: string) {
    effect:=bridge_owner_pending_bind_effect
    if effect==nil do effect=bridge_owner_pending_bind
    if bridge_owner_pending_sync_effects { effect(chain,instance,agent);return }
    Job :: struct { chain, instance, agent: string, effect: proc(chain, instance, agent: string) }
    job:=new(Job,runtime.heap_allocator())
    job^=Job{strings.clone(chain,runtime.heap_allocator()),strings.clone(instance,runtime.heap_allocator()),strings.clone(agent,runtime.heap_allocator()),effect}
    thread.run_with_poly_data(job,proc(j:^Job) {
        j.effect(j.chain,j.instance,j.agent)
        delete(j.chain,runtime.heap_allocator());delete(j.instance,runtime.heap_allocator());delete(j.agent,runtime.heap_allocator())
        free(j,runtime.heap_allocator())
        free_all(context.temp_allocator)
    })
}

// Worker thread, no locks held on entry: wait until the instance is a live
// child, then bind it as the chain's first (coordinator) member and publish.
bridge_owner_pending_bind :: proc(chain, instance, agent: string) {
    context.allocator=context.temp_allocator
    if waited:=bridge_owner_wait_live(instance,agent);waited!="" {
        fmt.eprintfln("owner chain %s: coordinator %s not bound: %s (retried at its next launch)",chain,instance,waited)
        bridge_owner_pending_bind_failed(chain)
        return
    }
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if bridge_owner_store.db==nil do return
    sync.mutex_lock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex)
    child,current:=bridge_owner_child_locked(instance,"")
    code:="invalid_scope"
    if current && (agent=="" || child.agent_id==agent) do code=owner.bind_created_coordinator(&bridge_owner_store,chain,child,bridge_config.daemon_id,time.to_unix_nanoseconds(time.now())/1000000).code
    sync.mutex_unlock(&bridge_local_token_mutex)
    sync.mutex_unlock(&bridge_startup_io_mutex)
    if code!="ok" {
        fmt.eprintfln("owner chain %s: coordinator binding of %s refused (%s); retried at its next launch",chain,instance,code)
        bridge_owner_pending_bind_failed(chain)
        return
    }
    bridge_owner_coordinator_refresh_locked(chain)
    bridge_owner_pending_clear(chain)
    bridge_owner_publish()
}

// Sealed title/description and the owner key of this enrolled Bridge.
Owner_Create_Inputs :: struct { account: string, key: contracts.Owner_Verified_Key, title_cipher, description_cipher: string }

bridge_owner_create_inputs :: proc(title, description: string, kr: ^vault.Vault_Keyring) -> (in_: Owner_Create_Inputs, code, message: string) {
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    pub:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(pub,context.temp_allocator)
    if account=="" || !key_ok do return {},"invalid_scope","this Bridge is not enrolled"
    title_cipher,t_ok:=bridge_owner_seal_text(title,kr)
    description_cipher,d_ok:=bridge_owner_seal_text(description,kr)
    if !t_ok || !d_ok do return {},"vault_locked","could not seal the chain title"
    return Owner_Create_Inputs{account,contracts.Owner_Verified_Key{account,bridge_config.daemon_id,key_id,pub,"bridge",true,false},title_cipher,description_cipher},"ok",""
}

// A text the user's app already sealed (the Hub only relays it) is kept as
// is once it opens with this vault; plain text is sealed here.
bridge_owner_seal_text :: proc(text: string, kr: ^vault.Vault_Keyring) -> (string, bool) {
    if !vault.is_armored(text) do return vault.seal_string(text,kr,context.temp_allocator)
    _,opened:=vault.open(text,kr,context.temp_allocator)
    return text,opened==.Ok
}

// Caller holds bridge_owner_mutex with the store open: the signed genesis and
// chain.create with this Bridge's owner key (creator == owner).
bridge_owner_chain_create_execute_locked :: proc(in_: Owner_Create_Inputs, chain, op, requested_by: string, kr: ^vault.Vault_Keyring) -> string {
    now:=time.to_unix_nanoseconds(time.now())/1000000
    genesis,command,payload,built:=bridge_owner_chain_create_documents(in_.account,bridge_config.daemon_id,in_.key.key_id,chain,op,in_.title_cipher,in_.description_cipher,now,bridge_owner_signer())
    if !built do return "storage_error"
    version,hash:=owner.directory_pin(&bridge_owner_store)
    if version<0 do return "storage_error"
    return owner.execute(&bridge_owner_store,command,payload,genesis,in_.key,in_.key,version,hash,now,kr,bridge_owner_signer(),requested_by=requested_by).code
}

// Creates a pending chain for `agent`'s coordinator: (chain, code, message).
// title/description are vault tokens sealed by the user's app (the Hub never
// sees them in plain text) or, for agent and test callers, plain text.
// chain_id is the Hub-chosen id (so a prepare whose reply was lost can still be
// discarded); empty picks a fresh one. An existing chain id is refused.
bridge_owner_chain_prepare :: proc(agent, title, description: string, chain_id: string = "") -> (string, string, string) {
    context.allocator=context.temp_allocator
    if !contracts.owner_field_valid(agent,"id") do return "","bad_request","owner_chain_prepare: invalid agent_id"
    if chain_id!="" && (!strings.has_prefix(chain_id,"chain_") || !contracts.owner_field_valid(chain_id,"id")) do return "","bad_request","owner_chain_prepare: invalid chain_id"
    if strings.trim_space(title)=="" do return "","bad_request","owner_chain_prepare: a chain title is required"
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return "","vault_locked","the owner Bridge vault is locked"
    in_,code,message:=bridge_owner_create_inputs(strings.trim_space(title),description,&kr)
    if code=="vault_locked" && vault.is_armored(title) do return "","bad_request","owner_chain_prepare: the chain title is not sealed for this vault"
    if code!="ok" do return "",code,message
    chain,op:=chain_id,bridge_owner_chain_id("op_")
    if chain=="" do chain=bridge_owner_chain_id("chain_")
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(in_.account,in_.key.key_id) do return "","storage_error","owner store unavailable"
    if created:=bridge_owner_chain_create_execute_locked(in_,chain,op,bridge_config.daemon_id,&kr);created!="ok" do return "",created,"the owner store rejected the new chain"
    bridge_owner_pending_set(chain,agent)
    bridge_owner_coordinator_refresh_locked(chain)
    bridge_owner_publish()
    return chain,"ok",""
}

// Hub runtime command `owner_chain_prepare {command_id, agent_id, chain_id, title, description}`.
bridge_owner_chain_prepare_handle :: proc(conn: ^ws.Connection, text: string) {
    context.allocator=context.temp_allocator
    wire:struct{type,command_id,agent_id,chain_id,title,description:string}
    if json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    chain,code,message:=bridge_owner_chain_prepare(wire.agent_id,wire.title,wire.description,wire.chain_id)
    result:=bridge_owner_json(struct{type,command_id,code,message,chain_id:string}{"command_result",wire.command_id,code,message,chain})
    bridge_runtime_cache_command(wire.command_id,result)
    if conn!=nil do _=bridge_hub_send(conn,result)
}

// Rollback of a prepare whose launch failed: the Hub sends
// `owner_chain_discard {command_id, chain_id}`. Only a Bridge-created chain
// with no member and no task is discarded (owner.discard_created_chain): it is
// retired and its registry row is tombstoned, so it leaves the Hub listing.
// A chain whose coordinator is already bound is kept (operation_conflict).
bridge_owner_chain_discard :: proc(chain: string) -> (string, string) {
    context.allocator=context.temp_allocator
    if !contracts.owner_field_valid(chain,"id") do return "bad_request","owner_chain_discard: invalid chain_id"
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_config.daemon_id),context.temp_allocator)
    if account=="" || !key_ok do return "invalid_scope","this Bridge is not enrolled"
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,key_id) do return "storage_error","owner store unavailable"
    code:=owner.discard_created_chain(&bridge_owner_store,chain,bridge_config.daemon_id,time.to_unix_nanoseconds(time.now())/1000000,bridge_owner_signer()).code
    if code!="ok" do return code,"the owner store kept the chain"
    bridge_owner_pending_clear(chain)
    bridge_owner_coordinator_refresh_locked(chain)
    bridge_owner_publish()
    return "ok",""
}

// Hub runtime command `owner_chain_discard {command_id, chain_id}`.
bridge_owner_chain_discard_handle :: proc(conn: ^ws.Connection, text: string) {
    context.allocator=context.temp_allocator
    wire:struct{type,command_id,chain_id:string}
    if json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    code,message:=bridge_owner_chain_discard(wire.chain_id)
    result:=bridge_owner_json(struct{type,command_id,code,message,chain_id:string}{"command_result",wire.command_id,code,message,wire.chain_id})
    bridge_runtime_cache_command(wire.command_id,result)
    if conn!=nil do _=bridge_hub_send(conn,result)
}
