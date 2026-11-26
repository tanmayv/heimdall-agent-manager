package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
c2_acp_copilot_no_steering_serializes_priority_and_deduplicates :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_c2_fifo"); defer t16_close(&f)
    f.r.descriptor, _ = contracts.acp_provider_descriptor("copilot")
    acp_runtime_replace(&f.r.provider, "copilot"); acp_runtime_replace(&f.r.mode, "ask")
    testing.expect(t, !f.r.d.steering_supported)
    testing.expect(t, t16_input(&f, "first", "first turn", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    testing.expect(t, t16_input(&f, "priority", "priority after current turn", .Steer))
    testing.expect(t, t16_input(&f, "priority", "duplicate ignored", .Steer))
    testing.expect_value(t, t16_writes(&f), 1)
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    sync.mutex_lock(&f.f.mu)
    testing.expect(t, strings.contains(f.f.writes[1].bytes, "priority after current turn") && !strings.contains(f.f.writes[1].bytes, "duplicate ignored"))
    for write in f.f.writes do testing.expect(t, !strings.contains(write.bytes, "_session/steering"))
    sync.mutex_unlock(&f.f.mu)
    t4_runtime_reply(t, &f, 1, `{"stopReason":"end_turn"}`, 2)
    testing.expect(t, t16_input(&f, "priority", "completed duplicate ignored", .Steer))
    testing.expect_value(t, t16_writes(&f), 2)
}

t16_open :: proc(f: ^T4_Runtime_Test, instance: string) {
    t4_runtime_open(f, instance, "/unused/bootstrap")
    r := f.r
    r.d.ready = true; r.d.starter_sent = true; r.initialized = true
    r.inbox_started = true
    acp_runtime_replace(&r.d.phase, "ready"); acp_runtime_replace(&r.session, "t16-session")
    sync.atomic_store(&f.f.clock, 100000)
    r.client.io.now_ms = acp_test_clock
}
t16_close :: proc(f: ^T4_Runtime_Test) {
    f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f)
}
t16_input :: proc(f: ^T4_Runtime_Test, id, text: string, lane: ACP_Input_Lane, key := "task", kind := "ready") -> bool {
    raw, _ := json.marshal(ACP_Runtime_Input{id = id, text = text, lane = lane, key = key, kind = kind}, allocator = context.temp_allocator)
    return t4_runtime_call(f, string(raw))
}
t16_writes :: proc(f: ^T4_Runtime_Test) -> int {
    sync.mutex_lock(&f.f.mu); defer sync.mutex_unlock(&f.f.mu)
    return len(f.f.writes)
}

t16_tick :: proc(data: rawptr) {
    f := cast(^T4_Runtime_Test)data
    acp_inbox_tick(f.r)
}

t16_bot_input :: proc(f: ^T4_Runtime_Test, id, text: string) -> bool {
    return t16_input(f, id, text, acp_inbox_lane(ACP_BOT_KIND), ACP_BOT_KIND, ACP_BOT_KIND)
}

@(test)
t16_acp_bot_bypasses_notice_budget_and_does_not_reset_it :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_bot_budget"); defer t16_close(&f)
    testing.expect(t, t16_input(&f, "event_first", "first generic notice", .Batch))
    sync.atomic_store(&f.f.clock, 102000); t4_runtime_call(&f, "inbox_tick")
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    testing.expect(t, t16_input(&f, "event_second", "generic digest context", .Batch))
    testing.expect(t, len(f.r.d.queue) == 1 && f.r.d.queue[0].lane == .Digest)

    testing.expect(t, t16_bot_input(&f, "bot_first", "first bot turn"))
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    testing.expect(t, strings.contains(sn_write(&f, 1), "generic digest context"))
    t4_runtime_reply(t, &f, 1, `{"stopReason":"end_turn"}`, 2)
    sync.atomic_store(&f.f.clock, 122000)
    testing.expect(t, t16_bot_input(&f, "bot_second", "second bot turn"))
    if !acp_test_wait(t, &f.f, .Writes, 3) do return
    testing.expect(t, strings.contains(sn_write(&f, 2), "second bot turn"))
    testing.expect_value(t, f.r.d.last_notice_turn_ms, 102000)
    t4_runtime_reply(t, &f, 2, `{"stopReason":"end_turn"}`, 3)
}

@(test)
t16_acp_bot_burst_waits_for_idle_and_deduplicates :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_bot_burst"); defer t16_close(&f)
    f.r.d.steering_supported = true
    testing.expect(t, t16_input(&f, "msg_busy", "work in progress", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    testing.expect(t, t16_bot_input(&f, "bot_oldest", "oldest wake"))
    testing.expect(t, t16_bot_input(&f, "bot_middle", "middle wake"))
    testing.expect(t, t16_bot_input(&f, "bot_latest", "latest wake"))
    testing.expect(t, t16_bot_input(&f, "bot_latest", "retry while queued"))
    testing.expect(t, t16_bot_input(&f, "bot_oldest", "superseded retry"))
    testing.expect(t, len(f.r.d.queue) == 1 && f.r.d.queue[0].id == "bot_latest")
    // A write here would be an early prompt, a steer or a cancel.
    testing.expect_value(t, t16_writes(&f), 1)
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    line := sn_write(&f, 1)
    testing.expect(t, strings.contains(line, "session/prompt") && strings.contains(line, "latest wake") && !strings.contains(line, "retry"))
    t4_runtime_reply(t, &f, 1, `{"stopReason":"end_turn"}`, 2)
    testing.expect(t, t16_bot_input(&f, "bot_latest", "retry after completion"))
    testing.expect_value(t, t16_writes(&f), 2)
}

@(test)
t16_acp_bot_restore_promotes_and_coalesces_saved_digest :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_bot_restore")
    testing.expect(t, t16_input(&f, "notice_legacy_bot", "legacy channel wake", .Digest, "", ACP_BOT_KIND))
    testing.expect(t, t16_input(&f, "notice_other_bot", "duplicate legacy wake", .Digest, "", ACP_BOT_KIND))
    sync.mutex_lock(&f.f.mu); snapshot := strings.clone(f.f.snapshot, runtime.heap_allocator()); sync.mutex_unlock(&f.f.mu)
    defer delete(snapshot, runtime.heap_allocator())
    t16_close(&f)

    state, valid := acp_state_decode(snapshot); defer acp_state_delete(&state)
    if !testing.expect(t, valid) do return
    next: T4_Runtime_Test; t16_open(&next, "inst_bot_restore"); defer t16_close(&next)
    delete(next.r.d.phase, runtime.heap_allocator()); delete(next.r.d.starter, runtime.heap_allocator()); next.r.d = {}
    if !testing.expect(t, json.unmarshal_string(state.runtime_json, &next.r.d, allocator = runtime.heap_allocator()) == nil) do return
    testing.expect(t, acp_rpc_restore(next.r.client, snapshot))
    sn_do(&next, proc(f: ^T4_Runtime_Test) {
        acp_runtime_merge_saved_queue(&f.r.d)
        acp_runtime_reclassify_saved_queue(f.r)
    })
    t4_runtime_call(&next, "resume")
    if !acp_test_wait(t, &next.f, .Writes, 1) do return
    line := sn_write(&next, 0)
    testing.expect(t, strings.contains(line, "legacy channel wake") && !strings.contains(line, "duplicate legacy wake"))
    t4_runtime_reply(t, &next, 0, `{"stopReason":"end_turn"}`, 1)
    testing.expect_value(t, t16_writes(&next), 1)
}

@(test)
t16_acp_inbox_dispatcher_timer_and_long_turn_merge :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_timer"); defer t16_close(&f)
    // Exercise the real dispatcher's idle tick, rather than relying on chat
    // publication or a later arrival to flush a lone actionable event.
    f.r.client.callbacks.tick = t16_tick
    testing.expect(t, t16_input(&f, "action", "actionable", .Batch))
    sync.atomic_store(&f.f.clock, 102000)
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    testing.expect(t, t16_input(&f, "long1", "first during long turn", .Batch, kind = "ready"))
    testing.expect(t, t16_input(&f, "long2", "second during long turn", .Batch, kind = "shell_run"))
    testing.expect(t, t16_input(&f, "long3", "FYI during long turn", .Digest, kind = "hold_stale"))
    sync.atomic_store(&f.f.clock, 200000)
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    sync.mutex_lock(&f.f.mu)
    line := f.f.writes[1].bytes
    testing.expect(t, strings.contains(line, "first during long turn") && strings.contains(line, "second during long turn") && strings.contains(line, "FYI during long turn"))
    sync.mutex_unlock(&f.f.mu)
    t4_runtime_reply(t, &f, 1, `{"stopReason":"end_turn"}`, 2)
    testing.expect_value(t, t16_writes(&f), 2)
}

@(test)
t16_acp_inbox_restore_gate_and_child_loss_release_steering :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_restore_gate"); defer t16_close(&f)
    testing.expect(t, t16_input(&f, "action", "backlog", .Batch))
    sync.atomic_store(&f.f.clock, 102000)
    f.r.inbox_started = false
    // Simulate the interval after rpc_open starts its thread but before the
    // owner restores its checkpoint and assigns the client pointer.
    saved_client := f.r.client; f.r.client = nil
    acp_inbox_tick(f.r)
    f.r.client = saved_client
    testing.expect_value(t, t16_writes(&f), 0)
    testing.expect(t, t4_runtime_call(&f, "resume"))
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    f.r.d.steering_supported = true
    testing.expect(t, t16_input(&f, "ambiguous-steer", "may have been injected", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    acp_inbox_interrupt_pending(f.r)
    testing.expect(t, !f.r.d.steering_pending && f.r.d.steering_input.id == "")
    testing.expect(t, t16_input(&f, "ambiguous-steer", "never silently replay", .Steer))
    testing.expect_value(t, t16_writes(&f), 2)
}

@(test)
t16_acp_inbox_admission_bounds_and_checkpoint_failure :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_bounds"); defer t16_close(&f)
    // FYI capacity is bounded; rejection lets the Hub retry rather than
    // acknowledging content which was silently evicted.
    for i in 0..<ACP_INBOX_NOTICE_SLOTS do testing.expect(t, t16_input(&f, fmt.tprintf("fyi%d", i), "bounded", .Digest, key = fmt.tprintf("task%d", i)))
    testing.expect(t, !t16_input(&f, "over-cap", "must not be admitted", .Digest, key = "other"))
    testing.expect(t, t16_input(&f, "fyi0", "dedupe succeeds at capacity", .Digest))
    testing.expect(t, t16_input(&f, "replacement", "latest fits at capacity", .Digest, key = "task0"))
    testing.expect_value(t, len(f.r.d.queue), ACP_INBOX_NOTICE_SLOTS)
    testing.expect_value(t, t16_writes(&f), 0)
    testing.expect(t, t16_input(&f, "msg_reserved", "user still gets admitted", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    next: T4_Runtime_Test; t16_open(&next, "inst_t16_checkpoint"); defer t16_close(&next)
    sync.mutex_lock(&next.f.mu); next.f.checkpoint_fail = true; sync.mutex_unlock(&next.f.mu)
    testing.expect(t, !t16_input(&next, "uncommitted", "cannot ack", .Batch))
    testing.expect(t, next.r.d.error == "acp_state_write_failed")
    testing.expect_value(t, t16_writes(&next), 0)
}

@(test)
t16_acp_inbox_large_backlog_retains_context_without_extra_turns :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_large_backlog"); defer t16_close(&f)
    text := make([]byte, 256*1024, context.temp_allocator)
    for &ch in text do ch = 'x'
    for i in 0..<3 do testing.expect(t, t16_input(&f, fmt.tprintf("large%d", i), string(text), .Digest, key = fmt.tprintf("task%d", i)))
    testing.expect(t, acp_runtime_durable_valid(&f.r.d))
    testing.expect(t, t16_input(&f, "msg_first", "real input", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    // One 256 KiB notice fits alongside the user input. The remaining two are
    // still durable, rather than exceeding RPC bounds or being discarded.
    testing.expect_value(t, len(f.r.d.queue), 2)
    testing.expect(t, f.r.d.queue[0].lane == .Digest && f.r.d.queue[1].lane == .Digest)
    // A 256 KiB prompt occupies five daemon stdin chunks. Reply to its RPC ID,
    // rather than parsing a single chunk as though it were a complete frame.
    if !acp_test_wait(t, &f.f, .Writes, 5) do return
    f.r.client.io.feed(f.r.client, acp_test_response(ACP_RPC_ID("ham:t4_epoch:1"), `{"stopReason":"end_turn"}`), 1)
    if !acp_test_wait(t, &f.f, .Acks, 1) do return
    sync.atomic_store(&f.f.clock, 900000); t4_runtime_call(&f, "inbox_tick")
    testing.expect_value(t, t16_writes(&f), 5)
    testing.expect(t, t16_input(&f, "msg_second", "next real input", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 10) do return
    testing.expect_value(t, len(f.r.d.queue), 1)
}

@(test)
t16_acp_inbox_lanes_debounce_latest_dedupe_and_fyi :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    testing.expect(t, acp_inbox_lane("review_requested_from_user") == .Digest && acp_inbox_lane("hold_stale") == .Digest && acp_inbox_lane("work_batch_finished") == .Digest && acp_inbox_lane("agent_not_running") == .Digest && acp_inbox_lane("title_nudge") == .Digest)
    testing.expect(t, acp_inbox_lane("ready") == .Batch && acp_inbox_lane("shell_run") == .Batch && acp_inbox_lane("pausing", true) == .Steer)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_lanes"); defer t16_close(&f)
    testing.expect(t, t16_input(&f, "n1", "old ready", .Batch))
    testing.expect(t, t16_input(&f, "fyi1", "review FYI", .Digest, kind = "review_requested_from_user"))
    testing.expect(t, t16_input(&f, "fyi2", "batch finished FYI", .Digest, kind = "work_batch_finished"))
    sync.atomic_store(&f.f.clock, 101000)
    testing.expect(t, t16_input(&f, "n2", "latest ready", .Batch))
    testing.expect(t, t16_input(&f, "n1", "old redelivery must not replace latest", .Batch))
    sync.atomic_store(&f.f.clock, 102999); t4_runtime_call(&f, "inbox_tick")
    testing.expect_value(t, t16_writes(&f), 0)
    sync.atomic_store(&f.f.clock, 103000); t4_runtime_call(&f, "inbox_tick")
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    sync.mutex_lock(&f.f.mu)
    line := f.f.writes[0].bytes
    testing.expect(t, strings.contains(line, "latest ready") && strings.contains(line, "review FYI") && strings.contains(line, "batch finished FYI") && !strings.contains(line, "old ready"))
    testing.expect_value(t, f.f.order_errors, 0)
    sync.mutex_unlock(&f.f.mu)
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    testing.expect(t, t16_input(&f, "fyi3", "no autonomous turn", .Digest))
    sync.atomic_store(&f.f.clock, 900000); t4_runtime_call(&f, "inbox_tick")
    testing.expect_value(t, t16_writes(&f), 1)
    testing.expect(t, t16_input(&f, "msg_user", "real user input", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    sync.mutex_lock(&f.f.mu); testing.expect(t, strings.contains(f.f.writes[1].bytes, "no autonomous turn") && strings.contains(f.f.writes[1].bytes, "real user input")); sync.mutex_unlock(&f.f.mu)
}

@(test)
t16_acp_inbox_cap_and_budget_overflow_remains_context :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_cap"); defer t16_close(&f)
    for i in 0..<10 {
        sync.atomic_store(&f.f.clock, 100000+i64(i)*1000)
        testing.expect(t, t16_input(&f, fmt.tprintf("event%d", i), "keeps arriving", .Batch))
    }
    testing.expect_value(t, t16_writes(&f), 0)
    sync.atomic_store(&f.f.clock, 110000); t4_runtime_call(&f, "inbox_tick")
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    testing.expect(t, t16_input(&f, "overflow", "save this overflow", .Batch, kind = "shell_run"))
    testing.expect(t, len(f.r.d.queue) == 1 && f.r.d.queue[0].lane == .Digest)
    sync.atomic_store(&f.f.clock, 900000); t4_runtime_call(&f, "inbox_tick")
    testing.expect_value(t, t16_writes(&f), 1)
    testing.expect(t, t16_input(&f, "new_action", "new actionable event", .Batch))
    sync.atomic_store(&f.f.clock, 902000); t4_runtime_call(&f, "inbox_tick")
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    sync.mutex_lock(&f.f.mu); testing.expect(t, strings.contains(f.f.writes[1].bytes, "save this overflow") && strings.contains(f.f.writes[1].bytes, "new actionable event")); sync.mutex_unlock(&f.f.mu)
}

@(test)
t16_acp_inbox_user_steers_without_another_prompt :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_steer"); defer t16_close(&f)
    f.r.d.steering_supported = true
    testing.expect(t, t16_input(&f, "msg_first", "start real work", .Steer))
    testing.expect(t, t16_input(&f, "msg_midturn", "change direction", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    sync.mutex_lock(&f.f.mu)
    testing.expect(t, strings.contains(f.f.writes[0].bytes, "session/prompt") && strings.contains(f.f.writes[1].bytes, "_session/steering") && strings.contains(f.f.writes[1].bytes, "promptRequired"))
    sync.mutex_unlock(&f.f.mu)
    t4_runtime_reply(t, &f, 1, `{"outcome":"injected"}`, 1)
    testing.expect(t, t16_input(&f, "msg_midturn", "duplicate must not inject", .Steer))
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 2)
    testing.expect_value(t, t16_writes(&f), 2)
    testing.expect(t, f.r.d.phase == "ready" && !f.r.d.steering_pending)
}

@(test)
t16_acp_inbox_steering_idle_race_and_unsupported_fallback :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_race"); defer t16_close(&f)
    f.r.d.steering_supported = true
    testing.expect(t, t16_input(&f, "first", "first", .Steer))
    testing.expect(t, t16_input(&f, "race", "arrives as original ends", .Steer))
    t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
    testing.expect_value(t, t16_writes(&f), 2)
    t4_runtime_reply(t, &f, 1, `{"outcome":"promptRequired","reason":"noRunningTurn"}`, 2)
    if !acp_test_wait(t, &f.f, .Writes, 3) do return
    sync.mutex_lock(&f.f.mu); testing.expect(t, strings.contains(f.f.writes[2].bytes, "session/prompt") && strings.contains(f.f.writes[2].bytes, "arrives as original ends")); sync.mutex_unlock(&f.f.mu)
    f.r.d.steering_supported = false
    testing.expect(t, t16_input(&f, "fallback", "append to next turn", .Steer))
    testing.expect_value(t, t16_writes(&f), 3)
    t4_runtime_reply(t, &f, 2, `{"stopReason":"end_turn"}`, 3)
    if !acp_test_wait(t, &f.f, .Writes, 4) do return
    sync.mutex_lock(&f.f.mu); testing.expect(t, strings.contains(f.f.writes[3].bytes, "append to next turn")); sync.mutex_unlock(&f.f.mu)
}

@(test)
t16_acp_inbox_restore_merges_backlog_preserves_budget_and_receipts :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_restore")
    testing.expect(t, t16_input(&f, "notice_ready", "ready before restart", .Batch))
    testing.expect(t, t16_input(&f, "notice_fyi", "FYI before restart", .Digest, kind = "review_requested_from_user"))
    testing.expect(t, t16_input(&f, "notice_shell", "shell before restart", .Batch, kind = "shell_run"))
    sync.mutex_lock(&f.f.mu); snapshot := strings.clone(f.f.snapshot, runtime.heap_allocator()); sync.mutex_unlock(&f.f.mu)
    defer delete(snapshot, runtime.heap_allocator())
    t16_close(&f)
    state, valid := acp_state_decode(snapshot); defer acp_state_delete(&state)
    if !testing.expect(t, valid) do return
    next: T4_Runtime_Test; t16_open(&next, "inst_t16_restore"); defer t16_close(&next)
    delete(next.r.d.phase, runtime.heap_allocator()); delete(next.r.d.starter, runtime.heap_allocator()); next.r.d = {}
    testing.expect(t, json.unmarshal_string(state.runtime_json, &next.r.d, allocator = runtime.heap_allocator()) == nil)
    testing.expect(t, acp_rpc_restore(next.r.client, snapshot))
    testing.expect(t, t16_input(&next, "notice_shell", "redelivery must not duplicate", .Batch, kind = "shell_run"))
    sync.atomic_store(&next.f.clock, 200000); t4_runtime_call(&next, "resume")
    if !acp_test_wait(t, &next.f, .Writes, 1) do return
    sync.mutex_lock(&next.f.mu)
    line := next.f.writes[0].bytes
    testing.expect(t, strings.contains(line, "ready before restart") && strings.contains(line, "FYI before restart") && strings.contains(line, "shell before restart") && !strings.contains(line, "redelivery"))
    testing.expect_value(t, next.f.order_errors, 0); sync.mutex_unlock(&next.f.mu)
    t4_runtime_reply(t, &next, 0, `{"stopReason":"end_turn"}`, 1)
    testing.expect(t, t16_input(&next, "notice_ready", "completed duplicate", .Batch))
    testing.expect_value(t, t16_writes(&next), 1)
    testing.expect_value(t, next.r.d.last_notice_turn_ms, 200000)
}

@(test)
t16_acp_inbox_restore_pending_steering_keeps_original_turn :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    f: T4_Runtime_Test; t16_open(&f, "inst_t16_pending_restore")
    f.r.d.steering_supported = true
    f.r.d.last_notice_turn_ms = 95000
    testing.expect(t, t16_input(&f, "msg_original", "original prompt", .Steer))
    testing.expect(t, t16_input(&f, "msg_steered", "steering content", .Steer))
    if !acp_test_wait(t, &f.f, .Writes, 2) { t16_close(&f); return }
    ids: [2]string
    for i in 0..<2 {
        sync.mutex_lock(&f.f.mu)
        ids[i] = bridge_provider_json_extract_string(f.f.writes[i].bytes, "id", "")
        delivery := strings.clone(f.f.writes[i].delivery_id, runtime.heap_allocator())
        sync.mutex_unlock(&f.f.mu)
        acp_rpc_enqueue_frame(f.r.client, {kind = .Receipt, bytes = delivery})
        delete(delivery, runtime.heap_allocator())
    }
    defer for id in ids do delete(id)
    t4_runtime_call(&f, "inbox_tick")
    sync.mutex_lock(&f.f.mu); snapshot := strings.clone(f.f.snapshot, runtime.heap_allocator()); sync.mutex_unlock(&f.f.mu)
    defer delete(snapshot, runtime.heap_allocator())
    t16_close(&f)
    state, valid := acp_state_decode(snapshot); defer acp_state_delete(&state)
    if !testing.expect(t, valid && len(state.pending_writes) == 0 && len(state.pending_outbound) == 2) do return
    next: T4_Runtime_Test; t16_open(&next, "inst_t16_pending_restore"); defer t16_close(&next)
    delete(next.r.d.phase, runtime.heap_allocator()); delete(next.r.d.starter, runtime.heap_allocator()); next.r.d = {}
    testing.expect(t, json.unmarshal_string(state.runtime_json, &next.r.d, allocator = runtime.heap_allocator()) == nil)
    testing.expect(t, acp_rpc_restore(next.r.client, snapshot))
    testing.expect(t, next.r.d.steering_pending && next.r.d.steering_input.id == "msg_steered")
    testing.expect(t, t16_input(&next, "msg_steered", "pending duplicate", .Steer))
    next.r.client.io.feed(next.r.client, acp_test_response(ACP_RPC_ID(ids[1]), `{"outcome":"injected"}`), 1)
    if !acp_test_wait(t, &next.f, .Acks, 1) do return
    next.r.client.io.feed(next.r.client, acp_test_response(ACP_RPC_ID(ids[0]), `{"stopReason":"end_turn"}`), 2)
    if !acp_test_wait(t, &next.f, .Acks, 2) do return
    testing.expect(t, next.r.d.phase == "ready" && !next.r.d.steering_pending && len(next.r.d.queue) == 0)
    testing.expect(t, t16_input(&next, "msg_steered", "completed duplicate", .Steer))
    testing.expect_value(t, t16_writes(&next), 0)
    testing.expect_value(t, next.r.d.last_notice_turn_ms, 95000)
    testing.expect(t, t16_input(&next, "notice_after_restart", "budget must survive restart", .Batch))
    testing.expect(t, len(next.r.d.queue) == 1 && next.r.d.queue[0].lane == .Digest)
    testing.expect_value(t, t16_writes(&next), 0)
}
