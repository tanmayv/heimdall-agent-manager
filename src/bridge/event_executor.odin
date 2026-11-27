package main

import "core:encoding/json"
import "core:fmt"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

Bridge_Event_Local :: enum { Absent, Stopping, Booting, Idle, Busy, Unknown }
Bridge_Event_Action :: enum { Answer_Stored, Answer_Started, Type_Notice, Start, Retry, Fatal }
bridge_event_snapshot_proc: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) = bridge_runtime_instance_snapshot
bridge_event_probe_proc: proc(instance_id: string) -> Bridge_Instance_Probe_Result = bridge_instance_probe
bridge_event_start_proc: proc(instance_id, delivery_id: string, deadline_ns: i64) -> Bridge_Wake_Result = bridge_event_start
bridge_event_notice_proc: proc(instance_id: string, notice: contracts.Delivery_Notice_Wire) -> bool = bridge_event_type_notice
bridge_event_send_proc: proc(conn: ^ws.Connection, text: string) -> bool = bridge_hub_send
bridge_event_rollover_proc: proc(instance_id, sender: string) -> bool = bridge_rollover_queue_notice
bridge_event_deliver_proc: proc(instance_id, kind, sender, a, b, line: string) -> bool = bridge_event_deliver_notice
bridge_event_deliver_notice :: proc(instance_id, kind, sender, a, b, line: string) -> bool {
    return bridge_pty_host_deliver_to_agent(instance_id, kind, sender, a, b, human_message = line)
}
bridge_event_now_proc: proc() -> i64 = bridge_runtime_now_ms

bridge_event_decide :: proc(ledger: Maybe(Bridge_Ledger_Entry), local: Bridge_Event_Local, final: bool, busy_reason: string) -> (action: Bridge_Event_Action, reason: string, retry_after_ms: i64) {
    if e, has := ledger.?; has {
        if e.state == .Done do return .Answer_Stored, "", 0
        if e.state == .In_Progress && e.effect == .Start && (local == .Booting || local == .Idle || local == .Busy) do return .Answer_Started, "", 0
    }
    if busy_reason != "" do return (.Fatal if final else .Retry), busy_reason, 0
    switch local {
    case .Stopping:
        if !final do return .Retry, "stopping", 5000
        return .Start, "", 0
    case .Booting: return .Answer_Started, "", 0
    case .Idle: return .Type_Notice, "", 0
    case .Busy:
        if final do return .Type_Notice, "", 0
        return .Retry, "busy", 0
    case .Absent: return .Start, "", 0
    case .Unknown: return (.Fatal if final else .Retry), "process_unverified", 5000 if !final else 0
    }
    return .Fatal, "invalid_frame", 0
}
bridge_event_local :: proc(instance_id: string) -> Bridge_Event_Local {
    snap, found := bridge_event_snapshot_proc(instance_id)
    if found && snap.stopped_intent_unix_ms > 0 && bridge_event_now_proc() - snap.stopped_intent_unix_ms < i64(BRIDGE_STOP_INTENT_TTL_MS) do return .Stopping
    observation := bridge_event_probe_proc(instance_id)
    if observation.state == "absent" || observation.state == "exited" do return .Absent
    if observation.state != "alive" do return .Unknown
    if !found || !snap.start_success_seen do return .Booting
    if snap.activity_status == "idle" do return .Idle
    return .Busy
}
bridge_event_start :: proc(instance_id, delivery_id: string, deadline_ns: i64) -> Bridge_Wake_Result {
    return bridge_wake_attempt(instance_id, bridge_event_now_proc(), deadline_ns, delivery_id)
}
bridge_event_type_notice :: proc(instance_id: string, notice: contracts.Delivery_Notice_Wire) -> bool {
    if notice.line == contracts.DELIVERY_NOTICE_MESSAGE {
        return bridge_event_rollover_proc(instance_id, "user") || bridge_event_deliver_proc(instance_id, "message", "user", "", "", "")
    }
    if notice.line == contracts.DELIVERY_NOTICE_EVENTS {
        line := fmt.tprintf(contracts.EVENTS_NOTICE_FORMAT, notice.count)
        return bridge_event_deliver_proc(instance_id, "task_nudge", "events", "", "", line)
    }
    return false
}
bridge_event_start_answer :: proc(result: Bridge_Wake_Result, final: bool) -> (outcome, class, reason: string, retry: i64) {
    switch result.outcome {
    case .Launched, .Already_Active: return "started", "", "", 0
    case .Coalesced, .Backing_Off: return "", ("fatal" if final else "retry"), "start_backoff", result.retry_after_ms if !final else 0
    case .Parked: return "", "fatal", "start_parked", 0
    case .Failed:
        reason := "launch_failed"
        if result.err.code == .hub_rejected {
            reason = "start_refused"
            if result.err.hub_status == 404 do reason = "target_missing" if result.err.class == .fatal else "hub_unavailable"
            if result.err.hub_status == 409 && result.err.retry_after_ms == BRIDGE_LIVE_ROW_RETRY_MS do reason = "hub_row_live"
        }
        retry := result.err.class == .retriable && !final
        return "", ("retry" if retry else "fatal"), reason, result.retry_after_ms if retry else 0
    }
    return "", "fatal", "launch_failed", 0
}
bridge_event_deliver_handle :: proc(conn: ^ws.Connection, text: string) {
    frame: contracts.Event_Deliver_Wire
    parse_err := json.unmarshal_string(text, &frame, allocator = context.temp_allocator)
    command_id := frame.command_id
    if command_id == "" do command_id = extract_json_string(text, "command_id", "", context.temp_allocator)
    outcome, class, reason := "", "fatal", "invalid_frame"
    retry: i64
    id := frame.delivery.delivery_id
    // The sole answer is deferred until all effects and persistence are finished.
    defer {
        if class != "" && id != "" do bridge_event_ledger_forget(id)
        if frame.final && class == "retry" { class = "fatal"; retry = 0 }
        answer := bridge_event_result_json(command_id, "succeeded" if class == "" else "failed", outcome, class, retry, reason, reason)
        defer delete(answer)
        bridge_runtime_cache_command(command_id, answer)
        _ = bridge_event_send_proc(conn, answer)
    }
    if parse_err != nil || frame.type != contracts.EVENT_DELIVER_FRAME || command_id == "" || id == "" ||
        frame.agent_instance_id == "" || frame.delivery.agent_instance_id != frame.agent_instance_id || frame.delivery.kind == "" { return }
    kind := frame.delivery.kind
    if kind != "prompt" && kind != "notice" && kind != "bot" && kind != "lease" do return
    entry, found := bridge_event_ledger_get(id)
    ledger: Maybe(Bridge_Ledger_Entry)
    if found do ledger = entry
    local := bridge_event_local(frame.agent_instance_id)
    busy_reason, _ := bridge_bot_busy_reason()
    action, why, delay := bridge_event_decide(ledger, local, frame.final, busy_reason)
    if action == .Answer_Stored { outcome, class, reason = entry.outcome, "", ""; return }
    if kind == "bot" || kind == "lease" { reason = "unknown_kind"; return }
    if frame.delivery.notice.line != "message" && frame.delivery.notice.line != "events" do return
    now := bridge_event_now_proc()
    switch action {
    case .Answer_Stored:
    case .Retry, .Fatal:
        class, reason, retry = ("retry" if action == .Retry else "fatal"), why, delay
    case .Answer_Started:
        if found && entry.state == .In_Progress && !bridge_event_ledger_done(id, "started", now) { reason = bridge_event_ledger_failure_reason(); class = "fatal" if frame.final else "retry"; retry = 60_000 if !frame.final else 0; return }
        outcome, class, reason = "started", "", ""
    case .Type_Notice, .Start:
        expires: i64
        if stamp, consumed := time.rfc3339_to_time_utc(frame.delivery.expires_at); consumed == len(frame.delivery.expires_at) && consumed > 0 do expires = time.to_unix_nanoseconds(stamp) / i64(time.Millisecond)
        effect := Bridge_Ledger_Effect.Type if action == .Type_Notice else Bridge_Ledger_Effect.Start
        if !bridge_event_ledger_begin(id, effect, now, expires) {
            class, reason, retry = ("fatal" if frame.final else "retry"), bridge_event_ledger_failure_reason(), (0 if frame.final else 60_000)
            return
        }
        if action == .Type_Notice {
            if !bridge_event_notice_proc(frame.agent_instance_id, frame.delivery.notice) {
                class, reason = ("fatal" if frame.final else "retry"), "notice_failed"
                return
            }
            outcome, class, reason = "notified", "", ""
        } else {
            result := bridge_event_start_proc(frame.agent_instance_id, id, bridge_command_worker_deadline_ns(conn))
            if result.outcome == .Failed && result.err.code != .hub_rejected && result.err.code != .hub_connect_failed do bridge_wake_report_failed_status(conn, frame.agent_instance_id)
            outcome, class, reason, retry = bridge_event_start_answer(result, frame.final)
        }
        if class == "" && !bridge_event_ledger_done(id, outcome, now) {
            outcome, class, reason, retry = "", ("fatal" if frame.final else "retry"), bridge_event_ledger_failure_reason(), (0 if frame.final else 60_000)
        }
    }
}
