package taskv2

// SCHED-1a: event-driven stops and the reviewer grace window (spec SCHED
// section 8, REQ-SCHED-19..29). One test per row of transition table 8.1,
// named test_sched1a_row<NN>_…, plus the REQ-SCHED-27 invariant and the
// stop-path read-count test (14.5).

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

@(private = "file")
BRIEF_NO_REVIEW :: `{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`
@(private = "file")
BRIEF_ONE_REVIEWER :: `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r"]}`
@(private = "file")
BRIEF_TWO_REVIEWERS :: `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r","agt_r2"]}`
@(private = "file")
BRIEF_USER_REVIEW :: `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["user"]}`
@(private = "file")
CHANGES_FINDINGS :: `[{"path":"a.odin","line":1,"severity":"major","text":"fix"}]`

// s1a_setup: worker inst_w1 (agt_w), reviewers inst_r1 (agt_r) and inst_r2
// (agt_r2), coordinator inst_coord (agt_c, no fleet row), all on br_1.
@(private = "file")
s1a_setup :: proc(t: ^testing.T, fx: ^Fixture, tag: string, idle_ttl := 0, worker_status := "idle", reviewer_status := "idle") -> domain.Task_Chain {
	chain := seed_live_chain(t, fx, fmt.tprintf("chain_%s", tag))
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w", idle_ttl = idle_ttl)
	seed_fleet(fx, chain, "agt_r", idle_ttl = idle_ttl)
	seed_fleet(fx, chain, "agt_r2", idle_ttl = idle_ttl)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", worker_status)
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", reviewer_status)
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", reviewer_status)
	return chain
}

@(private = "file")
s1a_gen :: proc(fx: ^Fixture, inst: string) -> int {
	cur, _, _ := iface.agent_get_instance(&fx.agents, inst)
	return cur.run_count
}

@(private = "file")
s1a_inst :: proc(fx: ^Fixture, inst: string) -> domain.Agent_Instance {
	cur, _, _ := iface.agent_get_instance(&fx.agents, inst)
	return cur
}

@(private = "file")
s1a_submit :: proc(t: ^testing.T, fx: ^Fixture, inst, summary: string) -> bool {
	confirm_holder(fx, inst)
	_, ok, err := lease_submit(&fx.svc, inst_auth(inst), Submit_Input{summary = summary, vcs_json = `{"head":"h","dirty":false}`})
	return testing.expectf(t, ok, "submit by %s: %s", inst, err.message)
}

@(private = "file")
s1a_review :: proc(t: ^testing.T, fx: ^Fixture, inst, verdict: string) -> (Review_Result, bool) {
	confirm_holder(fx, inst)
	findings := CHANGES_FINDINGS if verdict == "request_changes" else "[]"
	res, ok, err := review_post(&fx.svc, inst_auth(inst), Review_Input{verdict = verdict, findings_json = findings})
	return res, testing.expectf(t, ok, "%s by %s: %s", verdict, inst, err.message)
}

// s1a_run_entry: the last wake run[] object naming `inst` ("" when none).
@(private = "file")
s1a_run_entry :: proc(log: ^Wake_Log, inst: string) -> string {
	id_field := fmt.tprintf(`"agent_instance_id":"%s"`, inst)
	found := ""
	for c in log.cmds {
		run, ok := jsonx.extract_raw_array(c.body_json, "run", false, context.temp_allocator)
		if !ok do continue
		depth, start, in_str, esc := 0, -1, false, false
		for i in 0 ..< len(run) {
			ch := run[i]
			if in_str {
				if esc do esc = false
				else if ch == '\\' do esc = true
				else if ch == '"' do in_str = false
				continue
			}
			switch ch {
			case '"': in_str = true
			case '{':
				if depth == 1 do start = i
				depth += 1
			case '[':
				depth += 1
			case '}', ']':
				depth -= 1
				if depth == 1 && ch == '}' && start >= 0 {
					obj := run[start:i + 1]
					if strings.contains(obj, id_field) do found = obj
					start = -1
				}
			}
		}
	}
	return found
}

// The grant kept the live process: a nudge to the same generation.
@(private = "file")
s1a_expect_kept :: proc(t: ^testing.T, fx: ^Fixture, log: ^Wake_Log, inst: string, gen: int, what: string) {
	entry := s1a_run_entry(log, inst)
	testing.expectf(t, strings.contains(entry, `"deliver":"nudge"`), "%s: %s nudged (%s)", what, inst, entry)
	testing.expectf(t, s1a_gen(fx, inst) == gen, "%s: %s keeps generation %d (now %d)", what, inst, gen, s1a_gen(fx, inst))
	testing.expectf(t, !wake_log_has_stop(log, inst), "%s: %s is not stopped", what, inst)
}

// The grant started a fresh process on the same instance id.
@(private = "file")
s1a_expect_fresh :: proc(t: ^testing.T, fx: ^Fixture, log: ^Wake_Log, inst: string, gen: int, what: string) {
	entry := s1a_run_entry(log, inst)
	testing.expectf(t, entry != "" && !strings.contains(entry, `"deliver"`), "%s: %s relaunched (%s)", what, inst, entry)
	testing.expectf(t, s1a_gen(fx, inst) == gen + 1, "%s: %s generation %d -> %d (now %d)", what, inst, gen, gen + 1, s1a_gen(fx, inst))
}

@(private = "file")
s1a_expect_stopped :: proc(t: ^testing.T, fx: ^Fixture, log: ^Wake_Log, inst, reason, what: string) {
	testing.expectf(t, wake_log_has_stop(log, inst), "%s: %s is stopped", what, inst)
	testing.expectf(t, s1a_inst(fx, inst).stop_reason == reason, "%s: %s stop intent %q (got %q)", what, inst, reason, s1a_inst(fx, inst).stop_reason)
	_, held := lease_of(fx, inst)
	testing.expectf(t, !held, "%s: %s holds no lease", what, inst)
}

// s1a_idle_timer: the armed Idle_TTL timer for `inst`, if any.
@(private = "file")
s1a_idle_timer :: proc(svc: ^Service, inst: string) -> (Timer, bool) {
	for timer in svc.timers.heap do if timer.kind == .Idle_TTL && timer.key == inst do return timer, true
	return {}, false
}

// In its grace window: no lease, not stopped, idle_since = `since`, timer armed.
@(private = "file")
s1a_expect_grace :: proc(t: ^testing.T, fx: ^Fixture, log: ^Wake_Log, inst, since, what: string) {
	_, held := lease_of(fx, inst)
	testing.expectf(t, !held, "%s: %s holds no lease", what, inst)
	testing.expectf(t, !wake_log_has_stop(log, inst), "%s: %s is not stopped", what, inst)
	cur := s1a_inst(fx, inst)
	testing.expectf(t, cur.idle_since == since, "%s: %s idle_since %q (got %q)", what, inst, since, cur.idle_since)
	testing.expectf(t, cur.stop_reason == "", "%s: %s has no stop intent (got %q)", what, inst, cur.stop_reason)
	timer, armed := s1a_idle_timer(&fx.svc, inst)
	testing.expectf(t, armed && timer.armed == since, "%s: %s Idle_TTL armed from its idle_since", what, inst)
}

@(private = "file")
s1a_expect_coordinator_untouched :: proc(t: ^testing.T, fx: ^Fixture, log: ^Wake_Log, what: string) {
	testing.expectf(t, !wake_log_has_stop(log, "inst_coord"), "%s: the coordinator is never stopped", what)
	testing.expectf(t, s1a_run_entry(log, "inst_coord") == "", "%s: the coordinator is never woken", what)
}

// Row 1: work granted → the worker is started fresh (a reused instance).
@(test)
test_sched1a_row01_work_granted_starts_fresh :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r01")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r01", worker_status = "stopped")
	gen := s1a_gen(fx, "inst_w1")
	wake_log_reset(log)
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_NO_REVIEW)
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && lease.kind == domain.LEASE_KIND_WORK, "the stopped worker instance is reused")
	s1a_expect_fresh(t, fx, log, "inst_w1", gen, "work grant")
	s1a_expect_coordinator_untouched(t, fx, log, "work grant")
}

// Row 2: submit → in review. The worker keeps its process and a waiting claim;
// the listed reviewer gets a review lease and is started fresh.
@(test)
test_sched1a_row02_submit_keeps_worker_and_starts_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r02")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r02", reviewer_status = "stopped")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	r_gen := s1a_gen(fx, "inst_r1")
	wake_log_reset(log)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	claim, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && claim.phase == domain.LEASE_PHASE_WAITING, "worker keeps a waiting claim (REQ-SCHED-19)")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "submit does not stop the worker")
	review, rheld := lease_of(fx, "inst_r1")
	testing.expect(t, rheld && review.kind == domain.LEASE_KIND_REVIEW, "reviewer granted a review lease")
	s1a_expect_fresh(t, fx, log, "inst_r1", r_gen, "review grant")
}

// Row 3: submit with no reviewers → done; the worker is stopped.
@(test)
test_sched1a_row03_submit_without_reviewers_stops_worker :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r03")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r03")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_NO_REVIEW)
	wake_log_reset(log)
	if !s1a_submit(t, fx, "inst_w1", "done") do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	s1a_expect_stopped(t, fx, log, "inst_w1", STOP_REASON_TASK_COMPLETED, "done without review")
	s1a_expect_coordinator_untouched(t, fx, log, "done without review")
}

// Row 4: approve while the gate still waits for another reviewer: that
// reviewer's lease is deleted and it is stopped; the worker and the other
// reviewer are untouched.
@(test)
test_sched1a_row04_approve_with_gate_waiting_stops_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r04")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r04")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_TWO_REVIEWERS)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	confirm_holder(fx, "inst_r2")
	wake_log_reset(log)
	res, rok := s1a_review(t, fx, "inst_r1", "approve")
	if !rok do return
	testing.expect_value(t, res.gate, Gate_Result.Waiting)
	s1a_expect_stopped(t, fx, log, "inst_r1", STOP_REASON_REVIEW_POSTED, "approve, gate waiting")
	claim, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && claim.phase == domain.LEASE_PHASE_WAITING && !wake_log_has_stop(log, "inst_w1"), "worker kept with its waiting claim")
	other, oheld := lease_of(fx, "inst_r2")
	testing.expect(t, oheld && other.kind == domain.LEASE_KIND_REVIEW && other.phase == domain.LEASE_PHASE_ACTIVE, "the other reviewer keeps its review lease")
	testing.expect(t, !wake_log_has_stop(log, "inst_r2"), "the other reviewer is not stopped")
}

// Row 5: approve and the gate passes → done; worker and reviewer stopped.
@(test)
test_sched1a_row05_approve_gate_passes_stops_worker_and_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r05")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r05")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	wake_log_reset(log)
	res, rok := s1a_review(t, fx, "inst_r1", "approve")
	if !rok do return
	testing.expect_value(t, res.gate, Gate_Result.Approved)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	s1a_expect_stopped(t, fx, log, "inst_w1", STOP_REASON_TASK_COMPLETED, "task done")
	s1a_expect_stopped(t, fx, log, "inst_r1", STOP_REASON_REVIEW_POSTED, "task done")
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, "task_1")
	testing.expect_value(t, len(leases), 0)
	s1a_expect_coordinator_untouched(t, fx, log, "task done")
}

// Row 6: request-changes → ready. Every reviewer of the task loses its lease
// (none is parked) and is kept for the grace window; the worker keeps its
// claim for the rework.
@(test)
test_sched1a_row06_request_changes_starts_grace_for_all_reviewers :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r06")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r06", idle_ttl = 120)
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_TWO_REVIEWERS)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	confirm_holder(fx, "inst_r2")
	wake_log_reset(log)
	now := platform.clock_now(&fx.clock)
	_, rok := s1a_review(t, fx, "inst_r1", "request_changes")
	if !rok do return
	s1a_expect_grace(t, fx, log, "inst_r1", now, "request-changes poster")
	s1a_expect_grace(t, fx, log, "inst_r2", now, "other reviewer")
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, "task_1")
	for l in leases do testing.expectf(t, l.kind != domain.LEASE_KIND_REVIEW, "no review lease remains (found %s, phase %s)", l.lease_id, l.phase)
	timer, _ := s1a_idle_timer(&fx.svc, "inst_r1")
	testing.expect_value(t, timer.due_ms, to_ms(now) + 120 * 1000)
	claim, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && claim.kind == domain.LEASE_KIND_WORK, "the worker keeps its claim for rework (REQ-SCHED-19)")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "the worker is not stopped")
}

// Row 7: rework is granted to the same instance and the same process.
@(test)
test_sched1a_row07_rework_keeps_worker_process :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r07")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r07")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	w_gen := s1a_gen(fx, "inst_w1")
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	wake_log_reset(log)
	if _, rok := s1a_review(t, fx, "inst_r1", "request_changes"); !rok do return
	claim, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && claim.phase == domain.LEASE_PHASE_ACTIVE && claim.attempt_no == 2, "rework granted to the waiting holder")
	s1a_expect_kept(t, fx, log, "inst_w1", w_gen, "rework")
}

// Row 8: resubmit inside the grace window → the reviewer's live process is
// reused (same generation, no stop); its stale timer is then a no-op.
@(test)
test_sched1a_row08_resubmit_in_window_reuses_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r08")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r08", idle_ttl = 120)
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	r_gen := s1a_gen(fx, "inst_r1")
	if _, rok := s1a_review(t, fx, "inst_r1", "request_changes"); !rok do return
	fixture_advance(fx, 60)
	wake_log_reset(log)
	if !s1a_submit(t, fx, "inst_w1", "v2") do return
	review, held := lease_of(fx, "inst_r1")
	testing.expect(t, held && review.kind == domain.LEASE_KIND_REVIEW, "re-review granted to the grace instance")
	s1a_expect_kept(t, fx, log, "inst_r1", r_gen, "re-review inside the window")
	testing.expect_value(t, s1a_inst(fx, "inst_r1").idle_since, "")
	fixture_advance(fx, 61)
	wake_log_reset(log)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, !wake_log_has_stop(log, "inst_r1"), "the old window's timer does not stop a reviewer holding a lease")
}

// Row 9: the grace window ends with no lease → the reviewer is stopped; a
// later re-review starts a fresh process on the same instance id.
@(test)
test_sched1a_row09_grace_window_end_stops_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r09")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r09", idle_ttl = 120)
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	r_gen := s1a_gen(fx, "inst_r1")
	if _, rok := s1a_review(t, fx, "inst_r1", "request_changes"); !rok do return
	fixture_advance(fx, 119)
	wake_log_reset(log)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, !wake_log_has_stop(log, "inst_r1"), "kept inside the window")
	fixture_advance(fx, 2)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	s1a_expect_stopped(t, fx, log, "inst_r1", STOP_REASON_IDLE_TTL, "window ended")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "the reworking worker is not stopped")
	wake_log_reset(log)
	if !s1a_submit(t, fx, "inst_w1", "v2") do return
	review, held := lease_of(fx, "inst_r1")
	testing.expect(t, held && review.kind == domain.LEASE_KIND_REVIEW, "re-review granted to the same instance id")
	s1a_expect_fresh(t, fx, log, "inst_r1", r_gen, "re-review after the window")
	testing.expect_value(t, s1a_inst(fx, "inst_r1").stop_reason, "")
}

// Row 10: the user (a listed reviewer) approves → done; the worker is stopped,
// the coordinator is not.
@(test)
test_sched1a_row10_user_approval_stops_worker :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r10")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r10")
	task := publish_task(t, fx, chain, "task_1", brief = BRIEF_USER_REVIEW)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	wake_log_reset(log)
	_, uok, uerr := user_review(&fx.svc, user_auth(), task.task_id, Review_Input{verdict = "approve"})
	if !testing.expectf(t, uok, "user approve: %s", uerr.message) do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	s1a_expect_stopped(t, fx, log, "inst_w1", STOP_REASON_TASK_COMPLETED, "user approved")
	s1a_expect_coordinator_untouched(t, fx, log, "user approved")
}

// Row 11: the task is cancelled → worker and reviewer leases deleted, both
// stopped; the coordinator is not.
@(test)
test_sched1a_row11_cancel_stops_worker_and_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r11")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r11")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	confirm_holder(fx, "inst_r1")
	wake_log_reset(log)
	_, cancelled, cerr := task_cancel(&fx.svc, get_task(fx, "task_1"), actor_from_auth(inst_auth("inst_coord")), Task_Cancel_Input{reason = "obsolete", request_id = "req_s1a_r11"})
	if !testing.expectf(t, cancelled, "cancel: %s", cerr.message) do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Cancelled)
	stops := ownership_pending_stops(&fx.svc, get_task(fx, "task_1"))
	for inst in ([]string{"inst_w1", "inst_r1"}) {
		_, held := lease_of(fx, inst)
		testing.expectf(t, !held, "%s holds no lease after cancel", inst)
		stopped := wake_log_has_stop(log, inst)
		for s in stops do if s.instance_id == inst do stopped = true
		testing.expectf(t, stopped, "%s is stopped on cancel", inst)
	}
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "the coordinator is not stopped")
}

// Row 12: `lease block` keeps the worker and its claim (waiting); the idle
// timer never stops a claim holder.
@(test)
test_sched1a_row12_block_keeps_worker :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r12")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r12")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_NO_REVIEW)
	confirm_holder(fx, "inst_w1")
	wake_log_reset(log)
	_, bok, berr := lease_block(&fx.svc, inst_auth("inst_w1"), Block_Input{waiting_on_json = `{"kind":"human","reason":"which option?"}`})
	if !testing.expectf(t, bok, "block: %s", berr.message) do return
	claim, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && claim.phase == domain.LEASE_PHASE_WAITING, "blocked worker keeps a waiting claim")
	fixture_advance(fx, IDLE_TTL_DEFAULT_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "blocked worker is never stopped by a timer")
}

// Row 13: `lease handoff` deletes the lease and stops the worker; the next
// holder (here the same instance, re-granted at once) starts fresh.
@(test)
test_sched1a_row13_handoff_stops_worker_next_holder_fresh :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r13")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r13")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_NO_REVIEW)
	confirm_holder(fx, "inst_w1")
	before, _ := lease_of(fx, "inst_w1")
	gen := s1a_gen(fx, "inst_w1")
	wake_log_reset(log)
	_, hok, herr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "fresh window please"})
	if !testing.expectf(t, hok, "handoff: %s", herr.message) do return
	again, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && again.lease_id != before.lease_id && again.attempt_no == before.attempt_no, "next holder continues the same attempt")
	s1a_expect_fresh(t, fx, log, "inst_w1", gen, "handoff re-grant")
}

// Row 14: a dispatch failure parks the lease as waiting and blocks the task
// agent_not_running.
@(test)
test_sched1a_row14_dispatch_failure_parks_lease :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r14")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r14")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_NO_REVIEW)
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "granted") do return
	on_dispatch_failed(&fx.svc, lease.lease_id, "send failed")
	parked, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && parked.phase == domain.LEASE_PHASE_WAITING, "lease becomes waiting")
	task := get_task(fx, "task_1")
	testing.expect(t, is_agent_not_running_block(task.blocked_on_json), "task blocked agent_not_running")
}

// Row 15: a user stop ends the lease as user_stopped and the instance is
// never re-picked.
@(test)
test_sched1a_row15_user_stop_ends_lease :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r15")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r15")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_NO_REVIEW)
	confirm_holder(fx, "inst_w1")
	inst := s1a_inst(fx, "inst_w1")
	inst.runtime_status = "stopped"
	inst.stopped_by = "user"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_user_stopped(&fx.svc, "inst_w1")
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, !held, "user stop ends the lease and the instance is not re-picked")
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, "task_1", "u1")
	found := false
	for e in evs do if e.kind == EV_LEASE_EXPIRED && strings.contains(e.payload_json, EXPIRE_USER_STOPPED) do found = true
	testing.expect(t, found, "lease expired with reason user_stopped")
}

@(private = "file")
s1a_record_runtime :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	wake_log_observe(ctx, {bridge_id = command.bridge_id, body_json = command.body_json})
	return true, {}
}

// Row 16: a context rollover restarts the process in place; the lease is kept.
@(test)
test_sched1a_row16_rollover_keeps_lease :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r16")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r16")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_NO_REVIEW)
	confirm_holder(fx, "inst_w1")
	before, _ := lease_of(fx, "inst_w1")
	inst := s1a_inst(fx, "inst_w1")
	wake_log_reset(log)
	log.service.bridge_command_sink = {ctx = log, send_runtime_command = s1a_record_runtime}
	restarted, accepted, err := agent.restart_instance(&log.service, inst_auth("inst_w1"), "inst_w1", {expected_run_count = inst.run_count})
	if !testing.expectf(t, accepted, "rollover: %s", err.message) do return
	testing.expect_value(t, restarted.run_count, inst.run_count + 1)
	after, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && after.lease_id == before.lease_id && after.phase == before.phase, "lease kept through rollover")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "rollover is not a stop")
}

// Row 17: chain closed → all leases revoked, holders stopped, coordinator not.
@(test)
test_sched1a_row17_chain_closed_stops_holders :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r17")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r17")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	confirm_holder(fx, "inst_r1")
	wake_log_reset(log)
	testing.expect(t, chain_closed(&fx.svc, chain, Actor{kind = ACTOR_USER, id = "u1"}, true).code == .None, "chain_closed")
	stops := ownership_pending_stops(&fx.svc, get_task(fx, "task_1"))
	for inst in ([]string{"inst_w1", "inst_r1"}) {
		_, held := lease_of(fx, inst)
		testing.expectf(t, !held, "%s holds no lease after close", inst)
		stopped := wake_log_has_stop(log, inst)
		for s in stops do if s.instance_id == inst do stopped = true
		testing.expectf(t, stopped, "%s is stopped on close", inst)
	}
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "the coordinator is not stopped")
}

// Row 18: hub restart inside a grace window → rebuild_timers re-arms the
// timer from idle_since and the reviewer is stopped when it ends.
@(test)
test_sched1a_row18_hub_restart_rearms_grace_window :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r18")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r18", idle_ttl = 120)
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	if _, rok := s1a_review(t, fx, "inst_r1", "request_changes"); !rok do return
	since := s1a_inst(fx, "inst_r1").idle_since
	// Hub restart: the in-memory heap is lost and rebuilt from the columns.
	for due in timers_pop_due(&fx.svc, max(i64)) { d := due; timer_destroy(&d) }
	testing.expect_value(t, timers_armed_count(&fx.svc), 0)
	rebuild_timers(&fx.svc)
	timer, armed := s1a_idle_timer(&fx.svc, "inst_r1")
	testing.expect(t, armed && timer.armed == since, "grace timer re-armed from idle_since")
	fixture_advance(fx, 121)
	wake_log_reset(log)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	s1a_expect_stopped(t, fx, log, "inst_r1", STOP_REASON_IDLE_TTL, "window ended after restart")
}

// Row 19: bridge reconnect. A lease-free fleet instance inside its window is
// kept; past its window it is stopped; claim holders and the coordinator are
// never touched.
@(test)
test_sched1a_row19_bridge_reconnect_honours_grace_window :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_r19")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_r19", idle_ttl = 120)
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_ONE_REVIEWER)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	if _, rok := s1a_review(t, fx, "inst_r1", "request_changes"); !rok do return
	live := []string{"inst_w1", "inst_r1", "inst_coord"}
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", live)
	testing.expect(t, !wake_log_has_stop(log, "inst_r1"), "inside its window: kept")
	fixture_advance(fx, 121)
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", live)
	s1a_expect_stopped(t, fx, log, "inst_r1", STOP_REASON_IDLE_TTL, "reconnect past the window")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "the claim holder is kept")
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "the coordinator is never touched")
}

// Coordinator column of rows 4 and 6: the coordinator as a listed reviewer
// pulls the review, posts, loses the lease and is neither stopped nor timed out.
@(test)
test_sched1a_coordinator_reviewer_is_never_stopped :: proc(t: ^testing.T) {
	for verdict in ([]string{"approve", "request_changes"}) {
		fx, log, ok := lease_fixture(t, fmt.tprintf("s1a_coord_%s", verdict))
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := s1a_setup(t, fx, fmt.tprintf("s1a_coord_%s", verdict))
		_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_c"]}`)
		if !s1a_submit(t, fx, "inst_w1", "v1") do return
		gen := s1a_gen(fx, "inst_coord")
		pulled, pok, perr := lease_next(&fx.svc, inst_auth("inst_coord"), {})
		if !testing.expectf(t, pok && pulled.lease.kind == domain.LEASE_KIND_REVIEW, "%s: coordinator pulls its review: %s", verdict, perr.message) do return
		wake_log_reset(log)
		findings := CHANGES_FINDINGS if verdict == "request_changes" else "[]"
		_, rok, rerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{verdict = verdict, findings_json = findings})
		if !testing.expectf(t, rok, "%s: %s", verdict, rerr.message) do return
		_, held := lease_of(fx, "inst_coord")
		testing.expectf(t, !held, "%s: the coordinator's review lease is deleted", verdict)
		s1a_expect_coordinator_untouched(t, fx, log, verdict)
		testing.expect_value(t, s1a_gen(fx, "inst_coord"), gen)
		testing.expect_value(t, s1a_inst(fx, "inst_coord").stop_reason, "")
		_, armed := s1a_idle_timer(&fx.svc, "inst_coord")
		testing.expectf(t, !armed, "%s: no grace timer for the coordinator", verdict)
	}
}

// REQ-SCHED-27: through a full two-reviewer flow, every live, lease-free,
// non-coordinator fleet instance without a stop intent has idle_since and an
// armed Idle_TTL — including instances that came up with nothing to do.
@(test)
test_sched1a_every_lease_free_fleet_instance_has_idle_timer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1a_inv")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := s1a_setup(t, fx, "s1a_inv", idle_ttl = 300)
	seed_agent(fx, "agt_spare")
	seed_fleet(fx, chain, "agt_spare")
	seed_instance(fx, chain, "inst_spare", "agt_spare", "br_1", "idle")
	check :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, step: string) {
		insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
		for inst in insts {
			if !instance_is_live(inst) && !instance_is_pending(inst) do continue
			if inst.stop_reason != "" do continue // being stopped
			if _, managed := instance_stop_managed(&fx.svc, chain, inst); !managed do continue
			_, armed := s1a_idle_timer(&fx.svc, inst.agent_instance_id)
			testing.expectf(t, inst.idle_since != "" && armed, "%s: %s is lease-free with idle_since %q and timer armed %v", step, inst.agent_instance_id, inst.idle_since, armed)
		}
	}
	// Every instance reports start-success: the ones with nothing to do get a window.
	for id in ([]string{"inst_w1", "inst_r1", "inst_r2", "inst_spare"}) do confirm_holder(fx, id)
	check(t, fx, chain, "started")
	_ = publish_task(t, fx, chain, "task_1", brief = BRIEF_TWO_REVIEWERS)
	check(t, fx, chain, "granted")
	if !s1a_submit(t, fx, "inst_w1", "v1") do return
	check(t, fx, chain, "submitted")
	if _, rok := s1a_review(t, fx, "inst_r1", "request_changes"); !rok do return
	check(t, fx, chain, "changes requested")
	if !s1a_submit(t, fx, "inst_w1", "v2") do return
	check(t, fx, chain, "resubmitted")
	if _, rok := s1a_review(t, fx, "inst_r1", "approve"); !rok do return
	check(t, fx, chain, "first approval")
	if _, rok := s1a_review(t, fx, "inst_r2", "approve"); !rok do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	check(t, fx, chain, "done")
	// A waiting claim relinquished by handoff starts a window too.
	_ = publish_task(t, fx, chain, "task_2", brief = BRIEF_NO_REVIEW)
	confirm_holder(fx, "inst_w1")
	if _, bok, _ := lease_block(&fx.svc, inst_auth("inst_w1"), Block_Input{waiting_on_json = `{"kind":"human","reason":"?"}`}); !testing.expect(t, bok, "block") do return
	if _, hok, _ := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "release"}); !testing.expect(t, hok, "release waiting claim") do return
	check(t, fx, chain, "waiting claim released")
}

// ---- 14.5 stop-path read counts ------------------------------------------------
// A counting wrapper around the repository reads the stop paths use. Each stop
// decision must issue the same number of reads on a 1,000-task chain as on a
// 10-task chain (REQ-SCHED-26): approve's decision reads nothing beyond the
// lease it already holds, so it is covered by the shared helpers measured here.

@(private = "file", thread_local)
s1a_reads: int
@(private = "file", thread_local)
s1a_repo_orig: iface.Taskchain_Repository
@(private = "file", thread_local)
s1a_agents_orig: iface.Agent_Repository

@(private = "file")
s1a_install_read_counter :: proc(fx: ^Fixture) {
	s1a_repo_orig = fx.repo
	s1a_agents_orig = fx.agents
	fx.repo.get_task = proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.get_task(ctx, id) }
	fx.repo.get_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.get_chain(ctx, id) }
	fx.repo.list_tasks_by_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.list_tasks_by_chain(ctx, id, owner) }
	fx.repo.list_reviews_by_task = proc(ctx: rawptr, id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Review, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.list_reviews_by_task(ctx, id, owner) }
	fx.repo.list_attempts_by_task = proc(ctx: rawptr, id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Attempt, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.list_attempts_by_task(ctx, id, owner) }
	fx.repo.list_events_by_task = proc(ctx: rawptr, id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.list_events_by_task(ctx, id, owner) }
	fx.repo.list_leases_by_task = proc(ctx: rawptr, id: domain.Task_ID) -> ([]domain.Task_Lease, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.list_leases_by_task(ctx, id) }
	fx.repo.get_lease_by_holder = proc(ctx: rawptr, id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.get_lease_by_holder(ctx, id) }
	fx.repo.list_fleets_by_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Fleet, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.list_fleets_by_chain(ctx, id, owner) }
	fx.repo.list_members_by_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) { s1a_reads += 1; return s1a_repo_orig.list_members_by_chain(ctx, id, owner) }
	fx.agents.get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) { s1a_reads += 1; return s1a_agents_orig.get_instance(ctx, id) }
	fx.agents.list_instances_by_chain = proc(ctx: rawptr, owner: domain.User_ID, chain_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) { s1a_reads += 1; return s1a_agents_orig.list_instances_by_chain(ctx, owner, chain_id) }
}

@(private = "file")
s1a_uninstall_read_counter :: proc(fx: ^Fixture) {
	fx.repo = s1a_repo_orig
	fx.agents = s1a_agents_orig
}

Stop_Path_Reads :: struct { idle_ttl, sweep, task_done: int }

// s1a_measure_stop_paths: one in-review-then-rework task with two reviewers in
// their grace window, plus `filler` cancelled tasks each with an attempt and a
// review (what the removed chain scans read per task).
@(private = "file")
s1a_measure_stop_paths :: proc(t: ^testing.T, filler: int) -> (out: Stop_Path_Reads, ok: bool) {
	tag := fmt.tprintf("s1a_reads_%d", filler)
	fx, log, fok := lease_fixture(t, tag)
	defer lease_fixture_close(fx, log)
	if !fok do return {}, false
	chain := s1a_setup(t, fx, tag, idle_ttl = 120)
	_ = publish_task(t, fx, chain, "task_x", brief = BRIEF_TWO_REVIEWERS)
	if !s1a_submit(t, fx, "inst_w1", "v1") do return {}, false
	confirm_holder(fx, "inst_r2")
	if _, rok := s1a_review(t, fx, "inst_r1", "request_changes"); !rok do return {}, false
	now := platform.clock_now(&fx.clock)
	for i in 0 ..< filler {
		id := fmt.tprintf("task_fill_%04d", i)
		task := seed_task(t, fx, chain, id, BRIEF_ONE_REVIEWER)
		task.state = .Cancelled
		task.publish_state = .Published
		task.attempt_no = 1
		_, _, _ = iface.taskchain_save_task(&fx.repo, task)
		_, _, _ = iface.taskchain_save_attempt(&fx.repo, domain.Task_Attempt{task_id = task.task_id, attempt_no = 1, chain_id = chain.chain_id, owner_user_id = "u1", started_at = now, ended_at = now, holder_instance_id = "inst_w1"})
		_, _, _ = iface.taskchain_save_review(&fx.repo, domain.Task_Review{task_id = task.task_id, chain_id = chain.chain_id, owner_user_id = "u1", attempt_no = 1, role = domain.REVIEW_ROLE_AGENT, reviewer_kind = "agent", reviewer_agent_id = "agt_r", reviewer_instance_id = "inst_r1", verdict = "approve", findings_json = "[]", created_at = now})
	}
	s1a_install_read_counter(fx)
	defer s1a_uninstall_read_counter(fx)

	// Bridge sweep: r1 and r2 inside their window, w1 holds a claim, coordinator.
	{
		u, uok, _ := begin_uow(&fx.svc)
		if !testing.expect(t, uok, "begin uow") do return {}, false
		s1a_reads = 0
		swept := sweep_idle_instances_in_uow(&fx.svc, &u, "br_1", []string{"inst_w1", "inst_r1", "inst_r2", "inst_coord"})
		out.sweep = s1a_reads
		_, _ = end_uow(&fx.svc, &u, false)
		testing.expect(t, swept, "sweep")
	}
	// Idle TTL fires for r1: only its own timer is armed.
	{
		timer, armed := s1a_idle_timer(&fx.svc, "inst_r1")
		if !testing.expect(t, armed, "r1 grace timer") do return {}, false
		since := strings.clone(timer.armed, context.temp_allocator)
		for due in timers_pop_due(&fx.svc, max(i64)) { d := due; timer_destroy(&d) }
		timers_arm(&fx.svc, .Idle_TTL, "inst_r1", now_ms(&fx.clock), since)
		wake_log_reset(log)
		s1a_reads = 0
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
		out.idle_ttl = s1a_reads
		testing.expect(t, wake_log_has_stop(log, "inst_r1"), "idle TTL stopped r1")
	}
	// Task done or cancelled: clear_task_claims_in_uow on task_x (w1 holds rework).
	{
		u, uok, _ := begin_uow(&fx.svc)
		if !testing.expect(t, uok, "begin uow") do return {}, false
		task := get_task(fx, "task_x")
		s1a_reads = 0
		cleared := clear_task_claims_in_uow(&fx.svc, &u, task)
		out.task_done = s1a_reads
		_, _ = end_uow(&fx.svc, &u, false)
		testing.expect(t, cleared, "clear task claims")
	}
	return out, true
}

@(test)
test_sched1a_stop_path_reads_do_not_grow_with_chain_size :: proc(t: ^testing.T) {
	small, sok := s1a_measure_stop_paths(t, 10)
	large, lok := s1a_measure_stop_paths(t, 1000)
	if !testing.expect(t, sok && lok, "both measurements ran") do return
	log.infof("stop-path reads: 10 tasks %v, 1000 tasks %v", small, large)
	testing.expectf(t, small.sweep > 0 && small.idle_ttl > 0 && small.task_done > 0, "reads counted: %v", small)
	testing.expectf(t, small == large, "stop-path reads independent of chain size: 10 tasks %v, 1000 tasks %v", small, large)
	// Bounded by the instances involved, not by tasks.
	testing.expectf(t, large.idle_ttl <= 8 && large.task_done <= 16 && large.sweep <= 24, "stop-path reads are point lookups: %v", large)
}

_ :: runtime
_ :: contracts
