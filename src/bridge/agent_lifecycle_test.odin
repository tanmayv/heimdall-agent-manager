package main

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import jsonx "../lib/jsonx"

@(test)
bridge_stop_receipt_identifies_exact_process_generation :: proc(t: ^testing.T) {
    receipt := bridge_stop_confirmed_json("stop_7", "inst_old", 7)
    defer delete(receipt)
    testing.expect_value(t, jsonx.extract_string(receipt, "agent_instance_id", "", false, context.temp_allocator), "inst_old")
    testing.expect_value(t, jsonx.extract_int(receipt, "expected_run_count", -1), 7)
    testing.expect_value(t, jsonx.extract_string(receipt, "status", "", false, context.temp_allocator), "succeeded")
}

@(test)
bridge_only_failed_fenced_stops_bypass_result_cache :: proc(t: ^testing.T) {
    command := `{"type":"stop_agent","expected_run_count":7}`
    failure := bridge_command_failed_json("stop_7", bridge_cause_wire_error("stale_generation", "generation changed"))
    defer delete(failure)
    success := bridge_stop_confirmed_json("stop_7", "inst_old", 7)
    defer delete(success)
    testing.expect(t, bridge_failed_fenced_stop_retry("stop_agent", command, failure))
    testing.expect(t, !bridge_failed_fenced_stop_retry("stop_agent", command, success))
    testing.expect(t, !bridge_failed_fenced_stop_retry("stop_agent", `{}`, failure))
    testing.expect(t, !bridge_failed_fenced_stop_retry("launch_agent", command, failure))
}

@(test)
bridge_stale_stop_waits_for_launch_and_preserves_replacement :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    id:="inst_lifecycle_generation_test"
    sync.mutex_lock(&bridge_local_token_mutex)
    saved:=bridge_local_token_records
    records:=make([dynamic]Bridge_Local_Agent_Token_Record)
    append(&records,Bridge_Local_Agent_Token_Record{agent_instance_id=id,run_count=1})
    bridge_local_token_records=records
    sync.mutex_unlock(&bridge_local_token_mutex)
    defer {
        sync.mutex_lock(&bridge_local_token_mutex)
        bridge_local_token_records=saved
        sync.mutex_unlock(&bridge_local_token_mutex)
        delete(records)
    }
    bridge_runtime_set_status(id,"running","busy")
    // Hold the exact critical section used by both launch entry points while
    // the old-generation stop arrives through another dispatcher/recovery path.
    launching:=bridge_agent_lifecycle_enter(id)
    Race :: struct {started,finished:bool,ok,stale:bool}
    race:Race
    worker:=thread.create_and_start_with_data(&race,proc(raw:rawptr) {
        r:=(^Race)(raw)
        sync.atomic_store(&r.started,true)
        stop :: proc(id:string,force:bool)->bool {
            bridge_runtime_set_status(id,"stopped","idle")
            return true
        }
        restored:string
        present :: proc(id: string) -> bool { return false }
        r.ok,restored,r.stale=bridge_runtime_stop_generation("inst_lifecycle_generation_test",true,1,stop,present)
        delete(restored)
        sync.atomic_store(&r.finished,true)
    })
    deadline:=time.tick_now()
    for !sync.atomic_load(&race.started) && time.tick_since(deadline)<2*time.Second do thread.yield()
    testing.expect(t,sync.atomic_load(&race.started),"stop worker started")
    queued:=false
    for !queued && time.tick_since(deadline)<2*time.Second {
        sync.mutex_lock(&bridge_agent_lifecycle_mutex)
        queued=launching.users==2
        sync.mutex_unlock(&bridge_agent_lifecycle_mutex)
        if !queued do thread.yield()
    }
    testing.expect(t,queued,"old stop joined the same per-instance lifecycle fence")
    testing.expect(t,!sync.atomic_load(&race.finished),"stop cannot pass a launch in progress")
    unrelated:=bridge_agent_lifecycle_enter("inst_lifecycle_unrelated_test")
    bridge_agent_lifecycle_leave(unrelated)
    sync.mutex_lock(&bridge_local_token_mutex)
    bridge_local_token_records[0].run_count=2
    sync.mutex_unlock(&bridge_local_token_mutex)
    bridge_agent_lifecycle_leave(launching)
    thread.join(worker); thread.destroy(worker)
    testing.expect(t,race.stale && !race.ok,"old stop rejected after replacement launch")
    status,activity,_:=bridge_runtime_status_snapshot(id)
    defer {delete(status);delete(activity)}
    testing.expect_value(t,status,"running")
    testing.expect_value(t,activity,"busy")
    testing.expect_value(t,bridge_agent_instance_run_count(id),2)

    // The same fence admits the current generation, and a failed stop must
    // restore its live status rather than acknowledge termination to the Hub.
    failing_stop :: proc(id: string, force: bool) -> bool {
        bridge_runtime_set_status(id, "stopping", "idle")
        return false
    }
    stopped, restored, stale := bridge_runtime_stop_generation(id, true, 2, failing_stop)
    defer delete(restored)
    testing.expect(t, !stopped && !stale, "current generation stop failure is not stale or successful")
    testing.expect_value(t, restored, "running")
    current_status, current_activity, _ := bridge_runtime_status_snapshot(id)
    defer { delete(current_status); delete(current_activity) }
    testing.expect_value(t, current_status, "running")
    testing.expect_value(t, current_activity, "busy")

    absent :: proc(id: string) -> bool { return true }
    forbidden_stop :: proc(id: string, force: bool) -> bool {
        panic("mismatched generation must never stop a replacement")
    }
    recovered, recovery_status, recovery_stale := bridge_runtime_stop_generation(id, true, 1, forbidden_stop, absent)
    defer delete(recovery_status)
    testing.expect(t, recovered && !recovery_stale, "verified daemon absence clears the old holder fence")
    testing.expect_value(t, bridge_agent_instance_run_count(id), 2)
}
