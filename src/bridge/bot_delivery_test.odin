package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

Bridge_Bot_Test :: struct {
	w: ^Bridge_Bot_Worker,
	now: i64,
	status: string,
	activity: string,
	relaunched: bool,
	new_record_ms, ready_ms, rollover_until_ms: i64,
	refuse_provider, unrunnable: string,
	refuse_status: int,
	refuse_code: string,
	switches: [dynamic]string,
	launches, notices: int,
	exit_first_launch: bool,
	exit_ms, missing_record_ms, alive_ms: i64,
	process_alive: bool,
	startup_generation, previous_generation: u64,
	notice_at: i64,
	launch_id: string,
	reports: [dynamic]string,
	report_mutex: sync.Mutex,
	busy_stopped, busy_reserved, busy_locked: bool,
	gate, entered: bool, // atomic, for live worker cancellation
}
bridge_bot_test_mutex: sync.Mutex
bridge_bot_test: ^Bridge_Bot_Test

bridge_bot_test_now :: proc() -> i64 { return bridge_bot_test.now }
bridge_bot_test_sleep :: proc(ms: i64) { bridge_bot_test.now += ms }
bridge_bot_test_snapshot :: proc(instance: string) -> (Bridge_Runtime_Instance, bool) {
	s := bridge_bot_test
	status := s.status
	ready := status == "running" || status == "idle"
	if s.ready_ms > s.now && s.now >= s.new_record_ms { status = "starting"; ready = false }
	alive := s.process_alive
	if s.alive_ms > 0 && s.now >= s.alive_ms do alive = true
	if s.exit_ms > 0 && s.now >= s.exit_ms { status = "starting"; ready = false; alive = false }
	generation := s.startup_generation
	if s.new_record_ms > 0 && s.now < s.new_record_ms do generation = s.previous_generation
	pid: i32
	if generation > 0 do pid = 1
	return {runtime_status = status, start_success_seen = ready, pty_process_alive = alive,
		startup = {generation = generation, pty_pid = pid}}, true
}
bridge_bot_test_record :: proc(instance: string) -> (Bridge_Runtime_Launch, bool) {
	if bridge_bot_test.missing_record_ms > 0 && bridge_bot_test.now >= bridge_bot_test.missing_record_ms do return {}, false
	if bridge_bot_test.now >= bridge_bot_test.new_record_ms && bridge_bot_test.new_record_ms > 0 do return {command_id = "new"}, true
	return {command_id = "old"}, true
}
bridge_bot_test_switch :: proc(attempt_id: string, c: contracts.Bot_Candidate_Wire) -> (status: int, relaunched: bool, error_code: string) {
	s := bridge_bot_test
	append(&s.switches, c.provider)
	if c.provider == s.refuse_provider do return s.refuse_status, false, s.refuse_code
	return 200, s.relaunched, ""
}
bridge_bot_test_launch :: proc(instance, command_id: string) -> (ok: bool, detail: string, err: Bridge_Error) {
	s := bridge_bot_test
	s.launches += 1
	delete(s.launch_id, runtime.heap_allocator())
	s.launch_id = strings.clone(command_id, runtime.heap_allocator())
	s.startup_generation += 1
	s.status, s.process_alive = "running", true
	if s.exit_first_launch && s.launches == 1 { s.status = "stopped"; s.process_alive = false }
	return true, "", {}
}
bridge_bot_test_notice :: proc(instance: string) -> bool {
	s := bridge_bot_test
	s.notices += 1
	s.notice_at = s.now
	if s.w != nil { sync.atomic_store(&s.w.read_seen_ms, s.now); sync.atomic_store(&s.w.reply_seen_ms, s.now) }
	return true
}
bridge_bot_test_report :: proc(report: string) -> bool {
	s := bridge_bot_test
	sync.mutex_lock(&s.report_mutex)
	append(&s.reports, strings.clone(report, runtime.heap_allocator()))
	sync.mutex_unlock(&s.report_mutex)
	return true
}
bridge_bot_test_activity :: proc(instance: string) -> string { if bridge_bot_test.activity != "" do return bridge_bot_test.activity; return "idle" }

@(test)
test_bot_live_row_reuse_requires_observed_child :: proc(t: ^testing.T) {
	active_row := proc(_: string) -> (Bridge_Runtime_Instance, bool) { return {runtime_status = "running"}, true }
	stale_row := proc(_: string) -> (Bridge_Runtime_Instance, bool) { return {runtime_status = "unreachable"}, true }
	stopping := proc(_: string) -> (Bridge_Runtime_Instance, bool) { return {runtime_status = "running", stopped_intent_unix_ms = 1}, true }
	unavailable := proc(_: string) -> Bridge_Instance_Probe_Result { return {state = "unknown"} }
	exited := proc(_: string) -> Bridge_Instance_Probe_Result { return {state = "exited", pid = 42, exit_code = 0} }
	alive := proc(_: string) -> Bridge_Instance_Probe_Result { return {state = "alive", pid = 42} }
	testing.expect(t, !bridge_bot_can_reuse_live_row("inst_bot", active_row, unavailable))
	testing.expect(t, !bridge_bot_can_reuse_live_row("inst_bot", active_row, exited))
	testing.expect(t, bridge_bot_can_reuse_live_row("inst_bot", stale_row, alive))
	testing.expect(t, !bridge_bot_can_reuse_live_row("inst_bot", stopping, alive))
}

@(test)
test_bot_live_row_retry_ignores_stale_ready_projection :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test
	bridge_bot_test_begin(&s)
	defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	s.process_alive = false // The cached state still says running and start-success.
	w.live_row_retry_at_ms = s.now + 250
	w.ready_deadline_ms = s.now + 1_000
	outcome, _, _, _ := bridge_bot_wait_ready(w, false, "")
	testing.expect_value(t, outcome, "")
	testing.expect_value(t, s.launches, 1)
}

bridge_bot_test_busy :: proc() -> (traffic_stopped, update_reserved, vault_unlocked: bool) {
	s := bridge_bot_test
	sync.atomic_store(&s.entered, true)
	for sync.atomic_load(&s.gate) do time.sleep(time.Millisecond)
	return s.busy_stopped, s.busy_reserved, !s.busy_locked
}
bridge_bot_test_runnable :: proc(provider, model: string) -> bool { return provider != bridge_bot_test.unrunnable }
bridge_bot_test_rollover :: proc(instance: string) -> bool { return bridge_bot_test.now < bridge_bot_test.rollover_until_ms }

// Every fixture restores each seam, even on an early test return, and joins all
// workers before freeing test state. Serialize tests that replace package seams.
bridge_bot_test_begin :: proc(s: ^Bridge_Bot_Test) {
	sync.mutex_lock(&bridge_bot_test_mutex)
	bridge_bot_test = s
	s.now, s.status, s.process_alive = 1000, "running", true
	bridge_bot_switch_proc = bridge_bot_test_switch
	bridge_bot_launch_proc = bridge_bot_test_launch
	bridge_bot_snapshot_proc = bridge_bot_test_snapshot
	bridge_bot_launch_record_proc = bridge_bot_test_record
	bridge_bot_notice_proc = bridge_bot_test_notice
	bridge_bot_report_proc = bridge_bot_test_report
	bridge_bot_activity_proc = bridge_bot_test_activity
	bridge_bot_busy_inputs_proc = bridge_bot_test_busy
	bridge_bot_now_proc = bridge_bot_test_now
	bridge_bot_runnable_proc = bridge_bot_test_runnable
	bridge_bot_rollover_proc = bridge_bot_test_rollover
	bridge_bot_sleep_proc = bridge_bot_test_sleep
}
bridge_bot_test_end :: proc(s: ^Bridge_Bot_Test) {
	sync.atomic_store(&s.gate, false)
	bridge_bot_shutdown()
	for key in bridge_bot_backoff do delete(key, runtime.heap_allocator())
	clear(&bridge_bot_backoff)
	if s.w != nil { bridge_bot_forget_activity(s.w.frame.agent_instance_id); bridge_bot_worker_destroy(s.w) }
	for report in s.reports do delete(report, runtime.heap_allocator())
	delete(s.reports)
	delete(s.switches)
	delete(s.launch_id, runtime.heap_allocator())
	bridge_bot_switch_proc = bridge_bot_switch_http
	bridge_bot_launch_proc = bridge_bot_launch_via_start_begin
	bridge_bot_snapshot_proc = bridge_runtime_instance_snapshot
	bridge_bot_launch_record_proc = bridge_runtime_get_launch
	bridge_bot_notice_proc = bridge_bot_deliver_notice
	bridge_bot_report_proc = bridge_bot_send_report
	bridge_bot_activity_proc = bridge_bot_local_activity
	bridge_bot_busy_inputs_proc = bridge_bot_busy_inputs
	bridge_bot_now_proc = bridge_runtime_now_ms
	bridge_bot_runnable_proc = bridge_provider_runnable
	bridge_bot_rollover_proc = bridge_bot_rollover_in_progress
	bridge_bot_sleep_proc = bridge_bot_sleep
	bridge_bot_test = nil
	sync.mutex_unlock(&bridge_bot_test_mutex)
}
bridge_bot_test_frame :: proc(attempt: string = "attempt") -> string {
	candidates := [?]contracts.Bot_Candidate_Wire{{provider = "p1", provider_profile = "profile1", model = "m1", tier = "preferred"}, {provider = "p2", provider_profile = "profile2", model = "m2", tier = "allowed"}}
	frame := contracts.Bot_Deliver_Wire{type = "bot_deliver", command_id = attempt, agent_instance_id = "inst_bot_test", attempt_id = attempt, delivery_id = "delivery", candidates = candidates[:], timers = {launch_ready_ms = 2000, progress_interval_ms = 30_000}}
	bytes, _ := json.marshal(frame)
	return string(bytes)
}
bridge_bot_test_worker :: proc(s: ^Bridge_Bot_Test) -> ^Bridge_Bot_Worker {
	frame := bridge_bot_test_frame()
	defer delete(frame)
	w := new(Bridge_Bot_Worker, runtime.heap_allocator())
	_ = json.unmarshal_string(frame, &w.frame, allocator = runtime.heap_allocator())
	s.w = w
	return w
}
bridge_bot_test_join :: proc(w: ^Bridge_Bot_Worker) {
	thread.join(w.worker_thread)
	thread.destroy(w.worker_thread)
	w.worker_thread = nil
}

@(test)
test_bot_deliver_spec_and_ordering_key :: proc(t: ^testing.T) {
	spec, ok := bridge_command_spec("bot_deliver")
	testing.expect(t, ok && spec.class == .Interactive && spec.priority == .Interactive && spec.key_kind == .Agent)
	testing.expect(t, spec.queued && spec.requires_id && spec.retry_safe && !spec.coalescible)
	testing.expect_value(t, spec.timeout_ms, 10_000)
	testing.expect_value(t, spec.cost_units, 2)
	key := bridge_command_ordering_key("bot_deliver", `{"agent_instance_id":"inst_bot"}`)
	defer delete(key)
	testing.expect_value(t, key, "agent:inst_bot")
	ack, ack_ok := bridge_command_spec("bot_delivery_report_ack")
	testing.expect(t, ack_ok && !ack.queued && !ack.requires_id)
}

@(test)
test_handle_deliver_idempotent_by_attempt :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	s.busy_locked = true
	frame := bridge_bot_test_frame(); defer delete(frame)
	first := bridge_bot_handle_deliver(frame); defer delete(first)
	w := bridge_bot_workers["attempt"]
	bridge_bot_test_join(w)
	second := bridge_bot_handle_deliver(frame); defer delete(second)
	testing.expect_value(t, first, second)
	testing.expect(t, bridge_bot_workers["attempt"] == w && len(bridge_bot_workers) == 1)
	testing.expect_value(t, len(s.reports), 1)
	testing.expect(t, strings.contains(s.reports[0], `"state":"busy"`))
	for invalid in ([]string{`{}`, `{"attempt_id":"a","agent_instance_id":"i"}`, `{"attempt_id":"a","candidates":[{}]}`, `{"attempt_id":"a","agent_instance_id":"i","candidates":[]}`, "{"}) {
		result := bridge_bot_handle_deliver(invalid)
		testing.expect(t, strings.contains(result, "validation_failed"))
		delete(result)
	}
}

@(test)
test_new_attempt_cancels_old_worker :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	s.busy_locked = true
	sync.atomic_store(&s.gate, true)
	first := bridge_bot_test_frame("old"); defer delete(first)
	result := bridge_bot_handle_deliver(first); delete(result)
	old := bridge_bot_workers["old"]
	for !sync.atomic_load(&s.entered) do time.sleep(time.Millisecond)
	second := bridge_bot_test_frame("new"); defer delete(second)
	result = bridge_bot_handle_deliver(second); delete(result)
	testing.expect(t, sync.atomic_load(&old.cancel))
	sync.atomic_store(&s.gate, false)
	bridge_bot_test_join(old)
	bridge_bot_test_join(bridge_bot_workers["new"])
	testing.expect_value(t, len(s.reports), 1)
	testing.expect(t, strings.contains(s.reports[0], `"attempt_id":"new"`), "cancelled worker emits no report")
	bridge_bot_collect()
	testing.expect(t, len(bridge_bot_workers) == 1)
}

@(test)
test_candidate_loop_skips_skip_list_and_not_runnable :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	w.frame.skip = make([]contracts.Bot_Skip_Wire, 1, runtime.heap_allocator())
	w.frame.skip[0] = {provider = strings.clone("p1", runtime.heap_allocator()), model = strings.clone("m1", runtime.heap_allocator()), reason = strings.clone("previous", runtime.heap_allocator())}
	s.unrunnable = "p2"
	bridge_bot_run(w)
	testing.expect_value(t, len(w.outcomes), 2)
	testing.expect_value(t, w.outcomes[0].outcome, "skipped")
	testing.expect_value(t, w.outcomes[0].detail, "previous")
	testing.expect_value(t, w.outcomes[1].outcome, "not_runnable")
	testing.expect_value(t, len(s.switches), 0)
	testing.expect(t, strings.contains(s.reports[len(s.reports)-1], `"state":"exhausted"`))
}

@(test)
test_switch_refused_moves_on :: proc(t: ^testing.T) {
	for mode in 0..<3 {
		s: Bridge_Bot_Test; bridge_bot_test_begin(&s)
		w := bridge_bot_test_worker(&s)
		s.refuse_provider = "p1"
		s.refuse_status = 409
		s.refuse_code = "bot_relocation_open"
		expected := "bot_relocation_open"
		if mode == 1 { s.refuse_status = 0; s.refuse_code = ""; expected = "transport" }
		if mode == 2 { s.refuse_status = 403; s.refuse_code = ""; expected = "http_403" }
		bridge_bot_run(w)
		testing.expect_value(t, len(s.switches), 2)
		testing.expect_value(t, w.outcomes[0].outcome, "switch_refused")
		testing.expect_value(t, w.outcomes[0].detail, expected)
		testing.expect_value(t, w.outcomes[1].outcome, "acted")
		bridge_bot_test_end(&s)
	}
}

@(test)
test_terminal_report_resent_until_ack :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	if bridge_bot_workers == nil do bridge_bot_workers = make(map[string]^Bridge_Bot_Worker)
	bridge_bot_workers[w.frame.attempt_id] = w
	w.phase = .Done
	bridge_bot_report(w, "exhausted", "all_candidates_failed")
	original := strings.clone(w.terminal_json); defer delete(original)
	bridge_bot_drain(nil, 1)
	testing.expect_value(t, len(s.reports), 2)
	s.now += 4999; bridge_bot_drain(nil, 1)
	testing.expect_value(t, len(s.reports), 2)
	s.now += 1; bridge_bot_drain(nil, 1)
	testing.expect_value(t, len(s.reports), 3)
	testing.expect_value(t, s.reports[2], original)
	bridge_bot_drain(nil, 2)
	testing.expect_value(t, len(s.reports), 4)
	bridge_bot_handle_report_ack(`{"attempt_id":"attempt","seq":0}`)
	testing.expect(t, w.terminal_json != "")
	bridge_bot_handle_report_ack(`{"attempt_id":"attempt","seq":1}`)
	testing.expect_value(t, w.terminal_json, "")
	s.now += 5000; bridge_bot_drain(nil, 2)
	testing.expect_value(t, len(s.reports), 4)
	delete_key(&bridge_bot_workers, w.frame.attempt_id)
}

@(test)
test_feature_advertised :: proc(t: ^testing.T) {
	found := false
	for feature in BRIDGE_RUNTIME_FEATURES do if feature == contracts.BRIDGE_FEATURE_BOT_DELIVER_V1 do found = true
	testing.expect(t, found)
	wire := bridge_runtime_features_json(context.allocator); defer delete(wire)
	testing.expect(t, strings.contains(wire, "bot_deliver_v1"))
}

@(test)
test_sticky_candidate_delivers_without_switch :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	w.frame.current_provider, w.frame.current_model = strings.clone("p2", runtime.heap_allocator()), strings.clone("m2", runtime.heap_allocator())
	bridge_bot_run(w)
	testing.expect_value(t, len(s.switches), 0)
	testing.expect_value(t, s.launches, 0)
	testing.expect_value(t, s.notices, 1)
	testing.expect_value(t, len(w.outcomes), 1)
	testing.expect_value(t, w.outcomes[0].provider, "p2")
	testing.expect_value(t, w.outcomes[0].outcome, "acted")
	testing.expect_value(t, w.candidate_index, 1)
}

@(test)
test_sticky_ignored_when_stopped_skipped_or_backed_off :: proc(t: ^testing.T) {
	for mode in 0..<3 {
		s: Bridge_Bot_Test; bridge_bot_test_begin(&s)
		w := bridge_bot_test_worker(&s)
		w.frame.current_provider, w.frame.current_model = strings.clone("p2", runtime.heap_allocator()), strings.clone("m2", runtime.heap_allocator())
		if mode == 0 do s.status = "stopped"
		if mode == 1 {
			w.frame.skip = make([]contracts.Bot_Skip_Wire, 1, runtime.heap_allocator())
			w.frame.skip[0] = {provider = strings.clone("p2", runtime.heap_allocator()), model = strings.clone("m2", runtime.heap_allocator()), reason = strings.clone("old", runtime.heap_allocator())}
		}
		if mode == 2 do bridge_bot_candidate_record_failure(w.frame.candidates[1], "not_read", {}, false, s.now)
		bridge_bot_run(w)
		testing.expect_value(t, len(s.switches), 1)
		testing.expect_value(t, s.switches[0], "p1")
		testing.expect_value(t, w.outcomes[0].provider, "p1")
		if mode == 0 {
			testing.expect_value(t, s.launches, 1)
	// The launch seam receives the stable attempt ID; its legacy adapter builds
	// botl_attempt_0, while start-begin sends ref=bot_attempt.
	testing.expect_value(t, s.launch_id, "attempt")
		}
		bridge_bot_test_end(&s)
	}
}

@(test)
test_relaunch_waits_for_new_launch_record :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	s.relaunched, s.new_record_ms, s.ready_ms = true, 1500, 1750
	bridge_bot_run(w)
	testing.expect_value(t, s.launches, 0)
	testing.expect_value(t, s.notices, 1)
	testing.expect_value(t, s.notice_at, 1750)
	testing.expect_value(t, w.outcomes[0].outcome, "acted")
}

@(test)
test_relaunch_blocked_counts_only_after_new_record :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	s.new_record_ms, s.status = 1500, "blocked"
	w.ready_deadline_ms = 3000
	outcome, detail, _, _ := bridge_bot_wait_ready(w, true, "old")
	testing.expect_value(t, s.now, 1500)
	testing.expect_value(t, outcome, "startup_blocked")
	testing.expect_value(t, detail, "prompt")
	s.now, s.new_record_ms = 1000, 0
	outcome, _, _, _ = bridge_bot_wait_ready(w, true, "old")
	testing.expect_value(t, s.now, 3000)
	testing.expect_value(t, outcome, "launch_timeout")
	testing.expect_value(t, s.notices, 0)
}

@(test)
test_busy_reasons :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	for mode in 0..<4 {
		s.busy_stopped, s.busy_reserved, s.busy_locked = mode == 0, mode == 1, mode == 2
		reason, busy := bridge_bot_busy_reason()
		testing.expect_value(t, busy, mode < 3)
		expected := ""
		if mode < 2 do expected = "draining"
		if mode == 2 do expected = "vault_locked"
		testing.expect_value(t, reason, expected)
	}
}

@(test)
test_backoff_table :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	c := contracts.Bot_Candidate_Wire{provider = "test", model = "model"}
	for outcome in ([]string{"startup_blocked", "launch_timeout", "not_read", "idle_no_reply", "crashed"}) {
		bridge_bot_candidate_record_failure(c, outcome, {}, false, 100)
		delay := i64(300_000)
		if outcome == "startup_blocked" do delay = 1_800_000
		testing.expect(t, bridge_bot_candidate_backoff_active(c, 100+delay-1))
		testing.expect(t, !bridge_bot_candidate_backoff_active(c, 100+delay))
		bridge_bot_candidate_clear(c)
	}
	for class in ([]contracts.Bridge_Error_Class{.recoverable, .fatal}) {
		bridge_bot_candidate_record_failure(c, "launch_failed", {class = class}, true, 100)
		testing.expect(t, bridge_bot_candidate_backoff_active(c, 1_800_099))
		testing.expect(t, !bridge_bot_candidate_backoff_active(c, 1_800_100))
		bridge_bot_candidate_clear(c)
	}
	for n in 0..<8 {
		bridge_bot_candidate_record_failure(c, "launch_failed", {class = .retriable}, true, 100)
		expected := min(i64(60_000) << uint(n), 1_800_000)
		testing.expect(t, bridge_bot_candidate_backoff_active(c, 100+expected-1))
		testing.expect(t, !bridge_bot_candidate_backoff_active(c, 100+expected))
	}
	bridge_bot_candidate_clear(c)
	bridge_bot_candidate_record_failure(c, "launch_failed", {class = .retriable, retry_after_ms = 2_000_000}, true, 100)
	testing.expect(t, bridge_bot_candidate_backoff_active(c, 2_000_099))
	bridge_bot_candidate_clear(c)
	for outcome in ([]string{"skipped", "not_runnable", "switch_refused", "reply_timeout"}) {
		bridge_bot_candidate_record_failure(c, outcome, {}, false, 100)
		testing.expect(t, !bridge_bot_candidate_backoff_active(c, 100))
	}
}

@(test)
test_rollover_wait_shares_launch_budget_and_delays_notification :: proc(t: ^testing.T) {
	for timeout in ([]bool{false, true}) {
		s: Bridge_Bot_Test; bridge_bot_test_begin(&s)
		w := bridge_bot_test_worker(&s)
		s.rollover_until_ms = 1750
		if timeout do s.rollover_until_ms = 100_000
		bridge_bot_run(w)
		if timeout {
			testing.expect_value(t, s.notices, 0)
			testing.expect_value(t, w.notified_ms, 0)
			testing.expect_value(t, w.outcomes[0].outcome, "launch_timeout")
		} else {
			testing.expect_value(t, s.notices, 1)
			testing.expect_value(t, s.notice_at, 1750)
			testing.expect_value(t, w.notified_ms, s.notice_at)
		}
		bridge_bot_test_end(&s)
	}
}

@(test)
test_bot_worker_retirement_on_ack_expiry_and_shutdown :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	s.busy_locked = true
	frame := bridge_bot_test_frame(); defer delete(frame)
	for mode in 0..<3 {
		result := bridge_bot_handle_deliver(frame); delete(result)
		w := bridge_bot_workers["attempt"]
		bridge_bot_test_join(w)
		if mode == 0 {
			bridge_bot_handle_report_ack(`{"attempt_id":"attempt","seq":1}`)
			bridge_bot_collect()
		}
		if mode == 1 {
			s.now += 599_999; bridge_bot_collect()
			testing.expect_value(t, len(bridge_bot_workers), 1)
			s.now += 1; bridge_bot_collect()
		}
		if mode == 2 do bridge_bot_shutdown()
		testing.expect_value(t, len(bridge_bot_workers), 0)
	}
}

@(test)
test_bot_raw_activity_and_report_queue_are_bounded_and_cleaned :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	if bridge_bot_workers == nil do bridge_bot_workers = make(map[string]^Bridge_Bot_Worker, runtime.heap_allocator())
	bridge_bot_workers[w.frame.attempt_id] = w
	defer delete_key(&bridge_bot_workers, w.frame.attempt_id)
	bridge_bot_note_raw_activity("unrelated", "active")
	testing.expect_value(t, bridge_bot_local_activity("unrelated"), "active")
	bridge_bot_forget_activity("unrelated")
	for row in ([?][2]string{{"  Busy ", "active"}, {"working", "active"}, {"WAITING_APPROVAL", "waiting_user"}, {"waiting", "waiting_user"}, {"inactive", "idle"}, {"idle", "idle"}, {"bad", "unknown"}}) {
		bridge_bot_note_raw_activity(w.frame.agent_instance_id, row[0])
		testing.expect_value(t, bridge_bot_local_activity(w.frame.agent_instance_id), row[1])
	}
	bridge_bot_note_raw_activity(w.frame.agent_instance_id, "busy")
	for i in 0..<1050 do bridge_bot_note_raw_activity(fmt.tprintf("other_%d", i), "idle")
	sync.mutex_lock(&bridge_bot_raw_activity_mutex)
	testing.expect_value(t, len(bridge_bot_raw_activity), 1024)
	sync.mutex_unlock(&bridge_bot_raw_activity_mutex)
	testing.expect_value(t, bridge_bot_local_activity(w.frame.agent_instance_id), "active")
	sync.mutex_lock(&bridge_bot_raw_activity_mutex)
	for key in bridge_bot_raw_activity do delete(key, runtime.heap_allocator())
	clear(&bridge_bot_raw_activity)
	testing.expect_value(t, len(bridge_bot_raw_activity), 0)
	sync.mutex_unlock(&bridge_bot_raw_activity_mutex)
	_ = bridge_bot_send_report(`{"attempt_id":"attempt","seq":1}`)
	_ = bridge_bot_send_report(`{"attempt_id":"attempt","seq":2}`)
	testing.expect_value(t, len(w.pending_reports), 2)
	testing.expect(t, strings.contains(w.pending_reports[0], `"seq":1`))
	for _ in 0..<200 do _ = bridge_bot_send_report(`{"attempt_id":"attempt","seq":3}`)
	testing.expect_value(t, len(w.pending_reports), 128)
	bridge_bot_drain(nil, 1)
	testing.expect_value(t, len(w.pending_reports), 0)
}

// Watch fixtures drive the same clock/activity seams used by the worker loop.
bridge_bot_test_watch :: proc(s: ^Bridge_Bot_Test) -> ^Bridge_Bot_Worker {
 w := bridge_bot_test_worker(s)
 w.phase = .Notified
 w.notified_ms = s.now
 w.dispatched_ms = s.now
 w.frame.timers = {launch_ready_ms = 2000, read_ms = 60_000, read_extend_ms = 60_000, read_max_extends = 4, idle_no_reply_ms = 120_000, reply_cap_ms = 1_800_000, progress_interval_ms = 30_000}
 return w
}
bridge_bot_test_step :: proc(w: ^Bridge_Bot_Worker) -> (string, bool) {
 return bridge_bot_watch_step(w, bridge_bot_activity_proc(w.frame.agent_instance_id), bridge_bot_test.status, bridge_bot_now_proc())
}

@(test)
test_watch_acted_requires_read_then_reply :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s)
 w.reply_seen_ms = s.now
 _, done := bridge_bot_test_step(w); testing.expect(t, !done)
 w.read_seen_ms = s.now + 1
 _, done = bridge_bot_test_step(w); testing.expect(t, !done)
 w.reply_seen_ms = w.read_seen_ms
 result: string
 result, done = bridge_bot_test_step(w)
 testing.expect(t, done && result == "acted")
 for status in ([]string{"failed", "stopped", "unreachable"}) {
  w.reply_seen_ms = 0; s.status = status
  result, done = bridge_bot_test_step(w); testing.expect(t, done && result == "crashed")
 }
}

@(test)
test_watch_read_extends_while_active :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s); s.activity = "active"
 for i in 1..=4 {
  s.now = w.notified_ms + i64(i)*60_000
  _, done := bridge_bot_test_step(w); testing.expect(t, !done && w.read_extends == i)
 }
 s.now += 60_000
 result, done := bridge_bot_test_step(w); testing.expect(t, done && result == "not_read")
}

@(test)
test_watch_not_read :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s)
 s.now += 59_999
 _, done := bridge_bot_test_step(w); testing.expect(t, !done)
 s.now += 1
 result, terminal := bridge_bot_test_step(w); testing.expect(t, terminal && result == "not_read")
}

@(test)
test_watch_idle_no_reply_after_read :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s); w.read_seen_ms = s.now
 _, done := bridge_bot_test_step(w); testing.expect(t, !done && w.phase == .Read)
 s.now += 119_999
 _, done = bridge_bot_test_step(w); testing.expect(t, !done)
 s.now += 1
 result, terminal := bridge_bot_test_step(w); testing.expect(t, terminal && result == "idle_no_reply")
}

@(test)
test_watch_active_holds_reply_timer :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s); w.read_seen_ms = s.now
 _, _ = bridge_bot_test_step(w)
 s.now += 119_999; s.activity = "active"
 _, done := bridge_bot_test_step(w); testing.expect(t, !done && w.idle_since_ms == 0 && w.phase == .Replying)
 s.now += 120_001
 _, done = bridge_bot_test_step(w); testing.expect(t, !done)
 s.activity = "unknown"
 _, done = bridge_bot_test_step(w); testing.expect(t, !done && w.idle_since_ms == s.now)
}

@(test)
test_watch_reply_cap :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s); w.read_seen_ms = s.now; s.activity = "active"
 s.now += 1_799_999
 _, done := bridge_bot_test_step(w); testing.expect(t, !done)
 s.now += 1
 result, terminal := bridge_bot_test_step(w); testing.expect(t, terminal && result == "reply_timeout")
}

bridge_bot_test_silent_notice :: proc(instance: string) -> bool {
 s := bridge_bot_test
 if s.activity == "waiting_user" do s.w.read_seen_ms = s.now
 return true
}

bridge_bot_test_queued_notice :: proc(instance: string) -> bool {
 bridge_bot_test.w.notice_waits_for_dispatch = true
 return true
}

@(test)
test_watch_bot_queue_expiry_ends_attempt_without_switch_or_backoff :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s)
 bridge_bot_notice_proc = bridge_bot_test_queued_notice
 started := s.now
 bridge_bot_run(w)
 testing.expect_value(t, s.now - started, w.frame.timers.reply_cap_ms)
 testing.expect_value(t, len(s.switches), 1)
 if testing.expect_value(t, len(w.outcomes), 1) do testing.expect_value(t, w.outcomes[0].outcome, "not_dispatched")
 for c in w.frame.candidates do testing.expect(t, !bridge_bot_candidate_backoff_active(c, s.now))
 if testing.expect(t, len(s.reports) > 0) do testing.expect(t, strings.contains(s.reports[len(s.reports)-1], `"reason":"not_dispatched"`))
}

@(test)
test_watch_bot_read_deadline_starts_at_first_matching_dispatch :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s)
 w.dispatched_ms = 0
 sync.mutex_lock(&bridge_bot_workers_mutex)
 if bridge_bot_workers == nil do bridge_bot_workers = make(map[string]^Bridge_Bot_Worker, runtime.heap_allocator())
 bridge_bot_workers[w.frame.attempt_id] = w
 sync.mutex_unlock(&bridge_bot_workers_mutex)
 defer {
  sync.mutex_lock(&bridge_bot_workers_mutex)
  delete_key(&bridge_bot_workers, w.frame.attempt_id)
  sync.mutex_unlock(&bridge_bot_workers_mutex)
 }
 s.now += 2*w.frame.timers.read_ms
 _, done := bridge_bot_test_step(w); testing.expect(t, !done)
 id := fmt.tprintf("%s%s", ACP_BOT_INPUT_PREFIX, w.frame.attempt_id)
 bridge_bot_note_dispatch(w.frame.agent_instance_id, "bot_older", s.now)
 bridge_bot_note_dispatch("inst_other", id, s.now)
 sync.atomic_store(&w.cancel, true)
 bridge_bot_note_dispatch(w.frame.agent_instance_id, id, s.now)
 testing.expect_value(t, sync.atomic_load(&w.dispatched_ms), 0)
 sync.atomic_store(&w.cancel, false)
 bridge_bot_note_dispatch(w.frame.agent_instance_id, id, s.now)
 s.now += w.frame.timers.read_ms - 1
 bridge_bot_note_dispatch(w.frame.agent_instance_id, id, s.now)
 _, done = bridge_bot_test_step(w); testing.expect(t, !done)
 s.now += 1
 result: string
 result, done = bridge_bot_test_step(w)
 testing.expect(t, done && result == "not_read")
}
@(test)
test_watch_failure_records_backoff :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s)
 bridge_bot_notice_proc = bridge_bot_test_silent_notice
 bridge_bot_run(w)
 testing.expect(t, len(w.outcomes) == 2)
 for outcome in w.outcomes do testing.expect(t, outcome.outcome == "not_read")
 for c in w.frame.candidates do testing.expect(t, bridge_bot_candidate_backoff_active(c, s.now))
 for key in bridge_bot_backoff do delete(key, runtime.heap_allocator())
 clear(&bridge_bot_backoff)
 for outcome in w.outcomes { delete(outcome.provider, runtime.heap_allocator()); delete(outcome.model, runtime.heap_allocator()); delete(outcome.outcome, runtime.heap_allocator()); delete(outcome.detail, runtime.heap_allocator()) }
 clear(&w.outcomes)
 s.activity = "waiting_user"
 waiting_started := s.now
 bridge_bot_run(w)
 testing.expect(t, s.now - waiting_started == 2 * w.frame.timers.idle_no_reply_ms)
 for outcome in w.outcomes do testing.expect(t, outcome.outcome == "idle_no_reply" && outcome.detail == "waiting_user")
 for c in w.frame.candidates do testing.expect(t, bridge_bot_candidate_backoff_active(c, s.now))
}

@(test)
test_relay_observation_counts_non_empty_read_only :: proc(t: ^testing.T) {
 s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
 w := bridge_bot_test_watch(&s)
 sync.mutex_lock(&bridge_bot_workers_mutex)
 if bridge_bot_workers == nil do bridge_bot_workers = make(map[string]^Bridge_Bot_Worker, runtime.heap_allocator())
 bridge_bot_workers[w.frame.attempt_id] = w
 sync.mutex_unlock(&bridge_bot_workers_mutex)
 defer {
  sync.mutex_lock(&bridge_bot_workers_mutex)
  delete_key(&bridge_bot_workers, w.frame.attempt_id)
  sync.mutex_unlock(&bridge_bot_workers_mutex)
 }
 for body in ([]string{`{"data":{"messages":[]}}`, `{}`, `invalid`, `[]`, `{"data":[]}`, `{"data":{"messages":true}}`}) {
  bridge_bot_note_read(w.frame.agent_instance_id, body, s.now)
  testing.expect(t, w.read_seen_ms == 0)
 }
 bridge_bot_note_read("absent", `{"data":{"messages":[{}]}}`, s.now)
 testing.expect(t, w.read_seen_ms == 0)
 bridge_bot_note_read(w.frame.agent_instance_id, `{"data":{"messages":[{}]}}`, s.now)
 testing.expect(t, w.read_seen_ms == s.now)
 bridge_bot_note_reply(w.frame.agent_instance_id, s.now)
 testing.expect(t, w.reply_seen_ms == s.now)
 w.cancel = true
 bridge_bot_note_read(w.frame.agent_instance_id, `{"data":{"messages":[{}]}}`, s.now+1)
 bridge_bot_note_reply(w.frame.agent_instance_id, s.now+1)
 testing.expect(t, w.read_seen_ms == s.now && w.reply_seen_ms == s.now)
}

@(test)
test_bot_ready_child_exit_before_readiness :: proc(t: ^testing.T) {
	for status in ([]string{"stopped", "starting"}) {
		s: Bridge_Bot_Test; bridge_bot_test_begin(&s)
		w := bridge_bot_test_worker(&s)
		s.status, s.process_alive, s.startup_generation = status, false, 2
		if status == "starting" do s.exit_ms = s.now
		w.ready_deadline_ms = s.now + 2000
		outcome, _, err, has_err := bridge_bot_wait_ready(w, false, "", 1)
		testing.expect_value(t, outcome, "launch_failed")
		testing.expect(t, has_err && err.class == .retriable)
		testing.expect_value(t, s.now, 1000)
		bridge_bot_test_end(&s)
	}
}

@(test)
test_bot_ready_early_exit_relaunch_waits_for_new_generation :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	s.status, s.process_alive = "stopped", false
	s.previous_generation, s.startup_generation = 1, 2
	s.new_record_ms, s.exit_ms, s.missing_record_ms = 1500, 1500, 1500
	w.ready_deadline_ms = 3000
	// The new child exits before any poll can observe its launch record.
	outcome, _, _, _ := bridge_bot_wait_ready(w, true, "old", 1)
	testing.expect_value(t, outcome, "launch_failed")
	testing.expect_value(t, s.now, 1500)
}

@(test)
test_bot_child_exit_advances_to_next_candidate :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	s.status, s.exit_first_launch = "stopped", true
	bridge_bot_run(w)
	testing.expect_value(t, s.launches, 2)
	testing.expect_value(t, s.notices, 1)
	testing.expect_value(t, len(w.outcomes), 2)
	if len(w.outcomes) == 2 {
		testing.expect_value(t, w.outcomes[0].outcome, "launch_failed")
		testing.expect_value(t, w.outcomes[1].outcome, "acted")
	}
}

@(test)
test_bot_starting_without_exit_evidence_waits_for_ready :: proc(t: ^testing.T) {
	for sticky in ([]bool{false, true}) {
		for mode in 0..<3 {
			s: Bridge_Bot_Test; bridge_bot_test_begin(&s)
			w := bridge_bot_test_worker(&s)
			s.process_alive = false
			s.ready_ms, s.alive_ms = 1750, 1750
			if mode != 0 do s.startup_generation = 7
			if mode != 1 do s.missing_record_ms = s.now
			if sticky {
				w.frame.current_provider = strings.clone("p2", runtime.heap_allocator())
				w.frame.current_model = strings.clone("m2", runtime.heap_allocator())
			}
			bridge_bot_run(w)
			testing.expect_value(t, s.now, 1750)
			testing.expect_value(t, s.launches, 0)
			testing.expect_value(t, len(s.switches), 0 if sticky else 1)
			testing.expect_value(t, s.notices, 1)
			testing.expect_value(t, len(w.outcomes), 1)
			if len(w.outcomes) == 1 do testing.expect_value(t, w.outcomes[0].outcome, "acted")
			testing.expect_value(t, len(bridge_bot_backoff), 0)
			bridge_bot_test_end(&s)
		}
	}
}

@(test)
test_bot_observed_launch_record_removal_is_exit :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	s.status, s.process_alive, s.startup_generation = "starting", false, 7
	s.missing_record_ms = 1250
	w.ready_deadline_ms = 3000
	outcome, _, _, _ := bridge_bot_wait_ready(w, false, "", 7)
	testing.expect_value(t, outcome, "launch_failed")
	testing.expect_value(t, s.now, 1250)
}

@(test)
test_bot_observed_alive_child_exit_before_readiness :: proc(t: ^testing.T) {
	s: Bridge_Bot_Test; bridge_bot_test_begin(&s); defer bridge_bot_test_end(&s)
	w := bridge_bot_test_worker(&s)
	s.ready_ms, s.exit_ms, s.missing_record_ms = 3000, 1250, 1000
	w.ready_deadline_ms = 4000
	outcome, _, _, _ := bridge_bot_wait_ready(w, false, "")
	testing.expect_value(t, outcome, "launch_failed")
	testing.expect_value(t, s.now, 1250)
}
