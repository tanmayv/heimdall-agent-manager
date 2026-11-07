package main

import "core:sync"
import "core:encoding/json"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"

// Internal I/O injection keeps tests on an isolated real daemon. Production
// always resolves argv and the endpoint from local catalog/configuration.
Executor_Launch_IO :: struct {
    ctx:rawptr,
    prepare:proc(rawptr,^executor.Store,executor.Intent,i64)->(Pty_Host_Spawn_Request,bool),
    socket:string,
}
bridge_executor_startup_prepare :: proc(_:rawptr,s:^executor.Store,intent:executor.Intent,now:i64)->(Pty_Host_Spawn_Request,bool) {
    sync.mutex_lock(&bridge_runtime_mutex)
    endpoint,ready:=bridge_runtime_ensure_local_endpoint()
    sync.mutex_unlock(&bridge_runtime_mutex)
    if !ready do return {},false
    return bridge_executor_prepare_spawn(s,intent,now,endpoint)
}
Executor_Physical_Fence :: struct {
    proof:executor.Current_Owner_Fence,
    pending:^executor.Fence_Challenge,
}
bridge_executor_physical_clock :: proc(_:rawptr)->i64 {return time.to_unix_nanoseconds(time.now())/1000000}
bridge_executor_physical_fence :: proc(ctx:rawptr,_:executor.Intent)->executor.Current_Owner_Fence {
    p:=(^Executor_Physical_Fence)(ctx)
    q,valid:=contracts.executor_parse(p.pending.request,"fence_request")
    now:=bridge_executor_physical_clock(nil)
    issued,expires:=contracts.executor_number(q,"issued_ms"),contracts.executor_number(q,"request_expires_ms")
    elapsed:=time.tick_since(p.pending.started)
    if !valid || !p.pending.consumed || now<issued || now>=expires || elapsed<0 ||
       elapsed>=time.Duration(expires-issued)*time.Millisecond {return {}}
    return p.proof
}

// Caller holds bridge_executor_mutex. Bootstrap is already durably accepted.
// File I/O precedes the fresh nonce, and no application mutex spans owner HTTP.
bridge_executor_activate_dispatch :: proc(s:^executor.Store,action_raw:string,exchange:json.Object,
    owner_key,self:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,generation:i64,
    callback_ctx:rawptr,fence_exchange:Executor_Fence_Exchange,
    io:Executor_Launch_IO={nil,bridge_executor_startup_prepare,""})->(bool,string) {
    a,valid:=contracts.executor_parse(action_raw,"action")
    if !valid do return false,"malformed"
    now:=bridge_executor_physical_clock(nil)
    intent,query_only,selected:=executor.reservation_launch(s,contracts.owner_string(a,"reservation_id"),contracts.owner_string(a,"prepare_digest"),now)
    if !selected do return false,"stale_intent"
    socket:=io.socket
    owned_socket:=socket==""
    if owned_socket do socket=pty_host_socket_path()
    defer {if owned_socket do delete(socket)}
    if query_only {
        sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
        if !executor.expire(s,bridge_executor_physical_clock(nil)) do return false,"clock_or_storage_error"
        _,_,current:=executor.reservation_launch(s,intent.reservation,contracts.owner_string(a,"prepare_digest"),bridge_executor_physical_clock(nil))
        if !current do return false,"stale_intent"
        delivered,reason:=bridge_executor_observe_dispatch(s,intent,socket)
        if delivered do _=executor.complete_recovery(s,bridge_executor_physical_clock(nil))
        return delivered && reason=="child_present",reason
    }
    if io.prepare==nil || fence_exchange==nil do return false,"startup_unavailable"
    request,ready:=io.prepare(io.ctx,s,intent,now)
    if !ready do return false,"spawn_prepare_failed"
    defer bridge_pty_host_spawn_request_delete(request)
    pending,challenged:=executor.fence_challenge(s,action_raw,contracts.owner_string(exchange,"intent_id"),
        contracts.executor_number(exchange,"claim_attempt"),owner_key,self,bridge_executor_physical_clock(nil),{nil,bridge_executor_sign})
    if !challenged do return false,"owner_fence_not_current"
    defer executor.fence_challenge_destroy(&pending)
    sync.mutex_unlock(&bridge_executor_mutex)
    callback:=fence_exchange(callback_ctx,pending.request,generation)
    sync.mutex_lock(&bridge_executor_mutex)
    if generation!=bridge_task_chain_search_generation() do return false,"vault_locked"
    directory,trusted:=bridge_executor_directory(s,callback.directory,kr)
    own,self_current:=directory.trusted[self.key_id]
    peer,owner_current:=directory.trusted[owner_key.key_id]
    if !trusted || !self_current || own.kind!="bridge" || own.sign_public_key!=self.public_key ||
       !owner_current || peer.kind!="bridge" || peer.sign_public_key!=owner_key.public_key ||
       !executor.owner_bound(s,a,"action",owner_key) {return false,"invalid_scope"}
    proof:=bridge_executor_fence_accept(s,&pending,callback,owner_key,self,kr,bridge_executor_physical_clock(nil))
    physical:=Executor_Physical_Fence{proof,&pending}
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    remaining,current:=executor.intent_current(s,intent,bridge_executor_physical_clock(nil))
    if !current || remaining<1000 do return false,"stale_intent"
    request.timeout_seconds=u64(remaining/1000)
    delivered,reason:=bridge_executor_dispatch(s,intent,bridge_executor_physical_clock(nil),socket,request,
        &physical,bridge_executor_physical_fence,nil,bridge_executor_physical_clock,bridge_executor_physical_fence)
    return delivered && reason=="child_present",reason
}

Executor_Activation_Dispatch :: #type proc(^executor.Store,string,json.Object,contracts.Owner_Verified_Key,contracts.Owner_Verified_Key,^vault.Vault_Keyring,i64,rawptr,Executor_Fence_Exchange,Executor_Launch_IO)->(bool,string)
