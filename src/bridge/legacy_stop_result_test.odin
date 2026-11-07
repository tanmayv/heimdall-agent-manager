package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
bridge_legacy_wake_unknown_stop_reports_failure_without_idle_projection :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    store,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(store,path)
    packet:=`{"type":"wake_agent","command_id":"wake_unresolved","payload":{"run":[],"stop":["inst_unadmitted_wake_stop"]}}`
    spec,_:=bridge_command_spec("wake_agent")
    action,prepared:=bridge_legacy_dispatch_prepare(packet,"wake_agent",spec,store)
    testing.expect(t,prepared)
    job:=Bridge_Dispatch_Job{text=packet,command_type="wake_agent",legacy_action=action}
    testing.expect(t,bridge_legacy_dispatch_start(&job,store))
    sync.mutex_lock(&bridge_dispatch_mu)
    saved_worker:=bridge_dispatch_workers[0]
    saved_outputs:=bridge_dispatch_outputs
    saved_bytes:=bridge_dispatch_outbox_bytes
    bridge_dispatch_outputs=make([dynamic]Bridge_Dispatch_Output,runtime.default_allocator())
    bridge_dispatch_outbox_bytes=0
    worker:=&bridge_dispatch_workers[0]
    worker^={current_command_id=strings.clone("wake_unresolved",runtime.default_allocator()),current_generation=1}
    sync.mutex_unlock(&bridge_dispatch_mu)
    defer {
        sync.mutex_lock(&bridge_dispatch_mu)
        delete(worker.current_command_id,runtime.default_allocator())
        delete(worker.last_result,runtime.default_allocator())
        for output in bridge_dispatch_outputs do delete(output.text,runtime.default_allocator())
        delete(bridge_dispatch_outputs)
        worker^=saved_worker
        bridge_dispatch_outputs=saved_outputs
        bridge_dispatch_outbox_bytes=saved_bytes
        sync.mutex_unlock(&bridge_dispatch_mu)
    }
    bridge_hub_handle_wake_agent(&worker.sink_conn,packet,store,action)
    testing.expect(t,strings.contains(worker.last_result,`"status":"failed"`) && strings.contains(worker.last_result,`"cause":"stop_failed"`),
        "an unresolved stop cannot report succeeded to its source")
    status,activity,found:=bridge_runtime_status_snapshot("inst_unadmitted_wake_stop")
    defer delete(status);defer delete(activity)
    testing.expect(t,!found,"unobserved child cannot acquire stopped/idle status")
    testing.expect(t,bridge_legacy_dispatch_end(action,true,store))
}
