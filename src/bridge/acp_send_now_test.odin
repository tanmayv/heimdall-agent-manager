package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vm "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// Bridge-side Send now batch and delivery-evidence tests. Every scenario runs
// the real dispatcher (acp_rpc_call), driver and chat outbox; only the adapter
// pipe is faked (ACP_Test writes/feeds).

sn_fn: proc(f: ^T4_Runtime_Test)

// c4_chat_test pins the legacy assistant-only outbox; these scenarios run with
// delivery reports enabled so reports interleave with assistant revisions.
@(thread_local) sn_scenario: proc(t: ^testing.T, f: ^T4_Runtime_Test)
sn_chat_test :: proc(t: ^testing.T, scenario: proc(t: ^testing.T, f: ^T4_Runtime_Test)) {
    sn_scenario = scenario
    c4_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        acp_delivery_reports_enabled = true
        sn_scenario(t, f)
    })
}
// Results cross from the dispatcher thread; keep them out of either thread's
// temp allocator (the dispatcher frees its own per frame).
sn_arena: vm.Arena
sn_arena_ready: bool
sn_alloc :: proc() -> mem.Allocator {
    if !sn_arena_ready { _ = vm.arena_init_growing(&sn_arena); sn_arena_ready = true }
    return vm.arena_allocator(&sn_arena)
}
sn_work :: proc(data: rawptr, c: ^ACP_RPC_Client, arg: string) -> bool {
    f := cast(^T4_Runtime_Test)data
    if sn_fn != nil do sn_fn(f)
    return acp_rpc_checkpoint(c)
}
// Runs fn on the dispatcher thread, serialized like production callbacks.
sn_do :: proc(f: ^T4_Runtime_Test, fn: proc(f: ^T4_Runtime_Test)) {
    sn_fn = fn; defer sn_fn = nil
    cmd := ACP_RPC_Command{kind = .Runtime, a = "sn", runtime_work = sn_work, runtime_data = f}
    acp_rpc_call(f.r.client, &cmd)
}

sn_msg :: proc(f: ^T4_Runtime_Test, id, text: string) -> bool { return t16_input(f, id, text, .Steer, key = "", kind = "") }

sn_batch :: proc(f: ^T4_Runtime_Test, batch: string, attempt: i64, ids: []string, epoch := "t4_epoch") -> bool {
    raw := acp_event_json(ACP_Send_Now_Request{launch_epoch = epoch, batch_id = batch, attempt = attempt, message_ids = ids})
    return t4_runtime_call(f, strings.concatenate({"send_now_batch:", raw}, context.temp_allocator))
}

sn_write :: proc(f: ^T4_Runtime_Test, i: int) -> string {
    sync.mutex_lock(&f.f.mu); defer sync.mutex_unlock(&f.f.mu)
    if i >= len(f.f.writes) do return ""
    return strings.clone(f.f.writes[i].bytes, context.temp_allocator)
}

sn_count_writes :: proc(f: ^T4_Runtime_Test, needle: string) -> int {
    sync.mutex_lock(&f.f.mu); defer sync.mutex_unlock(&f.f.mu)
    n := 0
    for w in f.f.writes do if strings.contains(w.bytes, needle) do n += 1
    return n
}

Sn_Snapshot :: struct {
    reports: [dynamic]contracts.ACP_Input_State_Report,
    kinds: [dynamic]string,
}
sn_snap :: proc(f: ^T4_Runtime_Test) -> Sn_Snapshot {
    s: Sn_Snapshot
    s.reports = make([dynamic]contracts.ACP_Input_State_Report, sn_alloc())
    s.kinds = make([dynamic]string, sn_alloc())
    sn_snapshot_target = &s
    sn_do(f, proc(f: ^T4_Runtime_Test) {
        for e in f.r.chat.d.outbox {
            append(&sn_snapshot_target.kinds, strings.clone(e.kind, sn_alloc()))
            if e.kind != contracts.ACP_OUTBOX_INPUT_STATE do continue
            rep: contracts.ACP_Input_State_Report
            _ = json.unmarshal_string(e.body, &rep, allocator = sn_alloc())
            append(&sn_snapshot_target.reports, rep)
        }
    })
    return s
}
sn_snapshot_target: ^Sn_Snapshot

// Latest reported entry for a message across the whole outbox (FIFO).
sn_last :: proc(f: ^T4_Runtime_Test, id: string) -> contracts.ACP_Input_State_Entry {
    s := sn_snap(f)
    last: contracts.ACP_Input_State_Entry
    for rep in s.reports do for e in rep.inputs do if e.message_id == id do last = e
    return last
}
sn_last_batch :: proc(f: ^T4_Runtime_Test) -> (string, string, i64) {
    s := sn_snap(f)
    state, err: string; attempt: i64
    for rep in s.reports do if rep.batch_state != "" { state = rep.batch_state; err = rep.batch_error; attempt = rep.batch_attempt }
    return state, err, attempt
}
sn_queue_ids :: proc(f: ^T4_Runtime_Test) -> string {
    ids := make([dynamic]string, sn_alloc())
    sn_ids_target = &ids
    sn_do(f, proc(f: ^T4_Runtime_Test) { for q in f.r.d.queue do append(sn_ids_target, strings.clone(q.id, sn_alloc())) })
    return strings.join(ids[:], ",", context.temp_allocator)
}
sn_ids_target: ^[dynamic]string

@(test)
sn_send_now_steers_native_chat_ahead_of_bot_queue :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        sn_do(f, proc(f: ^T4_Runtime_Test) { f.r.d.steering_supported = true })
        testing.expect(t, sn_msg(f, "msg_active", "active work"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, t16_bot_input(f, "bot_waiting", "channel wake after turn"))
        testing.expect(t, sn_msg(f, "msg_urgent", "native urgent input"))
        e := sn_last(f, "msg_urgent")
        testing.expect_value(t, e.state, "queued")
        testing.expect_value(t, e.hold_reason, "turn_active")
        testing.expect_value(t, t16_writes(f), 1)
        testing.expect(t, sn_batch(f, "snb_native", 1, {"msg_urgent"}))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        line := sn_write(f, 1)
        testing.expect(t, strings.contains(line, "_session/steering") && strings.contains(line, "native urgent input") && !strings.contains(line, "channel wake"))
        t4_runtime_reply(t, f, 1, `{"outcome":"injected"}`, 1)
        t4_runtime_reply(t, f, 0, `{"stopReason":"end_turn"}`, 2)
        if !acp_test_wait(t, &f.f, .Writes, 3) do return
        testing.expect(t, strings.contains(sn_write(f, 2), "channel wake after turn"))
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 0)
        t4_runtime_reply(t, f, 2, `{"stopReason":"end_turn"}`, 3)
    })
}

@(test)
sn_idle_send_is_not_turn_held_and_delivers_as_prompt :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_idle", "hello"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        e := sn_last(f, "msg_idle")
        testing.expect_value(t, e.state, "delivered")
        testing.expect_value(t, e.mode, "prompt")
        testing.expect(t, e.turn_id != "", "delivery names the answering turn")
        // Admission while idle is dispatch_pending, never turn_active.
        s := sn_snap(f)
        for rep in s.reports do for x in rep.inputs do if x.message_id == "msg_idle" do testing.expect(t, x.hold_reason != "turn_active")
    })
}

@(test)
sn_batch_without_steering_cancels_once_then_one_fifo_prompt :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        testing.expect(t, sn_msg(f, "msg_c", "TEXT-C"))
        b := sn_last(f, "msg_b")
        testing.expect_value(t, b.state, "queued"); testing.expect_value(t, b.hold_reason, "turn_active")
        testing.expect(t, sn_batch(f, "snb_1", 1, {"msg_b", "msg_c"}))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 1)
        // A duplicate command and a later arrival change nothing now.
        testing.expect(t, sn_batch(f, "snb_1", 1, {"msg_b", "msg_c"}))
        testing.expect(t, sn_msg(f, "msg_d", "TEXT-D-LATER"))
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 1)
        t4_runtime_reply(t, f, 0, `{"stopReason":"cancelled"}`, 1)
        if !acp_test_wait(t, &f.f, .Writes, 3) do return
        prompt := sn_write(f, 2)
        testing.expect(t, strings.contains(prompt, "session/prompt"))
        bi, ci := strings.index(prompt, "TEXT-B"), strings.index(prompt, "TEXT-C")
        testing.expect(t, bi >= 0 && ci > bi, "one prompt, FIFO, boundaries kept")
        testing.expect(t, !strings.contains(prompt, "TEXT-D-LATER"), "later arrival waits for its own turn")
        testing.expect_value(t, sn_last(f, "msg_b").mode, "prompt")
        testing.expect_value(t, sn_last(f, "msg_c").batch_id, "snb_1")
        testing.expect_value(t, sn_last(f, "msg_c").turn_id, sn_last(f, "msg_b").turn_id)
        state, _, _ := sn_last_batch(f)
        testing.expect_value(t, state, "delivered")
        testing.expect_value(t, sn_last(f, "msg_d").state, "queued")
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 1)
        // The next natural turn sends D alone.
        t4_runtime_reply(t, f, 2, `{"stopReason":"end_turn"}`, 2)
        if !acp_test_wait(t, &f.f, .Writes, 4) do return
        testing.expect(t, strings.contains(sn_write(f, 3), "TEXT-D-LATER") && !strings.contains(sn_write(f, 3), "TEXT-B"))
    })
}

@(test)
sn_batch_steers_after_inflight_steer_without_cancel :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        f.r.d.steering_supported = true
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B")) // natural steer in flight
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        testing.expect_value(t, sn_last(f, "msg_b").state, "dispatching")
        testing.expect(t, sn_msg(f, "msg_c", "TEXT-C"))
        testing.expect(t, sn_batch(f, "snb_s", 1, {"msg_c"}))
        testing.expect_value(t, t16_writes(f), 2) // waits for the steer in flight
        t4_runtime_reply(t, f, 1, `{"outcome":"injected"}`, 1)
        if !acp_test_wait(t, &f.f, .Writes, 3) do return
        testing.expect(t, strings.contains(sn_write(f, 2), "_session/steering") && strings.contains(sn_write(f, 2), "TEXT-C"))
        testing.expect_value(t, sn_last(f, "msg_b").mode, "steer")
        t4_runtime_reply(t, f, 2, `{"outcome":"injected"}`, 2)
        testing.expect_value(t, sn_last(f, "msg_c").state, "delivered")
        testing.expect_value(t, sn_last(f, "msg_c").mode, "steer")
        state, _, _ := sn_last_batch(f)
        testing.expect_value(t, state, "delivered")
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 0)
    })
}

@(test)
sn_rejected_batch_steer_falls_back_to_one_cancel_without_resteer :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        testing.expect(t, sn_msg(f, "msg_c", "TEXT-C"))
        sn_do(f, proc(f: ^T4_Runtime_Test) { f.r.d.steering_supported = true })
        testing.expect(t, sn_batch(f, "snb_r", 1, {"msg_b", "msg_c"}))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        testing.expect(t, strings.contains(sn_write(f, 1), "_session/steering"))
        t4_runtime_reply(t, f, 1, `{"outcome":"promptRequired"}`, 1)
        if !acp_test_wait(t, &f.f, .Writes, 3) do return
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 1)
        testing.expect_value(t, sn_count_writes(f, "_session/steering"), 1)
        testing.expect_value(t, sn_last(f, "msg_b").state, "queued")
        t4_runtime_reply(t, f, 0, `{"stopReason":"cancelled"}`, 2)
        if !acp_test_wait(t, &f.f, .Writes, 4) do return
        prompt := sn_write(f, 3)
        testing.expect(t, strings.contains(prompt, "session/prompt") && strings.index(prompt, "TEXT-B") < strings.index(prompt, "TEXT-C"))
        testing.expect_value(t, sn_count_writes(f, "_session/steering"), 1)
        testing.expect_value(t, sn_last(f, "msg_c").mode, "prompt")
    })
}

@(test)
sn_natural_rejected_steer_returns_to_queue_front :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        f.r.d.steering_supported = true
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        testing.expect(t, sn_msg(f, "msg_c", "TEXT-C"))
        t4_runtime_reply(t, f, 1, `{"outcome":"promptRequired"}`, 1)
        testing.expect_value(t, sn_queue_ids(f), "msg_b,msg_c")
        testing.expect_value(t, sn_last(f, "msg_b").state, "queued")
        testing.expect_value(t, sn_last(f, "msg_b").hold_reason, "turn_active")
        t4_runtime_reply(t, f, 0, `{"stopReason":"end_turn"}`, 2)
        if !acp_test_wait(t, &f.f, .Writes, 3) do return
        testing.expect(t, strings.contains(sn_write(f, 2), "TEXT-B") && !strings.contains(sn_write(f, 2), "TEXT-C"), "FIFO is preserved after rejection")
        testing.expect_value(t, sn_count_writes(f, "_session/steering"), 1)
    })
}

@(test)
sn_empty_stale_and_already_dispatched_batches_never_cancel :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        // msg_a is the running turn: nothing left to send, so no interruption.
        testing.expect(t, sn_batch(f, "snb_e", 1, {"msg_a", "msg_unknown"}))
        state, _, _ := sn_last_batch(f)
        testing.expect_value(t, state, "empty")
        testing.expect(t, !sn_batch(f, "snb_old", 1, {"msg_a"}, epoch = "previous_epoch"))
        testing.expect_value(t, t16_writes(f), 1)
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 0)
    })
}

@(test)
sn_agent_read_drops_queued_and_batch_member :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        testing.expect(t, sn_msg(f, "msg_c", "TEXT-C"))
        testing.expect(t, sn_msg(f, "msg_x", "TEXT-X"))
        testing.expect(t, t4_runtime_call(f, `inputs_read:["msg_x"]`))
        testing.expect(t, sn_batch(f, "snb_read", 1, {"msg_b", "msg_c"}))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        // Actual agent read while the batch is pending (cancel already sent).
        testing.expect(t, t4_runtime_call(f, `inputs_read:["msg_b"]`))
        t4_runtime_reply(t, f, 0, `{"stopReason":"cancelled"}`, 1)
        if !acp_test_wait(t, &f.f, .Writes, 3) do return
        prompt := sn_write(f, 2)
        testing.expect(t, strings.contains(prompt, "TEXT-C"))
        testing.expect(t, !strings.contains(prompt, "TEXT-B") && !strings.contains(prompt, "TEXT-X"), "read inputs are never prompted")
        // A re-fetch of a read input is deduplicated.
        testing.expect(t, sn_msg(f, "msg_x", "TEXT-X again"))
        testing.expect_value(t, sn_queue_ids(f), "")
    })
}

@(test)
sn_cancel_timeout_fails_batch_honestly_and_keeps_inputs :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        testing.expect(t, sn_batch(f, "snb_t", 1, {"msg_b"}))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        sn_do(f, proc(f: ^T4_Runtime_Test) { acp_runtime_error(f.r, "acp_rpc_timeout") })
        state, err, attempt := sn_last_batch(f)
        testing.expect_value(t, state, "failed")
        testing.expect_value(t, err, "cancel_timeout")
        testing.expect_value(t, attempt, 1)
        // Never dispatched: still in the durable queue for honest recovery.
        testing.expect_value(t, sn_queue_ids(f), "msg_b")
        testing.expect_value(t, sn_last(f, "msg_b").state, "queued")
        testing.expect(t, acp_runtime_durable_valid(&f.r.d))
        // A failed runtime does not pretend to accept a retry.
        testing.expect(t, !sn_batch(f, "snb_t", 2, {"msg_b"}))
    })
}

@(test)
sn_retry_attempt_reevaluates_existing_selection :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        testing.expect(t, sn_batch(f, "snb_retry", 1, {"msg_b"}))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        // Attempt 2 (explicit retry) re-validates without re-merging or re-cancelling.
        testing.expect(t, sn_batch(f, "snb_retry", 2, {"msg_b"}))
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 1)
        _, _, attempt := sn_last_batch(f)
        testing.expect_value(t, attempt, 2)
        // A different batch while one is unresolved is refused honestly.
        testing.expect(t, sn_batch(f, "snb_other", 1, {"msg_b"}))
        s := sn_snap(f)
        found := false
        for rep in s.reports do if rep.batch_id == "snb_other" && rep.batch_state == "failed" && rep.batch_error == "batch_in_progress" do found = true
        testing.expect(t, found)
        t4_runtime_reply(t, f, 0, `{"stopReason":"cancelled"}`, 1)
        if !acp_test_wait(t, &f.f, .Writes, 3) do return
        state, _, attempt2 := sn_last_batch(f)
        testing.expect_value(t, state, "delivered")
        testing.expect_value(t, attempt2, 2)
    })
}

sn_next_ids: string
// Review finding (rev 4): a same-batch retry that arrives while the combined
// input is in flight as a steer must keep membership, so the injected steer
// still delivers every member and records all causal input ids.
@(test)
sn_retry_while_batch_steer_in_flight_keeps_members :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        testing.expect(t, sn_msg(f, "msg_c", "TEXT-C"))
        sn_do(f, proc(f: ^T4_Runtime_Test) { f.r.d.steering_supported = true })
        testing.expect(t, sn_batch(f, "snb_fly", 1, {"msg_b", "msg_c"}))
        if !acp_test_wait(t, &f.f, .Writes, 2) do return
        testing.expect(t, strings.contains(sn_write(f, 1), "_session/steering"))
        // Hub stall timer fired; the user retries with attempt 2 mid-steer.
        testing.expect(t, sn_batch(f, "snb_fly", 2, {"msg_b", "msg_c"}))
        state, _, attempt := sn_last_batch(f)
        testing.expect_value(t, state, "dispatching")
        testing.expect_value(t, attempt, 2)
        testing.expect_value(t, sn_last(f, "msg_c").state, "dispatching")
        testing.expect_value(t, t16_writes(f), 2) // no re-steer, no cancel
        t4_runtime_reply(t, f, 1, `{"outcome":"injected"}`, 1)
        b, c := sn_last(f, "msg_b"), sn_last(f, "msg_c")
        testing.expect(t, b.state == "delivered" && b.mode == "steer" && b.batch_id == "snb_fly", "member b delivered")
        testing.expect(t, c.state == "delivered" && c.mode == "steer" && c.batch_id == "snb_fly", "member c delivered")
        state, _, attempt = sn_last_batch(f)
        testing.expect_value(t, state, "delivered")
        testing.expect_value(t, attempt, 2)
        sn_do(f, proc(f: ^T4_Runtime_Test) { sn_next_ids = strings.join(f.r.chat.d.next_input_ids[:], ",", sn_alloc()) })
        testing.expect_value(t, sn_next_ids, "msg_b,msg_c")
        // A further retry after delivery only re-confirms; nothing is resent.
        testing.expect(t, sn_batch(f, "snb_fly", 3, {"msg_b", "msg_c"}))
        state, _, attempt = sn_last_batch(f)
        testing.expect_value(t, state, "delivered"); testing.expect_value(t, attempt, 3)
        testing.expect_value(t, sn_count_writes(f, "_session/steering"), 1)
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 0)
    })
}

@(test)
sn_codex_waits_for_turn_id_instead_of_cancelling :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        sn_do(f, proc(f: ^T4_Runtime_Test) {
            f.r.driver = &acp_protocol_codex_driver
            f.r.d.steering_supported = true
            acp_runtime_replace(&f.r.d.phase, "prompt")
            acp_send_now_hold_or_cancel(f.r, {id = "msg_q", kind = ACP_SEND_NOW_KIND})
        })
        testing.expect(t, !f.r.d.cancelling)
        testing.expect_value(t, f.r.d.send_now.state, "waiting")
        sn_do(f, proc(f: ^T4_Runtime_Test) {
            // Previously rejected input must not wait for a re-steer: cancel.
            acp_send_now_hold_or_cancel(f.r, {id = "msg_q", kind = "append_next_turn"})
        })
        testing.expect(t, f.r.d.cancelling)
        sn_do(f, proc(f: ^T4_Runtime_Test) { f.r.driver = &acp_protocol_acp_driver; acp_runtime_replace(&f.r.d.phase, "ready"); f.r.d.cancelling = false })
    })
}

sn_custom_driver: ACP_Protocol_Driver
sn_readiness: ACP_Steer_Readiness
sn_seen: [5]ACP_Steer_Readiness
sn_test_can_steer :: proc(r: ^ACP_Runtime) -> ACP_Steer_Readiness { return sn_readiness }

// Hold-or-cancel follows the driver's can_steer capability, for any driver.
@(test)
sn_hold_or_cancel_follows_driver_can_steer :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        sn_custom_driver = acp_protocol_acp_driver
        sn_custom_driver.can_steer = sn_test_can_steer
        sn_readiness = .Later
        sn_do(f, proc(f: ^T4_Runtime_Test) {
            f.r.driver = &sn_custom_driver
            f.r.d.steering_supported = true
            sn_seen[0] = acp_runtime_steer_readiness(f.r, {id = "msg_q", kind = ACP_SEND_NOW_KIND})
            sn_seen[1] = acp_runtime_steer_readiness(f.r, {id = "msg_q", kind = "append_next_turn"})
            acp_runtime_replace(&f.r.d.phase, "prompt")
            acp_send_now_hold_or_cancel(f.r, {id = "msg_q", kind = ACP_SEND_NOW_KIND})
        })
        testing.expect(t, !f.r.d.cancelling)
        testing.expect_value(t, f.r.d.send_now.state, "waiting")
        sn_readiness = .Never
        sn_do(f, proc(f: ^T4_Runtime_Test) { acp_send_now_hold_or_cancel(f.r, {id = "msg_q", kind = ACP_SEND_NOW_KIND}) })
        testing.expect(t, f.r.d.cancelling)
        testing.expect_value(t, sn_count_writes(f, "session/cancel"), 1)
        sn_do(f, proc(f: ^T4_Runtime_Test) {
            // Without the capability, a steering session is steerable now.
            f.r.driver = &acp_protocol_acp_driver
            sn_seen[2] = acp_runtime_steer_readiness(f.r, {id = "msg_q"})
            f.r.d.steering_supported = false
            sn_seen[3] = acp_runtime_steer_readiness(f.r, {id = "msg_q"})
            acp_runtime_replace(&f.r.d.phase, "ready"); f.r.d.cancelling = false
        })
        testing.expect_value(t, sn_seen[0], ACP_Steer_Readiness.Later)
        testing.expect_value(t, sn_seen[1], ACP_Steer_Readiness.Never)
        testing.expect_value(t, sn_seen[2], ACP_Steer_Readiness.Now)
        testing.expect_value(t, sn_seen[3], ACP_Steer_Readiness.Never)
    })
}

@(test)
sn_reports_precede_assistant_rows_and_name_inputs :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        c4_text(f, t, 1, "answer")
        s := sn_snap(f)
        testing.expect(t, len(s.kinds) >= 2)
        testing.expect_value(t, s.kinds[0], contracts.ACP_OUTBOX_INPUT_STATE)
        testing.expect_value(t, s.kinds[len(s.kinds)-1], "")
        sn_do(f, proc(f: ^T4_Runtime_Test) {
            last := f.r.chat.d.outbox[len(f.r.chat.d.outbox)-1]
            sn_ok = len(last.input_ids) == 1 && last.input_ids[0] == "msg_a"
        })
        testing.expect(t, sn_ok, "assistant revision names its causal input")
        // Reports coalesce instead of growing the outbox per transition.
        before := len(s.kinds)
        testing.expect(t, sn_msg(f, "msg_b", "b"))
        testing.expect(t, sn_msg(f, "msg_c", "c"))
        testing.expect(t, len(sn_snap(f).kinds) <= before+1)
    })
}
sn_ok: bool

@(test)
sn_durable_send_now_round_trips_and_validates :: proc(t: ^testing.T) {
    sn_chat_test(t, proc(t: ^testing.T, f: ^T4_Runtime_Test) {
        testing.expect(t, sn_msg(f, "msg_a", "first turn"))
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, sn_msg(f, "msg_b", "TEXT-B"))
        testing.expect(t, sn_batch(f, "snb_d", 1, {"msg_b"}))
        raw, _ := json.marshal(f.r.d, allocator = context.temp_allocator)
        back: ACP_Runtime_Durable
        testing.expect(t, json.unmarshal(raw, &back, allocator = context.temp_allocator) == nil)
        testing.expect(t, acp_driver_acp_durable_valid(&back))
        testing.expect_value(t, back.send_now.batch_id, "snb_d")
        testing.expect_value(t, len(back.send_now.members), 1)
        testing.expect(t, back.report_seq > 0)
        back.send_now.state = "bogus"
        testing.expect(t, !acp_driver_acp_durable_valid(&back))
        // The outbox (with its reports) restores through chat prepare.
        outbox := acp_event_json(f.r.chat.d)
        r := ACP_Runtime{instance = "inst_c4_chat", epoch = "t4_epoch", saved_outbox = outbox}
        testing.expect(t, acp_chat_prepare(&r))
        acp_chat_destroy(&r)
        _ = fmt.tprintf("")
    })
}
