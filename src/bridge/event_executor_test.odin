package main

import "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"
import httpc "odin_test:lib/httpc"

bridge_event_test_mutex: sync.Mutex
bridge_event_test_case: string
bridge_event_test_t: ^testing.T
bridge_event_test_snap: Bridge_Runtime_Instance
bridge_event_test_has: bool
bridge_event_test_start_result: Bridge_Wake_Result
bridge_event_test_answer: string
bridge_event_test_notices, bridge_event_test_starts, bridge_event_test_frames: int
bridge_event_test_notice_ok: bool
bridge_event_test_reason: string
bridge_event_test_http_status: int
bridge_event_test_http_body: string
bridge_event_test_launches: int
bridge_event_test_snapshot :: proc(id: string) -> (Bridge_Runtime_Instance, bool) { return bridge_event_test_snap, bridge_event_test_has }
bridge_event_test_busy :: proc() -> (bool, bool, bool) {
    return bridge_event_test_reason == "draining", false, bridge_event_test_reason != "vault_locked"
}
bridge_event_test_start :: proc(id, delivery_id: string, deadline: i64) -> Bridge_Wake_Result {
    bridge_event_test_starts += 1
    testing.expect_value(bridge_event_test_t, id, "inst_t17")
    testing.expect_value(bridge_event_test_t, delivery_id, "dlv_t17")
    e, found := bridge_event_ledger_get(delivery_id)
    testing.expect(bridge_event_test_t, found && e.state == .In_Progress && e.effect == .Start)
    return bridge_event_test_start_result
}
bridge_event_test_notice :: proc(id: string, notice: contracts.Delivery_Notice_Wire) -> bool {
    bridge_event_test_notices += 1
    testing.expect_value(bridge_event_test_t, id, "inst_t17")
    e, found := bridge_event_ledger_get("dlv_t17")
    testing.expect(bridge_event_test_t, found && e.state == .In_Progress && e.effect == .Type)
    if notice.line == "events" {
        testing.expect_value(bridge_event_test_t, notice.count, 3)
        testing.expect_value(bridge_event_test_t, fmt.tprintf(contracts.EVENTS_NOTICE_FORMAT, notice.count), "[events] 3 new event(s) — run ham-ctl events next")
    }
    return bridge_event_test_notice_ok
}
bridge_event_test_send :: proc(conn: ^ws.Connection, text: string) -> bool {
    bridge_event_test_frames += 1
    delete(bridge_event_test_answer)
    bridge_event_test_answer = strings.clone(text)
    return true
}
bridge_event_test_launch :: proc(command_id, command_json: string, deadline_ns: i64) -> (bool, string, Bridge_Error) {
    bridge_event_test_launches += 1
    testing.expect_value(bridge_event_test_t, command_id, "hub_t17")
    testing.expect_value(bridge_event_test_t, command_json, "{\"type\":\"launch_agent\",\"command_id\":\"hub_t17\",\"agent_instance_id\":\"inst_t17\",\"run_count\":7}")
    testing.expect(bridge_event_test_t, extract_json_int(command_json, "run_count", 0) > 0)
    return true, "", {}
}
bridge_event_test_http :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
    testing.expect_value(bridge_event_test_t, req.method, httpc.Method.POST)
    testing.expect_value(bridge_event_test_t, req.path[len(req.path)-1], "start-begin")
    testing.expect_value(bridge_event_test_t, req.path[len(req.path)-2], "inst_t17")
    if raw, ok := req.body.(httpc.Raw_Body); ok {
        testing.expect_value(bridge_event_test_t, extract_json_string(string(raw.bytes), "ref", "", context.temp_allocator), "dlv_t17")
    } else { testing.expect(bridge_event_test_t, false, "start-begin must carry a JSON body") }
    return {status = bridge_event_test_http_status, body = transmute([]byte)strings.clone(bridge_event_test_http_body)}, .None
}
bridge_event_test_frame :: proc(final := false, kind := "prompt", line := "message") -> string {
    f := contracts.Event_Deliver_Wire{type = "event_deliver", command_id = "dlv_t17:1", agent_instance_id = "inst_t17", attempt = 1, final = final,
        delivery = {delivery_id = "dlv_t17", agent_instance_id = "inst_t17", kind = kind, notice = {line = line, count = 3}}}
    bytes, _ := json.marshal(f, allocator = context.temp_allocator)
    return string(bytes)
}
bridge_event_test_expect :: proc(t: ^testing.T, status, outcome, class: string, reason := "", retry: i64 = -1) {
    a := bridge_event_test_answer
    testing.expect_value(t, extract_json_string(a, "type", "", context.temp_allocator), "command_result")
    testing.expect_value(t, extract_json_string(a, "status", "", context.temp_allocator), status)
    testing.expect_value(t, extract_json_string(a, "outcome", "", context.temp_allocator), outcome)
    testing.expect_value(t, extract_json_string(a, "class", "", context.temp_allocator), class)
    if reason != "" do testing.expect_value(t, extract_json_string(a, "cause", "", context.temp_allocator), reason)
    if retry >= 0 do testing.expect_value(t, i64(extract_json_int(a, "retry_after_ms", 0)), retry)
}
bridge_event_test_run :: proc(t: ^testing.T, name: string) {
    sync.mutex_lock(&bridge_event_test_mutex)
    defer sync.mutex_unlock(&bridge_event_test_mutex)
    bridge_agent_wake_init()
    bridge_event_test_case = name
    bridge_ledger_test_run(t, bridge_event_test_scenario)
}
bridge_event_test_scenario :: proc(t: ^testing.T) {
    bridge_event_test_t = t
    snap, start, notice, send, now := bridge_event_snapshot_proc, bridge_event_start_proc, bridge_event_notice_proc, bridge_event_send_proc, bridge_event_now_proc
    rollover, deliver := bridge_event_rollover_proc, bridge_event_deliver_proc
    bridge_event_rollover_proc, bridge_event_deliver_proc = bridge_event_test_rollover, bridge_event_test_deliver
    busy := bridge_bot_busy_inputs_proc
    bridge_event_snapshot_proc, bridge_event_start_proc, bridge_event_notice_proc, bridge_event_send_proc, bridge_event_now_proc = bridge_event_test_snapshot, bridge_event_test_start, bridge_event_test_notice, bridge_event_test_send, bridge_ledger_test_now
    bridge_bot_busy_inputs_proc = bridge_event_test_busy
    bridge_event_test_snap = {runtime_status = "running", activity_status = "idle", start_success_seen = true}
    bridge_event_test_has, bridge_event_test_notice_ok = true, true
    bridge_event_test_reason = ""
    bridge_event_test_notices, bridge_event_test_starts, bridge_event_test_frames = 0, 0, 0
    bridge_event_test_start_result = {.Launched, {}, 0}
    defer {
        delete(bridge_event_test_answer)
        bridge_event_test_answer = ""
        bridge_event_snapshot_proc, bridge_event_start_proc, bridge_event_notice_proc, bridge_event_send_proc, bridge_event_now_proc = snap, start, notice, send, now
        bridge_bot_busy_inputs_proc = busy
        bridge_event_rollover_proc, bridge_event_deliver_proc = rollover, deliver
    }
    name := bridge_event_test_case
    switch name {
    case "corrupt_ledger":
        path := bridge_ledger_test_path(); defer delete(path)
        testing.expect(t, bridge_retry_atomic_write(path, transmute([]byte)string("{broken")))
        bridge_event_ledger_load()
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "failed", "", "retry", "ledger_unavailable", 60_000)
        testing.expect(t, bridge_event_test_notices == 0 && bridge_event_test_starts == 0)
    case "rejected_start":
        // Use the real local registry and ACP pre-spawn rejection. A later fire
        // must not mistake the rejected startup for a booting child.
        bridge_event_snapshot_proc = bridge_runtime_instance_snapshot
        bridge_event_start_proc = bridge_event_test_rejected_start
        bridge_runtime_set_status("inst_t17", "stopped", "idle")
        defer bridge_runtime_set_status("inst_t17", "stopped", "idle")
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "failed", "", "fatal", "launch_failed")
        local := bridge_event_local("inst_t17")
        testing.expect_value(t, local, Bridge_Event_Local.Absent)
        rejected, found := bridge_runtime_instance_snapshot("inst_t17")
        testing.expect(t, found && rejected.runtime_status == "stopped" && rejected.activity_status == "idle")
        testing.expect(t, rejected.start_deadline_unix_ms == 0 && !rejected.has_last_error)
        next, _ := strings.replace_all(bridge_event_test_frame(), "dlv_t17", "dlv_t17_next")
        defer delete(next)
        bridge_event_deliver_handle(nil, next)
        bridge_event_test_expect(t, "failed", "", "fatal", "start_parked")
        testing.expect_value(t, bridge_event_test_starts, 2)
        testing.expect_value(t, bridge_event_test_notices, 0)
        _, stored := bridge_event_ledger_get("dlv_t17")
        testing.expect(t, !stored, "rejected startup must not leave a successful delivery receipt")
        _, stored = bridge_event_ledger_get("dlv_t17_next")
        testing.expect(t, !stored, "next fire must not leave a false delivered receipt")
    case "io_failure":
        _ = bridge_make_directory_all(bridge_ledger_test_dir)
        blocked := strings.concatenate({bridge_ledger_test_dir, "/blocked"}, context.temp_allocator)
        testing.expect(t, os.write_entire_file_from_string(blocked, "file, not a directory") == nil)
        saved_path := bridge_event_ledger_path_proc
        bridge_event_ledger_path_proc = bridge_event_test_blocked_path
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "failed", "", "retry", "ledger_unavailable", 60_000)
        testing.expect(t, bridge_event_test_notices == 0 && bridge_event_test_starts == 0)
        _, found := bridge_event_ledger_get("dlv_t17")
        testing.expect(t, !found)
        bridge_event_ledger_path_proc = saved_path
        _ = os.remove(blocked)
    case "final_matrix":
        for local in ([]Bridge_Event_Local{.Absent, .Stopping, .Booting, .Idle, .Busy}) {
            for class in ([]contracts.Bridge_Error_Class{.retriable, .recoverable, .fatal}) {
                for reason in ([]string{"", "draining", "vault_locked"}) {
                    bridge_event_ledger_clear_locked()
                    bridge_event_test_has = local != .Absent
                    bridge_event_test_snap = {runtime_status = "running", activity_status = "idle", start_success_seen = true}
                    if local == .Stopping do bridge_event_test_snap.runtime_status = "stopping"
                    if local == .Booting do bridge_event_test_snap.start_success_seen = false
                    if local == .Busy do bridge_event_test_snap.activity_status = "active"
                    bridge_event_test_reason = reason
                    bridge_event_test_notice_ok = false
                    err := bridge_error(.agent_launch_failed)
                    err.class = class
                    bridge_event_test_start_result = {.Failed, err, 1234}
                    bridge_event_deliver_handle(nil, bridge_event_test_frame(true))
                    status := extract_json_string(bridge_event_test_answer, "status", "", context.temp_allocator)
                    failure_class := extract_json_string(bridge_event_test_answer, "class", "", context.temp_allocator)
                    testing.expect(t, status == "succeeded" || (status == "failed" && failure_class == "fatal"))
                    testing.expect_value(t, extract_json_int(bridge_event_test_answer, "retry_after_ms", 0), 0)
                }
            }
        }
    case "raw":
        raw := "{ \"launch\" : { \"command_id\":\"x\", \"nested\":[{\"text\":\"brace } and quote \\\" here\"}] } }"
        object, ok := bridge_wake_object_text(raw, "launch")
        testing.expect(t, ok)
        testing.expect_value(t, object, raw[13:len(raw)-2])
    case "table":
        done := Bridge_Ledger_Entry{state = .Done}
        progress := Bridge_Ledger_Entry{state = .In_Progress, effect = .Start}
        typed := Bridge_Ledger_Entry{state = .In_Progress, effect = .Type}
        cases := []struct {ledger: Maybe(Bridge_Ledger_Entry), local: Bridge_Event_Local, final: bool, busy: string, expected: Bridge_Event_Action, retry: i64}{
            {done, .Absent, false, "draining", .Answer_Stored, 0},
            {progress, .Booting, false, "", .Answer_Started, 0},
            {progress, .Idle, false, "", .Answer_Started, 0},
            {progress, .Busy, false, "", .Answer_Started, 0},
            {typed, .Idle, false, "", .Type_Notice, 0},
            {nil, .Absent, false, "draining", .Retry, 0},
            {nil, .Absent, true, "vault_locked", .Fatal, 0},
            {nil, .Stopping, false, "", .Retry, 5000},
            {nil, .Stopping, true, "", .Start, 0},
            {nil, .Booting, false, "", .Answer_Started, 0},
            {nil, .Idle, false, "", .Type_Notice, 0},
            {nil, .Busy, false, "", .Retry, 0},
            {nil, .Busy, true, "", .Type_Notice, 0},
            {nil, .Absent, false, "", .Start, 0},
        }
        for c in cases {
            action, _, retry := bridge_event_decide(c.ledger, c.local, c.final, c.busy)
            testing.expect_value(t, action, c.expected)
            testing.expect_value(t, retry, c.retry)
        }
    case "json":
        ordinary := bridge_command_result_json("cmd", "succeeded", "running")
        defer delete(ordinary)
        testing.expect_value(t, ordinary, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"cmd\",\"ok\":true,\"payload\":{\"status\":\"succeeded\",\"result\":{\"runtime_status\":\"running\"}}}")
        for class in ([]string{"retry", "fatal"}) {
            answer := bridge_event_result_json("cmd", "failed", "", class, 12 if class == "retry" else 0, "notice_failed", "failed")
            testing.expect_value(t, extract_json_string(answer, "class", "", context.temp_allocator), class)
            testing.expect(t, !strings.contains(answer, "\"outcome\""))
            delete(answer)
        }
    case "spec":
        spec, found := bridge_command_spec("event_deliver")
        testing.expect(t, found && spec.queued && spec.retry_safe && spec.class == .Lifecycle && spec.timeout_ms == contracts.DELIVERY_HANDLER_BUDGET_MS)
        key := bridge_command_ordering_key("event_deliver", bridge_event_test_frame())
        defer delete(key)
        testing.expect_value(t, key, "agent:inst_t17")
    case "feature":
        found := false
        features := bridge_runtime_features()
        for f in features do if f == contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1 do found = true
        testing.expect(t, found)
    case "stop", "http", "live", "live_final", "live_local", "recover", "classes", "wrapper":
        bridge_event_http_scenario(t, name)
    case "done":
        testing.expect(t, bridge_event_ledger_begin("dlv_t17", .Start, bridge_ledger_test_clock, 0))
        testing.expect(t, bridge_event_ledger_done("dlv_t17", "started", bridge_ledger_test_clock))
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "succeeded", "started", "")
        testing.expect(t, bridge_event_test_notices == 0 && bridge_event_test_starts == 0)
    case "gates":
        for reason in ([]string{"draining", "vault_locked"}) {
            bridge_event_test_reason = reason
            for final in ([]bool{false, true}) {
                bridge_event_deliver_handle(nil, bridge_event_test_frame(final))
                bridge_event_test_expect(t, "failed", "", "fatal" if final else "retry", reason)
            }
        }
    case "booting", "restart_start":
        bridge_event_test_snap.start_success_seen = false
        if name == "restart_start" {
            testing.expect(t, bridge_event_ledger_begin("dlv_t17", .Start, bridge_ledger_test_clock, 0))
            bridge_event_ledger_load()
        }
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "succeeded", "started", "")
        testing.expect_value(t, bridge_event_test_notices, 0)
        testing.expect_value(t, bridge_event_test_starts, 0)
    case "idle", "events", "restart_type", "busy_final":
        bridge_event_notice_proc = bridge_event_type_notice
        if name == "busy_final" do bridge_event_test_snap.activity_status = "active"
        if name == "restart_type" {
            testing.expect(t, bridge_event_ledger_begin("dlv_t17", .Type, bridge_ledger_test_clock, 0))
            bridge_event_ledger_load()
        }
        bridge_event_deliver_handle(nil, bridge_event_test_frame(name == "busy_final", "notice" if name == "events" else "prompt", "events" if name == "events" else "message"))
        bridge_event_test_expect(t, "succeeded", "notified", "")
        testing.expect_value(t, bridge_event_test_notices, 1)
        e, found := bridge_event_ledger_get("dlv_t17")
        testing.expect(t, found && e.state == .Done && e.outcome == "notified")
    case "busy":
        bridge_event_test_snap.activity_status = "active"
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "failed", "", "retry")
        testing.expect(t, !strings.contains(bridge_event_test_answer, "\"retry_after_ms\""))
        _, had := bridge_event_ledger_get("dlv_t17")
        testing.expect(t, !had && bridge_event_test_notices == 0)
    case "absent", "restart_absent":
        bridge_event_test_has = false
        if name == "restart_absent" {
            testing.expect(t, bridge_event_ledger_begin("dlv_t17", .Start, bridge_ledger_test_clock, 0))
            bridge_event_ledger_load()
        }
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "succeeded", "started", "")
        testing.expect_value(t, bridge_event_test_starts, 1)
    case "unknown":
        for kind in ([]string{"bot", "lease"}) {
            bridge_event_deliver_handle(nil, bridge_event_test_frame(false, kind))
            bridge_event_test_expect(t, "failed", "", "fatal", "unknown_kind")
        }
        bridge_event_deliver_handle(nil, "{broken")
        bridge_event_test_expect(t, "failed", "", "fatal", "invalid_frame")
    case "last":
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "succeeded", "notified", "")
        testing.expect_value(t, bridge_event_test_frames, 1)
    case "margin", "ahead":
        base := bridge_ledger_test_clock
        expires := base + 1000
        if name == "ahead" do bridge_ledger_test_clock = base + 8 * 60_000
        testing.expect(t, bridge_event_ledger_begin("dlv_t17", .Type, bridge_ledger_test_clock, expires))
        testing.expect(t, bridge_event_ledger_done("dlv_t17", "notified", bridge_ledger_test_clock))
        if name == "margin" do bridge_ledger_test_clock = expires + 61_000
        bridge_event_ledger_load()
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "succeeded", "notified", "")
        testing.expect(t, bridge_event_test_notices == 0 && bridge_event_test_starts == 0)
    case "full":
        bridge_event_ledger = make(map[string]Bridge_Ledger_Entry, runtime.heap_allocator())
        for i in 0..<BRIDGE_LEDGER_MAX_ENTRIES {
            id := fmt.aprintf("live%d", i, allocator = runtime.heap_allocator())
            bridge_event_ledger[id] = {id = id, state = .Done, effect = .Type, outcome = strings.clone("notified", runtime.heap_allocator()), at_ms = bridge_ledger_test_clock}
        }
        testing.expect(t, !bridge_event_ledger_begin("extra", .Type, bridge_ledger_test_clock, 0))
        for final in ([]bool{false, true}) {
            bridge_event_deliver_handle(nil, bridge_event_test_frame(final))
            bridge_event_test_expect(t, "failed", "", "fatal" if final else "retry", "ledger_full", 0 if final else 60_000)
        }
    case "start_gates", "start_final", "final":
        bridge_event_test_has = false
        for outcome in ([]Bridge_Wake_Outcome{.Coalesced, .Backing_Off, .Parked, .Failed}) {
            bridge_event_test_start_result = {outcome, bridge_error(.hub_connect_failed, .transport), 4567}
            final := name != "start_gates"
            bridge_event_deliver_handle(nil, bridge_event_test_frame(final))
            expected := "fatal" if final || outcome == .Parked else "retry"
            bridge_event_test_expect(t, "failed", "", expected)
            if expected == "fatal" do testing.expect_value(t, extract_json_int(bridge_event_test_answer, "retry_after_ms", 0), 0)
        }
        if name == "final" {
            for local in ([]string{"running", "starting", "stopping", "stopped"}) {
                bridge_event_test_snap.runtime_status = local
                bridge_event_ledger_forget("dlv_t17")
                bridge_event_test_has = true
                bridge_event_test_notice_ok = false
                bridge_event_deliver_handle(nil, bridge_event_test_frame(true))
                testing.expect(t, extract_json_string(bridge_event_test_answer, "class", "", context.temp_allocator) != "retry")
            }
        }
    }
}

bridge_event_test_rejected_start :: proc(id, delivery_id: string, deadline: i64) -> Bridge_Wake_Result {
    bridge_event_test_starts += 1
    if bridge_event_test_starts > 1 do return {.Parked, bridge_error(.agent_launch_failed, .unsupported), 0}
    snapshot, loaded := bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded
    defer { bridge_provider_catalog_snapshot = snapshot; bridge_provider_catalog_loaded = loaded }
    env := make(map[string]string, context.temp_allocator)
    env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    catalog := Bridge_Provider_Catalog_Snapshot{etag = "sha256:rejected", providers = {Bridge_Catalog_Provider{provider = "claude", state = "active", acp_recipe = {command = "claude-agent-acp", protocol_version = 1, adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION, env = env}}}}
    bridge_provider_catalog_snapshot = &catalog; bridge_provider_catalog_loaded = true
    etag := bridge_provider_catalog_current_etag()
    defer delete(etag)
    ok, detail, err := acp_runtime_launch("rejected", id, "epoch_rejected", etag, "", "", "claude", "", "", "invalid_mode", "")
    testing.expect(bridge_event_test_t, !ok && detail == "invalid_acp_configuration")
    return {.Failed, err, 0}
}
@(test)
test_event_rejected_start_next_fire_never_delivered :: proc(t: ^testing.T) { bridge_event_test_run(t, "rejected_start") }

@(test)
test_event_row1_done_answers_stored_outcome :: proc(t: ^testing.T) { bridge_event_test_run(t, "done") }

@(test)
test_event_row4_draining_and_vault_locked :: proc(t: ^testing.T) { bridge_event_test_run(t, "gates") }

@(test)
test_event_row6_booting_succeeds_without_typing :: proc(t: ^testing.T) { bridge_event_test_run(t, "booting") }

@(test)
test_event_row7_idle_types_message_notice :: proc(t: ^testing.T) { bridge_event_test_run(t, "idle") }

@(test)
test_event_row7_idle_types_events_line :: proc(t: ^testing.T) { bridge_event_test_run(t, "events") }

@(test)
test_event_row8_busy_asks_retry :: proc(t: ^testing.T) { bridge_event_test_run(t, "busy") }

@(test)
test_event_row8b_busy_final_types_anyway :: proc(t: ^testing.T) { bridge_event_test_run(t, "busy_final") }

@(test)
test_event_row9_absent_starts :: proc(t: ^testing.T) { bridge_event_test_run(t, "http") }

@(test)
test_event_restart_in_progress_start_running :: proc(t: ^testing.T) { bridge_event_test_run(t, "restart_start") }

@(test)
test_event_restart_in_progress_start_absent :: proc(t: ^testing.T) { bridge_event_test_run(t, "restart_absent") }

@(test)
test_event_restart_in_progress_type :: proc(t: ^testing.T) { bridge_event_test_run(t, "restart_type") }

@(test)
test_event_unknown_kind_and_invalid_frame :: proc(t: ^testing.T) { bridge_event_test_run(t, "unknown") }

@(test)
test_event_answer_is_last_frame :: proc(t: ^testing.T) { bridge_event_test_run(t, "last") }

@(test)
test_ledger_redelivery_inside_margin_has_no_second_effect :: proc(t: ^testing.T) { bridge_event_test_run(t, "margin") }

@(test)
test_ledger_bridge_clock_ahead :: proc(t: ^testing.T) { bridge_event_test_run(t, "ahead") }

@(test)
test_ledger_full_answers_retry :: proc(t: ^testing.T) { bridge_event_test_run(t, "full") }

@(test)
test_event_start_gate_coalesced_backoff_parked :: proc(t: ^testing.T) { bridge_event_test_run(t, "start_gates") }

@(test)
test_event_start_retriable_on_final_is_fatal :: proc(t: ^testing.T) { bridge_event_test_run(t, "start_final") }

@(test)
test_event_final_never_retry :: proc(t: ^testing.T) { bridge_event_test_run(t, "final_matrix") }

bridge_event_test_manifest :: proc(instance_id, command_id: string, deadline_ns: i64) -> (string, Bridge_Error, bool) {
    return strings.clone("{\"type\":\"launch_agent\",\"command_id\":\"hub_t17\",\"agent_instance_id\":\"inst_t17\",\"run_count\":7}"), {}, true
}
bridge_event_http_scenario :: proc(t: ^testing.T, name: string) {
    config, cred := bridge_config, g_bridge_cred
    supported := bridge_hub_start_begin_supported
    wake_snap, launch, http, manifest := bridge_wake_snapshot_proc, bridge_wake_launch_proc, bridge_wake_http_proc, bridge_wake_manifest_proc
    start := bridge_event_start_proc
    saved_map := bridge_agent_wake
    bridge_agent_wake = make(map[string]Bridge_Wake_State, runtime.heap_allocator())
    bridge_config.daemon_url, bridge_config.bridge_token = "https://hub.test", "hba_test"
    g_bridge_cred = {}
    bridge_hub_start_begin_supported = true
    bridge_wake_snapshot_proc, bridge_wake_launch_proc, bridge_wake_http_proc, bridge_wake_manifest_proc = bridge_event_test_snapshot, bridge_event_test_launch, bridge_event_test_http, bridge_event_test_manifest
    bridge_event_start_proc = bridge_event_start
    bridge_event_test_launches = 0
    bridge_event_test_has = false
    bridge_event_test_http_status = 200
    bridge_event_test_http_body = "{\"data\":{\"launch\":{\"type\":\"launch_agent\",\"command_id\":\"hub_t17\",\"agent_instance_id\":\"inst_t17\",\"run_count\":7}}}"
    defer {
        for key, &state in bridge_agent_wake {
            bridge_wake_state_free(&state)
            delete(key, runtime.heap_allocator())
        }
        delete(bridge_agent_wake)
        bridge_agent_wake = saved_map
        bridge_config, g_bridge_cred = config, cred
        bridge_hub_start_begin_supported = supported
        bridge_wake_snapshot_proc, bridge_wake_launch_proc, bridge_wake_http_proc, bridge_wake_manifest_proc = wake_snap, launch, http, manifest
        bridge_event_start_proc = start
    }
    switch name {
    case "stop":
        bridge_wake_launch_proc = bridge_event_test_stopped_launch
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "failed", "", "retry", "launch_failed")
        testing.expect_value(t, bridge_event_test_launches, 1)
    case "http":
        bridge_event_deliver_handle(nil, bridge_event_test_frame())
        bridge_event_test_expect(t, "succeeded", "started", "")
        testing.expect_value(t, bridge_event_test_launches, 1)
        e, had := bridge_event_ledger_get("dlv_t17")
        testing.expect(t, had && e.state == .Done)
    case "live", "live_final", "live_local", "recover":
        bridge_event_test_http_status = 409
        bridge_event_test_http_body = "{\"error\":{\"code\":\"conflict\",\"details\":{\"code\":\"already_running\"}}}"
        if name == "live_local" {
            // First wake snapshot is absent; start-begin changes it to booting.
            bridge_wake_http_proc = bridge_event_test_http_then_running
        }
        count := 4 if name == "recover" else 1
        for i in 0..<count {
            if i == 3 {
                bridge_event_test_http_status = 200
                bridge_event_test_http_body = "{\"data\":{\"launch\":{\"type\":\"launch_agent\",\"command_id\":\"hub_t17\",\"agent_instance_id\":\"inst_t17\",\"run_count\":7}}}"
            }
            bridge_ledger_test_clock += 30_001
            bridge_event_deliver_handle(nil, bridge_event_test_frame(name == "live_final"))
            if name == "live_local" || i == 3 {
                bridge_event_test_expect(t, "succeeded", "started", "")
            } else {
                bridge_event_test_expect(t, "failed", "", "fatal" if name == "live_final" else "retry", "hub_row_live", 0 if name == "live_final" else 30_000)
                _, had := bridge_event_ledger_get("dlv_t17")
                testing.expect(t, !had)
            }
        }
        testing.expect_value(t, bridge_event_test_launches, 1 if name == "recover" else 0)
    case "classes":
        for c in ([]struct {status: int, body: string, class: contracts.Bridge_Error_Class, reason: string}{
            {0, "", .retriable, "launch_failed"},
            {429, "{}", .retriable, "start_refused"},
            {503, "{}", .retriable, "start_refused"},
            {409, "{\"error\":{\"code\":\"conflict\"}}", .retriable, "start_refused"},
            {423, "{}", .retriable, "start_refused"},
            {401, "{}", .retriable, "start_refused"},
            {403, "{}", .retriable, "start_refused"},
            {404, "{\"error\":{\"code\":\"not_found\"}}", .fatal, "target_missing"},
            {404, "<html>route missing</html>", .retriable, "hub_unavailable"},
            {400, "{}", .fatal, "start_refused"},
            {200, "{\"data\":{}}", .fatal, "start_refused"},
            {200, "{\"data\":{\"launch\":{\"command_id\":\"zero\",\"run_count\":0}}}", .fatal, "start_refused"},
        }) {
            bridge_event_test_http_status, bridge_event_test_http_body = c.status, c.body
            text, id, err, ok := bridge_wake_start_begin("inst_t17", "dlv_t17", time.to_unix_nanoseconds(time.now()) + i64(time.Second))
            delete(text); delete(id)
            testing.expect(t, !ok)
            testing.expect_value(t, err.class, c.class)
            _, _, reason, _ := bridge_event_start_answer({.Failed, err, 0}, false)
            testing.expect_value(t, reason, c.reason)
        }
    case "wrapper":
        // This regression pins the legacy manifest adapter; T24 separately
        // covers the capability-enabled fallback start-begin path.
        sync.atomic_store(&bridge_hub_start_begin_supported, false)
        // The bool wrapper must expose only Launched. Gate setup avoids HTTP
        // for active/coalesced/backoff/parked cases; launch uses the same seam.
        for outcome in ([]Bridge_Wake_Outcome{.Already_Active, .Coalesced, .Backing_Off, .Parked, .Launched, .Failed}) {
            for key, &state in bridge_agent_wake { bridge_wake_state_free(&state); delete(key, runtime.heap_allocator()) }
            clear(&bridge_agent_wake)
            bridge_event_test_has = outcome == .Already_Active
            bridge_event_test_snap = {runtime_status = "running"}
            now := bridge_ledger_test_clock
            if outcome == .Coalesced do bridge_agent_wake[strings.clone("inst_t17", runtime.heap_allocator())] = {last_wake_ms = now}
            if outcome == .Backing_Off do bridge_agent_wake[strings.clone("inst_t17", runtime.heap_allocator())] = {last_wake_ms = now - 60_000, next_at_ms = now + 4567}
            if outcome == .Parked do bridge_agent_wake[strings.clone("inst_t17", runtime.heap_allocator())] = {parked = true, err = {class = .fatal}}
            bridge_wake_launch_proc = bridge_event_test_wrapper_launch
            bridge_event_test_start_result.outcome = outcome
            testing.expect_value(t, bridge_task_wake_if_needed("inst_t17", now), outcome == .Launched)
        }
    }
}
bridge_event_test_http_then_running :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
    bridge_event_test_has = true
    bridge_event_test_snap = {runtime_status = "starting"}
    return bridge_event_test_http(req)
}
bridge_event_test_wrapper_launch :: proc(id, command: string, deadline: i64) -> (bool, string, Bridge_Error) {
    return bridge_event_test_start_result.outcome == .Launched, "", bridge_error(.hub_connect_failed, .transport)
}

@(test)
test_event_decide_table :: proc(t: ^testing.T) { bridge_event_test_run(t, "table") }

@(test)
test_event_result_json_fields :: proc(t: ^testing.T) { bridge_event_test_run(t, "json") }

@(test)
test_event_deliver_spec_and_key :: proc(t: ^testing.T) { bridge_event_test_run(t, "spec") }

@(test)
test_features_list_has_event_pipeline :: proc(t: ^testing.T) { bridge_event_test_run(t, "feature") }

@(test)
test_event_start_never_generation_zero :: proc(t: ^testing.T) { bridge_event_test_run(t, "http") }

@(test)
test_event_start_same_command_as_launch_agent :: proc(t: ^testing.T) { bridge_event_test_run(t, "http") }

@(test)
test_event_start_begin_failure_classes :: proc(t: ^testing.T) { bridge_event_test_run(t, "classes") }

@(test)
test_event_already_running_with_local_process_is_started :: proc(t: ^testing.T) { bridge_event_test_run(t, "live_local") }

@(test)
test_event_already_running_without_snapshot_retries :: proc(t: ^testing.T) { bridge_event_test_run(t, "live") }

@(test)
test_event_already_running_without_snapshot_final_is_fatal :: proc(t: ^testing.T) { bridge_event_test_run(t, "live_final") }

@(test)
test_event_stale_row_recovers_after_reaper :: proc(t: ^testing.T) { bridge_event_test_run(t, "recover") }

@(test)
test_wake_attempt_wrapper_unchanged :: proc(t: ^testing.T) { bridge_event_test_run(t, "wrapper") }


bridge_event_test_stopped_launch :: proc(id, command: string, deadline: i64) -> (bool, string, Bridge_Error) {
    // Exercise the actual launch prelude with an active stop mark. A deliberately
    // unavailable endpoint ends the launch after clearing the mark and before
    // token issuance, bootstrap HTTP, or spawning a child.
    context.allocator = context.temp_allocator
    bridge_event_test_launches += 1
    saved_instances := bridge_runtime_instances
    saved_started := bridge_runtime_local_endpoint_started
    saved_unix, saved_loopback := bridge_runtime_local_endpoint_unix_started, bridge_runtime_local_endpoint_loopback_started
    saved_descriptor := bridge_runtime_local_endpoint_descriptor
    saved_dir := bridge_config.local_endpoint_run_dir
    bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance)
    bridge_runtime_local_endpoint_started = true
    bridge_runtime_local_endpoint_unix_started, bridge_runtime_local_endpoint_loopback_started = false, false
    bridge_runtime_local_endpoint_descriptor = ""
    bridge_config.local_endpoint_run_dir = strings.concatenate({bridge_ledger_test_dir, "/launch"}, context.temp_allocator)
    defer {
        _ = os.remove_all(bridge_config.local_endpoint_run_dir)
        bridge_config.local_endpoint_run_dir = saved_dir
        bridge_runtime_instances = saved_instances
        bridge_runtime_local_endpoint_started = saved_started
        bridge_runtime_local_endpoint_unix_started, bridge_runtime_local_endpoint_loopback_started = saved_unix, saved_loopback
        bridge_runtime_local_endpoint_descriptor = saved_descriptor
    }
    bridge_runtime_mark_stop_intent("inst_t17")
    testing.expect(bridge_event_test_t, bridge_runtime_stop_intent_active_locked("inst_t17", bridge_runtime_now_ms()))
    ok, detail, err := bridge_runtime_launch_agent(id, command, deadline)
    testing.expect(bridge_event_test_t, !ok && err.reason == .socket_dir)
    testing.expect(bridge_event_test_t, !bridge_runtime_stop_intent_active_locked("inst_t17", bridge_runtime_now_ms()))
    return ok, detail, err
}
@(test)
test_event_start_user_stopped_instance :: proc(t: ^testing.T) { bridge_event_test_run(t, "stop") }


bridge_event_test_rollover :: proc(instance_id, sender: string) -> bool {
    testing.expect_value(bridge_event_test_t, sender, "user")
    return false
}
bridge_event_test_deliver :: proc(instance_id, kind, sender, a, b, line: string) -> bool {
    testing.expect_value(bridge_event_test_t, a, "")
    testing.expect_value(bridge_event_test_t, b, "")
    if kind == "message" {
        testing.expect_value(bridge_event_test_t, sender, "user")
        testing.expect_value(bridge_event_test_t, line, "")
        return bridge_event_test_notice(instance_id, {"message", 0})
    }
    testing.expect_value(bridge_event_test_t, kind, "task_nudge")
    testing.expect_value(bridge_event_test_t, sender, "events")
    testing.expect_value(bridge_event_test_t, line, "[events] 3 new event(s) — run ham-ctl events next")
    return bridge_event_test_notice(instance_id, {"events", 3})
}

@(test)
test_event_start_raw_json_preserves_whitespace_and_escapes :: proc(t: ^testing.T) { bridge_event_test_run(t, "raw") }

bridge_event_test_blocked_path :: proc() -> string {
    return strings.concatenate({bridge_ledger_test_dir, "/blocked/ledger.json"})
}
@(test)
test_event_ledger_write_failure_prevents_effect :: proc(t: ^testing.T) { bridge_event_test_run(t, "io_failure") }

@(test)
test_event_corrupt_ledger_reports_unavailable :: proc(t: ^testing.T) { bridge_event_test_run(t, "corrupt_ledger") }
