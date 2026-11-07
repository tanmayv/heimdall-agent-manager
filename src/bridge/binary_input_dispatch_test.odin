package main

import "base:runtime"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

@(test)
bridge_binary_input_retains_native_bytes_off_reader_and_refuses_barrier :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator=context.temp_allocator
    store,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(store,path)
    sync.mutex_lock(&bridge_dispatch_mu)
    saved_queues:=[7][dynamic]Bridge_Dispatch_Job{}
    for queue,i in bridge_legacy_dispatch_queues_locked() {saved_queues[i]=queue^;queue^=nil}
    saved_claims:=bridge_dispatch_claims
    saved_outputs:=bridge_dispatch_outputs
    saved_outbox:=bridge_dispatch_outbox_bytes
    saved_mcp_bytes,saved_mcp_outbox:=bridge_dispatch_mcp_large_bytes,bridge_dispatch_mcp_large_outbox_bytes
    saved_workers:=bridge_dispatch_workers
    saved_keys:=bridge_dispatch_active_keys
    saved_metrics:=bridge_dispatch_metrics
    saved_owned,saved_cost:=bridge_dispatch_owned_bytes,bridge_dispatch_queued_cost
    saved_revision:=bridge_dispatch_observation_revision
    saved_failed:=bridge_legacy_ingress_failed
    saved_generation:=bridge_dispatch_generation
    saved_daemon:=bridge_config.daemon_id
    bridge_dispatch_claims=make([dynamic]Bridge_Dispatch_Claim,runtime.default_allocator())
    bridge_dispatch_shell=make([dynamic]Bridge_Dispatch_Job,runtime.default_allocator())
    bridge_dispatch_active_keys=nil
    bridge_dispatch_workers={}
    bridge_dispatch_outputs=nil;bridge_dispatch_outbox_bytes=0
    bridge_dispatch_mcp_large_bytes=0;bridge_dispatch_mcp_large_outbox_bytes=0
    bridge_dispatch_owned_bytes=0;bridge_dispatch_queued_cost=0
    bridge_dispatch_generation=7
    bridge_config.daemon_id="paired"
    sync.mutex_unlock(&bridge_dispatch_mu)
    defer {
        sync.mutex_lock(&bridge_dispatch_mu)
        for job in bridge_dispatch_shell {
            delete(job.text,runtime.default_allocator());delete(job.command_id,runtime.default_allocator())
            delete(job.command_type,runtime.default_allocator());delete(job.ordering_key,runtime.default_allocator())
        }
        delete(bridge_dispatch_shell)
        for claim in bridge_dispatch_claims {
            delete(claim.command_id,runtime.default_allocator());delete(claim.input_digest,runtime.default_allocator());delete(claim.result_json,runtime.default_allocator())
        }
        delete(bridge_dispatch_claims)
        for output in bridge_dispatch_outputs do delete(output.text,runtime.default_allocator())
        delete(bridge_dispatch_outputs)
        bridge_dispatch_outputs=saved_outputs;bridge_dispatch_outbox_bytes=saved_outbox
        bridge_dispatch_mcp_large_bytes=saved_mcp_bytes;bridge_dispatch_mcp_large_outbox_bytes=saved_mcp_outbox
        for queue,i in bridge_legacy_dispatch_queues_locked() do queue^=saved_queues[i]
        bridge_dispatch_claims=saved_claims;bridge_dispatch_workers=saved_workers;bridge_dispatch_active_keys=saved_keys
        bridge_dispatch_metrics=saved_metrics;bridge_dispatch_owned_bytes=saved_owned;bridge_dispatch_queued_cost=saved_cost
        bridge_dispatch_observation_revision=saved_revision;bridge_legacy_ingress_failed=saved_failed
        bridge_dispatch_generation=saved_generation;bridge_config.daemon_id=saved_daemon
        sync.mutex_unlock(&bridge_dispatch_mu)
    }
    original:=contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT,contracts.PTY_WIRE_FLAG_ENCRYPTED,"exact_target",[]byte{0,255,3,0,128},context.temp_allocator)
    expected:=contracts.owner_payload_digest(transmute(string)original)
    // The actual reader entry returns while executor/journal I/O is blocked.
    sync.mutex_lock(&bridge_executor_mutex)
    accepted:=bridge_command_dispatch_binary_input(nil,original,7)
    sync.mutex_unlock(&bridge_executor_mutex)
    testing.expect(t,accepted && len(bridge_dispatch_shell)==1)
    testing.expect(t,bridge_dispatch_shell[0].native_binary && bridge_dispatch_shell[0].legacy_ingress==.Pending)
    testing.expect(t,bridge_dispatch_shell[0].ordering_key=="shell:exact_target")
    original[len(original)-1]=42
    testing.expect(t,contracts.owner_payload_digest(bridge_dispatch_shell[0].text)==expected,"queued bytes are owned")
    // Reconnect cannot erase the unrecorded binary interval.
    sync.mutex_lock(&bridge_dispatch_mu)
    bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_shell,8)
    _,early:=bridge_command_dispatch_take_queue_locked(&bridge_dispatch_shell)
    sync.mutex_unlock(&bridge_dispatch_mu)
    testing.expect(t,!early && len(bridge_dispatch_shell)==1)
    testing.expect(t,bridge_legacy_dispatch_ingress_once(store))
    rows,read:=executor.query(store.db,"SELECT command_id,chain_claim,command_kind,packet_digest,state FROM executor_legacy_actions")
    testing.expect(t,read && len(rows)==1 && rows[0][0]=="" && rows[0][1]=="" && rows[0][2]==BRIDGE_DISPATCH_BINARY_INPUT_KIND && rows[0][3]==expected && rows[0][4]=="prepared")
    barrier:=executor.Legacy_Barrier{"source","migration",contracts.owner_payload_digest("selection"),0}
    testing.expect_value(t,bridge_legacy_install_barrier(store,barrier,[]executor.Legacy_Resource{{"instance","other_claim"}}).code,"ok")
    worker:=&bridge_dispatch_workers[0]
    job,taken:=bridge_command_dispatch_take(.Shell,worker)
    testing.expect(t,taken && job.native_binary && worker.current_native_binary)
    testing.expect(t,!bridge_legacy_dispatch_start(&job,store) && job.legacy_start_fenced)
    testing.expect(t,bridge_legacy_dispatch_end(job.legacy_action,false,store))
    owned_bytes:=bridge_dispatch_owned_bytes
    testing.expect(t,owned_bytes>0)
    bridge_command_dispatch_finish(worker,&job)
    testing.expect(t,bridge_dispatch_owned_bytes==0 && bridge_dispatch_queued_cost==0)
    testing.expect(t,len(bridge_dispatch_outputs)==0,"ack-less binary input creates no command results")
    rows,read=executor.query(store.db,"SELECT state FROM executor_legacy_actions")
    testing.expect(t,read && rows[0][0]=="discarded")
    spec,known:=bridge_command_spec(BRIDGE_DISPATCH_BINARY_INPUT_KIND)
    testing.expect(t,!known && !spec.queued,"private binary discriminator is not a JSON wire command")
}

@(test)
bridge_binary_input_ordering_and_bounds_keep_native_transport :: proc(t:^testing.T) {
    key:=bridge_command_ordering_key("shell_pty_input",`{"agent_instance_id":"alias_target"}`)
    defer delete(key)
    testing.expect_value(t,key,"shell:alias_target")
    saved:=sync.atomic_load(&bridge_dispatch_binary_input_counter)
    sync.atomic_store(&bridge_dispatch_binary_input_counter,u64(0xffffffffffffffff))
    defer sync.atomic_store(&bridge_dispatch_binary_input_counter,saved)
    frame:=contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT,0,"target",[]byte{1})
    defer delete(frame)
    testing.expect(t,!bridge_command_dispatch_binary_input(nil,frame,1),"exhausted native handles never wrap")
    testing.expect(t,!bridge_command_dispatch_binary_input(nil,[]byte{1,2},1),"malformed native header is not converted to JSON")
    large:=make([]byte,BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT+1)
    defer delete(large)
    testing.expect(t,!bridge_command_dispatch_binary_input(nil,large,1),"reader enforces the existing bounded command byte budget")
}

@(test)
bridge_raw_input_rechecks_barrier_after_dispatch_start :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    store,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(store,path)
    packet:=`{"type":"shell_pty_input","shell_id":"shell"}`
    spec,known:=bridge_command_spec("shell_pty_input")
    testing.expect(t,known)
    action,prepared:=bridge_legacy_dispatch_prepare(packet,"shell_pty_input",spec,store)
    testing.expect(t,prepared)
    job:=Bridge_Dispatch_Job{text=packet,command_type="shell_pty_input",legacy_action=action}
    testing.expect(t,bridge_legacy_dispatch_start(&job,store))
    barrier:=executor.Legacy_Barrier{"source","migration",contracts.owner_payload_digest("selection"),0}
    testing.expect_value(t,bridge_legacy_install_barrier(store,barrier,[]executor.Legacy_Resource{{"instance","other"}}).code,"ok")
    delivered,refused:=bridge_legacy_shell_input("shell","original input",store,"/nonexistent/must-not-write")
    testing.expect(t,!delivered && refused,"a prior running observation cannot bypass the physical barrier")
    delivered,refused=bridge_legacy_shell_delivery({kind=.Resize,target="shell",rows=40,cols=120},store,"/nonexistent/must-not-write")
    testing.expect(t,!delivered && refused,"shell resize also rechecks the physical barrier")
    testing.expect(t,bridge_legacy_dispatch_end(action,true,store))
}
