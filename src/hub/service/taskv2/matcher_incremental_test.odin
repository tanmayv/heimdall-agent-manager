package taskv2

import "core:fmt"
import "core:log"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Incremental matcher cost (Scale A). The same submit → review → dependent
// grant flow runs on a 10-task chain and on a 1,000-task chain; the extra
// tasks are SQL-seeded background rows (done, backlog, ready and in_review work
// of agents the event does not touch). An event re-matches only what it can
// affect, so its reads must not grow with the background.

Event_Cost :: struct {
	calls:     []string,
	task_rows: int,
}

@(private = "file")
snapshot_cost :: proc(counter: ^Read_Counter) -> Event_Cost {
	calls := make([]string, len(counter.calls), context.temp_allocator)
	copy(calls, counter.calls[:])
	return Event_Cost{calls = calls, task_rows = counter.task_rows}
}

Incremental_Scenario :: struct {
	submit, approve: Event_Cost,
	submit_pass, approve_pass: Match_Pass,
	reviewer_granted: bool,
	dependent_granted: bool,
}

@(private = "file")
run_incremental_scenario :: proc(t: ^testing.T, tag: string, chain_tasks: int) -> (Incremental_Scenario, bool) {
	out: Incremental_Scenario
	fx, wlog, ok := lease_fixture(t, tag)
	defer lease_fixture_close(fx, wlog)
	if !ok do return out, false
	chain := seed_live_chain(t, fx, "chain_inc")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	actor := Actor{kind = ACTOR_USER, id = "u1"}
	_ = publish_task(t, fx, chain, "task_a", brief = `{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}`)
	b := seed_task(t, fx, chain, "task_b", `{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}`)
	_, dok, _ := work_dependency_add(&fx.svc, "u1", actor, chain.chain_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = "task_b"}, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = "task_a"}, reconcile = false)
	if !testing.expect(t, dok, "dependency") do return out, false
	if !testing.expect(t, task_created(&fx.svc, b, actor).code == .None, "create b") do return out, false
	confirm_holder(fx, "inst_w1")
	seed_background_tasks(t, fx, "chain_inc", "bg_", chain_tasks - 2)
	// The background agents are in the fleet and at capacity, so every
	// background item is one a full pass walks (and leaves queued).
	seed_agent(fx, "agt_x")
	seed_agent(fx, "agt_y")
	seed_fleet(fx, chain, "agt_x")
	seed_fleet(fx, chain, "agt_y")
	seed_instance(fx, chain, "inst_x1", "agt_x", "br_1", "running")
	seed_instance(fx, chain, "inst_y1", "agt_y", "br_1", "running")
	now := platform.clock_now(&fx.clock)
	for l in ([]domain.Task_Lease{
		{lease_id = "lease_bg_x", task_id = "bg_2", holder_instance_id = "inst_x1", kind = domain.LEASE_KIND_WORK},
		{lease_id = "lease_bg_y", task_id = "bg_3", holder_instance_id = "inst_y1", kind = domain.LEASE_KIND_REVIEW},
	}) {
		lease := l
		lease.chain_id, lease.owner_user_id, lease.attempt_no, lease.bridge_id = chain.chain_id, "u1", 1, "br_1"
		lease.granted_at, lease.confirmed_at, lease.last_beat_at = now, now, now
		lease.phase, lease.delivery = domain.LEASE_PHASE_ACTIVE, domain.LEASE_DELIVERY_WAKE
		if _, sok, serr := iface.taskchain_save_lease(&fx.repo, lease); !testing.expectf(t, sok, "background lease: %s", serr.message) do return out, false
	}

	// The SQL-seeded rows have no events: one full pass (as at boot) folds
	// their projections, so the measured events see a settled chain.
	if bu, bok, _ := begin_uow(&fx.svc); testing.expect(t, bok, "settle uow") {
		sok, serr := after_chain_change(&fx.svc, &bu, chain.chain_id, "u1", .Boot)
		testing.expectf(t, sok, "settle: %s", serr.message)
		_, _ = end_uow(&fx.svc, &bu, sok)
	}

	counter := new(Read_Counter, context.temp_allocator)
	read_counter_install(fx, counter)
	defer read_counter_uninstall(fx, counter)

	read_counter_reset(counter)
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expectf(t, sok, "submit: %s", serr.message) do return out, false
	out.submit = snapshot_cost(counter)
	out.submit_pass = match_last_pass
	rl, has_review := lease_of(fx, "inst_r1")
	out.reviewer_granted = has_review && rl.task_id == "task_a" && rl.kind == domain.LEASE_KIND_REVIEW
	if !out.reviewer_granted do return out, true
	confirm_holder(fx, "inst_r1")

	read_counter_reset(counter)
	_, rok, rerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	if !testing.expectf(t, rok, "approve: %s", rerr.message) do return out, false
	out.approve = snapshot_cost(counter)
	out.approve_pass = match_last_pass
	wl, has_work := lease_of(fx, "inst_w1")
	out.dependent_granted = has_work && wl.task_id == "task_b" && wl.kind == domain.LEASE_KIND_WORK
	return out, true
}

@(private = "file")
count_call :: proc(cost: Event_Cost, name: string) -> int {
	n := 0
	for c in cost.calls do if c == name do n += 1
	return n
}

@(test)
test_event_reads_do_not_grow_with_chain_tasks :: proc(t: ^testing.T) {
	small, sok := run_incremental_scenario(t, "matcher_inc_small", 10)
	if !sok do return
	large, lok := run_incremental_scenario(t, "matcher_inc_large", 1000)
	if !lok do return
	testing.expect(t, small.reviewer_granted && large.reviewer_granted, "submit grants the review")
	testing.expect(t, small.dependent_granted && large.dependent_granted, "approve unblocks and grants the dependent")
	testing.expect_value(t, large.submit_pass, Match_Pass.Incremental)
	testing.expect_value(t, large.approve_pass, Match_Pass.Incremental)
	log.infof("submit:  10 tasks %d reads (%d task rows); 1000 tasks %d reads (%d task rows)", len(small.submit.calls), small.submit.task_rows, len(large.submit.calls), large.submit.task_rows)
	log.infof("approve: 10 tasks %d reads (%d task rows); 1000 tasks %d reads (%d task rows)", len(small.approve.calls), small.approve.task_rows, len(large.approve.calls), large.approve.task_rows)
	log.infof("submit reads (1000): %v", large.submit.calls)
	log.infof("approve reads (1000): %v", large.approve.calls)
	for path in ([]string{"submit", "approve"}) {
		s := small.submit if path == "submit" else small.approve
		l := large.submit if path == "submit" else large.approve
		testing.expectf(t, len(l.calls) == len(s.calls), "%s: %d reads at 10 tasks vs %d at 1000", path, len(s.calls), len(l.calls))
		for name in ([]string{"list_reviews_by_task", "list_attempts_by_task", "list_events_by_task", "list_leases_by_task", "get_task", "agent_get_instance"}) {
			testing.expectf(t, count_call(l, name) == count_call(s, name), "%s: %s %d at 10 tasks vs %d at 1000", path, name, count_call(s, name), count_call(l, name))
		}
	}
	_ = fmt.tprintf
}

// A completed dependency makes its dependent ready; the incremental pass
// grants it although the event (the approve) never touched the dependent.
@(test)
test_incremental_dependency_unblock_grants_dependent :: proc(t: ^testing.T) {
	res, ok := run_incremental_scenario(t, "matcher_inc_dependency", 10)
	if !ok do return
	testing.expect(t, res.reviewer_granted, "submit grants the review")
	testing.expect(t, res.dependent_granted, "the dependent is granted to the freed worker")
	testing.expect_value(t, res.approve_pass, Match_Pass.Incremental)
}

// Capacity freed by an event goes to a ready task of the same agent that the
// event did not touch.
@(test)
test_incremental_freed_capacity_grants_untouched_task :: proc(t: ^testing.T) {
	fx, wlog, ok := lease_fixture(t, "matcher_inc_freed")
	defer lease_fixture_close(fx, wlog)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_inc_freed")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","assignee":"agt_w","reviewers":["user"]}`, priority = .P0)
	_ = publish_task(t, fx, chain, "task_2", brief = `{"goal":"g","assignee":"agt_w"}`)
	confirm_holder(fx, "inst_w1")
	if l, held := lease_of(fx, "inst_w1"); !testing.expect(t, held && l.task_id == "task_1", "task_1 holds the only slot") do return
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expectf(t, sok, "submit: %s", serr.message) do return
	// The waiting claim keeps the slot: task_2 still queues.
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Ready)
	_, rok, rerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{task_id = "task_1", verdict = "approve", on_behalf_of = "user"})
	if !testing.expectf(t, rok, "approve: %s", rerr.message) do return
	testing.expect_value(t, match_last_pass, Match_Pass.Incremental)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	testing.expect_value(t, count_events(fx, "task_2", EV_LEASE_GRANTED), 1)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.In_Progress)
}

// A chain cap slot is shared: work freed by one agent goes to another agent's
// queued task, which the event touched neither directly nor by agent.
@(test)
test_incremental_shared_chain_slot_grants_other_agent :: proc(t: ^testing.T) {
	fx, wlog, ok := lease_fixture(t, "matcher_inc_shared")
	defer lease_fixture_close(fx, wlog)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_inc_shared")
	c, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	c.max_parallel, c.review_reserve = 2, 1 // one work slot
	_, _, _ = iface.taskchain_save_chain(&fx.repo, c)
	seed_agent(fx, "agt_v")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_v")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_v1", "agt_v", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_w", brief = `{"goal":"g","assignee":"agt_w","reviewers":["user"]}`, priority = .P0)
	_ = publish_task(t, fx, chain, "task_v", brief = `{"goal":"g","assignee":"agt_v"}`)
	confirm_holder(fx, "inst_w1")
	if l, held := lease_of(fx, "inst_w1"); !testing.expect(t, held && l.task_id == "task_w", "task_w holds the work slot") do return
	_, held_v := lease_of(fx, "inst_v1")
	testing.expect(t, !held_v, "task_v queues behind the chain cap")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expectf(t, sok, "submit: %s", serr.message) do return
	_, rok, rerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{task_id = "task_w", verdict = "approve", on_behalf_of = "user"})
	if !testing.expectf(t, rok, "approve: %s", rerr.message) do return
	testing.expect_value(t, match_last_pass, Match_Pass.Incremental)
	l, held := lease_of(fx, "inst_v1")
	testing.expect(t, held && l.task_id == "task_v" && l.kind == domain.LEASE_KIND_WORK, "the freed chain slot goes to agt_v")
}

// Explicit recheck, the timers (Rematch) and boot keep the full pass.
@(test)
test_full_match_on_recheck_timer_and_boot :: proc(t: ^testing.T) {
	fx, wlog, ok := lease_fixture(t, "matcher_inc_full")
	defer lease_fixture_close(fx, wlog)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_inc_full")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	// Assigned to an agent without a fleet row: ready, never leased, so the
	// recheck reaches the matcher.
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","assignee":"agt_q"}`)
	testing.expect_value(t, match_last_pass, Match_Pass.Incremental)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
	_, rok, rerr := task_recheck(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_USER, id = "u1"})
	if !testing.expectf(t, rok, "recheck: %s", rerr.message) do return
	testing.expect_value(t, match_last_pass, Match_Pass.Full)
	testing.expect(t, match_trigger_is_full(.Timer) && match_trigger_is_full(.Boot) && match_trigger_is_full(.Bridge_Hello), "timers, boot and bridge hello match in full")
	testing.expect(t, !match_trigger_is_full(.Lease_Released) && !match_trigger_is_full(.Review_Posted) && !match_trigger_is_full(.Task_Created), "chain events match incrementally")
	// A chain event the scope never saw (a configuration-only change) is a full pass.
	u, uok, _ := begin_uow(&fx.svc)
	if !testing.expect(t, uok, "begin") do return
	aok, _ := after_chain_change(&fx.svc, &u, chain.chain_id, "u1", .Task_Updated)
	_, _ = end_uow(&fx.svc, &u, aok)
	testing.expect_value(t, match_last_pass, Match_Pass.Full)
}
