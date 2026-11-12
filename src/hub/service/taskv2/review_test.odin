package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Tests added for the M0/M1 review should-fix list (S1–S10).

// S1: the budget counts attempts whatever ended them — five blocks park the
// task for a human, and a grant beyond the budget is refused outright.
@(test)
test_budget_enforced_on_blocks_and_at_grant :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s1_budget")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_budget")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","review_roles":[],"budget":{"max_attempts":3}}`)
	testing.expect_value(t, task.state, domain.Task_State.In_Progress)
	for round in 1..=3 {
		lease, held := lease_of(fx, "inst_w1")
		if !testing.expect(t, held, fmt.tprintf("round %d leased", round)) do return
		testing.expect_value(t, lease.attempt_no, round)
		// block → backlog (blocked_on an external thing), then `answered` makes it ready again
		u, _, _ := begin_uow(&fx.svc)
		_, rok, _ := release_in_uow(&fx.svc, &u, lease, Actor{kind = ACTOR_AGENT, id = "inst_w1"}, EV_BLOCKED, fmt.tprintf(`{{"lease_id":"%s","attempt_no":%d,"waiting_on":{{"kind":"external","reason":"api down"}}}}`, lease.lease_id, lease.attempt_no), "blocked")
		testing.expect(t, rok, "block release")
		_, _ = after_chain_change(&fx.svc, &u, chain.chain_id, "u1", .Lease_Released)
		_, _ = end_uow(&fx.svc, &u, true)
		row := get_task(fx, "task_1")
		testing.expect_value(t, row.state, domain.Task_State.Backlog)
		if round < 3 {
			testing.expect(t, strings.contains(row.blocked_on_json, "api down"), "agent block badge")
			u2, _, _ := begin_uow(&fx.svc)
			_, _, _, _ = record_event(&fx.svc, &u2, row, hub_actor(), EV_ANSWERED, "{}")
			_, _ = after_chain_change(&fx.svc, &u2, chain.chain_id, "u1", .Task_Updated)
			_, _ = end_uow(&fx.svc, &u2, true)
			testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Progress) // re-granted, next attempt
		}
	}
	parked := get_task(fx, "task_1")
	testing.expect(t, strings.contains(parked.blocked_on_json, "budget_exhausted"), "third block exhausts a budget of 3")
	// even after an `answered`, a direct grant is refused: the budget is spent
	u3, _, _ := begin_uow(&fx.svc)
	_, _, _, _ = record_event(&fx.svc, &u3, parked, hub_actor(), EV_ANSWERED, "{}")
	_, _ = end_uow(&fx.svc, &u3, true)
	ready := get_task(fx, "task_1")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	u4, _, _ := begin_uow(&fx.svc)
	forced := ready
	forced.state = .Ready
	_, gok, gerr := grant_in_uow(&fx.svc, &u4, Grant_Request{chain = chain, task = forced, instance = inst, kind = domain.LEASE_KIND_WORK, placement = Placement{bridge_id = "br_1"}, actor = hub_actor()})
	_, _ = end_uow(&fx.svc, &u4, false)
	testing.expect(t, !gok && gerr.code == .Conflict && strings.contains(gerr.message, "budget"), "grant refused beyond the budget")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	counting := 0
	for a in attempts do if a.counts_toward_budget do counting += 1
	testing.expect(t, counting <= 3, "never more counting attempt rows than the budget")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "budget")
}

// S10: timer-vs-verb race — a TTL/hard-cap fire after the lease was released
// is a pure no-op (no event, no state change).
@(test)
test_timer_fire_after_release_is_noop :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s10_race")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_race")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	submit_via_release(t, fx, lease)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	events_before := count_events(fx, "task_1", EV_LEASE_EXPIRED)
	fixture_advance(fx, LEASE_HARD_CAP_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), events_before)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	// a stale expire call for the released lease is Gone, not Failed
	u, _, _ := begin_uow(&fx.svc)
	testing.expect_value(t, expire_lease_in_uow(&fx.svc, &u, lease, EXPIRE_TTL, hub_actor()), Expire_Result.Gone)
	_, _ = end_uow(&fx.svc, &u, false)
}

// Elapsed time cannot replace an assignment or create a recent-expiry lockout.
@(test)
test_lease_next_after_elapsed_time_returns_same_assignment :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s10_next")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s10_next")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return

	fixture_advance(fx, LEASE_HARD_CAP_SECONDS * 3)
	wake_log_reset(log)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "current" && res.lease.lease_id == lease.lease_id, "same durable assignment after elapsed time")
	testing.expect_value(t, res.lease.attempt_no, lease.attempt_no)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_BLOCKED), 0)
	testing.expect_value(t, len(log.cmds), 0)
	submit_via_release(t, fx, lease)
	res2, ok2, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{})
	testing.expect(t, ok2 && res2.status == "none", "completion clears assignment without recent-expiry lockout")
}

@(test)
test_matcher_double_grant_409 :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s10_double")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_dbl")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	w2 := seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1")
	testing.expect_value(t, task.state, domain.Task_State.In_Progress)
	stale := task
	stale.state = .Ready // a stale snapshot that still says ready
	u, _, _ := begin_uow(&fx.svc)
	_, gok, gerr := grant_in_uow(&fx.svc, &u, Grant_Request{chain = chain, task = stale, instance = w2, kind = domain.LEASE_KIND_WORK, placement = Placement{bridge_id = "br_1"}, actor = hub_actor()})
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect(t, !gok && gerr.code == .Conflict, "one work lease per task (unique index) → 409")
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	testing.expect_value(t, len(leases), 1)
	// same holder twice → 409 before the DB
	w1, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	original, _ := lease_of(fx, "inst_w1")
	t2 := publish_task(t, fx, chain, "task_2", bridge_pin = "br_1")
	_ = t2
	u2, _, _ := begin_uow(&fx.svc)
	stale2 := get_task(fx, "task_2")
	stale2.state = .Ready
	_, gok2, gerr2 := grant_in_uow(&fx.svc, &u2, Grant_Request{chain = chain, task = stale2, instance = w1, kind = domain.LEASE_KIND_WORK, placement = Placement{bridge_id = "br_1"}, actor = hub_actor()})
	_, _ = end_uow(&fx.svc, &u2, false)
	testing.expect(t, !gok2 && gerr2.code == .Conflict, "holder uniqueness → 409")
	after, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && after.lease_id == original.lease_id && after.task_id == task.task_id, "conflicting grant preserves the original assignment")
}

// S4: Idle_TTL honours "deadline moved": a release → re-grant → release
// sequence must not stop the instance at the FIRST release's deadline.
@(test)
test_idle_ttl_noop_when_release_time_moved :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s4_idle")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_idle2")
	seed_fleet(fx, chain, "agt_w", idle_ttl = 600)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	l1, _ := lease_of(fx, "inst_w1")
	submit_via_release(t, fx, l1) // T0: idle_since = T0, timer @ T0+600
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, inst.idle_since != "", "idle_since stamped on release")
	fixture_advance(fx, 100)
	_ = publish_task(t, fx, chain, "task_2") // re-granted at T0+100
	inst2, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, inst2.idle_since == "", "idle_since cleared on grant")
	fixture_advance(fx, 400)
	l2, held2 := lease_of(fx, "inst_w1")
	if !testing.expect(t, held2, "second lease") do return
	submit_via_release(t, fx, l2) // T0+500: idle_since moves, timer @ T0+1100
	wake_log_reset(log)
	fixture_advance(fx, 101) // T0+601: the FIRST timer fires
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "stale idle_ttl is a no-op")
	fixture_advance(fx, 500) // T0+1101
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "current idle_ttl stops the stranded instance")
	// boot rebuilds Idle_TTL from idle_since
	fx.svc.timers = Timer_Service{}
	rebuild_timers(&fx.svc)
	testing.expect(t, timers_armed_count(&fx.svc) >= 1, "idle_ttl re-armed from the column")
}

// Runtime activity does not renew ownership; explicit progress remains auditable.
@(test)
test_implicit_activity_does_not_renew_assignment :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s3_activity")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s3_activity")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return

	armed := timers_armed_count(&fx.svc)
	for _ in 0..<3 {
		fixture_advance(fx, IMPLICIT_HEARTBEAT_MIN_SECONDS + 1)
		touch_instance(&fx.svc, "inst_w1")
		on_instance_activity(&fx.svc, "inst_w1", "idle")
		on_instance_activity(&fx.svc, "inst_w1", "busy")
	}
	after, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && after.lease_id == lease.lease_id, "activity preserves assignment")
	testing.expect_value(t, after.last_beat_at, lease.last_beat_at)
	testing.expect_value(t, timers_armed_count(&fx.svc), armed)
	_, hok, _ := lease_heartbeat(&fx.svc, inst_auth("inst_w1"), Lease_Heartbeat_Input{note = "progress"})
	testing.expect(t, hok, "explicit progress note accepted")
	testing.expect_value(t, count_events(fx, "task_1", EV_HEARTBEAT), 1)
}

@(test)
test_clock_jumps_do_not_expire_or_extend_assignment :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s5_jump")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s5_jump")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return

	for jump in ([]bool{false, true, true}) {
		fixture_advance(fx, LEASE_HARD_CAP_SECONDS * 2)
		_ = fire_due(&fx.svc, now_ms(&fx.clock), jump_detected = jump)
		after, still := lease_of(fx, "inst_w1")
		testing.expect(t, still && after.lease_id == lease.lease_id, "clock jump preserves same assignment")
		testing.expect_value(t, after.extended_at, "")
	}
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXTENDED), 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 0)
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, lease.attempt_no)
}

@(test)
test_hello_stop_scope_bridge_and_fleet_only :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s8_hello")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_scope")
	seed_bridge(fx, "br_2")
	seed_agent(fx, "agt_chat")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")   // fleet worker, lease-less → stopped
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_2", "running")   // other bridge → untouched
	seed_instance(fx, chain, "inst_chat", "agt_chat", "br_1", "running") // member without a fleet row → untouched
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_coord", "inst_w1", "inst_w2", "inst_chat"})
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "lease-less fleet worker on br_1 stopped")
	testing.expect(t, !wake_log_has_stop(log, "inst_w2"), "other bridge's instance untouched")
	testing.expect(t, !wake_log_has_stop(log, "inst_chat"), "human-chat member untouched")
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "coordinator untouched")
	// a completed chain's workers are not touched either
	wake_log_reset(log)
	chain, _, _ = iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	saved, save_err := iface.taskchain_complete_work_chain(&fx.repo, chain.chain_id, chain.owner_user_id, chain.work_revision, "No work remains in this fixture", platform.clock_now(&fx.clock))
	if !testing.expect(t, saved, save_err.message) do return
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_w1"})
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "closed chain: nothing stopped")
}

// S7: a nested unit of work (engine called while the caller owns the
// transaction) flushes its wakes only after the OUTER commit.
@(test)
test_nested_uow_effects_flush_after_outer_commit :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "s7_nested")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_nested")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	wake_log_reset(log)
	// outer transaction owned by "the card service"
	outer, ook, _ := iface.unit_of_work_begin(&fx.uow)
	if !testing.expect(t, ook, "outer begin") do return
	err := cancel_task(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_USER, id = "u1"}, "nested")
	testing.expect(t, err.code == .None, "nested cancel ok")
	testing.expect_value(t, len(log.cmds), 0) // nothing sent under the outer lock
	committed, _ := iface.unit_of_work_commit(&outer)
	testing.expect(t, committed, "outer commit")
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "stop[] flushed after the outer commit")
	// Revocation requests a generation-fenced stop. Confirm the process exited
	// before reusing the same instance for the rollback half of this test.
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	confirm_pending_ownership_stop_for_test(t, fx, get_task(fx, "task_1"), "inst_w1")
	testing.expect(t, !ownership_cleanup_pending(&fx.svc, get_task(fx, "task_1")), "old process stop confirmed")
	inst.runtime_status = "idle"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	// a rolled-back outer transaction drops the nested effects
	wake_log_reset(log)
	_ = publish_task(t, fx, chain, "task_2")
	confirm_holder(fx, "inst_w1")
	wake_log_reset(log)
	outer2, _, _ := iface.unit_of_work_begin(&fx.uow)
	_ = cancel_task(&fx.svc, get_task(fx, "task_2"), Actor{kind = ACTOR_USER, id = "u1"}, "nested-rollback")
	iface.unit_of_work_rollback(&outer2)
	testing.expect_value(t, len(log.cmds), 0)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.In_Progress)
}
