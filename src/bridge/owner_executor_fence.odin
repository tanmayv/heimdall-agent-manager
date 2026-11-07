package main

import "core:crypto"
import "core:encoding/json"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import channel "odin_test:lib/executor_channel"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

Owner_Executor_Fence_Command :: struct {
    type,command_id,account_id,executor_bridge_id,relay:string,
    directory:vault.Directory_Verification_Input,
}

// Resolve an executor key only after durably observing the paired log. The
// exact Bridge/key assignment is checked against the claimed local intent by
// execution_fence_reply; enrollment alone confers no task authority.
bridge_owner_fence_directory :: proc(s:^owner.Store,input:vault.Directory_Verification_Input,
    kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,i64,string,bool) {
    floor,status:=keystore_read_epoch_floor(bridge_config.daemon_id)
    if status!=.Found || !floor.root.set || input.owner!=s.account do return {},0,"",false
    seq,head:=owner.directory_pin(s)
    if seq<0 do return {},0,"",false
    d:=input;d.pin_seq=seq;d.pin_hash=head
    dir,valid:=vault.directory_verify(d)
    if !valid do return {},0,"",false
    root,root_ok:=vault.root_pin_from_hex(dir.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,dir.root_public_key)
    paired:=floor.root
    if !root_ok || !vault.root_pin_equal(&paired,&root) || !owner.observe_directory(s,dir.version,dir.head_hash) do return {},0,"",false
    if !vault.directory_verify_keyring(&dir,kr) do return {},0,"",false
    own,own_ok:=dir.trusted[s.owner_key]
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    if !own_ok || own.kind!="bridge" || own.sign_public_key!=public do return {},0,"",false
    return contracts.Owner_Verified_Key{s.account,s.owner,s.owner_key,public,"bridge",true,false},dir.version,dir.head_hash,true
}

// Short, read-only owner callback. It does no network I/O and never publishes
// the outbox. Keep it on a distinct dispatcher key so a colocated executor's
// pending exchange cannot block the callback it is waiting for.
bridge_owner_executor_fence_handle :: proc(conn:^ws.Connection,text:string,child:bool=false) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    wire:Owner_Executor_Fence_Command
    if len(text)>3*1024*1024 || json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    relay,valid:=contracts.owner_parse(wire.relay,"relay")
    if !valid do return
    get:=contracts.owner_string
    reply:=struct{type,command_id,request_id,code,envelope:string}{"command_result",wire.command_id,get(relay,"request_id"),"invalid_scope",""}
    defer {
        if generation!=bridge_task_chain_search_generation() {reply.code="vault_locked";reply.envelope=""}
        result:=bridge_owner_json(reply)
        bridge_runtime_cache_command(wire.command_id,result)
        if conn!=nil do _=bridge_hub_send(conn,result)
    }
    now:=time.to_unix_nanoseconds(time.now())/1000000
    expires:=contracts.executor_number(relay,"expires_ms")
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    if wire.account_id!=account || get(relay,"bridge_id")!=bridge_config.daemon_id || expires<=now || expires-now>contracts.EXECUTOR_FENCE_TTL_MS do return
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked {reply.code="vault_locked";return}
    plain,opened:=bridge_open_current_epoch_token(get(relay,"envelope"),&kr,context.temp_allocator)
    if !opened do return
    defer crypto.zero_explicit(raw_data(plain),len(plain))
    exchange,parsed:=contracts.executor_parse(plain,"child_exchange" if child else "exchange")
    scope,scoped:=contracts.executor_parse(get(exchange,"scope"),"transport_scope")
    notification:=!child && get(scope,"method")=="notification_fence_request"
    request_kind:="child_request" if child else ("notification_fence_request" if notification else "fence_request")
    if !parsed || !scoped || get(scope,"method")!=request_kind || get(scope,"direction")!="request" ||
       get(scope,"account_id")!=account || get(scope,"owner_bridge_id")!=bridge_config.daemon_id ||
       get(scope,"executor_bridge_id")!=wire.executor_bridge_id ||
       get(scope,"chain_id")!=get(relay,"chain_id") || get(scope,"request_id")!=get(relay,"request_id") ||
       contracts.executor_number(scope,"request_expires_ms")>expires {return}
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    self,self_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !self_ok do return
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,self) {reply.code="storage_error";return}
    s:=&bridge_owner_store
    owner_key,version,head,trusted:=bridge_owner_fence_directory(s,wire.directory,&kr)
    if !trusted do return
    // Decrypt to select the key, then authenticate the exact same bytes and
    // channel scope. A shared account encryption key is not a Bridge identity.
    raw,decrypted:=channel.open(get(exchange,"envelope"),&kr,scope,now,context.temp_allocator)
    if !decrypted do return
    defer crypto.zero_explicit(raw_data(raw),len(raw))
    request,r_ok:=contracts.executor_parse(raw,request_kind)
    if !r_ok do return
    floor,status:=keystore_read_epoch_floor(bridge_config.daemon_id)
    if status!=.Found do return
    key,key_version,key_head,key_ok:=owner.verify_executor_directory(bridge_owner_json(wire.directory),account,
        get(scope,"executor_bridge_id"),get(request,"key_id"),floor.root,version,head,&kr)
    if !key_ok || key_version!=version || key_head!=head do return
    if notification {
        authenticated,verified:=channel.open_signed(get(exchange,"envelope"),&kr,scope,key,now,context.temp_allocator)
        if !verified do return
        defer crypto.zero_explicit(raw_data(authenticated),len(authenticated))
        result:=owner.execution_notification_fence_reply(s,authenticated,key,owner_key,version,head,
            time.to_unix_nanoseconds(time.now())/1000000,{nil,bridge_owner_sign})
        reply.code=result.code
        if result.code!="ok" do return
        scope["direction"]=json.String("response")
        token,sealed:=channel.seal(result.body,&kr,scope,time.to_unix_nanoseconds(time.now())/1000000,context.temp_allocator)
        if !sealed {reply.code="expired";return}
        reply.envelope=token
        return
    }
    if child {
        authenticated,verified:=channel.open_signed(get(exchange,"envelope"),&kr,scope,key,now,context.temp_allocator)
        if !verified do return
        defer crypto.zero_explicit(raw_data(authenticated),len(authenticated))
        exact,current:=owner.execution_child(s,authenticated,get(exchange,"input"),key,owner_key,time.to_unix_nanoseconds(time.now())/1000000)
        if !current do return
        body:=bridge_owner_executor_child_apply(s,get(exchange,"input"),exact,owner_key)
        token,sealed:=owner.execution_child_result(request,body,scope,owner_key,time.to_unix_nanoseconds(time.now())/1000000,&kr,{nil,bridge_owner_sign})
        if !sealed {reply.code="expired";return}
        reply.code="ok";reply.envelope=token
        return
    }
    result:=owner.execution_fence_channel_reply(s,get(exchange,"envelope"),scope,key,owner_key,version,head,
        time.to_unix_nanoseconds(time.now())/1000000,&kr,{nil,bridge_owner_sign})
    reply.code=result.code
    if result.code!="ok" do return
    reply.envelope=result.body
}
