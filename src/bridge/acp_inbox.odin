package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// The ACP adapter's side of the bridge inbox (bridge_inbox.odin): admission
// checks that need ACP state (the turn and steer in flight, chat queue ids,
// bot supersession) and the drain that turns queued input into prompts and
// steers on the dispatcher. The inbox is committed after the journal that
// carries the outgoing prompt (acp_runtime_committed).
// The bot delivery path (out of scope, G10) names the lane by its old name.
ACP_Input_Lane :: Bridge_Inbox_Lane
ACP_BOT_KIND :: "bot"
ACP_BOT_INPUT_PREFIX :: "bot_"

acp_inbox_next_turn_only :: proc(kind: string) -> bool {
    return kind == "append_next_turn" || kind == ACP_BOT_KIND
}

acp_inbox_interval :: proc() -> i64 {
    raw := os.get_env("HEIMDALL_ACP_NOTICE_INTERVAL_MS", context.temp_allocator)
    value, ok := strconv.parse_i64(raw)
    return clamp(value, 1000, 3600000) if ok else 60000
}

// Use the Hub's origin/trigger, never keywords in human_message.
acp_inbox_lane :: proc(kind: string, interrupt := false) -> Bridge_Inbox_Lane {
    if interrupt do return .Steer
    switch kind {
    case ACP_BOT_KIND: return .Steer
    case "review_requested_from_user", "hold_stale", "work_batch_finished", "agent_not_running", "title_nudge": return .Digest
    case: return .Batch
    }
}

// Inputs leaving the inbox with the outgoing prompt or steer (see
// ACP_Runtime_Durable.dispatched). Cleared once the inbox file is committed.
acp_inbox_dispatched :: proc(r: ^ACP_Runtime, id: string) {
    heap := runtime.heap_allocator()
    if r.d.dispatched.allocator.procedure == nil do r.d.dispatched = make([dynamic]string, heap)
    if len(r.d.dispatched) >= 512 { delete(r.d.dispatched[0], heap); ordered_remove(&r.d.dispatched, 0) }
    append(&r.d.dispatched, strings.clone(id, heap))
}

acp_inbox_dispatched_clear :: proc(r: ^ACP_Runtime) {
    heap := runtime.heap_allocator()
    for id in r.d.dispatched do delete(id, heap)
    clear(&r.d.dispatched)
}

acp_inbox_accept :: proc(r: ^ACP_Runtime, c: ^ACP_RPC_Client, argument: string) -> bool {
    if !acp_runtime_current(r) || r.d.error != "" || r.d.exit_pending || len(argument) > 512*1024 do return false
    input: Bridge_Inbox_Input
    if json.unmarshal_string(argument, &input, allocator = runtime.heap_allocator()) != nil || !bridge_inbox_input_valid(input) { bridge_inbox_input_delete(input); return false }
    dispatched := input.id == r.d.current_input || bridge_inbox_completed(r.inbox, input.id)
    duplicate := dispatched || input.id == r.d.steering_input.id || bridge_inbox_known(r.inbox, input.id)
    for id in c.state.queued_input_message_ids do if id == input.id do duplicate = true
    if duplicate {
        // A retried worker may have missed the dispatch hook during restart.
        if dispatched && input.kind == ACP_BOT_KIND do bridge_bot_note_dispatch(r.instance, input.id, acp_rpc_now(c))
        bridge_inbox_input_delete(input); return true
    }
    // A superseded worker might already be waiting on the runtime dispatcher.
    // It must not replace a newer notice just because its call arrived later.
    if input.kind == ACP_BOT_KIND && bridge_bot_notice_superseded(r.instance, input.id) {
        bridge_inbox_input_delete(input); return false
    }
    id := strings.clone(input.id, context.temp_allocator)
    lane := input.lane
    if bridge_inbox_admit(r.inbox, input, acp_rpc_now(c), coalesce_steer = input.kind == ACP_BOT_KIND,
        reserved_slots = int(r.d.steering_pending), reserved_bytes = len(r.d.steering_input.text)) != .Added { return false }
    if r.chat != nil && strings.has_prefix(id, "msg_") {
        append(&c.state.queued_input_message_ids, strings.clone(id))
        // Admission evidence; the drain below may immediately supersede it.
        if lane == .Steer do acp_delivery_report(r, acp_delivery_entries(r, []string{id}, "queued"))
    }
    // The caller may acknowledge the Hub only after this durable admission.
    if !acp_rpc_checkpoint(c) { acp_runtime_error(r, "acp_state_write_failed"); return false }
    acp_runtime_drain(r)
    return true
}

acp_inbox_tick :: proc(data: rawptr) {
    r := cast(^ACP_Runtime)data
    // acp_rpc_open starts its thread before the owner assigns r.client and
    // restores the journal. A tick must never drain that pre-restore state.
    if r.inbox_started && acp_runtime_current(r) {
        driver := acp_runtime_driver(r)
        if driver.tick != nil do driver.tick(r)
        acp_runtime_drain(r)
    }
}

acp_inbox_interrupt_pending :: proc(r: ^ACP_Runtime) {
    // Child-loss recovery explicitly fails the owning turn. Do not replay an
    // ambiguous injected message, or leave its pending flag wedging the inbox.
    if r.d.steering_input.id != "" do bridge_inbox_remember(r.inbox, r.d.steering_input.id)
    bridge_inbox_input_delete(r.d.steering_input)
    r.d.steering_input = {}; r.d.steering_pending = false
}

// The dispatcher owns the inbox and its clock. No timer thread or lifecycle
// mutex is needed, including while the Hub/vault is disconnected.
acp_runtime_drain :: proc(r: ^ACP_Runtime) {
    if !acp_runtime_current(r) || !r.d.ready || r.d.error != "" || r.d.exit_pending || r.d.steering_pending || len(r.inbox.queue) == 0 do return
    if r.chat != nil && (!acp_chat_can_process(r) || acp_chat_bytes(r.chat) > 1536*1024) do return
    steer := -1
    for input, i in r.inbox.queue do if input.lane == .Steer { steer = i; break }
    if r.d.phase == "prompt" {
        if steer < 0 do return
        // Keep normal input FIFO behind a next-turn-only entry. Explicit
        // Send now may move queued native chat ahead of that entry.
        front := r.inbox.queue[steer]
        // A pending Send now batch anywhere in the queue owns the decision.
        batch := false
        for input in r.inbox.queue do if input.lane == .Steer && acp_send_now_is_input(r, input) do batch = true
        if batch && !acp_send_now_is_input(r, front) {
            // An older rejected input sits ahead of the batch: it cannot be
            // steered again, so only a cancel lets the batch go next.
            acp_send_now_hold_or_cancel(r, front)
            return
        }
        if acp_runtime_steer_readiness(r, front) != .Now {
            if batch do acp_send_now_hold_or_cancel(r, front)
            return
        }
        acp_inbox_dispatched_clear(r)
        if front.kind == BRIDGE_INBOX_SEND_NOW_KIND {
            r.d.steering_input = acp_send_now_collect(r)
        } else {
            r.d.steering_input = front; ordered_remove(&r.inbox.queue, steer)
            acp_inbox_dispatched(r, front.id)
        }
        r.d.steering_pending = true
        acp_delivery_steer_started(r)
        if !acp_runtime_driver(r).steer(r) do acp_runtime_error(r, "acp_pipe_write_failed")
        return
    }
    now := acp_rpc_now(r.client)
    // Task notices whose task has moved on are dropped, never delivered;
    // notices whose relevance is being checked wait (task_notice_queue.odin).
    pruned := false
    batch, wake, waiting := false, false, false
    for i := 0; i < len(r.inbox.queue); {
        input := r.inbox.queue[i]
        switch bridge_inbox_relevance(r.instance, input, now) {
        case .Drop:
            bridge_inbox_remove(r.inbox, input.id); pruned = true; continue
        case .Wait:
            waiting = true
        case .Deliver:
            if input.lane == .Batch do batch = true
            if input.lane == .Wake do wake = true
        }
        i += 1
    }
    steer = -1 // pruning may have moved entries
    for input, i in r.inbox.queue do if input.lane == .Steer { steer = i; break }
    if steer < 0 {
        // FYI is context only, even after its budget refills. A wake (task
        // or lease notice) always gets its turn and leaves the budget alone.
        // Notices go as one turn once every relevance decision is known.
        if waiting || (!batch && !wake) { acp_inbox_commit_pruned(r, pruned); return }
        if !wake && r.inbox.last_notice_turn_ms != 0 && now-r.inbox.last_notice_turn_ms < r.notice_interval_ms {
            for &input in r.inbox.queue do if input.lane == .Batch do input.lane = .Digest
            bridge_inbox_window_reset(r.inbox)
            if !acp_rpc_checkpoint(r.client) do acp_runtime_error(r, "acp_state_write_failed")
            return
        }
        if !bridge_inbox_window_closed(r.inbox, now) { acp_inbox_commit_pruned(r, pruned); return }
        if !wake do r.inbox.last_notice_turn_ms = now
    }
    // One real input owns the response. All accumulated notices join that
    // prompt as one context block; their admission identities become receipts
    // in the same checkpoint as the outgoing RPC.
    acp_inbox_dispatched_clear(r)
    primary: Bridge_Inbox_Input
    if steer >= 0 && r.inbox.queue[steer].kind == BRIDGE_INBOX_SEND_NOW_KIND { primary = acp_send_now_collect(r) }
    else if steer >= 0 { primary = r.inbox.queue[steer]; ordered_remove(&r.inbox.queue, steer); acp_inbox_dispatched(r, primary.id) }
    else { primary.id = strings.clone(fmt.tprintf("digest_%d", r.client.state.next_rpc_id), runtime.heap_allocator()) }
    defer bridge_inbox_input_delete(primary)
    b := strings.builder_make(); defer strings.builder_destroy(&b)
    strings.write_string(&b, primary.text)
    has_notices := false
    digest_bytes := len(primary.text)
    for i := 0; i < len(r.inbox.queue); {
        input := r.inbox.queue[i]
        if input.lane == .Steer || bridge_inbox_relevance(r.instance, input, now) != .Deliver { i += 1; continue }
        if digest_bytes+len(input.text) > BRIDGE_INBOX_DIGEST_BYTES {
            // Retain oversized legacy backlogs as context for later real turns;
            // never fail restoration, evict text, or create N autonomous turns.
            r.inbox.queue[i].lane = .Digest; i += 1; continue
        }
        digest_bytes += len(input.text)
        if !has_notices { strings.write_string(&b, "\n\n<heimdall_notice_digest>\n"); has_notices = true }
        strings.write_string(&b, input.text); strings.write_string(&b, "\n")
        bridge_inbox_remember(r.inbox, input.id)
        acp_inbox_dispatched(r, input.id)
        ordered_remove(&r.inbox.queue, i); bridge_inbox_input_delete(input)
    }
    if has_notices do strings.write_string(&b, "</heimdall_notice_digest>")
    bridge_inbox_window_reset(r.inbox)
    acp_runtime_prompt(r, {id = primary.id, text = strings.to_string(b)})
}

// Stale notices were dropped without a prompt: commit their removal.
acp_inbox_commit_pruned :: proc(r: ^ACP_Runtime, pruned: bool) {
    if pruned && !acp_rpc_checkpoint(r.client) do acp_runtime_error(r, "acp_state_write_failed")
}

acp_inbox_steering_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    acp_runtime_driver(cast(^ACP_Runtime)data).steering_result(data, result)
}
