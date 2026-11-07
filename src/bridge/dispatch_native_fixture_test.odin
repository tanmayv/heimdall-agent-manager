package main

import "base:runtime"
import "core:sync"
import "core:testing"
import executor "odin_test:lib/executor_local"

// Isolate native queue/worker tests without starting immortal dispatcher threads.
// Test commands still use the production admission, ingress, take and execute.
Bridge_Test_Dispatch_State :: struct {
    queues:[7][dynamic]Bridge_Dispatch_Job,
    claims:[dynamic]Bridge_Dispatch_Claim,
    workers:[len(BRIDGE_DISPATCH_WORKER_CLASSES)]Bridge_Dispatch_Worker,
    keys:[dynamic]string,
    outputs:[dynamic]Bridge_Dispatch_Output,
    metrics:Bridge_Dispatch_Metrics,
    owned,cost,outbox,mcp_bytes,mcp_outbox:int,
    revision,generation:i64,
    failed:bool,
}

bridge_test_dispatch_save :: proc()->Bridge_Test_Dispatch_State {
    sync.mutex_lock(&bridge_dispatch_mu);defer sync.mutex_unlock(&bridge_dispatch_mu)
    saved:=Bridge_Test_Dispatch_State{
        claims=bridge_dispatch_claims,workers=bridge_dispatch_workers,
        keys=bridge_dispatch_active_keys,outputs=bridge_dispatch_outputs,metrics=bridge_dispatch_metrics,
        owned=bridge_dispatch_owned_bytes,cost=bridge_dispatch_queued_cost,outbox=bridge_dispatch_outbox_bytes,
        mcp_bytes=bridge_dispatch_mcp_large_bytes,mcp_outbox=bridge_dispatch_mcp_large_outbox_bytes,
        revision=bridge_dispatch_observation_revision,generation=bridge_dispatch_generation,failed=bridge_legacy_ingress_failed,
    }
    for queue,index in bridge_legacy_dispatch_queues_locked() {saved.queues[index]=queue^;queue^=make([dynamic]Bridge_Dispatch_Job,runtime.default_allocator())}
    bridge_dispatch_claims=make([dynamic]Bridge_Dispatch_Claim,runtime.default_allocator())
    bridge_dispatch_workers={}
    bridge_dispatch_active_keys=make([dynamic]string,runtime.default_allocator())
    bridge_dispatch_outputs=make([dynamic]Bridge_Dispatch_Output,runtime.default_allocator())
    bridge_dispatch_owned_bytes=0;bridge_dispatch_queued_cost=0;bridge_dispatch_outbox_bytes=0
    bridge_dispatch_mcp_large_bytes=0;bridge_dispatch_mcp_large_outbox_bytes=0
    bridge_dispatch_generation=7;bridge_legacy_ingress_failed=false
    return saved
}

bridge_test_binary_execute :: proc(t:^testing.T,store:^executor.Store,frame:[]byte)->(executor.Legacy_Action,bool) {
    if !testing.expect(t,bridge_command_dispatch_binary_input(nil,frame,7)) do return {},false
    if !testing.expect(t,bridge_legacy_dispatch_ingress_once(store)) do return {},false
    worker:=&bridge_dispatch_workers[0]
    job,taken:=bridge_command_dispatch_take(.Shell,worker)
    if !testing.expect(t,taken && job.native_binary) do return {},false
    action:=job.legacy_action
    bridge_command_dispatch_execute(worker,&job,store)
    return action,job.legacy_start_fenced
}

bridge_test_dispatch_restore :: proc(saved:Bridge_Test_Dispatch_State) {
    sync.mutex_lock(&bridge_dispatch_mu);defer sync.mutex_unlock(&bridge_dispatch_mu)
    for queue,index in bridge_legacy_dispatch_queues_locked() {
        for job in queue {
            delete(job.text,runtime.default_allocator());delete(job.command_id,runtime.default_allocator())
            delete(job.command_type,runtime.default_allocator());delete(job.ordering_key,runtime.default_allocator())
        }
        delete(queue^)
        queue^=saved.queues[index]
    }
    for claim in bridge_dispatch_claims {
        delete(claim.command_id,runtime.default_allocator());delete(claim.input_digest,runtime.default_allocator());delete(claim.result_json,runtime.default_allocator())
    }
    delete(bridge_dispatch_claims)
    for worker in bridge_dispatch_workers {
        delete(worker.current_command_id,runtime.default_allocator());delete(worker.current_input_digest,runtime.default_allocator());delete(worker.last_result,runtime.default_allocator())
    }
    for key in bridge_dispatch_active_keys do delete(key,runtime.default_allocator())
    delete(bridge_dispatch_active_keys)
    for output in bridge_dispatch_outputs do delete(output.text,runtime.default_allocator())
    delete(bridge_dispatch_outputs)
    bridge_dispatch_claims=saved.claims;bridge_dispatch_workers=saved.workers
    bridge_dispatch_active_keys=saved.keys;bridge_dispatch_outputs=saved.outputs;bridge_dispatch_metrics=saved.metrics
    bridge_dispatch_owned_bytes=saved.owned;bridge_dispatch_queued_cost=saved.cost;bridge_dispatch_outbox_bytes=saved.outbox
    bridge_dispatch_mcp_large_bytes=saved.mcp_bytes;bridge_dispatch_mcp_large_outbox_bytes=saved.mcp_outbox
    bridge_dispatch_observation_revision=saved.revision;bridge_dispatch_generation=saved.generation;bridge_legacy_ingress_failed=saved.failed
}
