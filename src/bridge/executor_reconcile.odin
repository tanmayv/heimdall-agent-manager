package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"

bridge_executor_local_reconcile_after:string

// Bounded safety work only: there is no launch or owner-task mutation here.
// Unknown daemon results retain the device charge and are revisited next sweep.
// The caller holds bridge_executor_mutex; only exact local daemon I/O runs here.
bridge_executor_reconcile_batch :: proc(s:^executor.Store,now:i64,socket,after:string,
    clock_ctx:rawptr=nil,clock:Executor_Now=bridge_executor_physical_clock)->(next:string,ok:bool) {
    if clock==nil || !executor.expire(s,now) do return after,false
    candidates,read:=executor.reconcile_candidates(s,after,executor.RECONCILE_BATCH_MAX)
    if !read do return after,false
    next=""
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    for intent in candidates {
        if !executor.expire(s,clock(clock_ctx)) do return after,false
        stop,current:=executor.reconcile_current(s,intent)
        next=intent.reservation
        if !current do continue
        if stop do _=bridge_pty_host_executor_close(socket,intent.instance,intent.launch_key)
        _,_=bridge_executor_observe_dispatch(s,intent,socket)
    }
    _=executor.complete_recovery(s,clock(clock_ctx))
    return next,true
}

bridge_executor_reconcile_once :: proc(after:string)->(string,bool) {
    context.allocator=context.temp_allocator
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key,valid:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !valid || account=="" do return after,false
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,key) do return after,false
    socket:=pty_host_socket_path();defer delete(socket)
    next,read:=bridge_executor_reconcile_batch(&bridge_executor_store,bridge_executor_physical_clock(nil),socket,after)
    sync.mutex_lock(&bridge_startup_io_mutex)
    local_next,local_read:=bridge_executor_local_reconcile_batch(&bridge_executor_store,socket,bridge_executor_local_reconcile_after)
    if local_read {
        delete(bridge_executor_local_reconcile_after,runtime.default_allocator())
        bridge_executor_local_reconcile_after=strings.clone(local_next,runtime.default_allocator())
    }
    sync.mutex_unlock(&bridge_startup_io_mutex)
    return next,read && local_read
}
bridge_executor_reconcile_worker :: proc() {
    after:string
    defer delete(after,runtime.default_allocator())
    for {
        if sync.atomic_load(&bridge_hub_traffic_stopped) do return
        next,read:=bridge_executor_reconcile_once(after)
        if read {
            delete(after,runtime.default_allocator())
            after=strings.clone(next,runtime.default_allocator())
        }
        free_all(context.temp_allocator)
        time.sleep(time.Second)
    }
}
bridge_executor_reconcile_start :: proc() {thread.run(bridge_executor_reconcile_worker)}
