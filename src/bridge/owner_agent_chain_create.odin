#+feature dynamic-literals
package main

// Agent `ham-ctl task-chain create` (agent.task_chain.create, a .Local route).
//
// This Bridge creates a chain it owns with its OWN owner key as the genesis
// creator (contracts.owner_genesis_bridge_creator; never any other Bridge
// key). The store enables root recovery for such a chain, so the user's app
// opens it with grant.recover. Exactly one coordinator is then bound through
// owner.bind_created_coordinator: the calling child, or a named agent launched
// on this Bridge into the new chain. The bound coordinator then manages the
// fleet (owner_agent_fleet.odin); grants stay human-only (agent_command_admit).
//
// Lock order is the owner one: bridge_owner_mutex -> bridge_startup_io_mutex
// -> bridge_local_token_mutex. Waiting for a named agent's launch holds none.

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

BRIDGE_CHAIN_CREATE_LAUNCH_WAIT_MS :: 90_000

// Same id shape as the UI's ownerId(prefix): prefix + 32 lowercase hex.
bridge_owner_chain_id :: proc(prefix:string) -> string {
    raw:[16]byte
    crypto.rand_bytes(raw[:])
    return fmt.tprintf("%s%s",prefix,vault.hex_encode_lower(raw[:],context.temp_allocator))
}

// The immutable genesis (creator == owner == this Bridge key), its create
// payload and the owner-signed chain.create command, bound as the store's
// owner_create_binding requires (principal/key/op == genesis creator/op).
bridge_owner_chain_create_documents :: proc(account,bridge,key_id,chain,op,title_cipher,description_cipher:string,now:i64,sign:owner.Signer) -> (genesis,command,payload:string,ok:bool) {
    zeros:=strings.repeat("0",128,context.temp_allocator)
    g:=make(json.Object,context.temp_allocator)
    for pair in ([11][2]string{{"protocol_version","1"},{"account_id",account},{"chain_id",chain},{"creation_op",op},{"owner_bridge_id",bridge},{"owner_key_id",key_id},
        {"creator_id",bridge},{"creator_key_id",key_id},{"schema_version","1"},{"creator_signature",zeros},{"owner_signature",zeros}}) { g[pair[0]]=json.String(pair[1]) }
    if sign.sign==nil do return
    creator_sig,c_ok:=sign.sign(sign.ctx,"genesis",g)
    if !c_ok do return
    g["creator_signature"]=json.String(creator_sig)
    owner_sig,o_ok:=sign.sign(sign.ctx,"genesis",g)
    if !o_ok do return
    g["owner_signature"]=json.String(owner_sig)
    digest,digested:=contracts.owner_digest("genesis",g)
    if !digested do return
    payload=bridge_owner_json(map[string]string{"genesis_digest"=digest,"title_cipher"=title_cipher,"description_cipher"=description_cipher})
    c:=make(json.Object,context.temp_allocator)
    for pair in ([13][2]string{{"protocol_version","1"},{"account_id",account},{"chain_id",chain},{"immutable_owner_bridge",bridge},{"principal_id",bridge},
        {"operation_id",op},{"method","chain.create"},{"task_id",""},{"expected_revision","0"},{"request_expires_ms",fmt.tprintf("%d",now+60000)},
        {"payload_digest",contracts.owner_payload_digest(payload)},{"key_id",key_id},{"signature",zeros}}) { c[pair[0]]=json.String(pair[1]) }
    signature,s_ok:=sign.sign(sign.ctx,"command",c)
    if !s_ok do return
    c["signature"]=json.String(signature)
    return bridge_owner_json(g),bridge_owner_json(c),payload,true
}

bridge_owner_chain_create_reply :: proc(request_id,chain,coordinator,warning:string) -> string {
    out:=make(json.Object,context.temp_allocator)
    authority:=make(json.Object,context.temp_allocator)
    authority["kind"]=json.String("owner");authority["bridge_id"]=json.String(bridge_config.daemon_id)
    out["chain_id"]=json.String(chain);out["coordinator_instance_id"]=json.String(coordinator);out["authority"]=authority
    if warning!="" do out["warning"]=json.String(warning)
    return bridge_local_response_data(request_id,bridge_owner_json(out))
}

bridge_owner_chain_create :: proc(request_id,params:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    context.allocator=context.temp_allocator
    if rec.role!=.Agent do return bridge_local_response_error(request_id,"invalid_scope","task-chain create: agent token required")
    p:=bridge_owner_params(params)
    title,description,named:=bridge_owner_pstr(p,"title"),bridge_owner_pstr(p,"description"),bridge_owner_pstr(p,"coordinator_agent_id")
    if title=="" do return bridge_local_response_error(request_id,"bad_request","task-chain create: --title is required")
    if named!="" && !contracts.owner_field_valid(named,"id") do return bridge_local_response_error(request_id,"bad_request","task-chain create: invalid --coordinator-agent")
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return bridge_local_response_error(request_id,"vault_locked","owner Bridge vault is locked")
    in_,in_code,in_message:=bridge_owner_create_inputs(title,description,&kr)
    if in_code!="ok" do return bridge_local_response_error(request_id,in_code,fmt.tprintf("task-chain create: %s",in_message))
    chain,op:=bridge_owner_chain_id("chain_"),bridge_owner_chain_id("op_")
    coordinator:=""
    {
        sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
        // An explicit create may create the owner store.
        if !bridge_owner_open(in_.account,in_.key.key_id) do return bridge_local_response_error(request_id,"storage_error","owner store unavailable")
        code,message:=bridge_owner_chain_create_locked(rec,named,in_,chain,op,&kr)
        if code=="ok" && named=="" {
            coordinator=rec.agent_instance_id
            bridge_owner_coordinator_refresh_locked(chain)
        }
        // Publish the registry entry (and any binding) before anything names
        // the chain to the Hub; a failure stays in the outbox for later.
        bridge_owner_publish()
        if code!="ok" do return bridge_local_response_error(request_id,code,message)
    }
    if named=="" do return bridge_owner_chain_create_reply(request_id,chain,coordinator,"")
    instance,launch_error:=bridge_owner_chain_launch_coordinator(chain,named,rec)
    if launch_error!="" do return bridge_local_response_error(request_id,"coordinator_launch_failed",fmt.tprintf("chain %s created; %s",chain,launch_error))
    {
        sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
        code:="storage_error"
        if bridge_owner_open(in_.account,in_.key.key_id) {
            sync.mutex_lock(&bridge_startup_io_mutex)
            sync.mutex_lock(&bridge_local_token_mutex)
            child,current:=bridge_owner_child_locked(instance,"")
            code="invalid_scope"
            if current && child.agent_id==named do code=owner.bind_created_coordinator(&bridge_owner_store,chain,child,rec.agent_instance_id,time.to_unix_nanoseconds(time.now())/1000000).code
            sync.mutex_unlock(&bridge_local_token_mutex)
            sync.mutex_unlock(&bridge_startup_io_mutex)
            if code=="ok" do bridge_owner_coordinator_refresh_locked(chain)
            bridge_owner_publish()
        }
        if code!="ok" do return bridge_local_response_error(request_id,code,fmt.tprintf("chain %s created and %s launched; coordinator binding refused",chain,instance))
    }
    // Relaunch so the bound instance boots with the coordinator role
    // (bridge_owner_launch_role); the binding itself survives the restart.
    warning:=""
    restart:=bridge_local_relay_raw(.POST,route_path("api","v1","agent-instances",instance,"restart"),nil,"{}",rec)
    if !restart.ok || restart.status<200 || restart.status>=300 do warning=fmt.tprintf("coordinator bound; restart failed (HTTP %d): restart %s to give it the coordinator role",restart.status,instance)
    return bridge_owner_chain_create_reply(request_id,chain,instance,warning)
}

// Caller holds bridge_owner_mutex with the store open. Proves the calling
// child, creates the chain with the owner key, and (default) binds the caller.
bridge_owner_chain_create_locked :: proc(rec:Bridge_Local_Agent_Token_Record,named:string,in_:Owner_Create_Inputs,chain,op:string,kr:^vault.Vault_Keyring) -> (string,string) {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
    child,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
    if !current do return "invalid_scope","task-chain create: current launched child required"
    if named=="" {
        // An instance serves one chain for life: refuse before creating.
        bound,read:=owner.query(bridge_owner_store.db,"SELECT chain_id FROM local_member_chains WHERE instance_id=?",child.instance)
        if !read do return "storage_error","owner store could not be read"
        if len(bound)>0 do return "invalid_scope",fmt.tprintf("this instance already belongs to chain %s; use --coordinator-agent <agt_id>",bound[0][0])
    }
    if created:=bridge_owner_chain_create_execute_locked(in_,chain,op,child.instance,kr);created!="ok" {
        return created,created=="storage_error" ? "task-chain create: signing or storage failed" : "task-chain create rejected by the owner store"
    }
    now:=time.to_unix_nanoseconds(time.now())/1000000
    if named!="" do return "ok",""
    bound:=owner.bind_created_coordinator(&bridge_owner_store,chain,child,child.instance,now)
    if bound.code!="ok" do return bound.code,fmt.tprintf("chain %s created; coordinator binding refused",chain)
    return "ok",""
}

// Launches the named agent on THIS Bridge into the new chain with the
// caller's Hub credential, then waits (no locks held) until it is a live
// child here. Returns the instance id, or a reason.
bridge_owner_chain_launch_coordinator :: proc(chain,agent:string,rec:Bridge_Local_Agent_Token_Record) -> (string,string) {
    return bridge_owner_launch_into_chain(bridge_owner_json(map[string]string{"agent_id"=agent,"chain_id"=chain,"bridge_id"=bridge_config.daemon_id}),agent,rec)
}

// Hub POST /api/v1/agent-instances with `body` (agent_id, chain_id, this
// bridge_id, optional provider/model/profile/project) and the caller's token;
// shared by the coordinator launch and fleet launches (owner_agent_fleet.odin).
// The caller holds no lock: the wait polls the live child under the startup
// and token locks only.
bridge_owner_launch_into_chain :: proc(body,agent:string,rec:Bridge_Local_Agent_Token_Record) -> (string,string) {
    launched:=bridge_local_relay_raw(.POST,route_path("api","v1","agent-instances"),nil,body,rec)
    if !launched.ok || launched.status<200 || launched.status>=300 {
        detail:=launched.body
        if len(detail)>300 do detail=detail[:300]
        return "",fmt.tprintf("launching %s failed (HTTP %d): %s",agent,launched.status,detail)
    }
    instance:=bridge_local_extract_json_string(launched.body,"agent_instance_id","",context.temp_allocator)
    if !contracts.owner_field_valid(instance,"id") do return "",fmt.tprintf("launching %s returned no instance id",agent)
    if waited:=bridge_owner_wait_live(instance,agent);waited!="" do return "",waited
    return instance,""
}
