package taskv2

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Coordinator flows (spec SCHED, section 14.2; REQ-SCHED-11..18). Solo mode is
// gone: the coordinator is an ordinary assignee and reviewer. It is served only
// by pulling (`lease next`, inline), never woken, restarted or stopped by a
// grant or a finished task or review, and its leases are active-only: submit,
// block and a posted review delete them, so it can pull its next item at once.

GREEN_VCS :: `{"head":"abc","dirty":false,"files":[]}`

// coordinator_chain: seed_live_chain (coordinator inst_coord of agt_c on br_1,
// no fleet row for agt_c) plus a worker agt_w with one idle instance.
coordinator_chain :: proc(t: ^testing.T, fx: ^Fixture, chain_id: string) -> domain.Task_Chain {
	chain := seed_live_chain(t, fx, chain_id)
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	return chain
}

// publish_coordinator_task: publish_task for a task assigned to the
// coordinator's agent (agt_c), reviewed by the user by default, with
// requires_user_approval resolved as the create paths do.
publish_coordinator_task :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, id: string, brief := `{"goal":"g","assignee":"agt_c","reviewers":["user"]}`, priority := domain.Task_Priority.P2) -> domain.Task {
	b := brief if brief_assignee(brief) != "" else `{"goal":"g","assignee":"agt_c","reviewers":["user"]}`
	task := seed_task(t, fx, chain, id, b)
	task.priority = priority
	task.requires_user_approval = brief_requires_user(b)
	task.publish_state = .Published
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	err := task_created(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"})
	testing.expect(t, err.code == .None, fmt.tprintf("task_created %s: %s", id, err.message))
	fresh, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	return fresh
}

coordinator_run_count :: proc(fx: ^Fixture) -> int {
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	return inst.run_count
}

@(test)
test_coordinator_assignee_pulls_inline_and_submit_frees_it :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_assignee")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := coordinator_chain(t, fx, "chain_coord_assignee")
	notices := notice_capture(fx)
	generation := coordinator_run_count(fx)
	wake_log_reset(log)
	_ = publish_coordinator_task(t, fx, chain, "task_1", priority = .P1)
	_ = publish_coordinator_task(t, fx, chain, "task_2", brief = `{"goal":"g","assignee":"agt_c"}`, priority = .P2)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
	testing.expect(t, !wake_log_has_run(log, "inst_coord"), "the hub never wakes the coordinator for a grant")
	_, held := lease_of(fx, "inst_coord")
	testing.expect(t, !held, "no lease until the coordinator pulls")
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_1"), 1)
	for r in notices.recipients do testing.expect_value(t, r, "inst_coord")
	// Re-evaluations that leave the task Ready do not repeat the notice.
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_1"), 1)
	testing.expect(t, get_task(fx, "task_1").requires_user_approval, "`user` in reviewers means the user approves")

	auth := inst_auth("inst_coord")
	res, nok, nerr := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, nok, fmt.tprintf("lease next: %s", nerr.message)) do return
	testing.expect_value(t, res.status, "granted")
	testing.expect_value(t, string(res.task.task_id), "task_1")
	testing.expect_value(t, res.lease.delivery, domain.LEASE_DELIVERY_INLINE)
	testing.expect_value(t, coordinator_run_count(fx), generation)

	wake_log_reset(log)
	sub, sok, serr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, sub.outcome, "in_review")
	_, still := lease_of(fx, "inst_coord")
	testing.expect(t, !still, "the coordinator's lease is deleted on submit (active-only)")
	testing.expect(t, !wake_log_has_stop(log, "inst_coord") && !wake_log_has_run(log, "inst_coord"), "submit never stops or restarts the coordinator")
	// While task_1 waits for the user, the coordinator pulls its next task.
	next, xok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	testing.expect(t, xok && next.status == "granted" && next.task.task_id == "task_2", fmt.tprintf("next assigned task while the first is in review: %s %s", next.status, next.task.task_id))
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	testing.expect_value(t, coordinator_run_count(fx), generation)
}

@(test)
test_coordinator_rework_returns_as_ready_with_one_attempt_increment :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_rework")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := coordinator_chain(t, fx, "chain_coord_rework")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","assignee":"agt_c","reviewers":["user"]}`)
	auth := inst_auth("inst_coord")
	first, fok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, fok && first.status == "granted", "pulled") do return
	testing.expect_value(t, first.lease.attempt_no, 1)
	_, sok, serr := lease_submit(&fx.svc, auth, Submit_Input{summary = "v1", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	_, cok, cerr := user_review(&fx.svc, user_auth(), "task_1", Review_Input{verdict = "request_changes", summary = "rename x"})
	if !testing.expect(t, cok, fmt.tprintf("request changes: %s", cerr.message)) do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_1"), 2)
	testing.expect(t, !wake_log_has_run(log, "inst_coord"), "rework is pulled, never woken")
	again, aok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, aok && again.status == "granted" && again.task.task_id == "task_1", "rework pulled") do return
	testing.expect_value(t, again.lease.attempt_no, 2)
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, 2)
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, "task_1", "u1")
	testing.expect_value(t, len(attempts), 2)
}

@(test)
test_coordinator_listed_reviewer_pulls_review_first_and_keeps_running :: proc(t: ^testing.T) {
	for verdict in ([]string{"approve", "request_changes"}) {
		fx, log, ok := lease_fixture(t, fmt.tprintf("coord_reviewer_%s", verdict))
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := coordinator_chain(t, fx, "chain_coord_reviewer")
		notices := notice_capture(fx)
		_ = publish_task(t, fx, chain, "task_w", brief = `{"goal":"g","assignee":"agt_w","reviewers":["agt_c"]}`, priority = .P2)
		confirm_holder(fx, "inst_w1")
		_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = GREEN_VCS})
		if !testing.expect(t, sok, fmt.tprintf("worker submit: %s", serr.message)) do return
		// The coordinator's own work is ready too, at a higher priority.
		_ = publish_task(t, fx, chain, "task_c", brief = `{"goal":"g","assignee":"agt_c"}`, priority = .P0)
		testing.expect(t, !wake_log_has_run(log, "inst_coord"), "a review owed by the coordinator is never woken")
		testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_w"), 1)
		generation := coordinator_run_count(fx)
		auth := inst_auth("inst_coord")
		res, nok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
		if !testing.expect(t, nok && res.status == "granted", "pulled") do return
		testing.expect_value(t, string(res.task.task_id), "task_w")
		testing.expect_value(t, res.lease.kind, domain.LEASE_KIND_REVIEW)
		wake_log_reset(log)
		input := Review_Input{verdict = verdict}
		if verdict == "request_changes" do input.summary = "fix it"
		_, rok, rerr := review_post(&fx.svc, auth, input)
		if !testing.expect(t, rok, fmt.tprintf("%s: %s", verdict, rerr.message)) do return
		_, still := lease_of(fx, "inst_coord")
		testing.expect(t, !still, "a posted review deletes the coordinator's lease")
		testing.expect(t, !wake_log_has_stop(log, "inst_coord") && !wake_log_has_run(log, "inst_coord"), fmt.tprintf("%s never stops or restarts the coordinator", verdict))
		testing.expect_value(t, coordinator_run_count(fx), generation)
		// approve: done; request_changes: rework goes back to the worker, which
		// still holds its claim and is re-granted at once.
		state := get_task(fx, "task_w").state
		testing.expectf(t, state == .Done if verdict == "approve" else (state == .Ready || state == .In_Progress), "%s: task_w state %v", verdict, state)
		// Then its own work.
		next, xok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
		testing.expect(t, xok && next.status == "granted" && next.task.task_id == "task_c", fmt.tprintf("%s: then its assigned work: %s %s", verdict, next.status, next.task.task_id))
	}
}

@(test)
test_coordinator_proxy_review_follows_the_author_rule :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_author")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := coordinator_chain(t, fx, "chain_coord_author")
	_ = publish_task(t, fx, chain, "task_w", brief = `{"goal":"g","assignee":"agt_w","reviewers":["user"]}`)
	_ = publish_task(t, fx, chain, "task_c", brief = `{"goal":"g","assignee":"agt_c","reviewers":["user"]}`)
	auth := inst_auth("inst_coord")
	// Not in review yet: the state error, not the author error.
	_, early, eerr := review_post(&fx.svc, auth, Review_Input{task_id = "task_c", verdict = "approve", on_behalf_of = "user"})
	testing.expect(t, !early && eerr.code == .Conflict && strings.contains(eerr.message, "not awaiting review"), fmt.tprintf("not in review: %s", eerr.message))
	confirm_holder(fx, "inst_w1")
	_, wok, werr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "w", vcs_json = GREEN_VCS})
	if !testing.expect(t, wok, fmt.tprintf("worker submit: %s", werr.message)) do return
	c, cok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, cok && c.status == "granted" && c.task.task_id == "task_c", "coordinator pulled its task") do return
	_, sok, serr := lease_submit(&fx.svc, auth, Submit_Input{summary = "c", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("coordinator submit: %s", serr.message)) do return
	// A worker's task: the coordinator may approve for the user.
	g, gok, gerr := review_post(&fx.svc, auth, Review_Input{task_id = "task_w", verdict = "approve", on_behalf_of = "user"})
	testing.expect(t, gok && g.gate == .Approved, fmt.tprintf("proxy approve on a worker's task: %s", gerr.message))
	testing.expect_value(t, get_task(fx, "task_w").state, domain.Task_State.Done)
	// Its own task: refused with the author error; the task waits for the user.
	_, rok, rerr := review_post(&fx.svc, auth, Review_Input{task_id = "task_c", verdict = "approve", on_behalf_of = "user"})
	testing.expect(t, !rok && rerr.code == .Forbidden && strings.contains(rerr.details_json, "author_self_review"), fmt.tprintf("own task: %s", rerr.details_json))
	testing.expect_value(t, get_task(fx, "task_c").state, domain.Task_State.In_Review)
	// request_changes still needs a reason (agent and user).
	_, aok, aerr := review_post(&fx.svc, auth, Review_Input{task_id = "task_c", verdict = "request_changes"})
	testing.expect(t, !aok && aerr.code == .Validation_Failed, "request_changes without a reason → 400")
}

@(test)
test_coordinator_gets_no_notice_for_other_agents_tasks :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_no_notice")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_coord_no_notice")
	seed_fleet(fx, chain, "agt_w")
	notices := notice_capture(fx)
	// No worker instance: the task stays Ready, but it is not the coordinator's.
	_ = publish_task(t, fx, chain, "task_other", brief = `{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}`)
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready"), 0)
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none" && res.refused_task_id == "", "nothing for the coordinator, no refusal")
}

@(test)
test_coordinator_lease_next_reports_blocking_runtime_action :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_busy")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := coordinator_chain(t, fx, "chain_coord_busy")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","assignee":"agt_c"}`)
	if !testing.expect(t, fx.svc.agents == &fx.agents, "fixture shares its agent repository") do return
	fx.agents.runtime_busy = proc(ctx: rawptr, instance_id: string) -> (bool, domain.Domain_Error) {
		return instance_id == "inst_coord", {}
	}
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", fmt.tprintf("status: %s", res.status))
	testing.expect_value(t, string(res.refused_task_id), "task_1")
	testing.expect(t, strings.contains(res.reason, "pending runtime action"), fmt.tprintf("reason: %s", res.reason))
	fx.agents.runtime_busy = nil
	again, aok, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, aok && again.status == "granted", "granted once the action settles")
}

@(test)
test_coordinator_lease_does_not_reduce_worker_capacity :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_capacity")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := coordinator_chain(t, fx, "chain_coord_capacity")
	// A stale fleet row for the coordinator's own agent is ignored for launching.
	seed_fleet(fx, chain, "agt_c")
	_ = publish_task(t, fx, chain, "task_c", brief = `{"goal":"g","assignee":"agt_c"}`)
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", "coordinator holds a lease") do return
	wake_log_reset(log)
	_ = publish_task(t, fx, chain, "task_w", brief = `{"goal":"g","assignee":"agt_w"}`)
	w, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && w.task_id == "task_w", "the worker (capacity 1) is still granted its task")
	testing.expect(t, !wake_log_has_run(log, "inst_coord"), "no copy of the coordinator is launched")
}

@(test)
test_coordinator_lease_switch_hands_off_and_grants_atomically :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_switch")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_coord_switch")
	_ = publish_task(t, fx, chain, "task_a", brief = `{"goal":"g","assignee":"agt_c"}`, priority = .P1)
	_ = publish_task(t, fx, chain, "task_b", brief = `{"goal":"g","assignee":"agt_c"}`, priority = .P2)
	_ = publish_task(t, fx, chain, "task_x", brief = `{"goal":"g","assignee":"agt_w"}`, priority = .P2)
	auth := inst_auth("inst_coord")
	res, nok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", "pulled") do return
	testing.expect_value(t, string(res.task.task_id), "task_a")
	a_attempt := res.lease.attempt_no
	_, mok, merr := lease_switch(&fx.svc, auth, Switch_Input{task_id = "task_b"})
	testing.expect(t, !mok && merr.code == .Validation_Failed, "summary required")
	_, xok, xerr := lease_switch(&fx.svc, auth, Switch_Input{task_id = "task_x", summary = "s"})
	testing.expect(t, !xok && xerr.code == .Conflict, "a task assigned to another agent is refused")
	still, sh := lease_of(fx, "inst_coord")
	testing.expect(t, sh && still.lease_id == res.lease.lease_id, "a refused switch keeps the current lease")
	wake_log_reset(log)
	sw, wok, werr := lease_switch(&fx.svc, auth, Switch_Input{task_id = "task_b", summary = "paused A", handoff_json = `{"next_steps":"finish A"}`})
	if !testing.expect(t, wok, fmt.tprintf("switch: %s", werr.message)) do return
	testing.expect_value(t, string(sw.task.task_id), "task_b")
	testing.expect_value(t, get_task(fx, "task_a").state, domain.Task_State.Ready)
	testing.expect(t, !wake_log_has_stop(log, "inst_coord") && !wake_log_has_run(log, "inst_coord"), "switch never stops or wakes the coordinator")
	_, bsok, bserr := lease_submit(&fx.svc, auth, Submit_Input{summary = "B done", vcs_json = GREEN_VCS})
	if !testing.expect(t, bsok, fmt.tprintf("submit B: %s", bserr.message)) do return
	back, bok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, bok && back.status == "granted", "pulled A again") do return
	testing.expect_value(t, string(back.task.task_id), "task_a")
	testing.expect_value(t, back.lease.attempt_no, a_attempt)
	testing.expect(t, strings.contains(back.pack_json, "paused A") && strings.contains(back.pack_json, "finish A"), "pack carries the handoff")
}

@(test)
test_coordinator_elapsed_time_retains_same_attempt :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "coord_elapsed")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_coord_elapsed")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","assignee":"agt_c"}`)
	auth := inst_auth("inst_coord")
	res, nok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", "pulled") do return
	wake_log_reset(log)
	for _ in 0..<6 {
		fixture_advance(fx, LEASE_HARD_CAP_SECONDS * 2)
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
		again, aok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
		testing.expect(t, aok && again.status == "current" && again.lease.lease_id == res.lease.lease_id, "the coordinator retains the same assignment")
		testing.expect_value(t, again.lease.attempt_no, res.lease.attempt_no)
	}
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 0)
	testing.expect_value(t, len(log.cmds), 0)
}

// ---- assignee-required and reviewer rules (REQ-SCHED-3/4/9, 14.1) --------------------

@(test)
test_work_goes_only_to_the_assignee_agent :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "assignee_only")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_assignee_only")
	seed_agent(fx, "agt_x")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_x")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	// Assigned to agt_x, whose row is paused, then full, then gone: never agt_w.
	now := "2026-01-01T00:00:00Z"
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = "agt_x", capacity = 1, paused = true, created_at = now, updated_at = now})
	_ = publish_task(t, fx, chain, "task_x", brief = `{"goal":"g","assignee":"agt_x"}`)
	_, wheld := lease_of(fx, "inst_w1")
	testing.expect(t, !wheld, "paused assignee: no other agent is granted")
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", "inline pull of another agent's task refused")
	_, _ = iface.taskchain_delete_fleet(&fx.repo, chain.chain_id, "agt_x", "u1")
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	_, wheld = lease_of(fx, "inst_w1")
	testing.expect(t, !wheld, "missing assignee row: no other agent is granted")
	// An unassigned task (a migration hold) is never granted to anyone.
	_ = publish_task(t, fx, chain, "task_none", brief = `{"goal":"g","assignee":""}`)
	_, wheld = lease_of(fx, "inst_w1")
	testing.expect(t, !wheld, "no any-worker fallback")
	blockers := dispatch_blockers(&fx.svc, chain, get_task(fx, "task_none"))
	testing.expect(t, len(blockers) == 1 && strings.contains(blockers[0], "no assignee"), "the blocker names the missing assignee")
}

@(test)
test_brief_assignment_rules :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(validate_brief_assignment(nil, `{"goal":"g"}`).details_json, `"code":"assignee_required"`), "assignee required")
	testing.expect(t, strings.contains(validate_brief_assignment(nil, `{"goal":"g","assignee":"agt_a","reviewers":["agt_a"]}`).details_json, `"code":"reviewer_is_assignee"`), "the assignee cannot review")
	testing.expect(t, strings.contains(validate_brief_assignment(nil, `{"goal":"g","assignee":"agt_a","reviewers":["inst_1"]}`).details_json, `"code":"reviewer_must_be_agent_id"`), "instance ids rejected")
	testing.expect_value(t, validate_brief_assignment(nil, `{"goal":"g","assignee":"agt_a","reviewers":["agt_b","user"]}`).code, domain.Error_Code.None)
	testing.expect(t, strings.contains(validate_brief_schema(`{"goal":"g","review_roles":["reviewer"]}`).details_json, `"code":"review_roles_removed"`), "review_roles rejected with its replacement")
	testing.expect(t, validate_brief_schema(`{"goal":"g","review_focus":{"agt_b":"security"}}`).code == .None, "review_focus accepted")
	testing.expect(t, validate_brief_schema(`{"goal":"g","review_focus":["x"]}`).code == .Validation_Failed, "review_focus must be an object")
	testing.expect(t, brief_requires_user(`{"reviewers":["user"]}`) && brief_requires_user(`{"requires_user_approval":true}`) && !brief_requires_user(`{"goal":"g"}`), "user approval only when asked")
	missing := brief_publish_missing(nil, {}, .Task, `{"goal":"g","acceptance":["a"]}`)
	testing.expect(t, len(missing) == 1 && missing[0] == "assignee", "publish requires an assignee")
}

@(test)
test_gate_requires_every_listed_reviewer_and_the_user :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "gate_agents")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_gate_agents")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r")
	seed_fleet(fx, chain, "agt_r2")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r","agt_r2","user"],"review_focus":{"agt_r":"check the schema"}}`)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	rl, r1 := lease_of(fx, "inst_r1")
	_, r2 := lease_of(fx, "inst_r2")
	if !testing.expect(t, r1 && r2, "one review lease per listed reviewer agent") do return
	inst_r1, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	pack := build_pack_json(&fx.svc, chain, get_task(fx, "task_1"), rl, inst_r1)
	testing.expect(t, strings.contains(pack, `"review_focus":"check the schema"`), "the reviewer's pack carries its review_focus")
	g1, _, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	testing.expect_value(t, g1.gate, Gate_Result.Waiting)
	testing.expect(t, strings.contains(gate_unmet_json(g1.unmet), `{"kind":"review","agent_id":"agt_r2"}`), fmt.tprintf("unmet names the other agent: %s", gate_unmet_json(g1.unmet)))
	g2, _, _ := review_post(&fx.svc, inst_auth("inst_r2"), Review_Input{verdict = "approve"})
	testing.expect_value(t, g2.gate, Gate_Result.Waiting)
	testing.expect(t, strings.contains(gate_unmet_json(g2.unmet), `"user_approval"`), "then waits for the user")
	_, uok, uerr := user_review(&fx.svc, user_auth(), "task_1", Review_Input{verdict = "approve"})
	testing.expect(t, uok, fmt.tprintf("user approve: %s", uerr.message))
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	reviews, _ := iface.taskchain_list_reviews_by_task(&fx.repo, "task_1", "u1")
	for r in reviews do if r.reviewer_kind == "agent" do testing.expect_value(t, r.role, domain.REVIEW_ROLE_AGENT)
}

// ---- guard: removed identifiers stay removed (SCHED-0b acceptance) -------------------

@(test)
test_guard_no_solo_or_role_identifiers_in_src :: proc(t: ^testing.T) {
	// Built by concatenation so this file does not match itself.
	banned := []string{
		"chain_" + "is_solo", "implicit_" + "solo_worker", "solo_" + "task_ready",
		"solo_" + "self_review", "fleet_row_" + "has_role", "Review_" + "Pair",
	}
	src := strings.concatenate({#directory, "/../../.."}, context.temp_allocator)
	hits := make([dynamic]string, context.temp_allocator)
	walk :: proc(dir: string, banned: []string, hits: ^[dynamic]string) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return
		for e in entries {
			if e.type == .Directory {
				if e.name == "migrations" || e.name == "node_modules" do continue
				walk(e.fullpath, banned, hits)
				continue
			}
			if !strings.has_suffix(e.name, ".odin") do continue
			data, rerr := os.read_entire_file_from_path(e.fullpath, context.temp_allocator)
			if rerr != nil do continue
			text := string(data)
			for b in banned do if strings.contains(text, b) do append(hits, fmt.tprintf("%s: %s", e.fullpath, b))
		}
	}
	walk(src, banned, &hits)
	testing.expectf(t, len(hits) == 0, "removed identifiers still present: %v", hits[:])
	verbs_path := strings.concatenate({src, "/hub/service/taskv2/verbs_m2.odin"}, context.temp_allocator)
	testing.expect(t, os.exists(verbs_path), "guard walked the real source tree")
	verbs, _ := os.read_entire_file_from_path(verbs_path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(verbs), `agent_id != "coordinator"`) && !strings.contains(string(verbs), `agent_id == "coordinator"`), "no literal \"coordinator\" agent-id comparison")
}
