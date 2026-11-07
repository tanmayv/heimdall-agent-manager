package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import executor "odin_test:lib/executor_local"

// Private dispatcher state, not a wire grant or migration completeness claim.
// Pending/Writing jobs retain their original bytes and all admission budgets.
Bridge_Legacy_Ingress_State :: enum { None, Pending, Writing, Ready, Failed }
bridge_legacy_ingress_failed: bool

bridge_legacy_dispatch_queues_locked :: proc()->[7]^[dynamic]Bridge_Dispatch_Job {
    return [7]^[dynamic]Bridge_Dispatch_Job{
        &bridge_dispatch_lifecycle,&bridge_dispatch_interactive,
        &bridge_dispatch_background,&bridge_dispatch_exclusive,
        &bridge_dispatch_general_io,&bridge_dispatch_shell,
        &bridge_dispatch_model_discovery,
    }
}

// Caller holds dispatch mutex. Clones are bounded by one admitted command.
// Reconnect retains the queue entry until this exact write attempt completes.
bridge_legacy_ingress_take_queue_locked :: proc(queue:^[dynamic]Bridge_Dispatch_Job)->(Bridge_Dispatch_Job,bool) {
    for &job in queue {
        if job.legacy_ingress!=.Pending do continue
        job.legacy_ingress=.Writing
        bridge_dispatch_observation_changed_locked()
        return Bridge_Dispatch_Job{
            native_binary=job.native_binary,
            text=strings.clone(job.text,runtime.default_allocator()),
            command_type=strings.clone(job.command_type,runtime.default_allocator()),
            command_id=strings.clone(job.command_id,runtime.default_allocator()),
        },true
    }
    return {},false
}

bridge_legacy_ingress_complete_queue_locked :: proc(queue:^[dynamic]Bridge_Dispatch_Job,id:string,action:executor.Legacy_Action,recorded:bool)->bool {
    for &job in queue {
        if job.command_id!=id || job.legacy_ingress!=.Writing do continue
        job.legacy_action=action
        job.legacy_ingress=.Ready if recorded else .Failed
        if !recorded do bridge_legacy_ingress_failed=true
        bridge_dispatch_observation_changed_locked()
        return true
    }
    return false
}

// One dedicated writer may wait for executor/journal I/O, never the reader or
// dispatch lock. Jobs cannot execute, expire or disappear while it writes.
bridge_legacy_dispatch_ingress_once :: proc(injected:^executor.Store=nil)->bool {
    work:Bridge_Dispatch_Job
    found:=false
    sync.mutex_lock(&bridge_dispatch_mu)
    for queue in bridge_legacy_dispatch_queues_locked() {
        work,found=bridge_legacy_ingress_take_queue_locked(queue)
        if found do break
    }
    sync.mutex_unlock(&bridge_dispatch_mu)
    if !found do return false
    defer delete(work.text,runtime.default_allocator())
    defer delete(work.command_type,runtime.default_allocator())
    defer delete(work.command_id,runtime.default_allocator())
    spec,known:=bridge_command_spec(work.command_type)
    if work.native_binary && work.command_type==BRIDGE_DISPATCH_BINARY_INPUT_KIND {spec=bridge_command_binary_input_spec();known=true}
    action:executor.Legacy_Action
    recorded:=false
    if known {
        action,recorded=bridge_legacy_dispatch_prepare(work.text,work.command_type,spec,injected)
        // Losing configured identity after admission cannot turn paired work
        // into pre-enrollment compatibility or an unobserved runnable job.
        recorded=recorded && action.id>0
    }
    sync.mutex_lock(&bridge_dispatch_mu)
    completed:=false
    for queue in bridge_legacy_dispatch_queues_locked() {
        if bridge_legacy_ingress_complete_queue_locked(queue,work.command_id,action,recorded) {
            completed=true
            break
        }
    }
    if !completed do bridge_legacy_ingress_failed=true
    sync.mutex_unlock(&bridge_dispatch_mu)
    return true
}

bridge_legacy_dispatch_ingress_worker :: proc(_:rawptr) {
    for {
        if !bridge_legacy_dispatch_ingress_once() do time.sleep(5*time.Millisecond)
        free_all(context.temp_allocator)
    }
}

bridge_legacy_dispatch_job_stale :: proc(job:Bridge_Dispatch_Job)->bool {
    sync.mutex_lock(&bridge_dispatch_mu);defer sync.mutex_unlock(&bridge_dispatch_mu)
    return job.generation!=bridge_dispatch_generation
}
