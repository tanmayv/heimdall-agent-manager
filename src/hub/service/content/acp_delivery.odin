package content

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// ACP user-input delivery evidence (see docs in contracts/acp_chat.odin).
//
// Two independent evidence dimensions per user message sent to an ACP agent:
//   state       sent -> queued -> dispatching -> delivered (or discarded),
//               bridge-authored, monotonic by report_seq, fenced by launch_epoch;
//   agent_read  set only when the agent itself reads the row through chat read.
// Bridge inbox admission (chat_messages.read_at for ACP) is neither of them.
// Only queued/dispatching rows with hold_reason turn_active are Send now eligible.

ACP_SEND_NOW_STALL_MS :: 30_000

Delivery_Apply_Result :: struct {
    conversation: domain.Chat_Conversation,
    changed_ids: [dynamic]string,
    requeued_ids: [dynamic]string,
    batch_changed: bool,
    stale: bool,
}

Send_Now_Request :: struct {
    request_id, launch_epoch: string,
    message_ids: []string,
}

Send_Now_Excluded :: struct { message_id, reason: string }

Send_Now_Result :: struct {
    // accepted | duplicate | empty | delivered | failed | queued (a memberless
    // Send now the runtime held back: not delivered, the notice waits for idle)
    outcome: string,
    batch: domain.ACP_Send_Now_Batch,
    conversation: domain.Chat_Conversation,
    changed_ids: [dynamic]string,
}

acp_delivery_state_valid :: proc(state: string) -> bool {
    switch state { case "queued", "dispatching", "delivered": return true }
    return false
}

acp_delivery_status :: proc(row: domain.ACP_Input_Delivery) -> string {
    // Sent -> optional Queued -> Delivered -> Read. Read needs agent evidence.
    if row.agent_read_at != "" do return "read"
    switch row.state {
    case "delivered": return "delivered"
    case "queued", "dispatching": return "queued" if row.hold_reason == "turn_active" else "sent"
    case "discarded": return "not_delivered"
    }
    return "sent"
}

// Tray/Send now eligibility: held by the bridge because a turn is running.
acp_delivery_turn_held :: proc(row: domain.ACP_Input_Delivery) -> bool {
    return (row.state == "queued" || row.state == "dispatching") && row.hold_reason == "turn_active" && row.agent_read_at == ""
}

acp_delivery_id_valid :: proc(id: string) -> bool {
    if len(id) < 5 || len(id) > 128 || !strings.has_prefix(id, "msg_") do return false
    for ch in id do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-') do return false
    return true
}

acp_delivery_token_valid :: proc(v: string, max: int, allow_empty := true) -> bool {
    if v == "" do return allow_empty
    if len(v) > max do return false
    for ch in v do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-' || ch == ':' || ch == '.') do return false
    return true
}

acp_delivery_ids_json :: proc(ids: []string) -> string {
    raw, _ := json.marshal(ids, allocator = context.temp_allocator)
    return string(raw)
}

acp_delivery_ids_parse :: proc(raw: string) -> []string {
    ids: []string
    if raw == "" || json.unmarshal_string(raw, &ids, allocator = context.temp_allocator) != nil do return nil
    return ids
}

// Creates the `sent` record for a user message to an ACP instance. Best effort:
// the bridge report path creates a missing record lazily.
acp_delivery_record_sent :: proc(s: ^Content_Service, c: domain.Chat_Conversation, m: domain.Chat_Message) {
    if s == nil || s.agents == nil || m.direction != "user_to_agent" || c.agent_instance_id == "" do return
    inst, found, _ := iface.agent_get_instance(s.agents, c.agent_instance_id)
    if !found || inst.runtime_transport != "acp" do return
    row := domain.ACP_Input_Delivery{message_id=m.message_id, owner_user_id=string(c.owner_user_id), conversation_id=c.conversation_id,
        agent_instance_id=c.agent_instance_id, state="sent", created_at=m.created_at, updated_at=m.created_at}
    if err := iface.content_save_input_delivery(s.content, row); err.code != .None do fmt.println("ACP delivery record failed", m.message_id, err.message)
}

acp_delivery_report_valid :: proc(report: contracts.ACP_Input_State_Report) -> bool {
    if len(report.launch_epoch) == 0 || len(report.launch_epoch) > 256 || report.report_seq < 1 || len(report.inputs) > contracts.ACP_INPUT_REPORT_MAX_ENTRIES do return false
    if !acp_delivery_token_valid(report.batch_id, 128) || report.batch_attempt < 0 do return false
    switch report.batch_state { case "", "dispatching", "delivered", "empty", "failed": case: return false }
    if !acp_delivery_token_valid(report.batch_error, 64) do return false
    if report.batch_state != "" && (report.batch_id == "" || report.batch_attempt < 1) do return false
    for e in report.inputs {
        if !acp_delivery_id_valid(e.message_id) || !acp_delivery_state_valid(e.state) do return false
        switch e.hold_reason { case "", "turn_active", "dispatch_pending": case: return false }
        switch e.mode { case "", "prompt", "steer": case: return false }
        if (e.state == "delivered") != (e.mode != "") do return false
        if !acp_delivery_token_valid(e.turn_id, 256) || !acp_delivery_token_valid(e.batch_id, 128) || !acp_delivery_token_valid(e.error, 64) do return false
    }
    return true
}

// Applies one bridge report atomically. A report from an epoch other than the
// instance's current one only touches rows still bound to that epoch. The first
// report of a new epoch reopens never-dispatched inputs of older epochs (they
// were lost with the old runtime queue) and discards ambiguous in-flight steers.
apply_input_state_report :: proc(s: ^Content_Service, auth: contracts.Auth_Context, instance: string, report: contracts.ACP_Input_State_Report) -> (Delivery_Apply_Result, bool, domain.Domain_Error) {
    result: Delivery_Apply_Result
    result.changed_ids = make([dynamic]string, context.temp_allocator)
    result.requeued_ids = make([dynamic]string, context.temp_allocator)
    if auth.kind != .Instance_Token || instance == "" || auth.agent_instance_id != instance do return result, false, domain.domain_error(.Forbidden, "instance token is required")
    if !acp_delivery_report_valid(report) do return result, false, domain.domain_error(.Validation_Failed, "invalid input state report")
    uow, begun, uerr := iface.unit_of_work_begin(s.uow_factory)
    if !begun do return result, false, uerr
    committed := false
    defer if !committed do iface.unit_of_work_rollback(&uow)
    local := s^
    if uow.repos != nil { local.content = &uow.repos.content; local.agents = &uow.repos.agents }
    c, found, cerr := get_conversation_by_instance(&local, auth, instance)
    if !found do return result, false, cerr
    result.conversation = c
    inst, exists, ierr := iface.agent_get_instance(local.agents, instance)
    if !exists do return result, false, ierr
    if string(inst.owner_user_id) != auth.user_id do return result, false, domain.domain_error(.Forbidden, "instance owner mismatch")
    now := platform.clock_now(s.clock)
    current := inst.launch_epoch == report.launch_epoch && inst.runtime_transport == "acp"
    result.stale = !current
    if current {
        rt, have_rt, rerr := iface.content_get_input_runtime(local.content, instance)
        if rerr.code != .None do return result, false, rerr
        if !have_rt || rt.launch_epoch != report.launch_epoch {
            open, lerr := iface.content_list_open_input_deliveries(local.content, "", instance)
            if lerr.code != .None do return result, false, lerr
            for row in open {
                if row.launch_epoch == "" || row.launch_epoch == report.launch_epoch do continue
                next := row
                next.updated_at = now; next.batch_id = ""; next.report_seq = 0
                if row.state == "queued" {
                    // Never dispatched: safe to admit again in the new runtime.
                    next.state = "sent"; next.launch_epoch = ""; next.hold_reason = ""; next.error = ""
                    if err := iface.content_set_message_delivery_flags(local.content, row.message_id, "", true); err.code != .None do return result, false, err
                    append(&result.requeued_ids, row.message_id)
                } else {
                    // A steer in flight when the runtime ended is ambiguous; never replay it.
                    next.state = "discarded"; next.error = "agent_restarted"
                }
                if err := iface.content_save_input_delivery(local.content, next); err.code != .None do return result, false, err
                append(&result.changed_ids, row.message_id)
            }
            batch, have_batch, berr := iface.content_latest_send_now_batch(local.content, c.conversation_id)
            if berr.code != .None do return result, false, berr
            if have_batch && batch.launch_epoch != report.launch_epoch && acp_batch_open(batch.state) {
                batch.state = "failed"; batch.error = "agent_restarted"; batch.updated_at = now
                if err := iface.content_save_send_now_batch(local.content, batch); err.code != .None do return result, false, err
                result.batch_changed = true
            }
        }
        if !have_rt || rt.launch_epoch != report.launch_epoch || rt.steering_supported != report.steering_supported {
            if err := iface.content_save_input_runtime(local.content, {agent_instance_id=instance, launch_epoch=report.launch_epoch, steering_supported=report.steering_supported, updated_at=now}); err.code != .None do return result, false, err
        }
    }
    for e in report.inputs {
        row, have, gerr := iface.content_get_input_delivery(local.content, e.message_id)
        if gerr.code != .None do return result, false, gerr
        if !have {
            if !current do continue
            msg, got, _ := iface.content_get_message(local.content, e.message_id)
            // The bridge inbox also carries agent-to-agent rows; only user input is tracked.
            if !got || msg.conversation_id != c.conversation_id || msg.owner_user_id != c.owner_user_id || msg.direction != "user_to_agent" do continue
            row = {message_id=msg.message_id, owner_user_id=string(c.owner_user_id), conversation_id=c.conversation_id, agent_instance_id=instance, state="sent", created_at=msg.created_at, updated_at=now}
        }
        if row.conversation_id != c.conversation_id || row.agent_instance_id != instance do continue
        // Epoch fence: an unbound row belongs only to the current epoch.
        if row.launch_epoch == "" { if !current do continue } else if row.launch_epoch != report.launch_epoch do continue
        if report.report_seq <= row.report_seq || row.state == "delivered" || row.state == "discarded" do continue
        next := row
        next.launch_epoch = report.launch_epoch; next.report_seq = report.report_seq; next.updated_at = now
        next.state = e.state; next.error = e.error
        if e.batch_id != "" do next.batch_id = e.batch_id
        if e.state == "delivered" {
            next.mode = e.mode; next.turn_id = e.turn_id
            if next.delivered_at == "" do next.delivered_at = now
            if err := iface.content_set_message_delivery_flags(local.content, row.message_id, next.delivered_at, false); err.code != .None do return result, false, err
            // Inline delivery is consumption for the reply origin (R7).
            if err := iface.content_record_input_consumption(local.content, c.owner_user_id, c.conversation_id, row.message_id, domain.INPUT_CONSUMED_DELIVERED, now); err.code != .None do return result, false, err
        } else if row.hold_reason != "turn_active" {
            // turn_active is sticky until delivery: a row never flickers out of the tray.
            next.hold_reason = e.hold_reason
        }
        if err := iface.content_save_input_delivery(local.content, next); err.code != .None do return result, false, err
        append(&result.changed_ids, row.message_id)
    }
    if report.batch_state != "" {
        batch, have_batch, berr := iface.content_get_send_now_batch(local.content, report.batch_id)
        if berr.code != .None do return result, false, berr
        if have_batch && batch.conversation_id == c.conversation_id && batch.launch_epoch == report.launch_epoch &&
           batch.attempt == report.batch_attempt && acp_batch_transition_ok(batch.state, report.batch_state) {
            batch.state = report.batch_state; batch.error = report.batch_error; batch.updated_at = now
            if err := iface.content_save_send_now_batch(local.content, batch); err.code != .None do return result, false, err
            result.batch_changed = true
        }
    }
    ok, err := iface.unit_of_work_commit(&uow)
    if !ok do return result, false, err
    committed = true
    return result, true, {}
}

acp_batch_open :: proc(state: string) -> bool {
    return state == "pending" || state == "sent" || state == "dispatching"
}

acp_batch_transition_ok :: proc(from, to: string) -> bool {
    switch from {
    case "pending", "sent": return to == "dispatching" || to == "delivered" || to == "empty" || to == "failed"
    case "dispatching": return to == "delivered" || to == "empty" || to == "failed"
    }
    return false // delivered/empty/failed are final for an attempt
}

// The agent itself read these rows (chat read, not the bridge's input drain):
// record read evidence, which implies delivery. Returns the IDs whose bridge
// queue entry must be dropped so the bridge never prompts them again.
note_agent_read :: proc(s: ^Content_Service, auth: contracts.Auth_Context, instance: string, message_ids: []string) -> (changed: [dynamic]string, drop: [dynamic]string, c: domain.Chat_Conversation, err: domain.Domain_Error) {
    changed = make([dynamic]string, context.temp_allocator)
    drop = make([dynamic]string, context.temp_allocator)
    if len(message_ids) == 0 do return
    if auth.kind != .Instance_Token || auth.agent_instance_id != instance { err = domain.domain_error(.Forbidden, "instance token is required"); return }
    uow, begun, uerr := iface.unit_of_work_begin(s.uow_factory)
    if !begun { err = uerr; return }
    committed := false
    defer if !committed do iface.unit_of_work_rollback(&uow)
    local := s^
    if uow.repos != nil { local.content = &uow.repos.content; local.agents = &uow.repos.agents }
    found: bool
    c, found, err = get_conversation_by_instance(&local, auth, instance)
    if !found do return
    now := platform.clock_now(s.clock)
    for id in message_ids {
        row, have, gerr := iface.content_get_input_delivery(local.content, id)
        if gerr.code != .None { err = gerr; return }
        if !have || row.conversation_id != c.conversation_id || row.agent_read_at != "" do continue
        next := row
        next.agent_read_at = now; next.updated_at = now
        if row.state != "delivered" {
            if row.state != "discarded" do append(&drop, id)
            next.state = "delivered"; next.mode = "read"; next.error = ""
            if next.delivered_at == "" do next.delivered_at = now
            if e := iface.content_set_message_delivery_flags(local.content, id, next.delivered_at, false); e.code != .None { err = e; return }
        }
        if e := iface.content_save_input_delivery(local.content, next); e.code != .None { err = e; return }
        append(&changed, id)
    }
    ok, cerr := iface.unit_of_work_commit(&uow)
    if !ok { err = cerr; return }
    committed = true
    return
}

// Best effort: the bridge revalidates every batch on its dispatcher thread, so
// a lost drop only means the read input is skipped by its completed-set check
// or, at worst, delivered once more in a prompt (never steered twice).
acp_send_inputs_read :: proc(s: ^Content_Service, c: domain.Chat_Conversation, ids: []string) -> bool {
    if len(ids) == 0 || s.agents == nil || s.bridge_command_sink.send_runtime_command == nil do return false
    inst, ok, _ := iface.agent_get_instance(s.agents, c.agent_instance_id)
    if !ok || inst.bridge_id == "" do return false
    command_id := platform.generate_id(s.ids, "cmd_")
    raw, _ := json.marshal(contracts.ACP_Inputs_Read_Command{type=contracts.ACP_INPUTS_READ_COMMAND, command_id=command_id, bridge_id=inst.bridge_id, agent_instance_id=c.agent_instance_id, message_ids=ids}, allocator=context.temp_allocator)
    sent, _ := project_service.bridge_command_send_runtime(s.bridge_command_sink, project_service.Runtime_Command{bridge_id=inst.bridge_id, command_id=command_id, body_json=string(raw)})
    return sent
}

acp_send_now_command_id :: proc(batch: domain.ACP_Send_Now_Batch) -> string {
    return fmt.tprintf("cmd_sn_%s_a%d", batch.batch_id, batch.attempt)
}

acp_batch_stalled :: proc(batch: domain.ACP_Send_Now_Batch, now: string) -> bool {
    if batch.state != "pending" && batch.state != "sent" do return false
    then, ok1 := platform.rfc3339_to_unix_ms(batch.updated_at)
    at, ok2 := platform.rfc3339_to_unix_ms(now)
    return ok1 && ok2 && at-then >= ACP_SEND_NOW_STALL_MS
}

acp_send_now_eligible :: proc(row: domain.ACP_Input_Delivery, epoch: string) -> (bool, string) {
    if row.agent_read_at != "" do return false, "read"
    switch row.state {
    case "delivered": return false, "delivered"
    case "discarded": return false, "discarded"
    case "dispatching": return false, "dispatching"
    case "sent": return false, "not_turn_held"
    }
    if row.launch_epoch != epoch do return false, "stale"
    if row.hold_reason != "turn_active" do return false, "not_turn_held"
    return true, ""
}

// One conversation-level Send now. The first request snapshots every queued,
// turn-held, current-epoch input (optionally cut off to message_ids the client
// saw) in FIFO order. Retrying a failed batch with the same request_id bumps the
// attempt and re-validates the frozen members; it never adds later arrivals.
send_now :: proc(s: ^Content_Service, auth: contracts.Auth_Context, cid: string, req: Send_Now_Request) -> (Send_Now_Result, bool, domain.Domain_Error) {
    result: Send_Now_Result
    result.changed_ids = make([dynamic]string, context.temp_allocator)
    if !acp_delivery_token_valid(req.request_id, 128, allow_empty=false) do return result, false, domain.domain_error(.Validation_Failed, "request_id is required (1-128 safe characters)")
    if len(req.message_ids) > contracts.ACP_SEND_NOW_MAX_MEMBERS do return result, false, domain.domain_error(.Validation_Failed, "too many message_ids")
    for id in req.message_ids do if !acp_delivery_id_valid(id) do return result, false, domain.domain_error(.Validation_Failed, "invalid message id")
    uow, begun, uerr := iface.unit_of_work_begin(s.uow_factory)
    if !begun do return result, false, uerr
    committed := false
    defer if !committed do iface.unit_of_work_rollback(&uow)
    local := s^
    if uow.repos != nil { local.content = &uow.repos.content; local.agents = &uow.repos.agents }
    c, found, cerr := get_conversation(&local, auth, cid)
    if !found do return result, false, cerr
    result.conversation = c
    if local.agents == nil do return result, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
    inst, exists, ierr := iface.agent_get_instance(local.agents, c.agent_instance_id)
    if !exists || inst.owner_user_id != c.owner_user_id do return result, false, ierr if ierr.code != .None else domain.domain_error(.Not_Found, "agent instance not found")
    send_now_kind := contracts.runtime_transport_capabilities(inst.runtime_transport).send_now
    if send_now_kind == .Unsupported do return result, false, domain.domain_error(.Conflict, "send now is not available for this agent's runtime")
    if req.launch_epoch != inst.launch_epoch do return result, false, domain.domain_error(.Conflict, "stale launch epoch")
    if send_now_kind == .Notice {
        notice, recorded, nerr := send_now_notice_record(&local, &uow, c, inst, req)
        if !recorded do return notice, false, nerr
        committed = true
        if notice.outcome != "accepted" do return notice, true, {}
        return send_now_notice_dispatch(s, inst, notice), true, {}
    }
    now := platform.clock_now(s.clock)
    batch, have, berr := iface.content_find_send_now_batch(local.content, c.conversation_id, req.request_id)
    if berr.code != .None do return result, false, berr
    send := false
    if have {
        if batch.launch_epoch != inst.launch_epoch && acp_batch_open(batch.state) { batch.state = "failed"; batch.error = "agent_restarted" }
        if acp_batch_stalled(batch, now) { batch.state = "failed"; batch.error = "bridge_no_response" }
        switch batch.state {
        case "pending", "sent", "dispatching":
            result.outcome = "duplicate"; result.batch = batch
            return result, true, {}
        case "delivered", "empty":
            result.outcome = batch.state; result.batch = batch
            return result, true, {}
        }
        if batch.launch_epoch != inst.launch_epoch do return result, false, domain.domain_error(.Conflict, "stale launch epoch")
        // Explicit retry of a failed attempt: attempt-specific command identity.
        members := make([dynamic]string, context.temp_allocator)
        excluded := make([dynamic]Send_Now_Excluded, context.temp_allocator)
        for id in acp_delivery_ids_parse(batch.member_ids_json) {
            row, ok, gerr := iface.content_get_input_delivery(local.content, id)
            if gerr.code != .None do return result, false, gerr
            eligible, reason := false, "not_found"
            if ok && row.conversation_id == c.conversation_id do eligible, reason = acp_send_now_eligible(row, inst.launch_epoch)
            if eligible { append(&members, id) } else { append(&excluded, Send_Now_Excluded{id, reason}) }
        }
        batch.attempt += 1; batch.error = ""; batch.updated_at = now
        batch.member_ids_json = acp_delivery_ids_json(members[:])
        raw, _ := json.marshal(excluded[:], allocator=context.temp_allocator); batch.excluded_json = string(raw)
        batch.state = "pending" if len(members) > 0 else "empty"
        send = len(members) > 0
    } else {
        latest, have_latest, lerr := iface.content_latest_send_now_batch(local.content, c.conversation_id)
        if lerr.code != .None do return result, false, lerr
        if have_latest && latest.launch_epoch == inst.launch_epoch && acp_batch_open(latest.state) && !acp_batch_stalled(latest, now) {
            // One batch per conversation: a second click while one is in flight never sends a command.
            result.outcome = "duplicate"; result.batch = latest
            return result, true, {}
        }
        open, oerr := iface.content_list_open_input_deliveries(local.content, c.conversation_id, "")
        if oerr.code != .None do return result, false, oerr
        members := make([dynamic]string, context.temp_allocator)
        excluded := make([dynamic]Send_Now_Excluded, context.temp_allocator)
        for row in open {
            if len(req.message_ids) > 0 {
                listed := false
                for id in req.message_ids do if id == row.message_id do listed = true
                if !listed do continue // arrived after the client's snapshot
            }
            eligible, reason := acp_send_now_eligible(row, inst.launch_epoch)
            if eligible && len(members) < contracts.ACP_SEND_NOW_MAX_MEMBERS { append(&members, row.message_id) } else if !eligible && len(req.message_ids) > 0 { append(&excluded, Send_Now_Excluded{row.message_id, reason}) }
        }
        for id in req.message_ids {
            seen := false
            for m in members do if m == id do seen = true
            for e in excluded do if e.message_id == id do seen = true
            if seen do continue
            row, ok, _ := iface.content_get_input_delivery(local.content, id)
            reason := "not_found"
            if ok && row.conversation_id == c.conversation_id { _, reason = acp_send_now_eligible(row, inst.launch_epoch) }
            append(&excluded, Send_Now_Excluded{id, reason})
        }
        raw, _ := json.marshal(excluded[:], allocator=context.temp_allocator)
        batch = {batch_id=platform.generate_id(s.ids, "snb_"), owner_user_id=string(c.owner_user_id), conversation_id=c.conversation_id,
            agent_instance_id=c.agent_instance_id, launch_epoch=inst.launch_epoch, request_id=req.request_id, attempt=1,
            state="pending" if len(members) > 0 else "empty", member_ids_json=acp_delivery_ids_json(members[:]), excluded_json=string(raw),
            created_at=now, updated_at=now}
        send = len(members) > 0
    }
    for id in acp_delivery_ids_parse(batch.member_ids_json) {
        row, ok, _ := iface.content_get_input_delivery(local.content, id)
        if !ok || row.batch_id == batch.batch_id do continue
        row.batch_id = batch.batch_id; row.updated_at = now
        if err := iface.content_save_input_delivery(local.content, row); err.code != .None do return result, false, err
        append(&result.changed_ids, id)
    }
    if err := iface.content_save_send_now_batch(local.content, batch); err.code != .None do return result, false, err
    ok, err := iface.unit_of_work_commit(&uow)
    if !ok do return result, false, err
    committed = true
    result.batch = batch
    result.outcome = "accepted" if send else "empty"
    if !send do return result, true, {}
    command := contracts.ACP_Send_Now_Batch_Command{type=contracts.ACP_SEND_NOW_BATCH_COMMAND, command_id=acp_send_now_command_id(batch), bridge_id=inst.bridge_id,
        agent_instance_id=c.agent_instance_id, launch_epoch=batch.launch_epoch, batch_id=batch.batch_id, attempt=batch.attempt, message_ids=acp_delivery_ids_parse(batch.member_ids_json)}
    raw, _ := json.marshal(command, allocator=context.temp_allocator)
    delivered := false
    if inst.bridge_id != "" && s.bridge_command_sink.send_runtime_command != nil {
        delivered, _ = project_service.bridge_command_send_runtime(s.bridge_command_sink, project_service.Runtime_Command{bridge_id=inst.bridge_id, command_id=command.command_id, body_json=string(raw)})
    }
    next := "sent" if delivered else "failed"
    updated, applied := acp_batch_advance_local(s, batch.batch_id, batch.attempt, "pending", next, "" if delivered else "bridge_offline")
    if applied do result.batch = updated
    if !delivered { result.outcome = "failed"; if !applied { result.batch.state = "failed"; result.batch.error = "bridge_offline" } }
    return result, true, {}
}

// Send now for a runtime without members (contracts.Runtime_Send_Now.Notice):
// the agent reads its own conversation, so the request carries no message ids
// and the bridge types one unread notice. The request is recorded as a batch
// row without members, so a repeat click with the same request_id is
// idempotent and a click while one is in flight never sends a second command.
// Commits the unit of work on success; outcome "accepted" means dispatch next.
send_now_notice_record :: proc(local: ^Content_Service, uow: ^iface.Unit_Of_Work, c: domain.Chat_Conversation, inst: domain.Agent_Instance, req: Send_Now_Request) -> (Send_Now_Result, bool, domain.Domain_Error) {
    result: Send_Now_Result
    result.changed_ids = make([dynamic]string, context.temp_allocator)
    result.conversation = c
    now := platform.clock_now(local.clock)
    batch, have, berr := iface.content_find_send_now_batch(local.content, c.conversation_id, req.request_id)
    if berr.code != .None do return result, false, berr
    if have {
        if batch.launch_epoch != inst.launch_epoch && acp_batch_open(batch.state) { batch.state = "failed"; batch.error = "agent_restarted" }
        if acp_batch_stalled(batch, now) { batch.state = "failed"; batch.error = "bridge_no_response" }
        switch batch.state {
        case "pending", "sent", "dispatching":
            result.outcome = "duplicate"; result.batch = batch
            ok, err := iface.unit_of_work_commit(uow)
            return result, ok, err
        case "delivered", "empty":
            result.outcome = batch.state; result.batch = batch
            ok, err := iface.unit_of_work_commit(uow)
            return result, ok, err
        }
        if batch.launch_epoch != inst.launch_epoch do return result, false, domain.domain_error(.Conflict, "stale launch epoch")
        batch.attempt += 1; batch.error = ""; batch.state = "pending"; batch.updated_at = now
    } else {
        latest, have_latest, lerr := iface.content_latest_send_now_batch(local.content, c.conversation_id)
        if lerr.code != .None do return result, false, lerr
        if have_latest && latest.launch_epoch == inst.launch_epoch && acp_batch_open(latest.state) && !acp_batch_stalled(latest, now) {
            result.outcome = "duplicate"; result.batch = latest
            ok, err := iface.unit_of_work_commit(uow)
            return result, ok, err
        }
        batch = {batch_id=platform.generate_id(local.ids, "snb_"), owner_user_id=string(c.owner_user_id), conversation_id=c.conversation_id,
            agent_instance_id=c.agent_instance_id, launch_epoch=inst.launch_epoch, request_id=req.request_id, attempt=1,
            state="pending", member_ids_json="[]", excluded_json="[]", created_at=now, updated_at=now}
    }
    if err := iface.content_save_send_now_batch(local.content, batch); err.code != .None do return result, false, err
    ok, err := iface.unit_of_work_commit(uow)
    if !ok do return result, false, err
    result.batch = batch; result.outcome = "accepted"
    return result, true, {}
}

// The bridge's command result is the outcome: delivered once the runtime has
// typed the notice; otherwise the stored batch is failed with the refusal's
// reason (send_now_notice_refusal), never delivered. A sink that cannot wait for results
// leaves the request sent (a stall makes it retryable).
SEND_NOW_NOTICE_REPLY_TIMEOUT_MS :: 15_000

send_now_notice_dispatch :: proc(s: ^Content_Service, inst: domain.Agent_Instance, accepted: Send_Now_Result) -> Send_Now_Result {
    result := accepted
    batch := accepted.batch
    command := contracts.ACP_Send_Now_Batch_Command{type=contracts.ACP_SEND_NOW_BATCH_COMMAND, command_id=acp_send_now_command_id(batch), bridge_id=inst.bridge_id,
        agent_instance_id=batch.agent_instance_id, launch_epoch=batch.launch_epoch, batch_id=batch.batch_id, attempt=batch.attempt}
    raw, _ := json.marshal(command, allocator=context.temp_allocator)
    runtime_command := project_service.Runtime_Command{bridge_id=inst.bridge_id, command_id=command.command_id, body_json=string(raw)}
    next, error := "failed", "bridge_offline"
    queued := false
    if inst.bridge_id != "" && s.bridge_command_sink.send_runtime_command_wait != nil {
        reply, replied, werr := project_service.bridge_command_send_runtime_wait(s.bridge_command_sink, runtime_command, SEND_NOW_NOTICE_REPLY_TIMEOUT_MS)
        if replied {
            defer delete(reply)
            if typed, rerr := project_service.bridge_reply_refusal(reply, inst.bridge_id); typed { next, error = "delivered", "" } else { error, queued = send_now_notice_refusal(rerr.cause) }
        } else {
            // A failed command_result arrives as a typed refusal.
            #partial switch werr.code {
            case .Bridge_Offline:
            case .Bridge_Timeout: error = "bridge_no_response"
            case: error, queued = send_now_notice_refusal(werr.cause)
            }
        }
    } else if inst.bridge_id != "" && s.bridge_command_sink.send_runtime_command != nil {
        if sent, _ := project_service.bridge_command_send_runtime(s.bridge_command_sink, runtime_command); sent { next, error = "sent", "" }
    }
    updated, applied := acp_batch_advance_local(s, batch.batch_id, batch.attempt, "pending", next, error)
    result.batch = updated if applied else batch
    if !applied { result.batch.state = next; result.batch.error = error }
    switch next {
    case "delivered": result.outcome = "delivered"
    case "failed": result.outcome = "queued" if queued else "failed"
    }
    return result
}

// send_now_notice_refusal maps the bridge's refusal cause to the batch error
// (contracts.Runtime_Send_Now_Outcome). The batch is never delivered then; a
// queued outcome (held) is not a failure for the
// user: the bridge keeps the notice and types it at the next trusted idle.
send_now_notice_refusal :: proc(cause: string) -> (error: string, queued: bool) {
    outcome := contracts.runtime_send_now_outcome_from_cause(cause)
    return contracts.RUNTIME_SEND_NOW_BATCH_ERROR[outcome], contracts.runtime_send_now_outcome_queued(outcome)
}

// Compare-and-set on (attempt, state) so a racing bridge report wins.
acp_batch_advance_local :: proc(s: ^Content_Service, batch_id: string, attempt: i64, from, to, error: string) -> (domain.ACP_Send_Now_Batch, bool) {
    uow, begun, _ := iface.unit_of_work_begin(s.uow_factory)
    if !begun do return {}, false
    committed := false
    defer if !committed do iface.unit_of_work_rollback(&uow)
    repo := s.content
    if uow.repos != nil do repo = &uow.repos.content
    batch, have, _ := iface.content_get_send_now_batch(repo, batch_id)
    if !have || batch.attempt != attempt || batch.state != from do return batch, false
    batch.state = to; batch.error = error; batch.updated_at = platform.clock_now(s.clock)
    if err := iface.content_save_send_now_batch(repo, batch); err.code != .None do return batch, false
    ok, _ := iface.unit_of_work_commit(&uow)
    committed = ok
    return batch, ok
}

// Re-admission after relaunch needs a fetch edge on the bridge.
acp_delivery_notify_requeued :: proc(s: ^Content_Service, c: domain.Chat_Conversation, ids: []string) {
    if len(ids) == 0 do return
    _, _ = notify_agent_message_checked(s, c, "user_to_agent", "user", ids[0], "User")
}
