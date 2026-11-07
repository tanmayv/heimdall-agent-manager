package main

import "base:runtime"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// Hold the dispatcher lock for the entire fixture; live workers cannot observe
// test claims or mutate the snapshot while the real globals are replaced.
@(test)
bridge_legacy_dispatch_snapshot_rejects_changed_or_unknown_memory :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_dispatch_mu);defer sync.mutex_unlock(&bridge_dispatch_mu)
    saved_claims:=bridge_dispatch_claims
    saved_workers:=bridge_dispatch_workers
    bridge_dispatch_workers={}
    saved_queues:=[7][dynamic]Bridge_Dispatch_Job{
        bridge_dispatch_lifecycle,bridge_dispatch_interactive,
        bridge_dispatch_background,bridge_dispatch_exclusive,
        bridge_dispatch_general_io,bridge_dispatch_shell,
        bridge_dispatch_model_discovery,
    }
    bridge_dispatch_lifecycle=make([dynamic]Bridge_Dispatch_Job)
    bridge_dispatch_interactive=nil;bridge_dispatch_background=nil
    bridge_dispatch_exclusive=nil;bridge_dispatch_general_io=nil
    bridge_dispatch_shell=nil;bridge_dispatch_model_discovery=nil
    saved_revision:=bridge_dispatch_observation_revision
    saved_generation:=bridge_dispatch_generation
    saved_initialized:=bridge_dispatch_initialized
    saved_exhausted:=bridge_dispatch_observation_exhausted
    defer {
        delete(bridge_dispatch_claims)
        delete(bridge_dispatch_lifecycle)
        bridge_dispatch_lifecycle=saved_queues[0];bridge_dispatch_interactive=saved_queues[1]
        bridge_dispatch_background=saved_queues[2];bridge_dispatch_exclusive=saved_queues[3]
        bridge_dispatch_general_io=saved_queues[4];bridge_dispatch_shell=saved_queues[5]
        bridge_dispatch_model_discovery=saved_queues[6]
        bridge_dispatch_claims=saved_claims
        for worker in bridge_dispatch_workers {
            delete(worker.current_command_id,runtime.default_allocator())
            delete(worker.current_input_digest,runtime.default_allocator())
        }
        bridge_dispatch_workers=saved_workers
        bridge_dispatch_observation_revision=saved_revision
        bridge_dispatch_generation=saved_generation
        bridge_dispatch_initialized=saved_initialized
        bridge_dispatch_observation_exhausted=saved_exhausted
    }
    bridge_dispatch_claims=make([dynamic]Bridge_Dispatch_Claim)
    bridge_dispatch_observation_revision=1
    bridge_dispatch_generation=7
    bridge_dispatch_initialized=false
    bridge_dispatch_observation_exhausted=false
    unopened:=bridge_legacy_dispatch_snapshot_locked()
    testing.expect(t,!unopened.valid,"uninitialized memory is not an empty verified inventory")
    bridge_dispatch_initialized=true
    empty:=bridge_legacy_dispatch_snapshot_locked()
    testing.expect(t,empty.valid && bridge_legacy_dispatch_current_locked(empty))
    packet:=`{"type":"wake_agent","command_id":"cmd","payload":{"run":[]}}`
    raw:=contracts.owner_payload_digest(packet)
    append(&bridge_dispatch_lifecycle,Bridge_Dispatch_Job{command_id="cmd",text=packet,generation=7})
    append(&bridge_dispatch_claims,Bridge_Dispatch_Claim{command_id="cmd",input_digest=raw,state=.Queued})
    bridge_dispatch_observation_changed_locked()
    queued:=bridge_legacy_dispatch_snapshot_locked()
    testing.expect(t,queued.valid)
    testing.expect_value(t,queued.queued,1)
    testing.expect_value(t,queued.running,0)
    testing.expect(t,!bridge_legacy_dispatch_current_locked(empty))
    bridge_dispatch_lifecycle[0].text="substituted queue packet"
    testing.expect(t,!bridge_legacy_dispatch_snapshot_locked().valid,"claim projection cannot hide changed actual queue bytes")
    bridge_dispatch_lifecycle[0].text=packet
    // A running projection without actual worker ownership is unknown. The
    // production take path now binds both under this same dispatch lock.
    clear(&bridge_dispatch_lifecycle)
    bridge_dispatch_claims[0].state=.Running
    bridge_dispatch_observation_changed_locked()
    testing.expect(t,!bridge_legacy_dispatch_snapshot_locked().valid,"running claim alone is not independent worker evidence")
    bridge_command_dispatch_bind_worker_locked(&bridge_dispatch_workers[0],Bridge_Dispatch_Job{text=packet,command_id="cmd",generation=7})
    running:=bridge_legacy_dispatch_snapshot_locked()
    testing.expect(t,running.valid)
    testing.expect_value(t,running.queued,0)
    testing.expect_value(t,running.running,1)
    testing.expect(t,!bridge_legacy_dispatch_current_locked(queued))
    bridge_dispatch_workers[0].current_legacy_action.id=42
    testing.expect(t,!bridge_legacy_dispatch_current_locked(running),"worker native occurrence is part of memory currentness")
    bridge_dispatch_workers[0].current_legacy_action={}
    bridge_dispatch_claims[0].input_digest=contracts.owner_payload_digest("changed raw packet")
    testing.expect(t,!bridge_legacy_dispatch_current_locked(running),"same ID cannot mask different raw bytes")
    bridge_dispatch_claims[0].input_digest=""
    testing.expect(t,!bridge_legacy_dispatch_snapshot_locked().valid,"old claims with missing evidence remain unknown")
    delete(bridge_dispatch_workers[0].current_command_id,runtime.default_allocator())
    delete(bridge_dispatch_workers[0].current_input_digest,runtime.default_allocator())
    bridge_dispatch_workers[0]={}
    clear(&bridge_dispatch_claims)
    bridge_dispatch_observation_changed_locked()
    after:=bridge_legacy_dispatch_snapshot_locked()
    testing.expect_value(t,after.digest,empty.digest)
    testing.expect(t,!bridge_legacy_dispatch_current_locked(empty),"empty -> work -> empty must reject old memory CAS")
    bridge_dispatch_generation+=1
    testing.expect(t,!bridge_legacy_dispatch_current_locked(after),"reconnect invalidates memory observation")
    bridge_dispatch_observation_revision=0x7fffffffffffffff
    bridge_dispatch_observation_changed_locked()
    testing.expect(t,!bridge_legacy_dispatch_snapshot_locked().valid,"overflow cannot recycle a current observation")
}
