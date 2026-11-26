package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"

BOT_NOTICE :: "New chat message for you — run './bin/ham-ctl channel read' to view and './bin/ham-ctl channel send --text \"<reply>\"' to answer."
Bridge_Bot_Phase :: enum { Launching, Waiting_Ready, Notified, Read, Replying, Done }
Bridge_Bot_Worker :: struct {
	frame: contracts.Bot_Deliver_Wire,
	cancel: bool, // atomic; observation stamps and finished are atomic too
	phase: Bridge_Bot_Phase,
	candidate_index: int,
	outcomes: [dynamic]contracts.Bot_Candidate_Outcome_Wire,
	seq: int,
	read_seen_ms, reply_seen_ms, notified_ms: i64,
	dispatched_ms: i64, // atomic, first dispatch only
	notice_waits_for_dispatch: bool, // set only by the delivery worker
	read_extends: int,
	idle_since_ms: i64,
	worker_thread: ^thread.Thread,
	finished: bool,
	// The registry mutex owns all report-retention fields.
	terminal_json: string,
	pending_reports: [dynamic]string,
	terminal_seq, acked_seq: int,
	ended_ms, last_sent_ms, last_generation: i64,
	last_progress_ms, ready_deadline_ms: i64,
    live_row_retry_at_ms: i64,
    live_row_retries: int,
}
Bridge_Bot_Backoff :: struct { failures: int, next_at_ms: i64 }
@(thread_local) bridge_bot_current_worker: ^Bridge_Bot_Worker
bridge_bot_workers: map[string]^Bridge_Bot_Worker
bridge_bot_workers_mutex: sync.Mutex
bridge_bot_backoff: map[string]Bridge_Bot_Backoff
bridge_bot_backoff_mutex: sync.Mutex
bridge_bot_raw_activity: map[string]string
bridge_bot_raw_activity_mutex: sync.Mutex

bridge_bot_switch_proc: proc(attempt_id: string, cand: contracts.Bot_Candidate_Wire) -> (status: int, relaunched: bool, error_code: string) = bridge_bot_switch_http
bridge_bot_launch_proc: proc(instance_id, attempt_id: string) -> (ok: bool, detail: string, err: Bridge_Error) = bridge_bot_launch_via_start_begin
bridge_bot_snapshot_proc: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) = bridge_runtime_instance_snapshot
bridge_bot_launch_record_proc: proc(instance_id: string) -> (Bridge_Runtime_Launch, bool) = bridge_runtime_get_launch
bridge_bot_notice_proc: proc(instance_id: string) -> bool = bridge_bot_deliver_notice
bridge_bot_report_proc: proc(report_json: string) -> bool = bridge_bot_send_report
bridge_bot_activity_proc: proc(instance_id: string) -> string = bridge_bot_local_activity
bridge_bot_busy_inputs_proc: proc() -> (traffic_stopped, update_reserved, vault_unlocked: bool) = bridge_bot_busy_inputs
bridge_bot_now_proc: proc() -> i64 = bridge_runtime_now_ms
// Local seams complete the dependency boundary without changing normative signatures.
bridge_bot_runnable_proc: proc(provider, model: string) -> bool = bridge_provider_runnable
bridge_bot_rollover_proc: proc(instance_id: string) -> bool = bridge_bot_rollover_in_progress
bridge_bot_sleep_proc: proc(ms: i64) = bridge_bot_sleep

bridge_bot_sleep :: proc(ms: i64) { time.sleep(time.Duration(ms) * time.Millisecond) }
bridge_bot_rollover_in_progress :: proc(instance_id: string) -> bool {
	return bridge_rollover_phase_in_progress(bridge_rollover_phase_of(instance_id))
}
bridge_bot_switch_http :: proc(attempt_id: string, cand: contracts.Bot_Candidate_Wire) -> (status: int, relaunched: bool, error_code: string) {
	credential := bridge_credential_snapshot()
	defer delete(credential)
	body, encode_err := json.marshal(struct {provider, provider_profile, model: string}{cand.provider, cand.provider_profile, cand.model})
	if encode_err != nil do return 0, false, ""
	defer delete(body)
	headers := [?]httpc.Header{httpc.bearer(credential)}
	req := httpc.Request{method = .POST, url = bridge_hub_url(), path = {"api", "v1", "bridge", "bot-attempts", attempt_id, "switch"}, headers = headers[:], body = httpc.raw_body(httpc.CONTENT_TYPE_JSON, body)}
	resp, err := bridge_http_request_retry(req)
	defer httpc.response_destroy(&resp)
	if err != .None do return 0, false, ""
	wire: struct {data: struct {relaunched: bool}, error: struct {details: struct {code: string}}}
	_ = json.unmarshal(resp.body, &wire, allocator = context.temp_allocator)
	return resp.status, wire.data.relaunched, wire.error.details.code
}
bridge_bot_launch_via_start_begin :: proc(instance_id, attempt_id: string) -> (ok: bool, detail: string, err: Bridge_Error) {
	deadline_ns: i64
	if w := bridge_bot_current_worker; w != nil {
		left_ms := w.ready_deadline_ms - bridge_bot_now_proc()
		if left_ms <= 0 do return false, "launch deadline elapsed", bridge_error(.hub_connect_failed, .transport)
		deadline_ns = time.to_unix_nanoseconds(time.now()) + left_ms * i64(time.Millisecond)
	}
    candidate_index := 0
    if w := bridge_bot_current_worker; w != nil do candidate_index = w.candidate_index
    command_id := fmt.aprintf("botl_%s_%d", attempt_id, candidate_index)
    defer delete(command_id)
    command_json: string
    fetch_err: Bridge_Error
    fetched: bool
    if sync.atomic_load(&bridge_hub_start_begin_supported) {
        delete(command_id)
        command_json, command_id, fetch_err, fetched = bridge_wake_start_begin_proc(instance_id, fmt.tprintf("bot_%s", attempt_id), deadline_ns)
    } else {
        command_json, fetch_err, fetched = bridge_wake_manifest(instance_id, command_id, deadline_ns, bot_delivery = true)
    }
    defer delete(command_json)
    if !fetched && bridge_wake_is_live_row(fetch_err) {
        if snap, found := bridge_bot_snapshot_proc(instance_id); found && bridge_runtime_status_active(snap.runtime_status) && snap.runtime_status != "stopping" {
            return true, "", {}
        }
        if w := bridge_bot_current_worker; w != nil && w.live_row_retries < BRIDGE_LIVE_ROW_RETRIES {
            w.live_row_retries += 1
            w.live_row_retry_at_ms = bridge_bot_now_proc() + BRIDGE_LIVE_ROW_RETRY_MS
            return true, "", {}
        }
    }
    if !fetched do return false, "start-begin or legacy descriptor fetch refused", fetch_err
    return bridge_bot_runtime_launch_proc(command_id, command_json, deadline_ns)

}
// Preserve bot launch admission for the legacy launcher as well.
bridge_bot_runtime_launch_proc: proc(command_id, command_json: string, deadline_ns: i64) -> (bool, string, Bridge_Error) = bridge_bot_runtime_launch
bridge_bot_busy_inputs :: proc() -> (traffic_stopped, update_reserved, vault_unlocked: bool) {
	traffic_stopped = sync.atomic_load(&bridge_hub_traffic_stopped)
	entered := bridge_auto_update_launch_enter()
	if entered do bridge_auto_update_launch_leave()
	return traffic_stopped, !entered, bridge_vault_status() == .Unlocked
}
bridge_bot_busy_reason :: proc() -> (reason: string, busy: bool) {
	stopped, reserved, unlocked := bridge_bot_busy_inputs_proc()
	if stopped || reserved do return "draining", true
	if !unlocked do return "vault_locked", true
	return "", false
}

bridge_bot_handle_deliver :: proc(command_json: string) -> string {
	// Parse transiently first so malformed and duplicate commands leave no heap leaves.
	frame: contracts.Bot_Deliver_Wire
	parse_err := json.unmarshal_string(command_json, &frame, allocator = context.temp_allocator)
	if parse_err != nil || frame.attempt_id == "" || frame.agent_instance_id == "" || len(frame.candidates) == 0 {
		id := extract_json_string(command_json, "command_id", "", context.temp_allocator)
		return bridge_command_failed_json(id, bridge_cause_wire_error("validation_failed", "attempt_id, agent_instance_id and candidates are required"))
	}
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	if bridge_bot_workers == nil do bridge_bot_workers = make(map[string]^Bridge_Bot_Worker, runtime.heap_allocator())
	if _, exists := bridge_bot_workers[frame.attempt_id]; exists do return bridge_command_result_json(frame.command_id, "succeeded", "")
	for _, old in bridge_bot_workers {
		if old.frame.agent_instance_id == frame.agent_instance_id do sync.atomic_store(&old.cancel, true)
	}
	w := new(Bridge_Bot_Worker, runtime.heap_allocator())
	_ = json.unmarshal_string(command_json, &w.frame, allocator = runtime.heap_allocator())
	bridge_bot_workers[w.frame.attempt_id] = w
	bridge_bot_start_thread(w)
	return bridge_command_result_json(frame.command_id, "succeeded", "")
}
bridge_bot_handle_report_ack :: proc(command_json: string) {
	ack: contracts.Bot_Delivery_Report_Ack_Wire
	if json.unmarshal_string(command_json, &ack, allocator = context.temp_allocator) != nil do return
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	if w, found := bridge_bot_workers[ack.attempt_id]; found {
		w.acked_seq = max(w.acked_seq, ack.seq)
		if w.terminal_json != "" && ack.seq >= w.terminal_seq {
			delete(w.terminal_json, runtime.heap_allocator()); w.terminal_json = ""
			for pending in w.pending_reports do delete(pending, runtime.heap_allocator())
			clear(&w.pending_reports)
		}
	}
}
bridge_bot_start_thread :: proc(w: ^Bridge_Bot_Worker) {
	context.allocator = runtime.heap_allocator()
	w.worker_thread = thread.create_and_start_with_data(rawptr(w), bridge_bot_worker_thread)
}
bridge_bot_worker_thread :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	w := cast(^Bridge_Bot_Worker)data
	bridge_bot_run(w)
	sync.mutex_lock(&bridge_bot_workers_mutex)
	replacement := false
	for _, other in bridge_bot_workers {
		if other != w && other.frame.agent_instance_id == w.frame.agent_instance_id && !sync.atomic_load(&other.cancel) do replacement = true
	}
	if !replacement do bridge_bot_forget_activity(w.frame.agent_instance_id)
	w.ended_ms = bridge_bot_now_proc()
	sync.atomic_store(&w.finished, true)
	sync.mutex_unlock(&bridge_bot_workers_mutex)
	free_all(context.temp_allocator)
}
bridge_bot_phase_text :: proc(phase: Bridge_Bot_Phase) -> string {
	switch phase {
	case .Launching: return "launching"
	case .Waiting_Ready: return "waiting_ready"
	case .Notified: return "notified"
	case .Read: return "read"
	case .Replying: return "replying"
	case .Done: return "done"
	}
	return "done"
}
bridge_bot_report :: proc(w: ^Bridge_Bot_Worker, state: string, reason: string = "") {
	if sync.atomic_load(&w.cancel) do return
	w.seq += 1
	report := contracts.Bot_Delivery_Report_Wire{type = contracts.BOT_DELIVERY_REPORT_FRAME, protocol_version = 1, delivery_id = w.frame.delivery_id, attempt_id = w.frame.attempt_id, agent_instance_id = w.frame.agent_instance_id, seq = w.seq, state = state, phase = bridge_bot_phase_text(w.phase), candidate_index = w.candidate_index, outcomes = w.outcomes[:], reason = reason}
	bytes, err := json.marshal(report)
	if err != nil do return
	defer delete(bytes)
	if state != "working" {
		sync.mutex_lock(&bridge_bot_workers_mutex)
		delete(w.terminal_json, runtime.heap_allocator())
		w.terminal_json = strings.clone(string(bytes), runtime.heap_allocator())
		w.terminal_seq = w.seq
		w.last_sent_ms = bridge_bot_now_proc()
		sync.mutex_unlock(&bridge_bot_workers_mutex)
	}
	sent := bridge_bot_report_proc(string(bytes))
	if sent && state != "working" do fmt.printf("bots: terminal report %s\n", string(bytes))
	w.last_progress_ms = bridge_bot_now_proc()
}
bridge_bot_progress :: proc(w: ^Bridge_Bot_Worker) {
	if bridge_bot_now_proc() - w.last_progress_ms >= max(1, w.frame.timers.progress_interval_ms) do bridge_bot_report(w, "working")
}
bridge_bot_outcome :: proc(w: ^Bridge_Bot_Worker, c: contracts.Bot_Candidate_Wire, outcome, detail: string, err := Bridge_Error{}, has_err := false) {
	context.allocator = runtime.heap_allocator()
	append(&w.outcomes, contracts.Bot_Candidate_Outcome_Wire{strings.clone(c.provider), strings.clone(c.model), strings.clone(outcome), strings.clone(detail)})
	if outcome == "acted" do bridge_bot_candidate_clear(c)
	else do bridge_bot_candidate_record_failure(c, outcome, err, has_err, bridge_bot_now_proc())
}
bridge_bot_skip :: proc(w: ^Bridge_Bot_Worker, c: contracts.Bot_Candidate_Wire) -> (string, bool) {
	for s in w.frame.skip do if s.provider == c.provider && s.model == c.model do return s.reason, true
	return "", false
}
bridge_bot_run :: proc(w: ^Bridge_Bot_Worker) {
	context.allocator = runtime.heap_allocator()
	previous := bridge_bot_current_worker
	bridge_bot_current_worker = w
	defer bridge_bot_current_worker = previous
	if reason, busy := bridge_bot_busy_reason(); busy {
		w.phase = .Done; bridge_bot_report(w, "busy", reason); return
	}
	order := make([dynamic]int)
	defer delete(order)
	sticky := -1
	snap, found := bridge_bot_snapshot_proc(w.frame.agent_instance_id)
	if found && bridge_runtime_status_active(snap.runtime_status) {
		for c, i in w.frame.candidates {
			_, skipped := bridge_bot_skip(w, c)
			if c.provider == w.frame.current_provider && c.model == w.frame.current_model && !skipped && !bridge_bot_candidate_backoff_active(c, bridge_bot_now_proc()) { sticky = i; break }
		}
	}
	if sticky >= 0 do append(&order, sticky)
	for _, i in w.frame.candidates do if i != sticky do append(&order, i)
	w.phase = .Launching; bridge_bot_report(w, "working")
	tried := 0
	for i in order {
		free_all(context.temp_allocator)
		if sync.atomic_load(&w.cancel) do return
		c := w.frame.candidates[i]
		w.candidate_index = i
		if reason, skipped := bridge_bot_skip(w, c); skipped { bridge_bot_outcome(w, c, "skipped", reason); continue }
		if !bridge_bot_runnable_proc(c.provider, c.model) { bridge_bot_outcome(w, c, "not_runnable", ""); continue }
		if i != sticky && bridge_bot_candidate_backoff_active(c, bridge_bot_now_proc()) { bridge_bot_outcome(w, c, "backoff", ""); continue }
		if tried >= 3 do break
		tried += 1
		w.phase = .Launching; bridge_bot_report(w, "working")
		w.ready_deadline_ms = bridge_bot_now_proc() + w.frame.timers.launch_ready_ms
        w.live_row_retry_at_ms, w.live_row_retries = 0, 0
		pre_id := ""
		before, _ := bridge_bot_snapshot_proc(w.frame.agent_instance_id)
		pre_generation := before.startup.generation
		relaunched := false
		if i != sticky {
			pre, pre_found := bridge_bot_launch_record_proc(w.frame.agent_instance_id)
			if pre_found do pre_id = strings.clone(pre.command_id)
			status, relaunch, error_code := bridge_bot_switch_proc(w.frame.attempt_id, c)
			relaunched = relaunch
			if status != 200 {
				detail := error_code
				if status == 0 do detail = "transport"
				else if detail == "" do detail = fmt.tprintf("http_%d", status)
				bridge_bot_outcome(w, c, "switch_refused", detail)
				delete(pre_id); continue
			}
			if sync.atomic_load(&w.cancel) { delete(pre_id); return }
			if !relaunched {
				current, current_found := bridge_bot_snapshot_proc(w.frame.agent_instance_id)
				if !current_found || !bridge_runtime_status_active(current.runtime_status) {
					ok, _, launch_err := bridge_bot_launch_proc(w.frame.agent_instance_id, w.frame.attempt_id)
					if !ok {
						bridge_bot_outcome(w, c, "launch_failed", contracts.bridge_error_class_name(launch_err.class), launch_err, true)
						delete(pre_id); continue
					}
				}
			}
		}
		w.phase = .Waiting_Ready; bridge_bot_report(w, "working")
		outcome, detail, ready_err, has_err := bridge_bot_wait_ready(w, relaunched, pre_id, pre_generation)
		delete(pre_id)
		if sync.atomic_load(&w.cancel) do return
		if outcome != "" { bridge_bot_outcome(w, c, outcome, detail, ready_err, has_err); continue }
		// Reset observation before typing: an immediate read/reply must not be lost.
		sync.atomic_store(&w.read_seen_ms, 0); sync.atomic_store(&w.reply_seen_ms, 0)
		sync.atomic_store(&w.dispatched_ms, 0)
		w.notice_waits_for_dispatch = false
		if !bridge_bot_notice_proc(w.frame.agent_instance_id) {
			if sync.atomic_load(&w.cancel) do return
			if bridge_bot_now_proc() >= w.ready_deadline_ms do bridge_bot_outcome(w, c, "launch_timeout", "")
			else do bridge_bot_outcome(w, c, "crashed", "")
			continue
		}
		w.phase = .Notified
		w.notified_ms = bridge_bot_now_proc()
		if !w.notice_waits_for_dispatch do sync.atomic_store(&w.dispatched_ms, w.notified_ms)
		w.read_extends, w.idle_since_ms = 0, 0
		bridge_bot_report(w, "working")
		for !sync.atomic_load(&w.cancel) {
			free_all(context.temp_allocator)
			current, _ := bridge_bot_snapshot_proc(w.frame.agent_instance_id)
			old_phase := w.phase
			act := bridge_bot_activity_proc(w.frame.agent_instance_id)
			result, done := bridge_bot_watch_step(w, act, current.runtime_status, bridge_bot_now_proc())
			if done {
				detail := ""
				if result == "idle_no_reply" && act == "waiting_user" do detail = "waiting_user"
				bridge_bot_outcome(w, c, result, detail)
				if result == "acted" { w.phase = .Done; bridge_bot_report(w, "acted"); return }
				if result == "not_dispatched" { w.phase = .Done; bridge_bot_report(w, "exhausted", result); return }
				break
			}
			if w.phase != old_phase do bridge_bot_report(w, "working")
			bridge_bot_progress(w)
			bridge_bot_sleep_proc(1000)
		}
	}
	w.phase = .Done; bridge_bot_report(w, "exhausted", "all_candidates_failed")
}
// READY and rollover consume the same candidate launch budget.
bridge_bot_wait_ready :: proc(w: ^Bridge_Bot_Worker, relaunched: bool, pre_id: string, pre_generation: u64 = 0) -> (outcome, detail: string, err: Bridge_Error, has_err: bool) {
    defer { w.live_row_retry_at_ms, w.live_row_retries = 0, 0 }
	observed_record, observed_alive := false, false
	for !sync.atomic_load(&w.cancel) {
		free_all(context.temp_allocator)
		if bridge_bot_now_proc() >= w.ready_deadline_ms do return "launch_timeout", "", {}, false
        snap, found := bridge_bot_snapshot_proc(w.frame.agent_instance_id)
        if w.live_row_retry_at_ms != 0 {
            if found && bridge_runtime_status_active(snap.runtime_status) && snap.runtime_status != "stopping" {
                w.live_row_retry_at_ms = 0
            } else if bridge_bot_now_proc() >= w.live_row_retry_at_ms {
                w.live_row_retry_at_ms = 0
                ok, _, launch_err := bridge_bot_launch_proc(w.frame.agent_instance_id, w.frame.attempt_id)
                if !ok do return "launch_failed", contracts.bridge_error_class_name(launch_err.class), launch_err, true
            }
        }
		launch, has_launch := bridge_bot_launch_record_proc(w.frame.agent_instance_id)
		launch_changed := !relaunched || (has_launch && launch.command_id != pre_id)
		if launch_changed && has_launch do observed_record = true
		if launch_changed && found && snap.pty_process_alive do observed_alive = true
		if found && snap.runtime_status == "failed" {
			launch_err := snap.last_error if snap.has_last_error else Bridge_Error{class = .retriable}
			return "launch_failed", contracts.bridge_error_class_name(launch_err.class), launch_err, true
		}
		if launch_changed && found {
			if snap.runtime_status == "blocked" {
				detail := "prompt"
				if snap.has_last_error && snap.last_error.reason == .login_required do detail = "login"
				return "startup_blocked", detail, {}, false
			}
			if !bridge_bot_rollover_proc(w.frame.agent_instance_id) && bridge_bot_ready(snap) do return "", "", {}, false
		}
		// ChildExited removes the launch record and clears liveness. A queued
		// activity signal can leave status "starting", so status alone is insufficient.
		// Unknown liveness during an existing startup is not an exit. Attribute
		// it to a newer spawned generation, observed liveness, or a launch record
		// that disappeared. During relaunch, observations of the old child do not count.
		new_startup := found && snap.startup.generation != 0 &&
			snap.startup.generation != pre_generation && snap.startup.pty_pid > 0
		exit_observed := new_startup || observed_alive || (observed_record && !has_launch)
		if found && !snap.pty_process_alive && exit_observed && !bridge_bot_rollover_proc(w.frame.agent_instance_id) {
			launch_err := Bridge_Error{class = .retriable}
			return "launch_failed", contracts.bridge_error_class_name(launch_err.class), launch_err, true
		}
		if bridge_bot_now_proc() >= w.ready_deadline_ms do return "launch_timeout", "", {}, false
		bridge_bot_progress(w)
		bridge_bot_sleep_proc(250)
	}
	return "", "", {}, false
}
bridge_bot_ready :: proc(snap: Bridge_Runtime_Instance) -> bool {
	return (snap.runtime_status == "running" || snap.runtime_status == "idle") && snap.start_success_seen
}
bridge_bot_deliver_notice :: proc(instance_id: string) -> bool {
	// Bind to the calling worker, not the newest worker for the instance: a
	// superseded thread must never type a notice on behalf of its replacement.
	w := bridge_bot_current_worker
	if w == nil || w.frame.agent_instance_id != instance_id do return false
	outcome, _, _, _ := bridge_bot_wait_ready(w, false, "")
	if outcome != "" || sync.atomic_load(&w.cancel) do return false
	if bridge_runtime_is_acp(instance_id) {
		w.notice_waits_for_dispatch = true
		return acp_runtime_deliver(instance_id, BOT_NOTICE, fmt.tprintf("%s%s", ACP_BOT_INPUT_PREFIX, w.frame.attempt_id), ACP_Input_Lane.Steer, ACP_BOT_KIND, ACP_BOT_KIND)
	}
	return bridge_pty_host_deliver_to_agent(instance_id, "task_nudge", "bot", "", "", human_message = BOT_NOTICE)
}
// Queue writes for the WS owner. Never retain a connection pointer in a worker.
bridge_bot_send_report :: proc(report_json: string) -> bool {
	id := extract_json_string(report_json, "attempt_id", "", context.temp_allocator)
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	if w, found := bridge_bot_workers[id]; found {
		// Working reports are best effort. Bound disconnected buffering; held
		// terminal reports have an independent retry path.
		if len(w.pending_reports) >= 128 {
			delete(w.pending_reports[0], runtime.heap_allocator())
			ordered_remove(&w.pending_reports, 0)
		}
		if w.pending_reports.allocator.procedure == nil do w.pending_reports = make([dynamic]string, runtime.heap_allocator())
		append(&w.pending_reports, strings.clone(report_json, runtime.heap_allocator()))
	}
	return sync.atomic_load(&bridge_hub_runtime_up)
}
bridge_bot_drain :: proc(conn: ^ws.Connection, generation: i64) {
	bridge_bot_collect()
	retry := make([dynamic]string)
	defer { for item in retry do delete(item); delete(retry) }
	now := bridge_bot_now_proc()
	sync.mutex_lock(&bridge_bot_workers_mutex)
	for _, w in bridge_bot_workers {
		if !sync.atomic_load(&w.cancel) && w.terminal_json != "" && (w.last_generation != generation || now - w.last_sent_ms >= 5000) {
			append(&retry, strings.clone(w.terminal_json))
			w.last_sent_ms, w.last_generation = now, generation
		}
	}
	sync.mutex_unlock(&bridge_bot_workers_mutex)
	for item in retry do _ = bridge_bot_report_proc(item)
	outgoing := make([dynamic]string)
	defer { for item in outgoing do delete(item, runtime.heap_allocator()); delete(outgoing) }
	sync.mutex_lock(&bridge_bot_workers_mutex)
	for _, w in bridge_bot_workers {
		for pending in w.pending_reports {
			if !sync.atomic_load(&w.cancel) do append(&outgoing, pending)
			else do delete(pending, runtime.heap_allocator())
		}
		clear(&w.pending_reports)
	}
	sync.mutex_unlock(&bridge_bot_workers_mutex)
	if conn != nil do for item in outgoing do _ = bridge_hub_send(conn, item)
}
bridge_bot_worker_destroy :: proc(w: ^Bridge_Bot_Worker) {
	context.allocator = runtime.heap_allocator()
	if w.worker_thread != nil { thread.join(w.worker_thread); thread.destroy(w.worker_thread) }
	for o in w.outcomes { delete(o.provider); delete(o.model); delete(o.outcome); delete(o.detail) }
	delete(w.outcomes)
	delete(w.frame.type); delete(w.frame.command_id); delete(w.frame.bridge_id)
	delete(w.frame.agent_instance_id); delete(w.frame.bot_id); delete(w.frame.delivery_id)
	delete(w.frame.attempt_id); delete(w.frame.through_message_id)
	delete(w.frame.current_provider); delete(w.frame.current_model)
	for c in w.frame.candidates { delete(c.provider); delete(c.provider_profile); delete(c.model); delete(c.tier) }
	delete(w.frame.candidates)
	for s in w.frame.skip { delete(s.provider); delete(s.model); delete(s.reason) }
	delete(w.frame.skip)
	delete(w.terminal_json, runtime.heap_allocator())
	for pending in w.pending_reports do delete(pending, runtime.heap_allocator())
	delete(w.pending_reports)
	free(w)
}
bridge_bot_collect :: proc() {
	retired := make([dynamic]^Bridge_Bot_Worker)
	defer delete(retired)
	now := bridge_bot_now_proc()
	sync.mutex_lock(&bridge_bot_workers_mutex)
	for id, w in bridge_bot_workers {
		if sync.atomic_load(&w.finished) && (sync.atomic_load(&w.cancel) || w.terminal_json == "" || now - w.ended_ms >= 600_000) {
			delete_key(&bridge_bot_workers, id)
			append(&retired, w)
		}
	}
	sync.mutex_unlock(&bridge_bot_workers_mutex)
	for w in retired do bridge_bot_worker_destroy(w)
}
bridge_bot_shutdown :: proc() {
	retired := make([dynamic]^Bridge_Bot_Worker)
	defer delete(retired)
	sync.mutex_lock(&bridge_bot_workers_mutex)
	for _, w in bridge_bot_workers { sync.atomic_store(&w.cancel, true); append(&retired, w) }
	clear(&bridge_bot_workers)
	sync.mutex_unlock(&bridge_bot_workers_mutex)
	for w in retired do bridge_bot_worker_destroy(w)
}

bridge_bot_notice_superseded :: proc(instance_id, input_id: string) -> bool {
	if !strings.has_prefix(input_id, ACP_BOT_INPUT_PREFIX) do return false
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	w := bridge_bot_workers[input_id[len(ACP_BOT_INPUT_PREFIX):]]
	return w != nil && w.frame.agent_instance_id == instance_id && sync.atomic_load(&w.cancel)
}

// Observe prompt dispatch once, even if the admission receipt is replayed.
bridge_bot_note_dispatch :: proc(instance_id, input_id: string, now_ms: i64) {
	if !strings.has_prefix(input_id, ACP_BOT_INPUT_PREFIX) do return
	attempt_id := input_id[len(ACP_BOT_INPUT_PREFIX):]
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	w := bridge_bot_workers[attempt_id]
	if w == nil || w.frame.agent_instance_id != instance_id || sync.atomic_load(&w.cancel) || sync.atomic_load(&w.finished) do return
	if sync.atomic_load(&w.dispatched_ms) == 0 do sync.atomic_store(&w.dispatched_ms, now_ms)
}

// Relay observations are accepted only for live delivery workers.
bridge_bot_note_read :: proc(instance_id, relay_body: string, now_ms: i64) {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	root, err := json.parse(relay_body, allocator = context.temp_allocator)
	if err != nil do return
	obj, object_ok := root.(json.Object)
	if !object_ok do return
	data, data_ok := obj["data"].(json.Object)
	if !data_ok do return
	messages, messages_ok := data["messages"].(json.Array)
	if !messages_ok || len(messages) == 0 do return
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	for _, w in bridge_bot_workers do if w.frame.agent_instance_id == instance_id && !sync.atomic_load(&w.cancel) && !sync.atomic_load(&w.finished) do sync.atomic_store(&w.read_seen_ms, now_ms)
}
bridge_bot_note_reply :: proc(instance_id: string, now_ms: i64) {
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	for _, w in bridge_bot_workers do if w.frame.agent_instance_id == instance_id && !sync.atomic_load(&w.cancel) && !sync.atomic_load(&w.finished) do sync.atomic_store(&w.reply_seen_ms, now_ms)
}
bridge_bot_watch_step :: proc(w: ^Bridge_Bot_Worker, act, status: string, now_ms: i64) -> (result: string, done: bool) {
	read := sync.atomic_load(&w.read_seen_ms)
	reply := sync.atomic_load(&w.reply_seen_ms)
	if read > 0 && reply > 0 && reply >= read do return "acted", true
	if status == "failed" || status == "stopped" || status == "unreachable" do return "crashed", true
	timers := w.frame.timers
	if w.phase == .Notified {
		dispatched := sync.atomic_load(&w.dispatched_ms)
		if read > 0 {
			w.phase = .Read
			w.idle_since_ms = 0
		} else if dispatched == 0 {
			if now_ms - w.notified_ms >= timers.reply_cap_ms do return "not_dispatched", true
		} else if now_ms - dispatched >= timers.read_ms + i64(w.read_extends) * timers.read_extend_ms {
			if act == "active" && w.read_extends < timers.read_max_extends do w.read_extends += 1
			else do return "not_read", true
		}
	}
	if w.phase == .Read || w.phase == .Replying {
		if act == "active" {
			w.idle_since_ms = 0
			w.phase = .Replying
		} else if w.idle_since_ms == 0 {
			w.idle_since_ms = now_ms
		}
		if w.idle_since_ms > 0 && now_ms - w.idle_since_ms >= timers.idle_no_reply_ms do return "idle_no_reply", true
		if now_ms - read >= timers.reply_cap_ms do return "reply_timeout", true
	}
	return "", false
}

bridge_bot_candidate_backoff_active :: proc(cand: contracts.Bot_Candidate_Wire, now_ms: i64) -> bool {
	key := fmt.tprintf("%s/%s", cand.provider, cand.model)
	sync.mutex_lock(&bridge_bot_backoff_mutex)
	defer sync.mutex_unlock(&bridge_bot_backoff_mutex)
	entry, found := bridge_bot_backoff[key]
	return found && entry.next_at_ms > now_ms
}
bridge_bot_candidate_record_failure :: proc(cand: contracts.Bot_Candidate_Wire, outcome: string, err: Bridge_Error, has_err: bool, now_ms: i64) {
	delay: i64
	switch outcome {
	case "launch_failed":
		if has_err && err.class != .retriable do delay = 1_800_000
	case "startup_blocked": delay = 1_800_000
	case "launch_timeout", "not_read", "idle_no_reply", "crashed": delay = 300_000
	case: return
	}
	key := fmt.tprintf("%s/%s", cand.provider, cand.model)
	sync.mutex_lock(&bridge_bot_backoff_mutex)
	defer sync.mutex_unlock(&bridge_bot_backoff_mutex)
	if bridge_bot_backoff == nil do bridge_bot_backoff = make(map[string]Bridge_Bot_Backoff, runtime.heap_allocator())
	entry, found := bridge_bot_backoff[key]
	entry.failures += 1
	if delay == 0 do delay = max(bridge_backoff_delay_ms({base_ms = 60_000, max_ms = 1_800_000}, entry.failures), err.retry_after_ms)
	entry.next_at_ms = now_ms + delay
	if !found do key = strings.clone(key, runtime.heap_allocator())
	bridge_bot_backoff[key] = entry
}
bridge_bot_candidate_clear :: proc(cand: contracts.Bot_Candidate_Wire) {
	key := fmt.tprintf("%s/%s", cand.provider, cand.model)
	sync.mutex_lock(&bridge_bot_backoff_mutex)
	defer sync.mutex_unlock(&bridge_bot_backoff_mutex)
	for owned in bridge_bot_backoff do if owned == key { delete_key(&bridge_bot_backoff, owned); delete(owned, runtime.heap_allocator()); break }
}
bridge_bot_note_raw_activity :: proc(instance_id, activity_status: string) {
	if instance_id == "" do return
	value := "unknown"
	normalized := strings.to_lower(strings.trim_space(activity_status), runtime.heap_allocator())
	defer delete(normalized, runtime.heap_allocator())
	switch normalized {
	case "active", "working", "busy": value = "active"
	case "waiting_user", "waiting", "waiting_approval": value = "waiting_user"
	case "idle", "inactive": value = "idle"
	}
	// Preserve pre-delivery activity for a sticky runtime too. Historical entries
	// are bounded; live workers are pinned and remove their entry when they end.
	sync.mutex_lock(&bridge_bot_workers_mutex)
	defer sync.mutex_unlock(&bridge_bot_workers_mutex)
	sync.mutex_lock(&bridge_bot_raw_activity_mutex)
	defer sync.mutex_unlock(&bridge_bot_raw_activity_mutex)
	if bridge_bot_raw_activity == nil do bridge_bot_raw_activity = make(map[string]string, runtime.heap_allocator())
	key := instance_id
	if _, found := bridge_bot_raw_activity[key]; !found {
		if len(bridge_bot_raw_activity) >= 1024 {
			for victim in bridge_bot_raw_activity {
				live := false
				for _, w in bridge_bot_workers {
					if w.frame.agent_instance_id == victim && !sync.atomic_load(&w.cancel) && !sync.atomic_load(&w.finished) { live = true; break }
				}
				if !live { delete_key(&bridge_bot_raw_activity, victim); delete(victim, runtime.heap_allocator()); break }
			}
		}
		key = strings.clone(instance_id, runtime.heap_allocator())
	}
	bridge_bot_raw_activity[key] = value
}
bridge_bot_local_activity :: proc(instance_id: string) -> string {
	sync.mutex_lock(&bridge_bot_raw_activity_mutex)
	defer sync.mutex_unlock(&bridge_bot_raw_activity_mutex)
	if act, found := bridge_bot_raw_activity[instance_id]; found do return act
	return "unknown"
}
bridge_bot_forget_activity :: proc(instance_id: string) {
	sync.mutex_lock(&bridge_bot_raw_activity_mutex)
	defer sync.mutex_unlock(&bridge_bot_raw_activity_mutex)
	for key in bridge_bot_raw_activity do if key == instance_id { delete_key(&bridge_bot_raw_activity, key); delete(key, runtime.heap_allocator()); break }
}
