package taskv2

// SCHED-2: system tests (spec SCHED section 14). The per-task suites cover
// their own requirements (coordinator_flow_test: 14.1/14.2, sched1a_lifecycle_test:
// 14.3 and the stop-path helpers of 14.5, sched1b_capacity_test: 14.4,
// lease_next_cost_test: 14.5 lease next and pack, sched0_migration_test: 14.6).
// This file holds the tests that span those tasks:
//
// - one chain driven end to end through assignment and the gate (SCHED-0),
//   event-driven stops and the grace window (SCHED-1a), the chain cap and
//   instance reuse (SCHED-1b) and the versioned pack (SCHED-1c), with the
//   invariants checked after every step;
// - 14.1 "never granted to agent Y" for an assignee that is full, and 14.3
//   "the next task for that worker has a higher run_count" on the same instance;
// - 14.5 read counts for the whole `review post` verb, both verdicts.
//
// REQ-SCHED-36 (per-agent stall) was dropped by user decision #4, so there is
// no per-agent stall test.

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

@(private = "file")
S2_CHANGES :: `[{"path":"a.odin","line":1,"severity":"major","text":"fix"}]`

@(private = "file")
s2_worker :: proc(fx: ^Fixture, chain: domain.Task_Chain, inst, agent_id: string, status := "stopped", capacity := 1, idle_ttl := 0) {
	seed_agent(fx, agent_id)
	seed_fleet(fx, chain, agent_id, capacity = capacity, idle_ttl = idle_ttl)
	seed_instance(fx, chain, inst, agent_id, "br_1", status)
}

@(private = "file")
s2_set_caps :: proc(fx: ^Fixture, chain: ^domain.Task_Chain, m, r: int) {
	c, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	c.max_parallel = m
	c.review_reserve = r
	_, _, _ = iface.taskchain_save_chain(&fx.repo, c)
	chain^ = c
}

// s2_publish: publish_task with requires_user_approval resolved from the
// brief, as the create paths do.
@(private = "file")
s2_publish :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, id, brief: string) {
	task := seed_task(t, fx, chain, id, brief)
	task.requires_user_approval = brief_requires_user(brief)
	task.publish_state = .Published
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	err := task_created(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"})
	testing.expectf(t, err.code == .None, "task_created %s: %s", id, err.message)
}

@(private = "file")
s2_gen :: proc(fx: ^Fixture, inst: string) -> int {
	cur, _, _ := iface.agent_get_instance(&fx.agents, inst)
	return cur.run_count
}

@(private = "file")
s2_slots :: proc(fx: ^Fixture, chain: domain.Task_Chain) -> Chain_Slots {
	c, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	ctx, ok, _ := load_match_context(&fx.svc, c)
	if !ok do return {}
	defer destroy_match_context(&ctx)
	return chain_slots(&fx.svc, &ctx, nil)
}

// s2_agent_approved: `agent_id` posted approve on the task's current attempt.
@(private = "file")
s2_agent_approved :: proc(fx: ^Fixture, task: domain.Task, agent_id: string) -> bool {
	reviews, _ := iface.taskchain_list_reviews_by_task(&fx.repo, task.task_id, "u1")
	for r in reviews do if r.reviewer_agent_id == agent_id && r.attempt_no == task.attempt_no && r.verdict == "approve" do return true
	return false
}

// s2_expect_pack_cached: the holder's `lease next` returns its lease with a
// versioned pack; sending that version back omits the pack (REQ-SCHED-39).
@(private = "file")
s2_expect_pack_cached :: proc(t: ^testing.T, fx: ^Fixture, inst: string, lease: domain.Task_Lease, step: string) {
	first, ok, err := lease_next(&fx.svc, inst_auth(inst), Lease_Next_Input{})
	if !testing.expectf(t, ok && first.status == "current" && first.lease.lease_id == lease.lease_id, "%s: %s lease next returns its lease (%s %s)", step, inst, first.status, err.message) do return
	testing.expectf(t, first.pack_json != "" && first.pack_version != "", "%s: %s gets a versioned pack", step, inst)
	again, aok, _ := lease_next(&fx.svc, inst_auth(inst), Lease_Next_Input{pack_version = first.pack_version})
	testing.expectf(t, aok && again.status == "current" && again.pack_json == "" && again.pack_version == first.pack_version, "%s: %s unchanged pack is not rebuilt (pack %d bytes)", step, inst, len(again.pack_json))
}

// End to end (spec 14, all tasks). M = 3, r = 1. Two worker agents and one
// reviewer agent Q (each capacity 1, grace window 300 s), and the coordinator
// as an assignee and a reviewer. Q requests changes once on every task, then
// approves. task_3 also needs the user; task_c is the coordinator's own work.
//
// After every step: every work lease is held by the task's assignee and every
// review lease by a listed reviewer; W + R + G ≤ M and W ≤ M − r; the chain
// never has more instances than it started with; and a holder's unchanged pack
// is not rebuilt. At the end: every task is done after exactly two attempts,
// no lease remains, and the coordinator was never woken, restarted or stopped.
@(test)
test_sched2_chain_end_to_end_across_assignment_lifecycle_capacity_and_pack :: proc(t: ^testing.T) {
	fx, wlog, ok := lease_fixture(t, "s2_e2e")
	defer lease_fixture_close(fx, wlog)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s2_e2e")
	s2_worker(fx, chain, "inst_w1", "agt_w1", idle_ttl = 300)
	s2_worker(fx, chain, "inst_w2", "agt_w2", idle_ttl = 300)
	s2_worker(fx, chain, "inst_q", "agt_q", idle_ttl = 300)
	s2_set_caps(fx, &chain, 3, 1)
	// A published chain has a summary row; the seeded chain needs one for a
	// versioned pack (test_pack_version_empty_without_summary_row).
	if _, sok, serr := chain_summary_set(&fx.svc, user_auth(), chain.chain_id, "chain note"); !testing.expectf(t, sok, "summary: %s", serr.message) do return
	coord_gen := s2_gen(fx, "inst_coord")
	wake_log_reset(wlog)

	tasks := []string{"task_1", "task_2", "task_3", "task_c"}
	s2_publish(t, fx, chain, "task_1", `{"goal":"g","acceptance":["a"],"assignee":"agt_w1","reviewers":["agt_q","agt_c"]}`)
	s2_publish(t, fx, chain, "task_2", `{"goal":"g","acceptance":["a"],"assignee":"agt_w2","reviewers":["agt_q"]}`)
	s2_publish(t, fx, chain, "task_3", `{"goal":"g","acceptance":["a"],"assignee":"agt_w1","reviewers":["agt_q","user"]}`)
	s2_publish(t, fx, chain, "task_c", `{"goal":"g","acceptance":["a"],"assignee":"agt_c","reviewers":["agt_q"]}`)
	testing.expect(t, get_task(fx, "task_3").requires_user_approval, "`user` in reviewers needs the user")

	start_insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
	start_count := len(start_insts)
	changes_requested := make(map[string]bool, context.temp_allocator)
	user_approved := 0
	steps := 0

	for step in 0 ..< 200 {
		steps = step
		progressed := false
		// Fleet instances act on what they hold.
		for inst in ([]string{"inst_w1", "inst_w2", "inst_q"}) {
			l, held := lease_of(fx, inst)
			if !held || l.phase != domain.LEASE_PHASE_ACTIVE do continue
			progressed = true
			confirm_holder(fx, inst)
			task := get_task(fx, string(l.task_id))
			cur, _, _ := iface.agent_get_instance(&fx.agents, inst)
			what := fmt.tprintf("step %d %s %s %s", step, inst, l.kind, l.task_id)
			s2_expect_pack_cached(t, fx, inst, l, what)
			if l.kind == domain.LEASE_KIND_WORK {
				testing.expectf(t, cur.agent_id == brief_assignee(task.brief_json), "%s: work goes only to the assignee", what)
				_, sok, serr := lease_submit(&fx.svc, inst_auth(inst), Submit_Input{summary = "s", vcs_json = GREEN_VCS})
				if !testing.expectf(t, sok, "%s: submit: %s", what, serr.message) do return
				continue
			}
			reviewers := brief_reviewer_agents(task.brief_json, context.temp_allocator)
			testing.expectf(t, slice.contains(reviewers[:], cur.agent_id), "%s: review goes only to a listed reviewer", what)
			verdict := "approve" if changes_requested[string(l.task_id)] else "request_changes"
			findings := S2_CHANGES if verdict == "request_changes" else "[]"
			_, rok, rerr := review_post(&fx.svc, inst_auth(inst), Review_Input{verdict = verdict, findings_json = findings})
			if !testing.expectf(t, rok, "%s: %s: %s", what, verdict, rerr.message) do return
			if verdict == "request_changes" do changes_requested[string(l.task_id)] = true
		}
		// The coordinator only pulls; its leases are active-only.
		pulled, pok, perr := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
		if !testing.expectf(t, pok, "step %d: coordinator lease next: %s", step, perr.message) do return
		if pulled.status == "granted" {
			progressed = true
			if pulled.lease.kind == domain.LEASE_KIND_WORK {
				testing.expectf(t, string(pulled.task.task_id) == "task_c", "step %d: the coordinator is granted only its own work (got %s)", step, pulled.task.task_id)
				_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_coord"), Submit_Input{summary = "s", vcs_json = GREEN_VCS})
				if !testing.expectf(t, sok, "step %d: coordinator submit: %s", step, serr.message) do return
			} else {
				testing.expectf(t, string(pulled.task.task_id) == "task_1", "step %d: the coordinator reviews only where listed (got %s)", step, pulled.task.task_id)
				_, rok, rerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{verdict = "approve", findings_json = "[]"})
				if !testing.expectf(t, rok, "step %d: coordinator review: %s", step, rerr.message) do return
			}
			_, still := lease_of(fx, "inst_coord")
			testing.expectf(t, !still, "step %d: the coordinator's lease is deleted after it acts", step)
		}
		// The user approves task_3 once Q has approved its current attempt.
		t3 := get_task(fx, "task_3")
		if t3.state == .In_Review && s2_agent_approved(fx, t3, "agt_q") {
			_, uok, uerr := user_review(&fx.svc, user_auth(), "task_3", Review_Input{verdict = "approve"})
			if !testing.expectf(t, uok, "step %d: user approve: %s", step, uerr.message) do return
			user_approved += 1
			progressed = true
		}

		s := s2_slots(fx, chain)
		testing.expectf(t, s.work + s.review + s.grace <= 3 && s.work <= 2, "step %d: W + R + G <= M and W <= M - r (got %v)", step, s)
		insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
		if !testing.expectf(t, len(insts) == start_count, "step %d: no instance is added (%d -> %d)", step, start_count, len(insts)) do return
		if !progressed do break
	}
	log.infof("SCHED-2 end to end settled after %d steps", steps)

	for id in tasks {
		task := get_task(fx, id)
		testing.expectf(t, task.state == .Done, "%s done (got %v, blocked %s)", id, task.state, task.blocked_on_json)
		testing.expectf(t, task.attempt_no == 2, "%s: one rework round, attempt 2 (got %d)", id, task.attempt_no)
		testing.expectf(t, changes_requested[id], "%s: Q requested changes once", id)
		leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, domain.Task_ID(id))
		testing.expectf(t, len(leases) == 0, "%s: no lease remains (%d)", id, len(leases))
	}
	testing.expect_value(t, user_approved, 1)
	for inst in ([]string{"inst_w1", "inst_w2", "inst_q"}) {
		_, held := lease_of(fx, inst)
		testing.expectf(t, !held, "%s holds no lease at the end", inst)
		testing.expectf(t, wake_log_has_stop(wlog, inst), "%s was stopped by a task or review event", inst)
	}
	// REQ-SCHED-11..18 across the whole run.
	testing.expect(t, !wake_log_has_run(wlog, "inst_coord"), "the coordinator is never woken by a grant")
	testing.expect(t, !wake_log_has_stop(wlog, "inst_coord"), "task done and review done never stop the coordinator")
	testing.expect_value(t, s2_gen(fx, "inst_coord"), coord_gen)
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	testing.expect_value(t, coord.stop_reason, "")
}

// 14.1 "full" and 14.3 "the next task for that worker has a higher run_count":
// agent X (capacity 1) is busy, so X's second task waits for X even though
// agent W has an idle instance and pulls. When X's first task is done, the
// second task starts a fresh process (run_count + 1) on the same instance id.
@(test)
test_sched2_full_assignee_waits_then_reuses_its_instance_fresh :: proc(t: ^testing.T) {
	fx, wlog, ok := lease_fixture(t, "s2_full")
	defer lease_fixture_close(fx, wlog)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s2_full")
	s2_worker(fx, chain, "inst_x", "agt_x")
	s2_worker(fx, chain, "inst_w1", "agt_w", status = "idle")
	s2_publish(t, fx, chain, "task_a", `{"goal":"g","acceptance":["a"],"assignee":"agt_x"}`)
	first, held := lease_of(fx, "inst_x")
	if !testing.expect(t, held && string(first.task_id) == "task_a", "X holds task_a") do return
	s2_publish(t, fx, chain, "task_b", `{"goal":"g","acceptance":["a"],"assignee":"agt_x"}`)
	_, wheld := lease_of(fx, "inst_w1")
	testing.expect(t, !wheld, "full assignee: no other agent is granted")
	insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
	testing.expectf(t, len(insts) == 3, "capacity 1: no second instance for X (got %d instances)", len(insts))
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", "another agent cannot pull X's task")

	confirm_holder(fx, "inst_x")
	gen := s2_gen(fx, "inst_x")
	wake_log_reset(wlog)
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_x"), Submit_Input{summary = "s", vcs_json = GREEN_VCS})
	if !testing.expectf(t, sok, "submit: %s", serr.message) do return
	testing.expect_value(t, get_task(fx, "task_a").state, domain.Task_State.Done)
	// Done ends task_a's process: task_b starts a new one on the same instance
	// (a relaunch, not a nudge of the old generation).
	testing.expect(t, wake_log_has_run(wlog, "inst_x"), "X is launched for task_b")
	next, nheld := lease_of(fx, "inst_x")
	testing.expect(t, nheld && string(next.task_id) == "task_b" && next.kind == domain.LEASE_KIND_WORK, "X's next task goes to the same instance")
	testing.expectf(t, s2_gen(fx, "inst_x") == gen + 1, "the next task has a higher run_count (%d -> %d)", gen, s2_gen(fx, "inst_x"))
	_, wheld = lease_of(fx, "inst_w1")
	testing.expect(t, !wheld, "W is still never granted X's task")
}

// ---- 14.5 read counts for the whole `review post` verb -------------------------
// The SCHED-1a test measures the stop helpers. This one counts every read of
// `review post` (both verdicts) on a 10-task and a 1,000-task chain.

@(private = "file", thread_local)
s2_reads: int
@(private = "file", thread_local)
s2_repo_orig: iface.Taskchain_Repository
@(private = "file", thread_local)
s2_agents_orig: iface.Agent_Repository

@(private = "file")
s2_install_read_counter :: proc(fx: ^Fixture) {
	s2_repo_orig = fx.repo
	s2_agents_orig = fx.agents
	fx.repo.get_task = proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.get_task(ctx, id) }
	fx.repo.get_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.get_chain(ctx, id) }
	fx.repo.list_tasks_by_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.list_tasks_by_chain(ctx, id, owner) }
	fx.repo.list_reviews_by_task = proc(ctx: rawptr, id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Review, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.list_reviews_by_task(ctx, id, owner) }
	fx.repo.list_attempts_by_task = proc(ctx: rawptr, id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Attempt, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.list_attempts_by_task(ctx, id, owner) }
	fx.repo.list_events_by_task = proc(ctx: rawptr, id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.list_events_by_task(ctx, id, owner) }
	fx.repo.list_leases_by_task = proc(ctx: rawptr, id: domain.Task_ID) -> ([]domain.Task_Lease, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.list_leases_by_task(ctx, id) }
	fx.repo.get_lease_by_holder = proc(ctx: rawptr, id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.get_lease_by_holder(ctx, id) }
	fx.repo.list_fleets_by_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Fleet, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.list_fleets_by_chain(ctx, id, owner) }
	fx.repo.list_members_by_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) { s2_reads += 1; return s2_repo_orig.list_members_by_chain(ctx, id, owner) }
	fx.agents.get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) { s2_reads += 1; return s2_agents_orig.get_instance(ctx, id) }
	fx.agents.list_instances_by_chain = proc(ctx: rawptr, owner: domain.User_ID, chain_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) { s2_reads += 1; return s2_agents_orig.list_instances_by_chain(ctx, owner, chain_id) }
}

@(private = "file")
s2_uninstall_read_counter :: proc(fx: ^Fixture) {
	fx.repo = s2_repo_orig
	fx.agents = s2_agents_orig
}

Review_Post_Reads :: struct { request_changes, approve: int }

// s2_measure_review_post: task_x in review with two reviewers; `filler`
// cancelled tasks, each with an attempt and a review. Counts the reads of
// r1's request-changes, and after the resubmit, of r1's and r2's approvals.
@(private = "file")
s2_measure_review_post :: proc(t: ^testing.T, filler: int) -> (out: Review_Post_Reads, ok: bool) {
	tag := fmt.tprintf("s2_rp_reads_%d", filler)
	fx, wlog, fok := lease_fixture(t, tag)
	defer lease_fixture_close(fx, wlog)
	if !fok do return {}, false
	chain := seed_live_chain(t, fx, fmt.tprintf("chain_%s", tag))
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w", idle_ttl = 120)
	seed_fleet(fx, chain, "agt_r", idle_ttl = 120)
	seed_fleet(fx, chain, "agt_r2", idle_ttl = 120)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	brief := `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r","agt_r2"]}`
	_ = publish_task(t, fx, chain, "task_x", brief = brief)
	now := platform.clock_now(&fx.clock)
	for i in 0 ..< filler {
		id := fmt.tprintf("task_fill_%04d", i)
		task := seed_task(t, fx, chain, id, brief)
		task.state = .Cancelled
		task.publish_state = .Published
		task.attempt_no = 1
		_, _, _ = iface.taskchain_save_task(&fx.repo, task)
		_, _, _ = iface.taskchain_save_attempt(&fx.repo, domain.Task_Attempt{task_id = task.task_id, attempt_no = 1, chain_id = chain.chain_id, owner_user_id = "u1", started_at = now, ended_at = now, holder_instance_id = "inst_w1"})
		_, _, _ = iface.taskchain_save_review(&fx.repo, domain.Task_Review{task_id = task.task_id, chain_id = chain.chain_id, owner_user_id = "u1", attempt_no = 1, role = domain.REVIEW_ROLE_AGENT, reviewer_kind = "agent", reviewer_agent_id = "agt_r", reviewer_instance_id = "inst_r1", verdict = "approve", findings_json = "[]", created_at = now})
	}
	submit_x :: proc(t: ^testing.T, fx: ^Fixture) -> bool {
		confirm_holder(fx, "inst_w1")
		_, ok, err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "s", vcs_json = GREEN_VCS})
		return testing.expectf(t, ok, "submit: %s", err.message)
	}
	post :: proc(t: ^testing.T, fx: ^Fixture, inst, verdict: string) -> (int, bool) {
		confirm_holder(fx, inst)
		findings := S2_CHANGES if verdict == "request_changes" else "[]"
		s2_install_read_counter(fx)
		s2_reads = 0
		_, ok, err := review_post(&fx.svc, inst_auth(inst), Review_Input{verdict = verdict, findings_json = findings})
		reads := s2_reads
		s2_uninstall_read_counter(fx)
		return reads, testing.expectf(t, ok, "%s by %s: %s", verdict, inst, err.message)
	}
	if !submit_x(t, fx) do return {}, false
	rc, rok := post(t, fx, "inst_r1", "request_changes")
	if !rok do return {}, false
	out.request_changes = rc
	if !submit_x(t, fx) do return {}, false
	a1, a1ok := post(t, fx, "inst_r1", "approve")
	if !a1ok do return {}, false
	a2, a2ok := post(t, fx, "inst_r2", "approve")
	if !a2ok do return {}, false
	out.approve = a1 + a2
	testing.expect_value(t, get_task(fx, "task_x").state, domain.Task_State.Done)
	return out, true
}

@(test)
test_sched2_review_post_reads_do_not_grow_with_chain_size :: proc(t: ^testing.T) {
	small, sok := s2_measure_review_post(t, 10)
	large, lok := s2_measure_review_post(t, 1000)
	if !testing.expect(t, sok && lok, "both measurements ran") do return
	log.infof("review post reads: 10 tasks %v, 1000 tasks %v", small, large)
	testing.expectf(t, small.request_changes > 0 && small.approve > 0, "reads counted: %v", small)
	testing.expectf(t, small == large, "review post reads independent of chain size: 10 tasks %v, 1000 tasks %v", small, large)
}
