package main

import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import executor "odin_test:lib/executor_local"

bridge_legacy_ingress_test_writer :: proc(data:rawptr) {
    _=bridge_legacy_dispatch_ingress_once((^executor.Store)(data))
    free_all(context.temp_allocator)
}

@(test)
bridge_legacy_ingress_retains_reconnect_and_deadline_before_worker :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    store,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(store,path)
    sync.mutex_lock(&bridge_dispatch_mu)
    saved_queues:=[7][dynamic]Bridge_Dispatch_Job{}
    queues:=bridge_legacy_dispatch_queues_locked()
    for queue,i in queues {saved_queues[i]=queue^;queue^=nil}
    saved_revision:=bridge_dispatch_observation_revision
    saved_failed:=bridge_legacy_ingress_failed
    saved_generation:=bridge_dispatch_generation
    saved_keys:=bridge_dispatch_active_keys
    bridge_dispatch_active_keys=nil
    bridge_dispatch_generation=8
    bridge_legacy_ingress_failed=false
    bridge_dispatch_lifecycle=make([dynamic]Bridge_Dispatch_Job)
    defer {
        sync.mutex_lock(&bridge_dispatch_mu)
        delete(bridge_dispatch_lifecycle)
        for queue,i in bridge_legacy_dispatch_queues_locked() do queue^=saved_queues[i]
        bridge_dispatch_observation_revision=saved_revision
        bridge_dispatch_generation=saved_generation
        bridge_dispatch_active_keys=saved_keys
        bridge_legacy_ingress_failed=saved_failed
        sync.mutex_unlock(&bridge_dispatch_mu)
    }
    packet:=`{"type":"wake_agent","payload":{"run":[]}}`
    append(&bridge_dispatch_lifecycle,Bridge_Dispatch_Job{
        text=packet,command_id="synthetic_queue_only",command_type="wake_agent",
        generation=7,paired_observation_required=true,legacy_ingress=.Pending,
    })
    _,early:=bridge_command_dispatch_take_queue_locked(&bridge_dispatch_lifecycle)
    testing.expect(t,!early,"worker cannot run pending ingress")
    bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_lifecycle,8)
    testing.expect(t,len(bridge_dispatch_lifecycle)==1,"reconnect preserves unrecorded native bytes")
    sync.mutex_unlock(&bridge_dispatch_mu)
    // Exercise the production writer with executor I/O deliberately blocked.
    // The reader must still acquire dispatch, process reconnect, and return.
    sync.mutex_lock(&bridge_executor_mutex)
    writer:=thread.create_and_start_with_data(rawptr(store),bridge_legacy_ingress_test_writer)
    observed_writing:=false
    started:=time.tick_now()
    for time.tick_since(started)<5*time.Second {
        sync.mutex_lock(&bridge_dispatch_mu)
        observed_writing=bridge_dispatch_lifecycle[0].legacy_ingress==.Writing
        if observed_writing {
            bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_lifecycle,8)
            _,runnable:=bridge_command_dispatch_take_queue_locked(&bridge_dispatch_lifecycle)
            testing.expect(t,!runnable && len(bridge_dispatch_lifecycle)==1)
        }
        sync.mutex_unlock(&bridge_dispatch_mu)
        if observed_writing do break
        time.sleep(time.Millisecond)
    }
    sync.mutex_unlock(&bridge_executor_mutex)
    thread.join(writer)
    thread.destroy(writer)
    testing.expect(t,observed_writing,"reader stays responsive while the dedicated writer waits for executor I/O")
    rows,read:=executor.query(store.db,"SELECT command_id,chain_claim,state FROM executor_legacy_actions")
    testing.expect(t,read && len(rows)==1 && rows[0][0]=="" && rows[0][1]=="" && rows[0][2]=="prepared",
        "journal records original idless/unscoped ingress, never synthetic ID")
    sync.mutex_lock(&bridge_dispatch_mu)
    bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_lifecycle,8)
    testing.expect(t,len(bridge_dispatch_lifecycle)==1,"recorded stale job awaits explicit discard")
    stale,taken:=bridge_command_dispatch_take_queue_locked(&bridge_dispatch_lifecycle)
    sync.mutex_unlock(&bridge_dispatch_mu)
    testing.expect(t,taken && bridge_legacy_dispatch_job_stale(stale))
    testing.expect(t,bridge_legacy_dispatch_end(stale.legacy_action,false,store))

    sync.mutex_lock(&bridge_dispatch_mu)
    append(&bridge_dispatch_lifecycle,Bridge_Dispatch_Job{
        text=packet,command_id="expired",command_type="wake_agent",generation=8,
        deadline_ns=1,paired_observation_required=true,legacy_ingress=.Pending,
    })
    sync.mutex_unlock(&bridge_dispatch_mu)
    testing.expect(t,bridge_legacy_dispatch_ingress_once(store))
    sync.mutex_lock(&bridge_dispatch_mu)
    expired,expired_taken:=bridge_command_dispatch_take_queue_locked(&bridge_dispatch_lifecycle)
    sync.mutex_unlock(&bridge_dispatch_mu)
    testing.expect(t,expired_taken && bridge_command_deadline_expired(expired.deadline_ns))
    testing.expect(t,bridge_legacy_dispatch_end(expired.legacy_action,false,store))
    rows,read=executor.query(store.db,"SELECT state FROM executor_legacy_actions ORDER BY action_id")
    testing.expect(t,read && len(rows)==2 && rows[0][0]=="discarded" && rows[1][0]=="discarded",
        "reconnect and deadline leave durable explicit handler nonexecution")

    testing.expect(t,executor.exec(store.db,"CREATE TRIGGER refuse_ingress BEFORE INSERT ON executor_legacy_actions BEGIN SELECT RAISE(ABORT,'storage fault'); END;"))
    sync.mutex_lock(&bridge_dispatch_mu)
    append(&bridge_dispatch_lifecycle,Bridge_Dispatch_Job{
        text=packet,command_id="failed",command_type="wake_agent",generation=8,
        paired_observation_required=true,legacy_ingress=.Pending,
    })
    sync.mutex_unlock(&bridge_dispatch_mu)
    testing.expect(t,bridge_legacy_dispatch_ingress_once(store))
    sync.mutex_lock(&bridge_dispatch_mu)
    failed,failed_taken:=bridge_command_dispatch_take_queue_locked(&bridge_dispatch_lifecycle)
    testing.expect(t,bridge_legacy_ingress_failed && !bridge_legacy_dispatch_snapshot_locked().valid,
        "failure poisons current coverage even when failed job leaves queue")
    sync.mutex_unlock(&bridge_dispatch_mu)
    testing.expect(t,failed_taken && failed.legacy_ingress==.Failed)
    testing.expect(t,executor.exec(store.db,"DROP TRIGGER refuse_ingress"))
    testing.expect(t,!bridge_legacy_dispatch_start(&failed,store),"later storage recovery cannot silently run failed ingress")
    rows,read=executor.query(store.db,"SELECT COUNT(*) FROM executor_legacy_actions")
    testing.expect(t,read && rows[0][0]=="2","failure does not manufacture another observation at worker start")
}

@(test)
bridge_legacy_ingress_writing_survives_reconnect_and_blocks_worker :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    queue:=make([dynamic]Bridge_Dispatch_Job);defer delete(queue)
    sync.mutex_lock(&bridge_dispatch_mu);defer sync.mutex_unlock(&bridge_dispatch_mu)
    saved_revision:=bridge_dispatch_observation_revision
    saved_failed:=bridge_legacy_ingress_failed
    defer {bridge_dispatch_observation_revision=saved_revision;bridge_legacy_ingress_failed=saved_failed}
    append(&queue,Bridge_Dispatch_Job{
        text=`{"type":"stop_agent","command_id":"stop"}`,command_id="stop",command_type="stop_agent",
        generation=2,paired_observation_required=true,legacy_ingress=.Pending,
    })
    work,taken:=bridge_legacy_ingress_take_queue_locked(&queue)
    testing.expect(t,taken && queue[0].legacy_ingress==.Writing)
    defer delete(work.text,runtime.default_allocator())
    defer delete(work.command_id,runtime.default_allocator())
    defer delete(work.command_type,runtime.default_allocator())
    bridge_command_dispatch_drop_stale_queue_locked(&queue,3)
    testing.expect_value(t,len(queue),1)
    _,runnable:=bridge_command_dispatch_take_queue_locked(&queue)
    testing.expect(t,!runnable,"I/O in progress cannot race worker take on reconnect")
    testing.expect(t,!bridge_legacy_ingress_complete_queue_locked(&queue,"other",{},true))
    testing.expect(t,bridge_legacy_ingress_complete_queue_locked(&queue,work.command_id,{},false))
    testing.expect(t,queue[0].legacy_ingress==.Failed && bridge_legacy_ingress_failed)
}
