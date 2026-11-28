package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// ACP user-input delivery evidence and conversation-level Send now batches.
//
// Every report rides the ACP chat outbox, so the Hub receives it in FIFO
// order with assistant revisions (a delivered report always precedes the
// first assistant text it caused) and it survives restarts with the journal.
// All state here is owned by the runtime dispatcher thread.

ACP_SEND_NOW_KIND :: "send_now"

// Test seam: assistant-outbox suites that predate delivery evidence switch
// reports off; acp_send_now_test covers reports interleaved with assistant rows.
acp_delivery_reports_enabled := true
ACP_SEND_NOW_INPUT_PREFIX :: "batch_"

// Durable batch selection. members is FIFO and frozen at the first merge;
// later arrivals never join (except a rejected steer that predates it).
// state: waiting | steering | cancelling | delivered | failed | empty.
ACP_Send_Now_Durable :: struct {
    batch_id, state: string,
    attempt: i64,
    members: [dynamic]string,
}

acp_send_now_delete :: proc(d: ^ACP_Send_Now_Durable) {
    context.allocator = runtime.heap_allocator()
    delete(d.batch_id); delete(d.state)
    for id in d.members do delete(id)
    delete(d.members)
    d^ = {}
}

acp_send_now_valid :: proc(d: ^ACP_Send_Now_Durable) -> bool {
    if len(d.batch_id) > 128 || d.attempt < 0 || len(d.members) > contracts.ACP_SEND_NOW_MAX_MEMBERS+128 do return false
    switch d.state { case "", "waiting", "steering", "cancelling", "delivered", "failed", "empty": case: return false }
    for id in d.members do if id == "" || len(id) > 1024 do return false
    return true
}

acp_send_now_active :: proc(r: ^ACP_Runtime) -> bool {
    s := r.d.send_now.state
    return r.d.send_now.batch_id != "" && (s == "waiting" || s == "steering" || s == "cancelling")
}

acp_send_now_input_id :: proc(r: ^ACP_Runtime) -> string {
    return fmt.tprintf("%s%s", ACP_SEND_NOW_INPUT_PREFIX, r.d.send_now.batch_id)
}

acp_send_now_is_input :: proc(r: ^ACP_Runtime, input: ACP_Runtime_Input) -> bool {
    return input.kind == ACP_SEND_NOW_KIND || (r.d.send_now.batch_id != "" && input.id == acp_send_now_input_id(r))
}

// User inputs one runtime input stands for (a batch has several).
acp_delivery_members :: proc(r: ^ACP_Runtime, input_id: string) -> []string {
    if r.d.send_now.batch_id != "" && input_id == acp_send_now_input_id(r) do return r.d.send_now.members[:]
    if strings.has_prefix(input_id, "msg_") {
        ids := make([]string, 1, context.temp_allocator); ids[0] = input_id
        return ids
    }
    return nil
}

acp_send_now_member :: proc(r: ^ACP_Runtime, id: string) -> bool {
    for m in r.d.send_now.members do if m == id do return true
    return false
}

acp_delivery_hold :: proc(r: ^ACP_Runtime) -> string {
    return "turn_active" if r.d.phase == "prompt" else "dispatch_pending"
}

acp_delivery_entries :: proc(r: ^ACP_Runtime, ids: []string, state: string, mode := "", turn_id := "", error := "") -> []contracts.ACP_Input_State_Entry {
    out := make([dynamic]contracts.ACP_Input_State_Entry, context.temp_allocator)
    hold := "" if state == "delivered" else (state == "dispatching" ? "turn_active" : acp_delivery_hold(r))
    for id in ids {
        if !strings.has_prefix(id, "msg_") do continue
        batch := r.d.send_now.batch_id if acp_send_now_member(r, id) else ""
        append(&out, contracts.ACP_Input_State_Entry{message_id=id, state=state, hold_reason=hold, mode=mode, turn_id=turn_id, batch_id=batch, error=error})
    }
    return out[:]
}

acp_send_now_set_state :: proc(r: ^ACP_Runtime, state: string) {
    acp_runtime_replace(&r.d.send_now.state, state)
}

// Appends or coalesces one report into the chat outbox. Coalescing keeps the
// newest entry per message and the newest report_seq; it never merges two
// different batch outcomes, so a final batch state is never lost.
acp_delivery_report :: proc(r: ^ACP_Runtime, entries: []contracts.ACP_Input_State_Entry, batch_state := "", batch_error := "", batch_id := "", batch_attempt: i64 = 0) {
    if r.chat == nil || r.d.replay_only || !acp_delivery_reports_enabled do return
    if len(entries) == 0 && batch_state == "" do return
    context.allocator = runtime.heap_allocator()
    r.d.report_seq += 1
    d := &r.chat.d
    report: contracts.ACP_Input_State_Report
    merge := -1
    if n := len(d.outbox); n > 0 && d.outbox[n-1].kind == contracts.ACP_OUTBOX_INPUT_STATE {
        prior: contracts.ACP_Input_State_Report
        if json.unmarshal_string(d.outbox[n-1].body, &prior, allocator = context.temp_allocator) == nil {
            same_batch := prior.batch_state == "" || batch_state == "" || (batch_id == "" && prior.batch_id == r.d.send_now.batch_id && prior.batch_attempt == r.d.send_now.attempt)
            if same_batch && len(prior.inputs)+len(entries) <= contracts.ACP_INPUT_REPORT_MAX_ENTRIES { report = prior; merge = n-1 }
        }
    }
    inputs := make([dynamic]contracts.ACP_Input_State_Entry, context.temp_allocator)
    for e in report.inputs {
        replaced := false
        for n in entries do if n.message_id == e.message_id do replaced = true
        if !replaced do append(&inputs, e)
    }
    for e in entries do append(&inputs, e)
    report.inputs = inputs[:]
    report.launch_epoch = r.epoch
    report.report_seq = r.d.report_seq
    report.steering_supported = r.d.steering_supported
    if batch_state != "" {
        report.batch_id = r.d.send_now.batch_id; report.batch_attempt = r.d.send_now.attempt
        if batch_id != "" { report.batch_id = batch_id; report.batch_attempt = batch_attempt }
        report.batch_state = batch_state; report.batch_error = batch_error
    }
    body := acp_event_json(report)
    if merge >= 0 {
        entry := &d.outbox[merge]
        acp_runtime_replace(&entry.body, body)
        entry.revision += 1
    } else {
        append(&d.outbox, contracts.ACP_Assistant_Message_Input{kind=strings.clone(contracts.ACP_OUTBOX_INPUT_STATE), launch_epoch=strings.clone(r.epoch),
            message_id=strings.clone(fmt.tprintf("rpt_%d", r.d.report_seq)), revision=1, body=strings.clone(body), message_status=strings.clone("pending")})
    }
    acp_runtime_replace(&r.saved_outbox, acp_event_json(d^))
}

// Prompt dispatch: deliver the primary input's members and mark every other
// user input still queued as held by this turn.
acp_delivery_prompt_started :: proc(r: ^ACP_Runtime, input_id, turn_id: string) {
    members := acp_delivery_members(r, input_id)
    entries := make([dynamic]contracts.ACP_Input_State_Entry, context.temp_allocator)
    for e in acp_delivery_entries(r, members, "delivered", mode="prompt", turn_id=turn_id) do append(&entries, e)
    for input in r.d.queue {
        if input.lane != .Steer do continue
        if acp_send_now_is_input(r, input) && input.kind != ACP_SEND_NOW_KIND {
            for e in acp_delivery_entries(r, r.d.send_now.members[:], "queued") do append(&entries, e)
        } else if strings.has_prefix(input.id, "msg_") {
            append(&entries, contracts.ACP_Input_State_Entry{message_id=input.id, state="queued", hold_reason="turn_active",
                batch_id=r.d.send_now.batch_id if acp_send_now_member(r, input.id) else ""})
        }
    }
    batch_state := ""
    if r.d.send_now.batch_id != "" && input_id == acp_send_now_input_id(r) {
        acp_send_now_set_state(r, "delivered"); batch_state = "delivered"
    }
    acp_delivery_report(r, entries[:], batch_state)
}

// Hub-side agent read evidence: the agent consumed these inputs itself, so
// they must never be prompted. Inputs already dispatched are unaffected.
acp_delivery_inputs_read :: proc(r: ^ACP_Runtime, ids: []string) -> bool {
    changed := false
    for id in ids {
        if !strings.has_prefix(id, "msg_") || len(id) > 1024 do continue
        for i := 0; i < len(r.d.queue); i += 1 {
            if r.d.queue[i].id != id || r.d.queue[i].lane != .Steer do continue
            acp_inbox_input_delete(r.d.queue[i]); ordered_remove(&r.d.queue, i)
            acp_inbox_remember(r, id); changed = true
            break
        }
        if acp_send_now_member(r, id) && acp_send_now_queued_members(r) {
            for m, i in r.d.send_now.members do if m == id { delete(m, runtime.heap_allocator()); ordered_remove(&r.d.send_now.members, i); break }
            changed = true
        }
    }
    if acp_send_now_active(r) && len(r.d.send_now.members) == 0 {
        acp_send_now_set_state(r, "empty")
        acp_delivery_report(r, nil, "empty")
    }
    return changed
}

// Members are still separate queue entries (the batch is not yet one input).
acp_send_now_queued_members :: proc(r: ^ACP_Runtime) -> bool {
    for input in r.d.queue do if input.kind == ACP_SEND_NOW_KIND do return true
    return false
}

ACP_Send_Now_Request :: struct {
    launch_epoch, batch_id: string,
    attempt: i64,
    message_ids: []string,
}

// Runs on the dispatcher, serialized with drain, steering results and turn
// completion. Re-validates every member against bridge truth: inputs already
// dispatched, in a steer in flight, part of the current turn or read are left
// out. The rest move to the queue front as one ordered batch; an empty batch
// is a no-op (never a cancel), so a stale request never interrupts later work.
acp_send_now_apply :: proc(r: ^ACP_Runtime, req: ACP_Send_Now_Request) -> bool {
    context.allocator = runtime.heap_allocator()
    if req.batch_id == "" || len(req.batch_id) > 128 || req.attempt < 1 || len(req.message_ids) > contracts.ACP_SEND_NOW_MAX_MEMBERS do return false
    d := &r.d.send_now
    if d.batch_id == req.batch_id && d.attempt >= req.attempt do return true // duplicate command delivery
    if req.launch_epoch != r.epoch do return false
    if d.batch_id != req.batch_id && acp_send_now_active(r) {
        // A different batch is still unresolved: keep one batch per runtime.
        acp_delivery_report(r, nil, "failed", "batch_in_progress", req.batch_id, req.attempt)
        return acp_rpc_checkpoint(r.client)
    }
    if d.batch_id == req.batch_id {
        d.attempt = req.attempt
        if acp_send_now_in_flight(r) {
            // Retry while the combined input is already steering, cancelling
            // or delivered: membership is frozen. Re-report the current state
            // for this attempt; never re-select (which would drop members).
            if d.state == "delivered" {
                acp_delivery_report(r, nil, "delivered")
            } else {
                acp_delivery_report(r, acp_delivery_entries(r, d.members[:], "dispatching"), "dispatching")
            }
            return acp_rpc_checkpoint(r.client)
        }
    } else {
        // An older batch's combined input that was never dispatched (failed)
        // is released back to ordinary queued inputs before the new selection.
        acp_send_now_release(r)
        acp_send_now_delete(d)
        d.batch_id = strings.clone(req.batch_id); d.attempt = req.attempt
    }
    if acp_send_now_combined_index(r) >= 0 {
        // Retry while the combined input is still queued (e.g. after a cancel
        // timeout on a recovered runtime): re-evaluate, never re-merge.
        acp_send_now_set_state(r, "waiting")
        acp_delivery_report(r, nil, "dispatching")
        acp_runtime_drain(r)
        return acp_rpc_checkpoint(r.client)
    }
    for id in d.members do delete(id)
    clear(&d.members)
    selected := make([dynamic]ACP_Runtime_Input, context.temp_allocator)
    for id in req.message_ids {
        for i := 0; i < len(r.d.queue); i += 1 {
            input := r.d.queue[i]
            if input.id != id || input.lane != .Steer || input.kind == ACP_BOT_KIND do continue
            append(&selected, input); ordered_remove(&r.d.queue, i)
            break
        }
    }
    if len(selected) == 0 {
        acp_send_now_set_state(r, "empty")
        acp_delivery_report(r, nil, "empty")
        return acp_rpc_checkpoint(r.client)
    }
    // FIFO among members follows bridge admission order, then front insertion.
    for &input in selected {
        acp_runtime_replace(&input.kind, ACP_SEND_NOW_KIND)
        append(&d.members, strings.clone(input.id))
    }
    inject_at_elems(&r.d.queue, 0, ..selected[:])
    acp_send_now_set_state(r, "waiting")
    acp_delivery_report(r, acp_delivery_entries(r, d.members[:], "queued"), "dispatching")
    if !acp_rpc_checkpoint(r.client) { acp_runtime_error(r, "acp_state_write_failed"); return false }
    acp_runtime_drain(r)
    return true
}

// The batch already left the queue as one input: a steer in flight, a cancel
// before its prompt, or dispatched.
acp_send_now_in_flight :: proc(r: ^ACP_Runtime) -> bool {
    d := &r.d.send_now
    if d.batch_id == "" do return false
    if r.d.steering_pending && r.d.steering_input.id == acp_send_now_input_id(r) do return true
    return d.state == "steering" || d.state == "cancelling" || d.state == "delivered"
}

acp_send_now_combined_index :: proc(r: ^ACP_Runtime) -> int {
    if r.d.send_now.batch_id == "" do return -1
    id := acp_send_now_input_id(r)
    for input, i in r.d.queue do if input.id == id do return i
    return -1
}

// Before a new batch: an old, undispatched selection returns to ordinary
// queued inputs (members keep their identity; a combined input stays one).
acp_send_now_release :: proc(r: ^ACP_Runtime) {
    for &input in r.d.queue do if input.kind == ACP_SEND_NOW_KIND do acp_runtime_replace(&input.kind, "")
}

// Builds the ONE ordered input that represents the batch, removing its
// members from the queue. Each original message keeps its own context block.
acp_send_now_collect :: proc(r: ^ACP_Runtime) -> ACP_Runtime_Input {
    context.allocator = runtime.heap_allocator()
    b := strings.builder_make(context.temp_allocator)
    count := 0
    for input in r.d.queue do if input.kind == ACP_SEND_NOW_KIND do count += 1
    fmt.sbprintf(&b, "[Heimdall: %d queued user messages sent together, oldest first. Each keeps its own message context.]", count)
    n := 0
    for i := 0; i < len(r.d.queue); {
        input := r.d.queue[i]
        if input.kind != ACP_SEND_NOW_KIND { i += 1; continue }
        n += 1
        fmt.sbprintf(&b, "\n\n--- message %d of %d ---\n", n, count)
        strings.write_string(&b, input.text)
        ordered_remove(&r.d.queue, i); acp_inbox_input_delete(input)
    }
    return {id = strings.clone(acp_send_now_input_id(r)), text = strings.clone(strings.to_string(b)), lane = .Steer, kind = strings.clone(ACP_SEND_NOW_KIND)}
}

// Busy and the batch cannot be steered right now. When the driver reports the
// turn will accept steering shortly (e.g. its native turn id is still pending),
// wait instead of cancelling; otherwise cancel the running turn once, and the
// batch becomes the next prompt.
acp_send_now_hold_or_cancel :: proc(r: ^ACP_Runtime, front: ACP_Runtime_Input) {
    if r.d.cancelling do return
    if acp_runtime_steer_readiness(r, front) == .Later {
        acp_send_now_set_state(r, "waiting")
        return
    }
    r.d.cancelling = true
    acp_send_now_set_state(r, "cancelling")
    acp_runtime_driver(r).permissions_cancel(r)
    if !acp_runtime_driver(r).cancel(r) { acp_runtime_error(r, "acp_pipe_write_failed"); return }
    if !acp_rpc_checkpoint(r.client) do acp_runtime_error(r, "acp_state_write_failed")
}

// A steering RPC finished without injection. The input returns to the queue
// FRONT (FIFO) and is never steered again. While a batch is selected, a
// rejected older user input joins it so the batch still goes as one prompt.
acp_delivery_steer_rejected :: proc(r: ^ACP_Runtime, input: ACP_Runtime_Input) {
    context.allocator = runtime.heap_allocator()
    input := input
    if acp_send_now_queued_members(r) && strings.has_prefix(input.id, "msg_") && acp_send_now_active(r) {
        acp_runtime_replace(&input.kind, ACP_SEND_NOW_KIND)
        inject_at(&r.d.send_now.members, 0, strings.clone(input.id))
    } else {
        acp_runtime_replace(&input.kind, "append_next_turn")
    }
    inject_at(&r.d.queue, 0, input)
    members := acp_delivery_members(r, input.id)
    if r.d.send_now.batch_id != "" && input.id == acp_send_now_input_id(r) do acp_send_now_set_state(r, "waiting")
    acp_delivery_report(r, acp_delivery_entries(r, members if input.kind != ACP_SEND_NOW_KIND else []string{input.id}, "queued"))
}

acp_delivery_steer_injected :: proc(r: ^ACP_Runtime, input: ACP_Runtime_Input) {
    members := acp_delivery_members(r, input.id)
    turn := r.chat.d.turn_id if r.chat != nil else ""
    batch_state := ""
    if r.d.send_now.batch_id != "" && input.id == acp_send_now_input_id(r) { acp_send_now_set_state(r, "delivered"); batch_state = "delivered" }
    for id in members do acp_inbox_remember(r, id)
    if r.chat != nil do acp_chat_set_next_inputs(r, members)
    acp_delivery_report(r, acp_delivery_entries(r, members, "delivered", mode="steer", turn_id=turn), batch_state)
}

acp_delivery_steer_started :: proc(r: ^ACP_Runtime) {
    members := acp_delivery_members(r, r.d.steering_input.id)
    batch_state := ""
    if r.d.send_now.batch_id != "" && r.d.steering_input.id == acp_send_now_input_id(r) { acp_send_now_set_state(r, "steering"); batch_state = "dispatching" }
    acp_delivery_report(r, acp_delivery_entries(r, members, "dispatching"), batch_state)
}

// The runtime failed (for example a cancel that was never acknowledged). The
// batch fails honestly; its inputs stay in the durable queue, and after a
// relaunch the Hub reopens them for re-admission (never dispatched = no replay).
acp_delivery_runtime_failed :: proc(r: ^ACP_Runtime, reason: string) {
    if !acp_send_now_active(r) do return
    code := "cancel_timeout" if r.d.cancelling && reason == "acp_rpc_timeout" else "runtime_failed"
    acp_send_now_set_state(r, "failed")
    acp_delivery_report(r, nil, "failed", code)
}

// Initial runtime facts for a launch epoch (steering capability). The first
// report of a new epoch also lets the Hub reopen inputs lost with the old queue.
acp_delivery_hello :: proc(r: ^ACP_Runtime) {
    if r.chat == nil || r.d.replay_only || !acp_delivery_reports_enabled do return
    entries := make([dynamic]contracts.ACP_Input_State_Entry, context.temp_allocator)
    for input in r.d.queue do if input.lane == .Steer && strings.has_prefix(input.id, "msg_") {
        append(&entries, contracts.ACP_Input_State_Entry{message_id=input.id, state="queued", hold_reason=acp_delivery_hold(r), batch_id=r.d.send_now.batch_id if acp_send_now_member(r, input.id) else ""})
    }
    // An empty report still carries steering_supported; force one entry-less report.
    if len(entries) == 0 {
        context.allocator = runtime.heap_allocator()
        r.d.report_seq += 1
        report := contracts.ACP_Input_State_Report{launch_epoch=r.epoch, report_seq=r.d.report_seq, steering_supported=r.d.steering_supported}
        append(&r.chat.d.outbox, contracts.ACP_Assistant_Message_Input{kind=strings.clone(contracts.ACP_OUTBOX_INPUT_STATE), launch_epoch=strings.clone(r.epoch),
            message_id=strings.clone(fmt.tprintf("rpt_%d", r.d.report_seq)), revision=1, body=strings.clone(acp_event_json(report)), message_status=strings.clone("pending")})
        acp_runtime_replace(&r.saved_outbox, acp_event_json(r.chat.d))
        return
    }
    acp_delivery_report(r, entries[:])
}
