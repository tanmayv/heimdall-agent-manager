package main

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
t15_acp_prompt_owns_activity_across_late_telemetry_and_queued_turns :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    previous_ingest := acp_events_ingest
    acp_events_ingest = t14_live_ingest
    defer { acp_events_ingest = previous_ingest; t5_reset_events() }
    f: T4_Runtime_Test; t5_fixture_open(&f)
    defer { f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f); bridge_runtime_set_status("inst_t5_events", "stopped", "idle") }
    bridge_runtime_mark_start_success(f.r.instance)
    previous_transport := t15_set_transport(f.r.instance, "acp")
    defer t15_set_transport(f.r.instance, previous_transport)
    f.r.d.ready = true; f.r.d.starter_sent = true
    acp_runtime_replace(&f.r.d.phase, "ready")
    testing.expect(t, t4_runtime_call(&f, `{"id":"turn-one","text":"respond"}`))
    t15_expect_activity(t, f.r.instance, "active")
    // Native hooks and ACP tool telemetry are asynchronous; neither owns the
    // prompt boundary. An early Stop must not make an in-flight prompt idle.
    t15_native_activity(t, f.r.rec, "idle")
    t15_expect_activity(t, f.r.instance, "active")
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    t15_expect_activity(t, f.r.instance, "idle")
    // The adapter's long-lived consumer can emit between prompts. These must
    // not resurrect Working after the authoritative session/prompt result.
    t5_update(&f, t, 2, `{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"late thought"}}`)
    t15_expect_activity(t, f.r.instance, "idle")
    t5_update(&f, t, 3, `{"sessionUpdate":"tool_call_update","toolCallId":"late","status":"completed","kind":"execute"}`)
    t15_expect_activity(t, f.r.instance, "idle")
    tool := f.r.tools.entries["late"]
    testing.expect(t, tool != nil && tool.ended, "late telemetry is still recorded")
    t15_native_activity(t, f.r.rec, "active")
    t15_expect_activity(t, f.r.instance, "idle")
    // A real queued follow-up does keep Working until its own result arrives.
    testing.expect(t, t4_runtime_call(&f, `{"id":"turn-two","text":"second"}`))
    testing.expect(t, t4_runtime_call(&f, `{"id":"turn-three","text":"queued"}`))
    t4_runtime_reply(t, &f, 1, `{"stopReason":"end_turn"}`, 4)
    t15_expect_activity(t, f.r.instance, "active")
    t4_runtime_reply(t, &f, 2, `{"stopReason":"cancelled"}`, 5)
    t15_expect_activity(t, f.r.instance, "idle")
}

t15_expect_activity :: proc(t: ^testing.T, instance, expected: string) {
    snap, found := bridge_runtime_instance_snapshot(instance)
    testing.expect(t, found)
    testing.expect_value(t, snap.activity_status, expected)
    // Verify the actual repair heartbeat sent to the Hub, not just the UI input.
    raw := bridge_hub_heartbeat_json_shaped({omit_metadata = true, omit_diagnostics = true})
    defer delete(raw)
    heartbeat: struct { instances: []Bridge_Heartbeat_Instance }
    // Decode in temp storage; the heartbeat includes other fixture instances.
    testing.expect(t, json.unmarshal_string(raw, &heartbeat, allocator = context.temp_allocator) == nil)
    reported := false
    for row in heartbeat.instances do if row.agent_instance_id == instance {
        reported = true
        testing.expect_value(t, row.activity_status, expected)
    }
    testing.expect(t, reported, "heartbeat includes the live ACP instance")
}

t15_native_activity :: proc(t: ^testing.T, rec: Bridge_Local_Agent_Token_Record, state: string) {
    raw := strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","ext_version":"native-test","event":"activity","session_id":"s","payload":{"state":"`, state, `"}}`}, context.temp_allocator)
    result := bridge_ext_ingest(rec, raw, bridge_runtime_now_ms())
    defer bridge_ext_ingest_result_destroy(&result)
    testing.expect_value(t, result.accepted, 1)
}

t15_set_transport :: proc(instance, transport: string) -> string {
    sync.mutex_lock(&bridge_runtime_mutex); defer sync.mutex_unlock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == instance {
        previous := inst.runtime_transport
        inst.runtime_transport = transport
        return previous
    }
    return ""
}

@(test)
t15_acp_permission_activity_stays_owned_by_dispatcher :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    f: T4_Runtime_Test; t9_fixture_open(&f, "inst_t15_permission")
    defer { t9_fixture_close(&f); bridge_runtime_set_status("inst_t15_permission", "stopped", "idle") }
    bridge_runtime_mark_start_success(f.r.instance)
    previous_transport := t15_set_transport(f.r.instance, "acp")
    defer t15_set_transport(f.r.instance, previous_transport)
    testing.expect(t, t4_runtime_call(&f, `{"id":"permission-turn","text":"run command"}`))
    t9_permission(&f, t, "7", 1)
    blocker := t9_blocker(t, &f, "7"); defer delete(blocker)
    t15_expect_activity(t, f.r.instance, "idle") // waiting_user is idle-equivalent
    waiting, _ := bridge_runtime_instance_snapshot(f.r.instance)
    testing.expect_value(t, waiting.activity_source, "acp")
    testing.expect(t, bridge_permission_resolve(f.r.instance, blocker, "allow", ""))
    t9_response(t, &f, 1, "7", "opaque-yes-123")
    t9_worker_barrier(&f)
    t15_expect_activity(t, f.r.instance, "active")
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 2)
    t15_expect_activity(t, f.r.instance, "idle")
}
