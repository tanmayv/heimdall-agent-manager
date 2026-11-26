package taskv2

// SCHED-1b: reuse, cross-bridge capacity and the chain cap (spec SCHED 7.4,
// 9 and 14.4; REQ-SCHED-30..35, 37). REQ-SCHED-36 was dropped (user decision
// #4), so there is no per-agent stall test.

import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
CHANGES :: `[{"path":"a.odin","line":1,"severity":"major","text":"fix"}]`

@(private = "file")
brief_for :: proc(assignee: string, reviewers := `"agt_q"`) -> string {
	return fmt.tprintf(`{{"goal":"g","acceptance":["a"],"assignee":"%s","reviewers":[%s]}}`, assignee, reviewers)
}

@(private = "file")
set_caps :: proc(fx: ^Fixture, chain: ^domain.Task_Chain, m, r: int) {
	c, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	c.max_parallel = m
	c.review_reserve = r
	_, _, _ = iface.taskchain_save_chain(&fx.repo, c)
	chain^ = c
}

@(private = "file")
seed_worker :: proc(fx: ^Fixture, chain: domain.Task_Chain, inst, agent_id: string, bridge := "br_1", status := "stopped", capacity := 1) {
	seed_agent(fx, agent_id)
	seed_fleet(fx, chain, agent_id, capacity = capacity)
	seed_instance(fx, chain, inst, agent_id, bridge, status)
}

@(private = "file")
submit :: proc(t: ^testing.T, fx: ^Fixture, inst: string) -> bool {
	confirm_holder(fx, inst)
	_, ok, err := lease_submit(&fx.svc, inst_auth(inst), Submit_Input{summary = "s", vcs_json = `{"head":"h","dirty":false}`})
	return testing.expectf(t, ok, "submit by %s: %s", inst, err.message)
}

@(private = "file")
review :: proc(t: ^testing.T, fx: ^Fixture, inst, verdict: string) -> bool {
	confirm_holder(fx, inst)
	findings := CHANGES if verdict == "request_changes" else "[]"
	_, ok, err := review_post(&fx.svc, inst_auth(inst), Review_Input{verdict = verdict, findings_json = findings})
	return testing.expectf(t, ok, "%s by %s: %s", verdict, inst, err.message)
}

@(private = "file")
holds :: proc(fx: ^Fixture, inst, kind, task_id: string) -> bool {
	l, ok := lease_of(fx, inst)
	return ok && l.kind == kind && string(l.task_id) == task_id && l.phase == domain.LEASE_PHASE_ACTIVE
}

@(private = "file")
task_has_lease :: proc(fx: ^Fixture, task_id, kind: string) -> bool {
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, domain.Task_ID(task_id))
	for l in leases do if l.kind == kind && l.phase == domain.LEASE_PHASE_ACTIVE do return true
	return false
}

@(private = "file")
slots_now :: proc(fx: ^Fixture, chain: domain.Task_Chain) -> Chain_Slots {
	c, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	ctx, ok, _ := load_match_context(&fx.svc, c)
	if !ok do return {}
	defer destroy_match_context(&ctx)
	return chain_slots(&fx.svc, &ctx, nil)
}

// deadlock_setup: the 9.3 scenario. Workers inst_a..inst_d (one agent each)
// and reviewer inst_q (agt_q) are stopped fleet instances on br_1, capacity 1.
@(private = "file")
deadlock_setup :: proc(t: ^testing.T, fx: ^Fixture, tag: string) -> domain.Task_Chain {
	chain := seed_live_chain(t, fx, fmt.tprintf("chain_%s", tag))
	for x in ([]string{"a", "b", "c", "d"}) do seed_worker(fx, chain, fmt.tprintf("inst_%s", x), fmt.tprintf("agt_w%s", x))
	seed_worker(fx, chain, "inst_q", "agt_q")
	set_caps(fx, &chain, 3, 1)
	for x in ([]string{"a", "b", "c", "d"}) do _ = publish_task(t, fx, chain, fmt.tprintf("task_%s", x), brief = brief_for(fmt.tprintf("agt_w%s", x)))
	return chain
}

// Deadlock test (spec 9.3 / 14.4, decision 12): M = 3, r = 1, four tasks with
// different assignees and one reviewer agent Q (capacity 1). The third work
// grant is refused while a review slot is reserved; the owed review takes the
// reserved slot; all four tasks complete.
@(test)
test_sched1b_deadlock_reserve_lets_all_tasks_complete :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_dl")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := deadlock_setup(t, fx, "s1b_dl")

	// Step 1: A and B granted; C refused (W + 1 = 3 > M - r = 2); D refused.
	testing.expect(t, holds(fx, "inst_a", domain.LEASE_KIND_WORK, "task_a"), "A granted")
	testing.expect(t, holds(fx, "inst_b", domain.LEASE_KIND_WORK, "task_b"), "B granted")
	testing.expect(t, !task_has_lease(fx, "task_c", domain.LEASE_KIND_WORK), "C refused by the work limit")
	testing.expect(t, !task_has_lease(fx, "task_d", domain.LEASE_KIND_WORK), "D refused by the work limit")

	// Steps 2-3: A and B in review; Q reviews A; the cap is full; B's review
	// waits for Q (capacity 1); C is still refused.
	if !submit(t, fx, "inst_a") do return
	testing.expect(t, holds(fx, "inst_q", domain.LEASE_KIND_REVIEW, "task_a"), "review of A granted to Q")
	if !submit(t, fx, "inst_b") do return
	testing.expect(t, !task_has_lease(fx, "task_b", domain.LEASE_KIND_REVIEW), "review of B waits for Q")
	testing.expect(t, !task_has_lease(fx, "task_c", domain.LEASE_KIND_WORK), "C still refused while two workers are in review")
	s := slots_now(fx, chain)
	testing.expectf(t, s.work == 2 && s.review == 1 && s.grace == 0, "W=2 R=1 G=0 (got %v)", s)

	// Steps 4-5: Q approves A → A done; the review of B and then C are placed.
	if !review(t, fx, "inst_q", "approve") do return
	testing.expect_value(t, get_task(fx, "task_a").state, domain.Task_State.Done)
	testing.expect(t, holds(fx, "inst_q", domain.LEASE_KIND_REVIEW, "task_b"), "review of B placed first (REQ-SCHED-35)")
	testing.expect(t, holds(fx, "inst_c", domain.LEASE_KIND_WORK, "task_c"), "C placed in the freed work slot")
	testing.expect(t, !task_has_lease(fx, "task_d", domain.LEASE_KIND_WORK), "D still refused")

	// Step 6: Q approves B → B done; D granted.
	if !review(t, fx, "inst_q", "approve") do return
	testing.expect_value(t, get_task(fx, "task_b").state, domain.Task_State.Done)
	testing.expect(t, holds(fx, "inst_d", domain.LEASE_KIND_WORK, "task_d"), "D granted")

	// The rest completes.
	if !submit(t, fx, "inst_c") do return
	if !submit(t, fx, "inst_d") do return
	if !review(t, fx, "inst_q", "approve") do return
	if !review(t, fx, "inst_q", "approve") do return
	for x in ([]string{"a", "b", "c", "d"}) {
		testing.expectf(t, get_task(fx, fmt.tprintf("task_%s", x)).state == .Done, "task_%s done", x)
	}
}

// The same scenario without the reserve (r forced to 0 through the test hook)
// stalls: three workers fill the cap and no review can ever start. This shows
// the deadlock test above detects the deadlock.
@(test)
test_sched1b_deadlock_without_reserve_stalls :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_dl0")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain_cap_reserve_forced_zero = true
	defer chain_cap_reserve_forced_zero = false
	_ = deadlock_setup(t, fx, "s1b_dl0")
	testing.expect(t, holds(fx, "inst_c", domain.LEASE_KIND_WORK, "task_c"), "without the reserve a third work lease is granted")
	testing.expect(t, !task_has_lease(fx, "task_d", domain.LEASE_KIND_WORK), "D refused (W = M)")
	for x in ([]string{"a", "b", "c"}) do if !submit(t, fx, fmt.tprintf("inst_%s", x)) do return
	for x in ([]string{"a", "b", "c"}) {
		task_id := fmt.tprintf("task_%s", x)
		testing.expectf(t, get_task(fx, task_id).state == .In_Review, "%s in review", task_id)
		testing.expectf(t, !task_has_lease(fx, task_id, domain.LEASE_KIND_REVIEW), "%s: no review can start", task_id)
	}
	_, qheld := lease_of(fx, "inst_q")
	testing.expect(t, !qheld, "the reviewer never gets a lease: the chain is deadlocked")
}

// Grace yield (14.4): the cap is full with one grace reviewer; a review for
// another agent stops it and is placed.
@(test)
test_sched1b_review_takes_slot_of_grace_instance :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_gy")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_gy")
	seed_worker(fx, chain, "inst_w1", "agt_w1")
	seed_worker(fx, chain, "inst_w2", "agt_w2")
	seed_worker(fx, chain, "inst_r1", "agt_r1")
	seed_worker(fx, chain, "inst_r2", "agt_r2")
	set_caps(fx, &chain, 3, 1)
	_ = publish_task(t, fx, chain, "task_1", brief = brief_for("agt_w1", `"agt_r1"`))
	_ = publish_task(t, fx, chain, "task_2", brief = brief_for("agt_w2", `"agt_r2"`))
	if !submit(t, fx, "inst_w1") do return
	testing.expect(t, holds(fx, "inst_r1", domain.LEASE_KIND_REVIEW, "task_1"), "r1 reviews task_1")
	if !review(t, fx, "inst_r1", "request_changes") do return
	s := slots_now(fx, chain)
	testing.expectf(t, s.work == 2 && s.review == 0 && s.grace == 1, "W=2 R=0 G=1 after request-changes (got %v)", s)
	wake_log_reset(log)
	if !submit(t, fx, "inst_w2") do return
	testing.expect(t, holds(fx, "inst_r2", domain.LEASE_KIND_REVIEW, "task_2"), "the pending review of another agent is placed")
	testing.expect(t, wake_log_has_stop(log, "inst_r1"), "the grace instance yields its slot")
	r1, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	testing.expect_value(t, r1.stop_reason, STOP_REASON_CAPACITY_YIELD)
}

// Warm re-review at the cap (14.4): M = 3, r = 1, W = 2 and Q in its grace
// window (G = 1). The resubmitted task's review goes to Q's grace instance at
// once: same run_count, no stop, and the counts become W = 2, R = 1, G = 0.
@(test)
test_sched1b_warm_rereview_at_cap_is_net_zero :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_wr")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_wr")
	seed_worker(fx, chain, "inst_w1", "agt_w1")
	seed_worker(fx, chain, "inst_w2", "agt_w2")
	// Q's process is running (the fixture has no bridge runtime report to
	// move a launched instance out of `launching`; see SCHED-1a row 8).
	seed_worker(fx, chain, "inst_q", "agt_q", status = "idle")
	set_caps(fx, &chain, 3, 1)
	_ = publish_task(t, fx, chain, "task_1", brief = brief_for("agt_w1"))
	_ = publish_task(t, fx, chain, "task_2", brief = brief_for("agt_w2", `"user"`))
	if !submit(t, fx, "inst_w2") do return
	if !submit(t, fx, "inst_w1") do return
	if !review(t, fx, "inst_q", "request_changes") do return
	s := slots_now(fx, chain)
	testing.expectf(t, s.work == 2 && s.review == 0 && s.grace == 1, "W=2 R=0 G=1 (got %v)", s)
	q_gen := s1b_run_count(fx, "inst_q")
	wake_log_reset(log)
	if !submit(t, fx, "inst_w1") do return
	testing.expect(t, holds(fx, "inst_q", domain.LEASE_KIND_REVIEW, "task_1"), "re-review granted to Q's grace instance")
	testing.expect_value(t, s1b_run_count(fx, "inst_q"), q_gen)
	testing.expect(t, !wake_log_has_stop(log, "inst_q"), "Q is not stopped")
	s = slots_now(fx, chain)
	testing.expectf(t, s.work == 2 && s.review == 1 && s.grace == 0, "W=2 R=1 G=0 (got %v)", s)
}

@(private = "file")
s1b_run_count :: proc(fx: ^Fixture, inst: string) -> int {
	cur, _, _ := iface.agent_get_instance(&fx.agents, inst)
	return cur.run_count
}

// Rework at the work limit (14.4): with W = M - r, re-activating a waiting
// work claim after request-changes is granted (W unchanged), while a new work
// lease is refused.
@(test)
test_sched1b_rework_allowed_at_work_limit_new_work_refused :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_rw")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_rw")
	seed_worker(fx, chain, "inst_w1", "agt_w1")
	seed_worker(fx, chain, "inst_w2", "agt_w2")
	seed_worker(fx, chain, "inst_w3", "agt_w3")
	seed_worker(fx, chain, "inst_q", "agt_q")
	set_caps(fx, &chain, 3, 1)
	_ = publish_task(t, fx, chain, "task_1", brief = brief_for("agt_w1"))
	_ = publish_task(t, fx, chain, "task_2", brief = brief_for("agt_w2", `"user"`))
	_ = publish_task(t, fx, chain, "task_3", brief = brief_for("agt_w3"))
	testing.expect(t, !task_has_lease(fx, "task_3", domain.LEASE_KIND_WORK), "third work lease refused")
	if !submit(t, fx, "inst_w2") do return
	if !submit(t, fx, "inst_w1") do return
	if !review(t, fx, "inst_q", "request_changes") do return
	testing.expect(t, holds(fx, "inst_w1", domain.LEASE_KIND_WORK, "task_1"), "rework re-activated at the work limit")
	testing.expect(t, !task_has_lease(fx, "task_3", domain.LEASE_KIND_WORK), "new work still refused")
	testing.expect_value(t, slots_now(fx, chain).work, 2)
}

// Parked review lease (14.4, spec 12 dispatch failure): a review lease parked
// as waiting occupies no slot; its re-activation is a review grant checked
// under the cap: refused while full, granted once a slot frees.
@(test)
test_sched1b_parked_review_lease_occupies_no_slot :: proc(t: ^testing.T) {
	ctx := Match_Context{
		chain = domain.Task_Chain{chain_id = "chain_p", max_parallel = 2, review_reserve = 1},
		has_coordinator = true,
		coordinator = domain.Agent_Instance{agent_instance_id = "inst_coord", agent_id = "agt_c"},
	}
	ctx.leases = make([dynamic]domain.Task_Lease)
	ctx.instances = make([dynamic]domain.Agent_Instance)
	ctx.held = make(map[string]bool)
	defer delete(ctx.leases)
	defer delete(ctx.instances)
	defer delete(ctx.held)
	fleets := []domain.Task_Chain_Fleet{{agent_id = "agt_w"}, {agent_id = "agt_r"}, {agent_id = "agt_g"}}
	ctx.fleets = fleets
	append(&ctx.leases, domain.Task_Lease{task_id = "task_1", holder_instance_id = "inst_w", kind = domain.LEASE_KIND_WORK, phase = domain.LEASE_PHASE_ACTIVE})
	append(&ctx.leases, domain.Task_Lease{task_id = "task_2", holder_instance_id = "inst_r", kind = domain.LEASE_KIND_REVIEW, phase = domain.LEASE_PHASE_WAITING})
	append(&ctx.leases, domain.Task_Lease{task_id = "task_3", holder_instance_id = "inst_coord", kind = domain.LEASE_KIND_WORK, phase = domain.LEASE_PHASE_ACTIVE})
	for l in ctx.leases do ctx.held[l.holder_instance_id] = true
	append(&ctx.instances, domain.Agent_Instance{agent_instance_id = "inst_w", agent_id = "agt_w", runtime_status = "running"})
	append(&ctx.instances, domain.Agent_Instance{agent_instance_id = "inst_r", agent_id = "agt_r", runtime_status = "stopped"})
	append(&ctx.instances, domain.Agent_Instance{agent_instance_id = "inst_g", agent_id = "agt_g", runtime_status = "running"})
	append(&ctx.instances, ctx.coordinator)

	s := chain_slots(nil, &ctx, nil)
	testing.expectf(t, s.work == 1 && s.review == 0 && s.grace == 1, "parked review and coordinator not counted (got %v)", s)
	parked := ctx.instances[1]
	testing.expect(t, !instance_slot_counted(nil, &ctx, nil, parked), "a parked review lease does not count its holder")
	task_2 := domain.Task{task_id = "task_2"}
	refusal := chain_cap_refusal(nil, &ctx, nil, parked, false, domain.LEASE_KIND_REVIEW, task_2)
	testing.expectf(t, refusal != "", "re-activation refused while the cap is full (W=1, G=1, M=2)")
	ctx.instances[2].runtime_status = "stopped" // the grace instance stops
	refusal = chain_cap_refusal(nil, &ctx, nil, parked, false, domain.LEASE_KIND_REVIEW, task_2)
	testing.expectf(t, refusal == "", "re-activation granted once a slot frees (got %q)", refusal)
	// With a grace instance to yield, the review is admitted and the victim
	// is only chosen here: the caller stops it after its grant succeeds.
	ctx.instances[2].runtime_status = "running"
	victim: domain.Agent_Instance
	refusal = chain_cap_refusal(nil, &ctx, nil, parked, false, domain.LEASE_KIND_REVIEW, task_2, &victim)
	testing.expectf(t, refusal == "" && victim.agent_instance_id == "inst_g", "review admitted by yielding inst_g (got %q, victim %q)", refusal, victim.agent_instance_id)
	testing.expect_value(t, ctx.instances[2].stop_reason, "")
	ctx.instances[2].runtime_status = "stopped"
	// The coordinator is outside the cap.
	testing.expect_value(t, chain_cap_refusal(nil, &ctx, nil, ctx.coordinator, false, domain.LEASE_KIND_WORK, domain.Task{task_id = "task_9"}), "")
	// New work needs W + 1 <= M - r = 1: refused.
	testing.expect(t, chain_cap_refusal(nil, &ctx, nil, ctx.instances[2], false, domain.LEASE_KIND_WORK, domain.Task{task_id = "task_9"}) != "", "new work refused at the work limit")
}

// Cross-bridge (14.4, REQ-SCHED-33): an agent with capacity 1 has instances on
// two bridges; with one occupied, a grant on the other bridge is refused.
@(test)
test_sched1b_capacity_counts_all_bridges :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_xb")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_xb")
	seed_bridge(fx, "br_2")
	seed_bridge(fx, "br_3")
	seed_worker(fx, chain, "inst_w1", "agt_w1", bridge = "br_1", status = "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w1", "br_2", "idle")
	seed_instance(fx, chain, "inst_w3", "agt_w1", "br_3", "stopped")
	_ = publish_task(t, fx, chain, "task_1", brief = brief_for("agt_w1", ""))
	_ = publish_task(t, fx, chain, "task_2", brief = brief_for("agt_w1", ""))
	held := 0
	for id in ([]string{"inst_w1", "inst_w2", "inst_w3"}) {
		if _, h := lease_of(fx, id); h do held += 1
	}
	testing.expect_value(t, held, 1)
	testing.expect(t, holds(fx, "inst_w1", domain.LEASE_KIND_WORK, "task_1"), "the base bridge's live instance takes task_1")
	testing.expect(t, !task_has_lease(fx, "task_2", domain.LEASE_KIND_WORK), "task_2 is refused on the other bridges")
	insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
	testing.expect_value(t, len(insts), 4) // three of agt_w1 + the coordinator: no new instance
}

// Reuse across bridges (REQ-SCHED-30/31): the only instance of the agent is
// stopped on br_2 while the base placement is br_1. It is reused on br_2 and
// no new instance is created.
@(test)
test_sched1b_reuses_stopped_instance_on_other_bridge :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_ru")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_ru")
	seed_bridge(fx, "br_2")
	seed_worker(fx, chain, "inst_w9", "agt_w9", bridge = "br_2")
	_ = publish_task(t, fx, chain, "task_1", brief = brief_for("agt_w9", ""))
	l, held := lease_of(fx, "inst_w9")
	testing.expect(t, held && l.kind == domain.LEASE_KIND_WORK, "the stopped instance on br_2 is reused")
	testing.expect_value(t, l.bridge_id, "br_2")
	insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
	testing.expect_value(t, len(insts), 2) // inst_w9 + the coordinator
}

// A task pin wins over reuse (REQ-SCHED-31): a live lease-free instance on
// br_1 would be the first choice, but the task is pinned to br_2, so the
// stopped instance there is used instead.
@(test)
test_sched1b_task_pin_wins_over_reuse :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_pin")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_pin")
	seed_bridge(fx, "br_2")
	seed_worker(fx, chain, "inst_w9", "agt_w9", bridge = "br_2", capacity = 2)
	seed_instance(fx, chain, "inst_w8", "agt_w9", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = brief_for("agt_w9", ""), bridge_pin = "br_2")
	l, held := lease_of(fx, "inst_w9")
	testing.expect(t, held && l.bridge_id == "br_2", "the pinned bridge's instance takes the task")
	_, other := lease_of(fx, "inst_w8")
	testing.expect(t, !other, "the live instance on another bridge is not used")
}

// Instance count (14.4): 5 tasks × 3 review rounds with 2 worker agents and 1
// reviewer agent. The chain's instance count equals what is needed at once
// and does not grow per round or per task.
@(test)
test_sched1b_instance_count_does_not_grow :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_ic")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_ic")
	seed_worker(fx, chain, "inst_w1", "agt_w1")
	seed_worker(fx, chain, "inst_w2", "agt_w2")
	seed_worker(fx, chain, "inst_q", "agt_q")
	tasks := []string{"task_1", "task_2", "task_3", "task_4", "task_5"}
	for id, i in tasks do _ = publish_task(t, fx, chain, id, brief = brief_for("agt_w1" if i % 2 == 0 else "agt_w2"))
	rounds := make(map[string]int, context.temp_allocator)
	for _ in 0 ..< 200 {
		progressed := false
		for inst in ([]string{"inst_w1", "inst_w2", "inst_q"}) {
			l, held := lease_of(fx, inst)
			if !held || l.phase != domain.LEASE_PHASE_ACTIVE do continue
			progressed = true
			if l.kind == domain.LEASE_KIND_WORK {
				if !submit(t, fx, inst) do return
				continue
			}
			task_id := string(l.task_id)
			verdict := "request_changes" if rounds[task_id] < 2 else "approve"
			rounds[task_id] += 1
			if !review(t, fx, inst, verdict) do return
		}
		insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
		if !testing.expectf(t, len(insts) == 4, "instance count stays 3 + coordinator (got %d)", len(insts)) do return
		if !progressed do break
	}
	for id in tasks {
		testing.expectf(t, get_task(fx, id).state == .Done, "%s done", id)
		testing.expectf(t, rounds[id] == 3, "%s had 3 review rounds (got %d)", id, rounds[id])
	}
}

// REQ-SCHED-30 (5): an agent whose only instance is Dead (terminated) gets a
// new instance under capacity instead of a Start agent card.
@(test)
test_sched1b_dead_only_agent_gets_new_instance :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1b_dead")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s1b_dead")
	seed_worker(fx, chain, "inst_dead", "agt_wd", status = "terminated")
	task := publish_task(t, fx, chain, "task_1", brief = brief_for("agt_wd", ""))
	testing.expectf(t, task.blocked_on_json == "", "no Start agent card for a Dead-only agent (got %s)", task.blocked_on_json)
	_, dead_held := lease_of(fx, "inst_dead")
	testing.expect(t, !dead_held, "the Dead instance is not reused")
	insts, _ := iface.agent_list_instances_by_chain(&fx.agents, chain.owner_user_id, string(chain.chain_id))
	fresh := ""
	for inst in insts do if inst.agent_id == "agt_wd" && inst.agent_instance_id != "inst_dead" do fresh = inst.agent_instance_id
	testing.expect(t, fresh != "", "a new instance is created for the agent")
	l, held := lease_of(fx, fresh)
	testing.expect(t, held && l.kind == domain.LEASE_KIND_WORK && string(l.task_id) == "task_1", "the new instance holds the work lease")
}
