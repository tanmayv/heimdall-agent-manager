package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import vm "core:mem/virtual"

notice_test_state: string
notice_test_status: int
notice_test_reads, notice_test_turns: int
notice_test_fail: bool

notice_test_relay :: proc(path: []string, method, params: string, rec: Bridge_Local_Agent_Token_Record, timeout_ms: int) -> Bridge_Local_Relay_Result {
    notice_test_reads += 1
    return {ok = true, status = notice_test_status, body = fmt.aprintf("{{\"data\":{{\"state\":\"%s\"}}}}", notice_test_state)}
}
// Counts typing attempts (input frames); fails them all while notice_test_fail.
notice_test_send :: proc(socket: string, frame: []byte) -> bool {
    if _, captured := pty_test_captured(frame); !captured do return bridge_pty_host_send_oneway(socket, frame)
    if len(frame) > 4 && frame[4] == PTY_HOST_T_INPUT do notice_test_turns += 1
    return !notice_test_fail
}
notice_test_n :: proc(text: string, origin := "coordinator_item_ready", expected := "ready", task := "task_notice") -> Runtime_Input {
    return {kind = .Notification, text = text, key = task, origin = origin, wake = true, task = task, expected_state = expected}
}

// A private data dir and an empty inbox registry; pair with inbox_test_end.
inbox_test_begin :: proc(name: string) -> (prev, dir: string) {
    prev = bridge_config.data_dir
    dir = fmt.aprintf("%s/.cache/heimdall-tests/%s-%d", os.get_env("HOME", context.temp_allocator), name, sync.current_thread_id(), allocator = runtime.heap_allocator())
    _ = os.remove_all(dir)
    bridge_config.data_dir = dir
    bridge_inbox_forget_all(); bridge_task_states_reset()
    return
}
inbox_test_end :: proc(prev, dir: string) {
    bridge_inbox_forget_all(); bridge_task_states_reset()
    bridge_config.data_dir = prev
    _ = os.remove_all(dir); delete(dir, runtime.heap_allocator())
}

inbox_test_slot_ids :: proc(instance: string) -> []string {
    ids := make([dynamic]string, context.temp_allocator)
    sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
    if slot := bridge_inbox_slots[instance]; slot != nil do for input in slot.inbox.queue do append(&ids, strings.clone(input.id, context.temp_allocator))
    return ids[:]
}

inbox_test_records :: proc(instances: ..string) -> [dynamic]Bridge_Local_Agent_Token_Record {
    prev := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    for id in instances do append(&bridge_local_token_records, Bridge_Local_Agent_Token_Record{agent_instance_id = id, role = .Agent})
    return prev
}

@(test)
inbox_upgrade_legacy_notice_file_once_without_duplicates :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev, dir := inbox_test_begin("inbox-upgrade"); defer inbox_test_end(prev, dir)
    now := bridge_runtime_now_ms()
    legacy := fmt.tprintf(`{{"entries":[`+
        `{{"instance":"inst_up","id":"msg_1","kind":"user_message","text":"queued user message","queued_ms":%d,"due_ms":%d}},`+
        `{{"instance":"inst_up","task":"task_a","expected_state":"ready","origin":"coordinator_item_ready","text":"task a is ready","queued_ms":%d}},`+
        `{{"instance":"inst_up","origin":"shell_run","text":"expired","queued_ms":%d}},`+
        `{{"instance":"inst_other","origin":"shell_run","text":"other instance","queued_ms":%d}}]}}`,
        now, now, now, now-BRIDGE_TASK_NOTICE_MAX_AGE_MS-1000, now)
    path := bridge_task_notice_legacy_path(); defer delete(path)
    _ = bridge_make_directory_all(filepath.dir(path))
    testing.expect(t, bridge_retry_atomic_write(path, transmute([]byte)legacy))
    // An interrupted upgrade runs again: content-derived ids prevent duplicates.
    testing.expect(t, bridge_task_notice_upgrade(legacy, now))
    bridge_inbox_forget_all()
    bridge_inbox_restore_all()
    testing.expect(t, !os.exists(path), "the legacy file is removed once every inbox is committed")
    ids := inbox_test_slot_ids("inst_up")
    if !testing.expect_value(t, len(ids), 2) do return
    testing.expect_value(t, ids[0], "msg_1")
    testing.expect(t, strings.has_prefix(ids[1], "notice_legacy_"))
    testing.expect_value(t, len(inbox_test_slot_ids("inst_other")), 1)
    inbox := bridge_inbox_lock("inst_up")
    if testing.expect(t, inbox != nil) {
        testing.expect(t, inbox.queue[0].lane == .Steer && inbox.queue[1].lane == .Wake && inbox.queue[1].expected_state == "ready" && inbox.queue[1].task == "task_a")
        bridge_inbox_unlock()
    }
    testing.expect(t, !bridge_task_notice_upgrade("invalid", now))
}

@(test)
inbox_admission_bounds_dedupe_and_coalescing :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    inbox: Bridge_Inbox; defer bridge_inbox_delete(&inbox)
    n :: proc(id: string, lane: Bridge_Inbox_Lane, key := "", kind := "") -> Bridge_Inbox_Input {
        return {id = strings.clone(id), text = strings.clone(id), lane = lane, key = strings.clone(key), kind = strings.clone(kind)}
    }
    for i in 0..<BRIDGE_INBOX_NOTICE_SLOTS do testing.expect(t, bridge_inbox_admit(&inbox, n(fmt.tprintf("notice_%d", i), .Wake), 1) == .Added)
    testing.expect(t, bridge_inbox_admit(&inbox, n("overflow", .Wake), 1) == .Full)
    testing.expect(t, bridge_inbox_admit(&inbox, n("notice_0", .Wake), 1) == .Duplicate, "duplicates accepted at capacity")
    testing.expect(t, bridge_inbox_admit(&inbox, n("user", .Steer), 1) == .Added, "user input keeps reserved slots")
    testing.expect(t, !bridge_inbox_input_valid({id = "big", text = string(make([]byte, BRIDGE_INBOX_TEXT_MAX+1, context.temp_allocator))}))
    small: Bridge_Inbox; defer bridge_inbox_delete(&small)
    testing.expect(t, bridge_inbox_admit(&small, n("a", .Wake, "task", "ready"), 1) == .Added)
    testing.expect(t, bridge_inbox_admit(&small, n("b", .Wake, "task", "ready"), 2) == .Added)
    testing.expect(t, len(small.queue) == 1 && small.queue[0].id == "b" && bridge_inbox_completed(&small, "a"), "same task and reason: the newest notice replaces the older")
    testing.expect(t, bridge_inbox_admit(&small, n("a", .Wake, "task", "ready"), 3) == .Duplicate)
}

@(test)
notice_queue_relevance_preserves_legacy_and_lookup_failure :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    prev_records := inbox_test_records("inst_notice_test")
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_relay
    defer bridge_task_notice_relay = prev_relay
    id := "inst_notice_test"
    notice_test_reads = 0; notice_test_state = "ready"; notice_test_status = 200
    testing.expect(t, bridge_task_notice_relevant(id, "task_notice", "ready"))
    notice_test_state = "done"
    testing.expect(t, !bridge_task_notice_relevant(id, "task_notice", "ready"))
    notice_test_status = 503
    testing.expect(t, bridge_task_notice_relevant(id, "task_notice", "ready"))
    notice_test_status = 200; notice_test_state = ""
    testing.expect(t, bridge_task_notice_relevant(id, "task_notice", "ready"))
    reads := notice_test_reads
    testing.expect(t, bridge_task_notice_relevant(id, "", "ready"))
    testing.expect(t, bridge_task_notice_relevant(id, "task_notice", ""))
    testing.expect_value(t, notice_test_reads, reads)
}

@(test)
notice_queue_pty_batches_two_seconds_filters_stale_and_coalesces :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    id := "inst_notice_test"
    pty_test_activity(id, "idle", "pane_diff")
    pty_test_forget_typed(id)
    defer bridge_runtime_set_status(id, "stopped", "idle")
    prev, dir := inbox_test_begin("notice-queue"); defer inbox_test_end(prev, dir)
    prev_daemon, prev_send, prev_sleep := pty_runtime_daemon, pty_runtime_send, pty_runtime_sleep
    pty_runtime_daemon, pty_runtime_send, pty_runtime_sleep = pty_test_daemon, pty_test_send, pty_test_sleep
    defer { pty_runtime_daemon, pty_runtime_send, pty_runtime_sleep = prev_daemon, prev_send, prev_sleep; pty_test_reset() }
    pty_test_reset()
    prev_records := inbox_test_records(id)
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_relay
    defer bridge_task_notice_relay = prev_relay
    notice_test_state = "ready"; notice_test_status = 200
    testing.expect(t, bridge_task_notice_enqueue(id, notice_test_n("first", origin = "o1")))
    bridge_task_notice_tick(bridge_runtime_now_ms())
    turns0, _ := pty_test_inputs()
    testing.expect_value(t, turns0, 0) // the collection window is open
    testing.expect(t, bridge_task_notice_enqueue(id, notice_test_n("second", origin = "o2")))
    testing.expect(t, bridge_task_notice_enqueue(id, notice_test_n("stale", origin = "o3", expected = "in_progress")))
    testing.expect(t, bridge_task_notice_enqueue(id, notice_test_n("legacy", origin = "o4", task = "")))
    // A bridge restart while they wait: the inbox file replays them.
    bridge_inbox_forget_all(); bridge_inbox_restore_all()
    testing.expect_value(t, len(inbox_test_slot_ids(id)), 4)
    bridge_task_notice_tick(bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_WINDOW_MS + 1)
    turns, text := pty_test_inputs()
    testing.expect_value(t, turns, 1)
    testing.expect_value(t, text, "first | second | legacy")
    testing.expect_value(t, pty_test_trace(), `"first | second | legacy" Enter Enter`) // no Esc: notices never interrupt
    testing.expect_value(t, len(inbox_test_slot_ids(id)), 0)
    // The same task and reason coalesce to the newest notice.
    pty_test_reset(); pty_test_forget_typed(id)
    testing.expect(t, bridge_task_notice_enqueue(id, notice_test_n("older", origin = "o5")))
    testing.expect(t, bridge_task_notice_enqueue(id, notice_test_n("newer", origin = "o5")))
    bridge_task_notice_tick(bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_WINDOW_MS + 1)
    testing.expect_value(t, pty_test_trace(), `"newer" Enter Enter`)
    bridge_inbox_forget_all(); bridge_inbox_restore_all()
    testing.expect_value(t, len(inbox_test_slot_ids(id)), 0)
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
inbox_acp_journal_upgrade_and_exactly_once_restore :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev, dir := inbox_test_begin("inbox-acp-upgrade"); defer inbox_test_end(prev, dir)
    f: T4_Runtime_Test; t16_open(&f, "inst_inbox_upgrade"); defer t16_close(&f)
    acp_runtime_replace(&f.r.d.current_input, "running")
    // A journal from before the bridge inbox: queue, completed ids, batch.
    state := ACP_State{runtime_json = `{"phase":"ready","queue":[{"id":"running","text":"running"},{"id":"pending","text":"pending"},{"id":"done","text":"done"},{"id":"pending","text":"pending"},{"id":"last","text":"last"}],"completed_inputs":["done"],"send_now":{"batch_id":"snb_old","state":"failed","attempt":1,"members":[]}}`}
    testing.expect(t, acp_runtime_inbox_restore(f.r, &state))
    testing.expect(t, acp_runtime_inbox_restore(f.r, &state), "a repeated upgrade never duplicates")
    if !testing.expect_value(t, len(f.r.inbox.queue), 2) do return
    testing.expect_value(t, f.r.inbox.queue[0].id, "pending")
    testing.expect_value(t, f.r.inbox.queue[1].id, "last")
    testing.expect(t, bridge_inbox_completed(f.r.inbox, "done") && f.r.inbox.send_now.batch_id == "snb_old")
    // Saved before any journal rewrite could drop the old fields.
    saved, ok := bridge_inbox_load("inst_inbox_upgrade"); defer bridge_inbox_delete(&saved)
    testing.expect(t, ok && len(saved.queue) == 2)
    // The journal's outgoing prompt carried "last"; the inbox file was not
    // rewritten before the crash. Restore removes it: never delivered twice.
    acp_inbox_dispatched(f.r, "last")
    current := ACP_State{runtime_json = `{"phase":"ready"}`}
    testing.expect(t, acp_runtime_inbox_restore(f.r, &current))
    testing.expect(t, len(f.r.inbox.queue) == 1 && f.r.inbox.queue[0].id == "pending" && bridge_inbox_completed(f.r.inbox, "last"))
}

@(test)
inbox_acp_queued_input_replays_after_restart_once :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev, dir := inbox_test_begin("inbox-acp-replay"); defer inbox_test_end(prev, dir)
    id := "inst_inbox_replay"
    {
        f: T4_Runtime_Test; t16_open(&f, id); defer t16_close(&f)
        acp_runtime_replace(&f.r.d.phase, "prompt") // busy: the input queues
        testing.expect(t, t16_input(&f, "msg_r1", "replayed after restart", .Steer, "", ACP_NEXT_TURN_KIND))
        testing.expect_value(t, t16_writes(&f), 0)
        testing.expect(t, acp_runtime_committed(f.r)) // the production checkpoint's inbox commit
    }
    {
        f: T4_Runtime_Test; t16_open(&f, id); defer t16_close(&f)
        testing.expect(t, len(f.r.inbox.queue) == 1 && f.r.inbox.queue[0].id == "msg_r1")
        t4_runtime_call(&f, "inbox_tick")
        if !acp_test_wait(t, &f.f, .Writes, 1) do return
        testing.expect(t, strings.contains(sn_write(&f, 0), "replayed after restart"))
        t4_runtime_reply(t, &f, 0, `{"stopReason":"end_turn"}`, 1)
        testing.expect(t, acp_runtime_committed(f.r))
    }
    {
        f: T4_Runtime_Test; t16_open(&f, id); defer t16_close(&f)
        testing.expect_value(t, len(f.r.inbox.queue), 0)
        testing.expect(t, t16_input(&f, "msg_r1", "retried admission", .Steer, "", ACP_NEXT_TURN_KIND), "a delivered identity is acknowledged")
        testing.expect_value(t, t16_writes(&f), 0)
    }
}

inbox_test_acp_own :: proc(f: ^T4_Runtime_Test) -> map[string]^ACP_Runtime {
    bridge_runtime_set_status(f.r.instance, "running", "idle")
    prev := acp_runtimes; acp_runtimes = make(map[string]^ACP_Runtime)
    acp_runtimes[f.r.instance] = f.r
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == f.r.instance do inst.runtime_transport = "acp"
    sync.mutex_unlock(&bridge_runtime_mutex)
    return prev
}

@(test)
notice_queue_acp_busy_waits_and_revalidates_at_prompt_start :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev, dir := inbox_test_begin("notice-acp"); defer inbox_test_end(prev, dir)
    prev_records := inbox_test_records()
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_relay
    defer bridge_task_notice_relay = prev_relay
    f: T4_Runtime_Test; t16_open(&f, "inst_notice_acp")
    defer { t16_close(&f); bridge_runtime_set_status("inst_notice_acp", "stopped", "idle") }
    prev_owners := inbox_test_acp_own(&f)
    defer { delete(acp_runtimes); acp_runtimes = prev_owners }
    acp_runtime_replace(&f.r.d.phase, "prompt")
    notice_test_status = 200; notice_test_state = "ready"
    testing.expect(t, bridge_task_notice_enqueue(f.r.instance, notice_test_n("first", origin = "o1")))
    testing.expect(t, bridge_task_notice_enqueue(f.r.instance, notice_test_n("second", origin = "o2")))
    testing.expect_value(t, len(f.r.inbox.queue), 2) // busy: they wait in the inbox
    testing.expect(t, f.r.inbox.queue[0].lane == .Wake)
    // The turn ends; the task moved on while they waited: no prompt.
    acp_runtime_replace(&f.r.d.phase, "ready"); notice_test_state = "done"
    sync.atomic_store(&f.f.clock, 103000)
    t4_runtime_call(&f, "inbox_tick") // asks for the task state
    bridge_task_state_refresh()        // the worker reads it outside every lock
    t4_runtime_call(&f, "inbox_tick")
    testing.expect_value(t, len(f.r.inbox.queue), 0)
    testing.expect_value(t, t16_writes(&f), 0)
    testing.expect_value(t, f.r.d.phase, "ready")
    bridge_task_states_reset()
    notice_test_state = "ready"
    testing.expect(t, bridge_task_notice_enqueue(f.r.instance, notice_test_n("third", origin = "o1")))
    testing.expect(t, bridge_task_notice_enqueue(f.r.instance, notice_test_n("fourth", origin = "o2")))
    t4_runtime_call(&f, "inbox_tick"); bridge_task_state_refresh()
    t4_runtime_call(&f, "inbox_tick")
    testing.expect_value(t, t16_writes(&f), 0) // the collection window is open
    sync.atomic_store(&f.f.clock, 106000)
    t4_runtime_call(&f, "inbox_tick")
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    line := sn_write(&f, 0)
    testing.expect(t, strings.contains(line, "third") && strings.contains(line, "fourth"), "one turn for the batch")
    testing.expect_value(t, f.r.d.phase, "prompt")
}

@(test)
notice_queue_failed_delivery_retries_and_expiry_never_sends :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev, dir := inbox_test_begin("notice-retry"); defer inbox_test_end(prev, dir)
    prev_daemon, prev_send, prev_sleep := pty_runtime_daemon, pty_runtime_send, pty_runtime_sleep
    pty_runtime_daemon, pty_runtime_send, pty_runtime_sleep = pty_test_daemon, notice_test_send, pty_test_sleep
    defer { pty_runtime_daemon, pty_runtime_send, pty_runtime_sleep = prev_daemon, prev_send, prev_sleep; notice_test_fail = false }
    notice_test_turns = 0; notice_test_fail = true
    id := "inst_notice_retry"
    n := notice_test_n("retry", task = "")
    testing.expect(t, bridge_task_notice_enqueue(id, n), "an unknown instance's notice waits in its inbox file")
    start := bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_WINDOW_MS + 1
    bridge_task_notice_tick(start)
    testing.expect_value(t, notice_test_turns, 0) // unknown restored runtime waits for reconciliation
    pty_test_activity(id, "idle", "pane_diff")
    pty_test_forget_typed(id)
    defer bridge_runtime_set_status(id, "stopped", "idle")
    path, _ := bridge_inbox_path(id); defer delete(path)
    before_retry, before_err := os.read_entire_file(path, context.allocator); defer delete(before_retry)
    testing.expect(t, before_err == nil)
    now := start + 2*BRIDGE_TASK_NOTICE_WINDOW_MS
    bridge_task_notice_tick(now)
    after_retry, after_err := os.read_entire_file(path, context.allocator); defer delete(after_retry)
    testing.expect(t, after_err == nil)
    testing.expect_value(t, string(after_retry), string(before_retry)) // a failed delivery rewrites nothing
    testing.expect_value(t, len(inbox_test_slot_ids(id)), 1)
    testing.expect_value(t, notice_test_turns, 1)
    bridge_task_notice_tick(now + BRIDGE_TASK_NOTICE_WINDOW_MS - 1)
    testing.expect_value(t, notice_test_turns, 1)
    notice_test_fail = false; bridge_task_notice_tick(now + BRIDGE_TASK_NOTICE_WINDOW_MS)
    testing.expect_value(t, notice_test_turns, 2)
    testing.expect_value(t, len(inbox_test_slot_ids(id)), 0)
    testing.expect(t, bridge_task_notice_enqueue(id, n))
    bridge_task_notice_tick(bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_MAX_AGE_MS + 2000)
    testing.expect_value(t, notice_test_turns, 2)
    testing.expect_value(t, len(inbox_test_slot_ids(id)), 0)
}

@(test)
notice_queue_worker_restores_saved_inboxes :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev, dir := inbox_test_begin("notice-worker"); defer inbox_test_end(prev, dir)
    testing.expect(t, bridge_task_notice_enqueue("inst_notice_worker", notice_test_n("saved", task = "")))
    bridge_inbox_forget_all()
    worker := bridge_task_notice_start()
    testing.expect(t, worker != nil)
    testing.expect_value(t, len(inbox_test_slot_ids("inst_notice_worker")), 1)
    bridge_task_notice_stop(worker)
    testing.expect_value(t, len(inbox_test_slot_ids("inst_notice_worker")), 0)
    worker = bridge_task_notice_start()
    testing.expect_value(t, len(inbox_test_slot_ids("inst_notice_worker")), 1)
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
    p.ready = acp_runtime_command(p.instance, "inbox_tick")
    sync.atomic_store(&p.done, true)
}

@(test)
notice_queue_slow_relevance_read_leaves_acp_ownership_and_dispatcher_free :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    prev, dir := inbox_test_begin("notice-slow"); defer inbox_test_end(prev, dir)
    prev_records := inbox_test_records()
    defer { delete(bridge_local_token_records); bridge_local_token_records = prev_records }
    f: T4_Runtime_Test; t16_open(&f, "inst_notice_slow_relay")
    defer { t16_close(&f); bridge_runtime_set_status("inst_notice_slow_relay", "stopped", "idle") }
    prev_owners := inbox_test_acp_own(&f)
    defer { delete(acp_runtimes); acp_runtimes = prev_owners }
    blocked: Notice_Test_Blocked_Relay; notice_test_blocked = &blocked
    prev_relay := bridge_task_notice_relay; bridge_task_notice_relay = notice_test_blocked_relay
    defer { bridge_task_notice_relay = prev_relay; notice_test_blocked = nil }
    testing.expect(t, bridge_task_notice_enqueue(f.r.instance, notice_test_n("fail-open notice")))
    sync.atomic_store(&f.f.clock, 103000)
    t4_runtime_call(&f, "inbox_tick") // asks for the task state
    worker := thread.create_and_start(proc() {
        context.allocator = runtime.heap_allocator()
        arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
        context.temp_allocator = vm.arena_allocator(&arena)
        bridge_task_state_refresh()
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
    // Always release and join, even if an assertion would fail.
    sync.atomic_store(&blocked.release, true)
    thread.join(worker); thread.destroy(worker)
    thread.join(probe); thread.destroy(probe)
    testing.expect(t, entered, "relay must have blocked before probing ACP")
    testing.expect(t, available_while_http_blocked && p.owned && p.ready, "ownership lookup and dispatcher command complete while relay is blocked")
    testing.expect_value(t, t16_writes(&f), 0)
    t4_runtime_call(&f, "inbox_tick")
    testing.expect(t, acp_test_wait(t, &f.f, .Writes, 1), "a failed relevance read preserves the notice")
}
