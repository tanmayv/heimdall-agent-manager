package main

import "core:sync"
import "core:time"
import "core:crypto"
import "core:encoding/json"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import channel "odin_test:lib/executor_channel"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// Caller owns executor serialization and resolves keys from the current paired
// directory. This is deliberately separate from legacy Hub agent-token auth.
// Startup invalidation and physical child observation share the I/O mutex.
bridge_executor_child_attest :: proc(s:^executor.Store,instance,secret,input,socket:string,
    owner_key,executor_key:contracts.Owner_Verified_Key,sign:executor.Signer)->executor.Result {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    raw,authenticated:=executor.child_bootstrap(s,instance,secret,time.to_unix_nanoseconds(time.now())/1000000)
    if !authenticated do return executor.Result{code="invalid_scope"}
    b,parsed:=contracts.executor_parse(raw,"bootstrap")
    if !parsed do return executor.Result{code="invalid_scope"}
    launch_key:=contracts.owner_string(b,"launch_key")
    pid,known:=bridge_pty_host_executor_query(socket,instance,launch_key)
    if !known || pid<=0 do return executor.Result{code="child_not_current"}
    return executor.attest_child_request(s,instance,secret,input,
        executor.Child_Observation{instance,launch_key,s.incarnation,true},owner_key,executor_key,
        time.to_unix_nanoseconds(time.now())/1000000,sign)
}

bridge_executor_child_keys :: proc(s:^executor.Store,b:json.Object,d:vault.Directory_Verification_Input,
    kr:^vault.Vault_Keyring)->(owner_key,executor_key:contracts.Owner_Verified_Key,valid:bool) {
    dir,trusted:=bridge_executor_directory(s,d,kr)
    if !trusted do return {},{},false
    get:=contracts.owner_string
    own,self_ok:=dir.trusted[s.operator_key]
    peer,owner_ok:=dir.trusted[get(b,"key_id")]
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    if !self_ok || own.kind!="bridge" || own.sign_public_key!=public || !owner_ok || peer.kind!="bridge" do return {},{},false
    host:=contracts.Owner_Verified_Key{s.account,s.executor,s.operator_key,public,"bridge",true,false}
    source:=contracts.Owner_Verified_Key{s.account,get(b,"owner_bridge_id"),peer.id,peer.sign_public_key,"bridge",true,false}
    return source,host,contracts.executor_verify("bootstrap",b,source)
}

// Fresh directory retrieval and the reverse owner exchange happen without the
// application executor mutex. The token stays local; only an exact signed
// child/input attestation crosses the encrypted transit channel.
Executor_Child_Transport :: struct {
    ctx:rawptr,
    directory:proc(rawptr,i64)->(vault.Directory_Verification_Input,bool),
    exchange:proc(rawptr,string,string,i64)->Executor_Fence_Outcome,
}
bridge_executor_child_fetch :: proc(_:rawptr,generation:i64)->(vault.Directory_Verification_Input,bool) {return bridge_executor_directory_fetch(generation)}
bridge_executor_child_send :: proc(_:rawptr,request,input:string,generation:i64)->Executor_Fence_Outcome {return bridge_executor_child_exchange(request,input,generation)}
bridge_executor_agent :: proc(request_id,input,secret:string,
    transport:Executor_Child_Transport={nil,bridge_executor_child_fetch,bridge_executor_child_send},socket_path:string="")->(string,bool) {
    generation:=bridge_task_chain_search_generation()
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    self,self_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !self_ok || account=="" do return "",false
    sync.mutex_lock(&bridge_executor_mutex)
    opened:=bridge_executor_open(account,self)
    instance,raw:string
    authenticated:=false
    if opened {instance,raw,authenticated=executor.child_token(&bridge_executor_store,secret,time.to_unix_nanoseconds(time.now())/1000000)}
    sync.mutex_unlock(&bridge_executor_mutex)
    if !authenticated do return "",false
    fail:=proc(id,code:string)->(string,bool) {return bridge_local_response_error(id,code,"remote owner request rejected"),true}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return fail(request_id,"vault_locked")
    if transport.directory==nil || transport.exchange==nil do return fail(request_id,"owner_unavailable")
    directory,fetched:=transport.directory(transport.ctx,generation)
    if !fetched do return fail(request_id,"directory_unavailable")
    b,parsed:=contracts.executor_parse(raw,"bootstrap")
    if !parsed do return fail(request_id,"invalid_scope")
    sync.mutex_lock(&bridge_executor_mutex)
    source,host,trusted:=bridge_executor_child_keys(&bridge_executor_store,b,directory,&kr)
    attested:=executor.Result{code="invalid_scope"}
    if trusted && generation==bridge_task_chain_search_generation() {
        socket:=socket_path
        if socket=="" do socket=pty_host_socket_path()
        attested=bridge_executor_child_attest(&bridge_executor_store,instance,secret,input,socket,source,host,{nil,bridge_executor_sign})
        if socket_path=="" do delete(socket)
    }
    sync.mutex_unlock(&bridge_executor_mutex)
    if attested.code!="ok" do return fail(request_id,attested.code)
    outcome:=transport.exchange(transport.ctx,attested.body,input,generation)
    if outcome.envelope=="" do return fail(request_id,"owner_unavailable")
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    current_source,current_host,current:=bridge_executor_child_keys(&bridge_executor_store,b,outcome.directory,&kr)
    _,still_authenticated:=executor.child_bootstrap(&bridge_executor_store,instance,secret,time.to_unix_nanoseconds(time.now())/1000000)
    if !current || !still_authenticated || current_source.public_key!=source.public_key || current_host.public_key!=host.public_key ||
       generation!=bridge_task_chain_search_generation() {return fail(request_id,"invalid_scope")}
    scope,scoped:=contracts.executor_parse(outcome.scope,"transport_scope")
    request,requested:=contracts.executor_parse(attested.body,"child_request")
    if !scoped || !requested do return fail(request_id,"invalid_scope")
    body,verified:=channel.open_child_result(outcome.envelope,&kr,scope,request,current_source,time.to_unix_nanoseconds(time.now())/1000000,context.temp_allocator)
    if !verified do return fail(request_id,"invalid_owner_result")
    defer crypto.zero_explicit(raw_data(body),len(body))
    result:owner.Result
    if json.unmarshal_string(body,&result,.JSON,context.temp_allocator)!=nil do return fail(request_id,"invalid_owner_result")
    if result.code!="ok" do return fail(request_id,result.code)
    command,valid:=contracts.owner_parse(input,"lifecycle_input")
    if valid && contracts.owner_string(command,"method")=="requirements.present" && !result.replay {
        dir,within:=bridge_fs_run_dir_root(instance)
        if !within do return fail(request_id,"context_delivery_failed")
        defer delete(dir)
        command["instance_id"]=json.String(instance)
        if !bridge_owner_materialize_context(dir,command,result.body) do return fail(request_id,"context_delivery_failed")
    }
    return bridge_local_response_data(request_id,body),true
}
