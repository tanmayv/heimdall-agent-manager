package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import vm "core:mem/virtual"

notice_test_state: string
notice_test_status: int
notice_test_reads, notice_test_turns: int
notice_test_text: string
notice_test_interrupt: bool
notice_test_fail: bool

notice_test_relay :: proc(path: []string, method, params: string, rec: Bridge_Local_Agent_Token_Record, timeout_ms: int) -> Bridge_Local_Relay_Result {
    notice_test_reads += 1
    return {ok = true, status = notice_test_status, body = fmt.aprintf("{{\"data\":{{\"state\":\"%s\"}}}}", notice_test_state)}
}
notice_test_daemon :: proc() -> (string, bool) { return "test-socket", true }
notice_test_pty :: proc(socket, instance, task_id, target_role, human_message, task_title: string, interrupt: bool) -> bool {
    notice_test_turns += 1
    delete(notice_test_text); notice_test_text = strings.clone(human_message)
    notice_test_interrupt = interrupt
    return !notice_test_fail
}
notice_test_n :: proc(text: string, now: i64 = 1000, instance: string = "inst_notice_test") -> Bridge_Task_Notice {
    return {instance = instance, task = "task_notice", expected_state = "ready", origin = "coordinator_item_ready", text = text,
        queued_ms = now, due_ms = now+BRIDGE_TASK_NOTICE_WINDOW_MS}
}

@(test)
notice_queue_restore_merges_live_saved_and_repeated_restore :: proc(t: ^testing.T) {
    q: Bridge_Task_Notice_Queue; defer bridge_task_notice_queue_delete(&q)
    saved: Bridge_Task_Notice_Queue; defer bridge_task_notice_queue_delete(&saved)
    testing.expect(t, bridge_task_notice_merge(&q, notice_test_n("live")))
    testing.expect(t, bridge_task_notice_merge(&saved, notice_test_n("live")))
    testing.expect(t, bridge_task_notice_merge(&saved, notice_test_n("saved")))
    raw, _ := json.marshal(saved); defer delete(raw)
    testing.expect(t, bridge_task_notice_restore(&q, string(raw), 4000))
    testing.expect(t, bridge_task_notice_restore(&q, string(raw), 4000))
    testing.expect_value(t, len(q.entries), 2)
    testing.expect_value(t, q.entries[0].text, "live")
    testing.expect_value(t, q.entries[1].due_ms, i64(6000))
    testing.expect(t, !bridge_task_notice_restore(&q, "invalid", 4000))
}

@(test)
notice_queue_bounds_and_expired_restore :: proc(t: ^testing.T) {
    q: Bridge_Task_Notice_Queue; defer bridge_task_notice_queue_delete(&q)
    for i in 0..<128 do testing.expect(t, bridge_task_notice_merge(&q, notice_test_n(fmt.tprintf("notice %d", i))))
    testing.expect(t, !bridge_task_notice_merge(&q, notice_test_n("overflow")))
    testing.expect(t, bridge_task_notice_merge(&q, notice_test_n("notice 0")), "duplicates accepted at capacity")
    raw, _ := json.marshal(q); defer delete(raw)
    restored: Bridge_Task_Notice_Queue; defer bridge_task_notice_queue_delete(&restored)
    testing.expect(t, bridge_task_notice_restore(&restored, string(raw), BRIDGE_TASK_NOTICE_MAX_AGE_MS+2000))
    testing.expect_value(t, len(restored.entries), 0)
    oversized := notice_test_n(string(make([]byte, 64*1024+1, context.temp_allocator)))
    testing.expect(t, !bridge_task_notice_merge(&restored, oversized))
    for i in 0..<BRIDGE_TASK_NOTICE_MAX {
        testing.expect(t, bridge_task_notice_merge(&restored, notice_test_n("bounded", instance = fmt.tprintf("inst_%d", i))))
    }
    testing.expect(t, !bridge_task_notice_merge(&restored, notice_test_n("global overflow", instance = "another")))
}

@(test)
notice_queue_relevance_preserves_legacy_and_lookup_failure :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    prev_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    append(&bridge_local_token_records, Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_notice_test", role = .Agent})
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_relay
    defer bridge_task_notice_relay = prev_relay
    n := notice_test_n("notice"); notice_test_reads = 0; notice_test_state = "ready"; notice_test_status = 200
    testing.expect(t, bridge_task_notice_relevant(n))
    notice_test_state = "done"
    testing.expect(t, !bridge_task_notice_relevant(n))
    notice_test_status = 503
    testing.expect(t, bridge_task_notice_relevant(n))
    notice_test_status = 200; notice_test_state = ""
    testing.expect(t, bridge_task_notice_relevant(n))
    reads := notice_test_reads
    n.task = ""; testing.expect(t, bridge_task_notice_relevant(n))
    n.task = "task_notice"; n.expected_state = ""; testing.expect(t, bridge_task_notice_relevant(n))
    testing.expect_value(t, notice_test_reads, reads)
}

@(test)
notice_queue_pty_batches_two_seconds_filters_stale_and_merges_restore :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    bridge_runtime_set_status("inst_notice_test", "running", "idle")
    defer bridge_runtime_set_status("inst_notice_test", "stopped", "idle")
    prev_q := bridge_task_notices; bridge_task_notices = {}
    defer { bridge_task_notice_queue_delete(&bridge_task_notices); bridge_task_notices = prev_q }
    prev_data := bridge_config.data_dir
    dir := fmt.aprintf("%s/.cache/heimdall-tests/notice-queue-%d", os.get_env("HOME", context.temp_allocator), sync.current_thread_id())
    bridge_config.data_dir = dir
    defer { bridge_config.data_dir = prev_data; os.remove_all(dir); delete(dir) }
    prev_daemon := bridge_task_notice_daemon; prev_deliver := bridge_task_notice_pty_deliver
    bridge_task_notice_daemon = notice_test_daemon; bridge_task_notice_pty_deliver = notice_test_pty
    defer { bridge_task_notice_daemon = prev_daemon; bridge_task_notice_pty_deliver = prev_deliver; delete(notice_test_text); notice_test_text = "" }
    prev_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    append(&bridge_local_token_records, Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_notice_test", role = .Agent})
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_relay
    defer bridge_task_notice_relay = prev_relay
    notice_test_state = "ready"; notice_test_status = 200; notice_test_turns = 0
    testing.expect(t, bridge_task_notice_enqueue(notice_test_n("first")))
    bridge_task_notice_tick(2999)
    testing.expect_value(t, notice_test_turns, 0)
    second := notice_test_n("second", 2700)
    testing.expect(t, bridge_task_notice_enqueue(second))
    stale := notice_test_n("stale", 2800); stale.expected_state = "in_progress"
    testing.expect(t, bridge_task_notice_enqueue(stale))
    legacy := notice_test_n("legacy", 2900); legacy.task = ""
    testing.expect(t, bridge_task_notice_enqueue(legacy))
    path := bridge_task_notice_path(); defer delete(path)
    raw, err := os.read_entire_file(path, context.allocator); defer delete(raw)
    testing.expect(t, err == nil && bridge_task_notice_restore(&bridge_task_notices, string(raw), 2900))
    testing.expect_value(t, len(bridge_task_notices.entries), 4)
    bridge_task_notice_tick(3000)
    testing.expect_value(t, notice_test_turns, 1)
    testing.expect_value(t, notice_test_text, "first | second | legacy")
    testing.expect(t, !notice_test_interrupt, "notices never interrupt (CONTRACT-07)")
    bridge_task_notice_tick(9000)
    testing.expect_value(t, notice_test_turns, 1)
    saved, read_err := os.read_entire_file(path, context.allocator); defer delete(saved)
    restored: Bridge_Task_Notice_Queue; defer bridge_task_notice_queue_delete(&restored)
    testing.expect(t, read_err == nil && bridge_task_notice_restore(&restored, string(saved), 9000))
    testing.expect_value(t, len(restored.entries), 0)
}

@(test)
notice_queue_debounce_task_identity_keeps_distinct_reasons_states_messages :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev := bridge_recent_nudges; bridge_recent_nudges = {}
    defer { for rec in bridge_recent_nudges do delete(rec.key); delete(bridge_recent_nudges); bridge_recent_nudges = prev }
    testing.expect(t, !bridge_should_debounce_nudge("inst", "task", "ready", "ready", "first"))
    testing.expect(t, bridge_should_debounce_nudge("inst", "task", "ready", "ready", "first"))
    testing.expect(t, !bridge_should_debounce_nudge("inst", "task", "blocked", "ready", "first"))
    testing.expect(t, !bridge_should_debounce_nudge("inst", "task", "ready", "done", "first"))
    testing.expect(t, !bridge_should_debounce_nudge("inst", "task", "ready", "ready", "second"))
    testing.expect(t, !bridge_should_debounce_nudge("inst", "other", "ready", "ready", "first"))
    testing.expect(t, !bridge_should_debounce_nudge("inst", ""))
    testing.expect(t, !bridge_should_debounce_nudge("inst", "not-accepted", record = false))
    testing.expect(t, !bridge_should_debounce_nudge("inst", "not-accepted", record = false))
    bridge_recent_nudges[0].timestamp_ms = bridge_runtime_now_ms()-1501
    testing.expect(t, !bridge_should_debounce_nudge("inst", "task", "ready", "ready", "first"), "debounce expires at 1.5 seconds")
}

@(test)
notice_queue_acp_saved_fifo_merges_current_completed_and_duplicate_ids :: proc(t: ^testing.T) {
    d := ACP_Runtime_Durable{current_input = "running"}
    append(&d.completed_inputs, "done"); defer delete(d.completed_inputs)
    for id in ([]string{"running", "pending", "done", "pending", "last"}) {
        append(&d.queue, ACP_Runtime_Input{id = strings.clone(id), text = strings.clone(id)})
    }
    defer { for input in d.queue { delete(input.id); delete(input.text) }; delete(d.queue) }
    acp_runtime_merge_saved_queue(&d); acp_runtime_merge_saved_queue(&d)
    testing.expect_value(t, len(d.queue), 2)
    testing.expect_value(t, d.queue[0].id, "pending")
    testing.expect_value(t, d.queue[1].id, "last")
}

@(test)
notice_queue_acp_busy_waits_and_revalidates_at_prompt_start :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_relay
    defer bridge_task_notice_relay = prev_relay
    f: T4_Runtime_Test; t4_runtime_open(&f, "inst_notice_acp", "/unused/bootstrap")
    defer { f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f); bridge_runtime_set_status("inst_notice_acp", "stopped", "idle") }
    bridge_runtime_set_status(f.r.instance, "running", "idle")
    prev_q := bridge_task_notices; bridge_task_notices = {}
    defer { bridge_task_notice_queue_delete(&bridge_task_notices); bridge_task_notices = prev_q }
    prev_data := bridge_config.data_dir
    dir := fmt.aprintf("%s/.cache/heimdall-tests/notice-acp-%d", os.get_env("HOME", context.temp_allocator), sync.current_thread_id())
    bridge_config.data_dir = dir
    defer { bridge_config.data_dir = prev_data; os.remove_all(dir); delete(dir) }
    prev_owners := acp_runtimes; acp_runtimes = make(map[string]^ACP_Runtime)
    acp_runtimes[f.r.instance] = f.r
    defer { delete(acp_runtimes); acp_runtimes = prev_owners }
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == f.r.instance do inst.runtime_transport = "acp"
    sync.mutex_unlock(&bridge_runtime_mutex)
    acp_runtime_replace(&f.r.d.phase, "prompt"); f.r.d.ready = true
    acp_runtime_replace(&f.r.session, "notice-session")
    batch := [?]Bridge_Task_Notice{notice_test_n("first", instance = f.r.instance), notice_test_n("second", instance = f.r.instance)}
    notice_test_status = 200; notice_test_state = "ready"
    notice_test_reads = 0
    testing.expect(t, bridge_task_notice_enqueue(batch[0]))
    bridge_task_notice_tick(2999)
    testing.expect_value(t, f.r.d.phase, "prompt")
    batch[1].queued_ms = 2700; batch[1].due_ms = 4700
    testing.expect(t, bridge_task_notice_enqueue(batch[1]))
    bridge_task_notice_tick(3000)
    testing.expect(t, len(bridge_task_notices.entries) == 2, "busy notices remain in the common queue")
    testing.expect_value(t, len(f.r.d.queue), 0)
    testing.expect_value(t, notice_test_reads, 0)
    acp_runtime_replace(&f.r.d.phase, "ready")
    append(&f.r.d.queue, ACP_Runtime_Input{id = strings.clone("queued"), text = strings.clone("queued text")})
    testing.expect(t, !bridge_task_notice_deliver(batch[:]), "queued FIFO prevents relevance reads")
    testing.expect_value(t, notice_test_reads, 0)
    delete(f.r.d.queue[0].id); delete(f.r.d.queue[0].text); clear(&f.r.d.queue)
    notice_test_state = "done"; acp_runtime_replace(&f.r.d.phase, "ready")
    bridge_task_notice_tick(5000)
    testing.expect(t, len(bridge_task_notices.entries) == 0, "state changed while waiting, no prompt")
    testing.expect_value(t, f.r.d.phase, "ready")
    notice_test_state = "ready"
    testing.expect(t, bridge_task_notice_enqueue(batch[0]))
    testing.expect(t, bridge_task_notice_enqueue(batch[1]))
    bridge_task_notice_tick(2999)
    testing.expect_value(t, f.r.d.phase, "ready")
    bridge_task_notice_tick(3000)
    testing.expect(t, acp_test_wait(t, &f.f, .Writes, 1))
    sync.mutex_lock(&f.f.mu)
    testing.expect_value(t, len(f.f.writes), 1)
    testing.expect(t, strings.contains(f.f.writes[0].bytes, "first | second"))
    sync.mutex_unlock(&f.f.mu)
    testing.expect_value(t, f.r.d.phase, "prompt")
}

@(test)
notice_queue_failed_delivery_retries_and_expiry_never_sends :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev_q := bridge_task_notices; bridge_task_notices = {}
    defer { bridge_task_notice_queue_delete(&bridge_task_notices); bridge_task_notices = prev_q }
    prev_data := bridge_config.data_dir
    dir := fmt.aprintf("%s/.cache/heimdall-tests/notice-retry-%d", os.get_env("HOME", context.temp_allocator), sync.current_thread_id())
    bridge_config.data_dir = dir
    defer { bridge_config.data_dir = prev_data; os.remove_all(dir); delete(dir) }
    prev_daemon := bridge_task_notice_daemon; prev_deliver := bridge_task_notice_pty_deliver
    bridge_task_notice_daemon = notice_test_daemon; bridge_task_notice_pty_deliver = notice_test_pty
    defer { bridge_task_notice_daemon = prev_daemon; bridge_task_notice_pty_deliver = prev_deliver; notice_test_fail = false; delete(notice_test_text); notice_test_text = "" }
    notice_test_turns = 0; notice_test_fail = true
    n := notice_test_n("retry", instance = "inst_notice_retry"); n.task = ""
    testing.expect(t, bridge_task_notice_enqueue(n))
    testing.expect(t, !bridge_task_notice_deliver(bridge_task_notices.entries[:]), "unknown restored runtime waits for reconciliation")
    testing.expect_value(t, notice_test_turns, 0)
    bridge_runtime_set_status(n.instance, "running", "idle")
    defer bridge_runtime_set_status(n.instance, "stopped", "idle")
    path := bridge_task_notice_path(); defer delete(path)
    before_retry, before_err := os.read_entire_file(path, context.allocator); defer delete(before_retry)
    testing.expect(t, before_err == nil)
    bridge_task_notice_tick(3000)
    after_retry, after_err := os.read_entire_file(path, context.allocator); defer delete(after_retry)
    testing.expect(t, after_err == nil)
    testing.expect_value(t, string(after_retry), string(before_retry))
    testing.expect_value(t, bridge_task_notices.entries[0].due_ms, i64(5000))
    testing.expect_value(t, len(bridge_task_notices.entries), 1)
    testing.expect_value(t, notice_test_turns, 1)
    bridge_task_notice_tick(4999)
    testing.expect_value(t, notice_test_turns, 1)
    notice_test_fail = false; bridge_task_notice_tick(5000)
    testing.expect_value(t, notice_test_turns, 2)
    testing.expect_value(t, len(bridge_task_notices.entries), 0)
    testing.expect(t, bridge_task_notice_enqueue(n))
    bridge_task_notice_tick(BRIDGE_TASK_NOTICE_MAX_AGE_MS+2000)
    testing.expect_value(t, notice_test_turns, 2)
    testing.expect_value(t, len(bridge_task_notices.entries), 0)
}

@(test)
notice_queue_worker_restores_merges_and_joins :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev_q := bridge_task_notices; bridge_task_notices = {}
    defer { bridge_task_notice_queue_delete(&bridge_task_notices); bridge_task_notices = prev_q }
    prev_data := bridge_config.data_dir
    dir := fmt.aprintf("%s/.cache/heimdall-tests/notice-worker-%d", os.get_env("HOME", context.temp_allocator), sync.current_thread_id())
    bridge_config.data_dir = dir
    defer { bridge_config.data_dir = prev_data; os.remove_all(dir); delete(dir) }
    testing.expect(t, bridge_task_notice_enqueue(notice_test_n("saved and live", bridge_runtime_now_ms())))
    worker := bridge_task_notice_start()
    testing.expect(t, worker != nil)
    sync.mutex_lock(&bridge_task_notices_mu)
    testing.expect_value(t, len(bridge_task_notices.entries), 1)
    sync.mutex_unlock(&bridge_task_notices_mu)
    bridge_task_notice_stop(worker)
    testing.expect_value(t, len(bridge_task_notices.entries), 0)
    worker = bridge_task_notice_start()
    sync.mutex_lock(&bridge_task_notices_mu)
    testing.expect_value(t, len(bridge_task_notices.entries), 1)
    sync.mutex_unlock(&bridge_task_notices_mu)
    bridge_task_notice_stop(worker)
}

Notice_Test_Blocked_Relay :: struct { entered, release: bool }
notice_test_blocked: ^Notice_Test_Blocked_Relay

notice_test_blocked_relay :: proc(path: []string, method, params: string, rec: Bridge_Local_Agent_Token_Record, timeout_ms: int) -> Bridge_Local_Relay_Result {
    sync.atomic_store(&notice_test_blocked.entered, true)
    for !sync.atomic_load(&notice_test_blocked.release) do time.sleep(time.Millisecond)
    return {ok = true, status = 503, body = strings.clone("{}")}
}

Notice_Test_Probe :: struct { instance: string, done, owned, ready: bool }
notice_test_probe :: proc(data: rawptr) {
    p := cast(^Notice_Test_Probe)data
    p.owned = acp_runtime_owned(p.instance)
    p.ready = acp_runtime_command(p.instance, "task_notices_ready")
    sync.atomic_store(&p.done, true)
}

@(test)
notice_queue_slow_relevance_read_leaves_acp_ownership_and_dispatcher_free :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    f: T4_Runtime_Test; t4_runtime_open(&f, "inst_notice_slow_relay", "/unused/bootstrap")
    defer { f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f); bridge_runtime_set_status("inst_notice_slow_relay", "stopped", "idle") }
    bridge_runtime_set_status(f.r.instance, "running", "idle")
    prev_owners := acp_runtimes; acp_runtimes = make(map[string]^ACP_Runtime)
    acp_runtimes[f.r.instance] = f.r
    defer { delete(acp_runtimes); acp_runtimes = prev_owners }
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == f.r.instance do inst.runtime_transport = "acp"
    sync.mutex_unlock(&bridge_runtime_mutex)
    acp_runtime_replace(&f.r.d.phase, "ready"); f.r.d.ready = true
    acp_runtime_replace(&f.r.session, "slow-relay-session")
    blocked: Notice_Test_Blocked_Relay; notice_test_blocked = &blocked
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_blocked_relay
    defer { bridge_task_notice_relay = prev_relay; notice_test_blocked = nil }
    Delivery :: struct { batch: [1]Bridge_Task_Notice, delivered: bool }
    d := Delivery{batch = {notice_test_n("fail-open notice", instance = f.r.instance)}}
    worker := thread.create_and_start_with_data(&d, proc(data: rawptr) {
        context.allocator = runtime.heap_allocator()
        arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
        context.temp_allocator = vm.arena_allocator(&arena)
        d := cast(^Delivery)data
        d.delivered = bridge_task_notice_deliver(d.batch[:])
    })
    for i in 0..<2000 {
        if sync.atomic_load(&blocked.entered) do break
        time.sleep(time.Millisecond)
    }
    entered := sync.atomic_load(&blocked.entered)
    p := Notice_Test_Probe{instance = f.r.instance}
    probe := thread.create_and_start_with_data(&p, notice_test_probe)
    for i in 0..<500 {
        if sync.atomic_load(&p.done) do break
        time.sleep(time.Millisecond)
    }
    available_while_http_blocked := sync.atomic_load(&p.done)
    // Always release and join, even if an assertion would fail in the old code.
    sync.atomic_store(&blocked.release, true)
    thread.join(worker); thread.destroy(worker)
    thread.join(probe); thread.destroy(probe)
    testing.expect(t, entered, "relay must have blocked before probing ACP")
    testing.expect(t, available_while_http_blocked && p.owned && p.ready, "ownership lookup and dispatcher command complete while relay is blocked")
    testing.expect(t, d.delivered, "failed relevance read preserves the notice")
    testing.expect(t, acp_test_wait(t, &f.f, .Writes, 1))
}
