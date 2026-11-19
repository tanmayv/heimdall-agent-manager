package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

ACP_INBOX_DEBOUNCE_MS :: 2000
ACP_INBOX_CAP_MS :: 10000
// Preserve the pre-inbox journal's 128 x 256 KiB restore contract. Limit each
// prompt's context separately, and reserve admission slots for real input.
ACP_INBOX_MAX_BYTES :: 128*256*1024
ACP_INBOX_DIGEST_BYTES :: 512*1024
ACP_INBOX_NOTICE_SLOTS :: 112

acp_inbox_interval :: proc() -> i64 {
    raw := os.get_env("HEIMDALL_ACP_NOTICE_INTERVAL_MS", context.temp_allocator)
    value, ok := strconv.parse_i64(raw)
    return clamp(value, 1000, 3600000) if ok else 60000
}

// Use the Hub's origin/trigger, never keywords in human_message.
acp_inbox_lane :: proc(kind: string, interrupt := false) -> ACP_Input_Lane {
    if interrupt do return .Steer
    switch kind {
    case "review_requested_from_user", "hold_stale", "work_batch_finished", "agent_not_running", "title_nudge": return .Digest
    case: return .Batch
    }
}

acp_inbox_input_delete :: proc(input: ACP_Runtime_Input) {
    delete(input.id); delete(input.text); delete(input.key); delete(input.kind)
}

acp_inbox_remember :: proc(r: ^ACP_Runtime, id: string) {
    for saved in r.d.completed_inputs do if saved == id do return
    append(&r.d.completed_inputs, strings.clone(id))
    if len(r.d.completed_inputs) > 256 { delete(r.d.completed_inputs[0]); ordered_remove(&r.d.completed_inputs, 0) }
}

acp_inbox_input_valid :: proc(input: ACP_Runtime_Input) -> bool {
    return input.id != "" && len(input.id) <= 1024 && len(input.text) <= 256*1024 && len(input.key) <= 1024 && len(input.kind) <= 256 &&
        (input.lane == .Steer || input.lane == .Batch || input.lane == .Digest)
}

acp_inbox_accept :: proc(r: ^ACP_Runtime, c: ^ACP_RPC_Client, argument: string) -> bool {
    if !acp_runtime_current(r) || r.d.error != "" || r.d.exit_pending || len(argument) > 512*1024 do return false
    input: ACP_Runtime_Input
    if json.unmarshal_string(argument, &input) != nil || !acp_inbox_input_valid(input) { acp_inbox_input_delete(input); return false }
    duplicate := input.id == r.d.current_input || input.id == r.d.steering_input.id
    for entry in r.d.queue do if entry.id == input.id do duplicate = true
    for id in r.d.completed_inputs do if id == input.id do duplicate = true
    for id in c.state.queued_input_message_ids do if id == input.id do duplicate = true
    if duplicate { acp_inbox_input_delete(input); return true }
    replace := -1
    bytes := len(input.text) + len(r.d.steering_input.text)
    for entry, i in r.d.queue {
        if input.lane != .Steer && entry.lane != .Steer && input.key != "" && entry.key == input.key && entry.kind == input.kind { replace = i }
        bytes += len(entry.text)
    }
    if replace >= 0 do bytes -= len(r.d.queue[replace].text)
    slots := 128 if input.lane == .Steer else ACP_INBOX_NOTICE_SLOTS
    if (replace < 0 && len(r.d.queue) + int(r.d.steering_pending) >= slots) || bytes > ACP_INBOX_MAX_BYTES { acp_inbox_input_delete(input); return false }
    if replace >= 0 {
        acp_inbox_remember(r, r.d.queue[replace].id)
        acp_inbox_input_delete(r.d.queue[replace]); r.d.queue[replace] = input
    } else { append(&r.d.queue, input) }
    if input.lane == .Batch {
        now := acp_rpc_now(c)
        if r.d.batch_first_ms == 0 do r.d.batch_first_ms = now
        r.d.batch_last_ms = now
    }
    if r.chat != nil && strings.has_prefix(input.id, "msg_") do append(&c.state.queued_input_message_ids, strings.clone(input.id))
    // The caller may acknowledge the Hub only after this durable admission.
    if !acp_rpc_checkpoint(c) { acp_runtime_error(r, "acp_state_write_failed"); return false }
    acp_runtime_drain(r)
    return true
}

acp_inbox_tick :: proc(data: rawptr) {
    r := cast(^ACP_Runtime)data
    // acp_rpc_open starts its thread before the owner assigns r.client and
    // restores the journal. A tick must never drain that pre-restore state.
    if r.inbox_started && acp_runtime_current(r) do acp_runtime_drain(r)
}

acp_inbox_interrupt_pending :: proc(r: ^ACP_Runtime) {
    // Child-loss recovery explicitly fails the owning turn. Do not replay an
    // ambiguous injected message, or leave its pending flag wedging the inbox.
    if r.d.steering_input.id != "" do acp_inbox_remember(r, r.d.steering_input.id)
    acp_inbox_input_delete(r.d.steering_input)
    r.d.steering_input = {}; r.d.steering_pending = false
}

// The dispatcher owns the inbox and its clock. No timer thread or lifecycle
// mutex is needed, including while the Hub/vault is disconnected.
acp_runtime_drain :: proc(r: ^ACP_Runtime) {
    if !acp_runtime_current(r) || !r.d.ready || r.d.error != "" || r.d.exit_pending || r.d.steering_pending || len(r.d.queue) == 0 do return
    if r.chat != nil && (!acp_chat_vault_ready() || acp_chat_bytes(r.chat) > 1536*1024) do return
    steer := -1
    batch := false
    for input, i in r.d.queue {
        if input.lane == .Steer && steer < 0 do steer = i
        if input.lane == .Batch do batch = true
    }
    if r.d.phase == "prompt" {
        if steer < 0 || !r.d.steering_supported || r.d.queue[steer].kind == "append_next_turn" do return
        r.d.steering_input = r.d.queue[steer]; ordered_remove(&r.d.queue, steer)
        r.d.steering_pending = true
        raw, _ := json.marshal(struct{
            sessionId: string,
            prompt: [1]struct{type, text: string},
            _meta: struct{steering: struct{idleBehavior: string}},
        }{sessionId = r.session, prompt = {{"text", r.d.steering_input.text}}, _meta = {steering = {idleBehavior = "promptRequired"}}}, allocator = context.temp_allocator)
        id, sent := acp_rpc_request(r.client, "_session/steering", string(raw), 0, {acp_inbox_steering_result, r})
        delete(string(id))
        if !sent do acp_runtime_error(r, "acp_pipe_write_failed")
        return
    }
    now := acp_rpc_now(r.client)
    if steer < 0 {
        if !batch do return // FYI is context only, even after its budget refills.
        if r.d.last_notice_turn_ms != 0 && now-r.d.last_notice_turn_ms < r.notice_interval_ms {
            for &input in r.d.queue do if input.lane == .Batch do input.lane = .Digest
            r.d.batch_first_ms = 0; r.d.batch_last_ms = 0
            if !acp_rpc_checkpoint(r.client) do acp_runtime_error(r, "acp_state_write_failed")
            return
        }
        if now-r.d.batch_last_ms < ACP_INBOX_DEBOUNCE_MS && now-r.d.batch_first_ms < ACP_INBOX_CAP_MS do return
        r.d.last_notice_turn_ms = now
    }
    // One real input owns the response. All accumulated notices join that
    // prompt as one context block; their admission identities become receipts
    // in the same checkpoint as the outgoing RPC.
    primary: ACP_Runtime_Input
    if steer >= 0 { primary = r.d.queue[steer]; ordered_remove(&r.d.queue, steer) }
    else { primary.id = strings.clone(fmt.tprintf("digest_%d", r.client.state.next_rpc_id)) }
    defer acp_inbox_input_delete(primary)
    b := strings.builder_make(); defer strings.builder_destroy(&b)
    strings.write_string(&b, primary.text)
    has_notices := false
    digest_bytes := len(primary.text)
    for i := 0; i < len(r.d.queue); {
        input := r.d.queue[i]
        if input.lane == .Steer { i += 1; continue }
        if digest_bytes+len(input.text) > ACP_INBOX_DIGEST_BYTES {
            // Retain oversized legacy backlogs as context for later real turns;
            // never fail restoration, evict text, or create N autonomous turns.
            r.d.queue[i].lane = .Digest; i += 1; continue
        }
        digest_bytes += len(input.text)
        if !has_notices { strings.write_string(&b, "\n\n<heimdall_notice_digest>\n"); has_notices = true }
        strings.write_string(&b, input.text); strings.write_string(&b, "\n")
        acp_inbox_remember(r, input.id)
        ordered_remove(&r.d.queue, i); acp_inbox_input_delete(input)
    }
    if has_notices do strings.write_string(&b, "</heimdall_notice_digest>")
    r.d.batch_first_ms = 0; r.d.batch_last_ms = 0
    acp_runtime_prompt(r, {id = primary.id, text = strings.to_string(b)})
}

acp_inbox_steering_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    r := cast(^ACP_Runtime)data
    if !acp_runtime_current(r) || r.d.error != "" do return
    // A lost connection restores this pending RPC and its exact completion;
    // it must not consume or resubmit an ambiguous steering input.
    if !result.ok && (result.error.message == "acp_pipe_lost" || result.error.message == "acp_pipe_gap") do return
    outcome := ""
    if result.ok {
        obj := acp_event_object(result.result_json)
        outcome = acp_event_string(obj, "outcome")
    }
    if outcome != "injected" && outcome != "promptRequired" && (result.ok || result.error.code != -32601) {
        acp_runtime_error(r, "acp_rpc_failed"); return
    }
    input := r.d.steering_input; r.d.steering_input = {}; r.d.steering_pending = false
    if outcome == "injected" {
        acp_inbox_remember(r, input.id); acp_inbox_input_delete(input)
    } else {
        if !result.ok do r.d.steering_supported = false
        acp_runtime_replace(&input.kind, "append_next_turn")
        append(&r.d.queue, input)
    }
    if !acp_rpc_checkpoint(r.client) { acp_runtime_error(r, "acp_state_write_failed"); return }
    acp_runtime_drain(r)
}
