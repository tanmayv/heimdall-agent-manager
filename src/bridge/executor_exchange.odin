#+feature dynamic-literals
package main
import "core:crypto"
import "core:encoding/json"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"
import channel "odin_test:lib/executor_channel"
import ws "odin_test:lib/ws"

Executor_Exchange_Wire :: struct {
    type,command_id,account_id,relay,genesis:string,
    directory:vault.Directory_Verification_Input,
}
// Observe a verified paired log before checking a requested principal or the
// content-key epoch. Revocation observations survive rejected commands and
// cannot later be replaced by an older still-valid directory snapshot.
bridge_executor_directory :: proc(s:^executor.Store,input:vault.Directory_Verification_Input,kr:^vault.Vault_Keyring)->(vault.Verified_Directory,bool) {
    if input.owner!=s.account do return {},false
    floor,status:=keystore_read_epoch_floor(bridge_config.daemon_id)
    if status!=.Found || !floor.root.set do return {},false
    seq,head,pinned:=executor.enrollment_pin(s)
    if !pinned do return {},false
    d:=input;d.pin_seq=seq;d.pin_hash=head
    dir,valid:=vault.directory_verify(d)
    if !valid do return {},false
    pin,pin_ok:=vault.root_pin_from_hex(dir.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,dir.root_public_key)
    paired:=floor.root
    if !pin_ok || !vault.root_pin_equal(&paired,&pin) || !executor.observe_enrollment(s,dir.version,dir.head_hash) do return {},false
    if !vault.directory_verify_keyring(&dir,kr) do return {},false
    return dir,true
}
bridge_executor_prepare_resources :: proc(s:^executor.Store,p:json.Object)->executor.Resolved_Resources {
    resources,issued:=executor.issued_prepare_resources(s,p)
    if !issued do return {}
    raw,found:=executor.issued_configuration(s,contracts.owner_string(p,"instance_id"))
    c,parsed:=contracts.owner_parse(raw,"remote_configuration")
    if !found || !parsed do return {}
    selection:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("issuance_selection") do selection[f.name]=c[f.name]
    resolved:=bridge_executor_resolve_issuance(s,executor.encode(selection))
    if !resolved.resolved || resolved.directory_key!=resources.directory_key do return {}
    return resources
}
bridge_executor_exchange_handle :: proc(conn:^ws.Connection,text:string,activation:bool=false,callback_ctx:rawptr=nil,
    fence_exchange:Executor_Fence_Exchange=bridge_executor_fence_exchange,
    dispatch:Executor_Activation_Dispatch=bridge_executor_activate_dispatch,
    launch_io:Executor_Launch_IO={nil,bridge_executor_startup_prepare,""}) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    wire:Executor_Exchange_Wire
    if len(text)>3*1024*1024 || json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    relay,valid:=contracts.owner_parse(wire.relay,"relay")
    if !valid do return
    get:=contracts.owner_string
    reply:=struct{type,command_id,request_id,code,envelope:string}{"command_result",wire.command_id,get(relay,"request_id"),"invalid_scope",""}
    defer {
        if bridge_task_chain_search_generation()!=generation {reply.code="vault_locked";reply.envelope=""}
        result:=bridge_owner_json(reply)
        bridge_runtime_cache_command(wire.command_id,result)
        if conn!=nil do _=bridge_hub_send(conn,result)
    }
    now:=time.to_unix_nanoseconds(time.now())/1000000
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    expires:=contracts.executor_number(relay,"expires_ms")
    if wire.account_id!=account || get(relay,"bridge_id")!=bridge_config.daemon_id || expires<=now || expires-now>contracts.EXECUTOR_TRANSPORT_TTL_MS {return}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked {reply.code="vault_locked";return}
    plain,opened:=bridge_open_current_epoch_token(get(relay,"envelope"),&kr,context.temp_allocator)
    if !opened do return
    defer crypto.zero_explicit(raw_data(plain),len(plain))
    exchange,parsed:=contracts.executor_parse(plain,"activation_exchange" if activation else "exchange")
    notification:=false
    if !activation && !parsed {
        exchange,parsed=contracts.executor_parse(plain,"notification_exchange")
        notification=parsed
    }
    has_bootstrap:=false
    if activation && !parsed {
        exchange,parsed=contracts.executor_parse(plain,"activation_bootstrap_exchange")
        has_bootstrap=parsed
    }
    scope,scoped:=contracts.executor_parse(get(exchange,"scope"),"transport_scope")
    genesis,g_ok:=contracts.owner_parse(wire.genesis,"genesis")
    method:=get(scope,"method")
    if notification!=(method=="notification") do return
    if !parsed || !scoped || !g_ok || (method!="prepare" && method!="action" && method!="notification") || get(scope,"direction")!="request" ||
       get(scope,"account_id")!=account || get(scope,"executor_bridge_id")!=bridge_config.daemon_id ||
       get(scope,"chain_id")!=get(relay,"chain_id") || get(scope,"request_id")!=get(relay,"request_id") ||
       get(genesis,"chain_id")!=get(scope,"chain_id") || get(genesis,"account_id")!=account ||
       get(genesis,"owner_bridge_id")!=get(scope,"owner_bridge_id") ||
       contracts.executor_number(scope,"request_expires_ms")>expires {return}
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    self_id,self_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !self_ok do return
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,self_id) {reply.code="storage_error";return}
    s:=&bridge_executor_store
    dir,trusted:=bridge_executor_directory(s,wire.directory,&kr)
    if !trusted do return
    own,own_ok:=dir.trusted[self_id]
    peer,peer_ok:=dir.trusted[get(genesis,"owner_key_id")]
    if !own_ok || own.kind!="bridge" || own.sign_public_key!=public || !peer_ok || peer.kind!="bridge" do return
    owner_key:=contracts.Owner_Verified_Key{account,get(genesis,"owner_bridge_id"),peer.id,peer.sign_public_key,"bridge",true,false}
    creator,creator_ok:=dir.trusted[get(genesis,"creator_id")]
    creator_key:=contracts.Owner_Verified_Key{account,get(genesis,"creator_id"),get(genesis,"creator_id"),creator.sign_public_key,"device",creator_ok && creator.kind=="browser",!creator_ok}
    request_raw,authenticated:=channel.open_signed(get(exchange,"envelope"),&kr,scope,owner_key,now,context.temp_allocator)
    if !authenticated do return
    defer crypto.zero_explicit(raw_data(request_raw),len(request_raw))
    p,p_ok:=contracts.executor_parse(request_raw,method)
    if !p_ok do return
    if activation && (method!="action" || (get(p,"method")!="activate" && get(p,"method")!="heartbeat") || has_bootstrap && get(p,"method")!="activate") do return
    now=time.to_unix_nanoseconds(time.now())/1000000
    binding:=executor.bind_owner(s,wire.genesis,creator_key,owner_key,now)
    if binding.code!="ok" {reply.code=binding.code;return}
    if !executor.owner_bound(s,p,method,owner_key) do return
    if contracts.executor_number(scope,"executor_incarnation")!=s.incarnation &&
       !(method=="action" && get(p,"method")=="query") &&
       !(activation && method=="action" && get(p,"method")=="activate") {reply.code="stale_incarnation";return}
    if notification {
        self:=contracts.Owner_Verified_Key{account,bridge_config.daemon_id,self_id,public,"bridge",true,false}
        result:=bridge_executor_notification_dispatch(s,request_raw,get(exchange,"message"),contracts.executor_number(exchange,"claim_attempt"),
            owner_key,self,&kr,generation,callback_ctx,fence_exchange,launch_io)
        reply.code=result.code
        if result.code!="ok" do return
        scope["direction"]=json.String("response")
        token,sealed:=channel.seal(result.body,&kr,scope,time.to_unix_nanoseconds(time.now())/1000000,context.temp_allocator)
        if !sealed {reply.code="expired";return}
        reply.envelope=token
        return
    }
    // Trusted housekeeping retains charges for active/uncertain children.
    _=executor.expire(s,now)
    result:executor.Result
    current:executor.Current_Owner_Fence
    if method=="prepare" {
        resources:=bridge_executor_prepare_resources(s,p)
        result=executor.prepare(s,request_raw,owner_key,time.to_unix_nanoseconds(time.now())/1000000,resources)
    } else {
        // Replay/query/stop need no network callback. A fresh activate through
        // the separate General_IO command must consume a live owner nonce.
        result=executor.action(s,request_raw,owner_key,time.to_unix_nanoseconds(time.now())/1000000)
        if activation && (result.code=="owner_fence_not_current" || has_bootstrap && result.code=="ok" && !executor.bootstrap_retained(s,get(p,"reservation_id"))) {
            self:=contracts.Owner_Verified_Key{account,bridge_config.daemon_id,self_id,public,"bridge",true,false}
            pending,ready:=executor.fence_challenge(s,request_raw,get(exchange,"intent_id"),contracts.executor_number(exchange,"claim_attempt"),
                owner_key,self,time.to_unix_nanoseconds(time.now())/1000000,{nil,bridge_executor_sign})
            if !ready {reply.code="owner_fence_not_current";return}
            defer executor.fence_challenge_destroy(&pending)
            // No executor/owner mutex or SQLite UoW spans the callback.
            sync.mutex_unlock(&bridge_executor_mutex)
            callback:=fence_exchange(callback_ctx,pending.request,generation)
            sync.mutex_lock(&bridge_executor_mutex)
            if bridge_task_chain_search_generation()!=generation {reply.code="vault_locked";return}
            verified,verified_ok:=bridge_executor_directory(s,callback.directory,&kr)
            latest_self,self_current:=verified.trusted[self_id]
            latest_owner,owner_current:=verified.trusted[owner_key.key_id]
            if !verified_ok || !self_current || latest_self.kind!="bridge" || latest_self.sign_public_key!=public ||
               !owner_current || latest_owner.kind!="bridge" || latest_owner.sign_public_key!=owner_key.public_key ||
               !executor.owner_bound(s,p,method,owner_key) {return}
            current=bridge_executor_fence_accept(s,&pending,callback,owner_key,self,&kr,time.to_unix_nanoseconds(time.now())/1000000)
            result=executor.action(s,request_raw,owner_key,time.to_unix_nanoseconds(time.now())/1000000,current)
        }
    }
    if has_bootstrap && result.code=="ok" {
        accepted:=executor.accept_bootstrap(s,get(exchange,"bootstrap"),get(exchange,"body"),request_raw,owner_key,
            time.to_unix_nanoseconds(time.now())/1000000,current)
        if accepted.code!="ok" {reply.code=accepted.code;return}
        self:=contracts.Owner_Verified_Key{account,bridge_config.daemon_id,self_id,public,"bridge",true,false}
        launched,reason:=dispatch(s,request_raw,exchange,owner_key,self,&kr,generation,callback_ctx,fence_exchange,launch_io)
        if !launched {reply.code=reason;return}
    }
    if activation && get(p,"method")=="heartbeat" && result.code=="ok" {
        self:=contracts.Owner_Verified_Key{account,bridge_config.daemon_id,self_id,public,"bridge",true,false}
        delivered,reason:=dispatch(s,request_raw,exchange,owner_key,self,&kr,generation,callback_ctx,fence_exchange,launch_io)
        if !delivered {reply.code=reason;return}
    }
    reply.code=result.code
    if result.code!="ok" do return
    if method=="action" && get(p,"method")=="stop" {
        sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
        if !bridge_executor_authority_begin(generation) {reply.code="vault_locked";return}
        defer bridge_executor_authority_end()
        socket:=launch_io.socket
        owned_socket:=socket==""
        if owned_socket do socket=pty_host_socket_path()
        defer {if owned_socket do delete(socket)}
        if intent,pending:=executor.reservation_stop(s,p);pending {
            _,_=bridge_executor_dispatch(s,intent,bridge_executor_physical_clock(nil),socket,{},nil,nil,nil,bridge_executor_physical_clock)
        }
        observed:=executor.stop_result(s,p)
        if observed.code!="ok" {reply.code=observed.code;return}
        result.body=observed.body
    }
    receipt,signed:=executor.seal_receipt(s,p,method,result,executor.Signer{nil,bridge_executor_sign})
    if !signed {reply.code="signer_unavailable";return}
    response_scope:=scope;response_scope["direction"]=json.String("response")
    token,sealed:=channel.seal(receipt,&kr,response_scope,time.to_unix_nanoseconds(time.now())/1000000,context.temp_allocator)
    if !sealed {reply.code="expired";return}
    reply.envelope=token
}
