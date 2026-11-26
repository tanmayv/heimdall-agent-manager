package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// N1: [taskv2] notice relevance. Every rule has a positive test (the notice
// still goes out when it matters) and a negative test (it is suppressed when
// it does not). Rules, as in the N1 brief:
//   (a) task_id + expected state on every task notice, re-checked after commit
//   (b) coordinator_item_ready after the matcher, for the coordinator's items, once per transition
//   (c) never to the actor about its own action
//   (d) review_requested_from_user once per gate pass, never to the author coordinator
//   (e) hold_stale back-off, cap, user routing, live-lease check
//   (f) no ready_unclaimed for a task assigned to the coordinator
//   (g) no agent_not_running to the unreachable instance, no "ready" right after

Notice_Log :: struct {
	recipients: [dynamic]string,
	triggers:   [dynamic]string,
	lines:      [dynamic]string,
}

// notice_capture records every notice that survives the send-time re-check.
// The log and its strings live on the test's temp allocator.
notice_capture :: proc(fx: ^Fixture) -> ^Notice_Log {
	log := new(Notice_Log, context.temp_allocator)
	log.recipients = make([dynamic]string, context.temp_allocator)
	log.triggers = make([dynamic]string, context.temp_allocator)
	log.lines = make([dynamic]string, context.temp_allocator)
	fx.svc.notify_observer_ctx = log
	fx.svc.notify_observer = proc(ctx: rawptr, coord_id, trigger, line: string) {
		l := (^Notice_Log)(ctx)
		append(&l.recipients, strings.clone(coord_id, context.temp_allocator))
		append(&l.triggers, strings.clone(trigger, context.temp_allocator))
		append(&l.lines, strings.clone(line, context.temp_allocator))
	}
	return log
}

notice_count :: proc(log: ^Notice_Log, trigger: string, task_id := "") -> int {
	n := 0
	for tr, i in log.triggers {
		if tr != trigger do continue
		if task_id != "" && !strings.contains(log.lines[i], task_id) do continue
		n += 1
	}
	return n
}

// ---- (a) payload + send-time re-check ---------------------------------------------

@(test)
test_notice_payload_carries_task_and_expected_state :: proc(t: ^testing.T) {
	body := agent_notice_command_json("cmd_1", "inst_coord", "chain_1", "coordinator_item_ready", "[taskv2] line", "task_1", "ready")
	defer delete(body)
	testing.expect_value(t, jsonx.extract_string(body, "notice_task_id", "", true, context.temp_allocator), "task_1")
	testing.expect_value(t, jsonx.extract_string(body, "expected_state", "", true, context.temp_allocator), "ready")
	testing.expect_value(t, jsonx.extract_string(body, "type", "", true, context.temp_allocator), "notify_task_nudge")
	// The top-level task_id stays empty: the bridge's per-task debounce would
	// drop a second, different notice about the same task (N2 owns coalescing).
	testing.expect_value(t, jsonx.extract_string(body, "task_id", "x", true, context.temp_allocator), "")
	chain_scoped := agent_notice_command_json("cmd_2", "inst_coord", "chain_1", "proposal_decided", "[taskv2] line")
	defer delete(chain_scoped)
	testing.expect_value(t, jsonx.extract_string(chain_scoped, "notice_task_id", "x", true, context.temp_allocator), "")
	testing.expect_value(t, jsonx.extract_string(chain_scoped, "expected_state", "x", true, context.temp_allocator), "")
}

@(test)
test_notice_sent_while_task_state_holds :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_a_pos")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_a_pos")
	notices := notice_capture(fx)
	task := publish_task(t, fx, chain, "task_1")
	testing.expect_value(t, task.state, domain.Task_State.Ready)
	u, _, _ := begin_uow(&fx.svc)
	effect_notify_task(&fx.svc, &u, task, "ready_unclaimed", "[taskv2] ready_unclaimed: task task_1")
	effect_notify_coordinator(&fx.svc, &u, chain.chain_id, chain.owner_user_id, "proposal_decided", "[taskv2] proposal_decided: chain")
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect_value(t, notice_count(notices, "ready_unclaimed", "task_1"), 1)
	testing.expect_value(t, notice_count(notices, "proposal_decided"), 1)
}

@(test)
test_notice_dropped_when_task_left_expected_state :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_a_neg")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_a_neg")
	notices := notice_capture(fx)
	task := publish_task(t, fx, chain, "task_1")
	u, _, _ := begin_uow(&fx.svc)
	effect_notify_task(&fx.svc, &u, task, "ready_unclaimed", "[taskv2] ready_unclaimed: task task_1")
	// The same unit of work then cancels the task: by commit the notice is stale.
	_, _, rok, _ := record_event(&fx.svc, &u, task, hub_actor(), EV_CANCELLED, `{"reason":"test"}`)
	testing.expect(t, rok, "cancel")
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Cancelled)
	testing.expect_value(t, notice_count(notices, "ready_unclaimed"), 0)
}

// ---- (b) coordinator_item_ready ------------------------------------------------------------

@(test)
test_coordinator_item_ready_once_per_ready :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_b_pos")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_b_pos")
	notices := notice_capture(fx)
	_ = publish_coordinator_task(t, fx, chain, "task_1")
	_ = publish_coordinator_task(t, fx, chain, "task_2", brief = `{"goal":"g","assignee":"agt_c"}`)
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_1"), 1)
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_2"), 1)
	for r in notices.recipients do testing.expect_value(t, r, "inst_coord")
	// Re-evaluations that leave the task Ready do not repeat it.
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	testing.expect(t, task_updated(&fx.svc, get_task(fx, "task_1"), hub_actor(), []string{"title"}).code == .None, "task_updated")
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_1"), 1)
}

@(test)
test_coordinator_item_ready_suppressed_for_other_assignee :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_b_neg")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_b_neg")
	notices := notice_capture(fx)
	// Assigned to another agent: not the coordinator's task.
	_ = publish_coordinator_task(t, fx, chain, "task_other", brief = `{"goal":"g","assignee":"agt_w"}`)
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_other"), 0)
	// A worker the matcher grants in the same unit of work: claimed by commit.
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	matched := publish_coordinator_task(t, fx, chain, "task_matched", brief = `{"goal":"g","assignee":"agt_w"}`)
	_, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "the matcher grants the free worker") do return
	testing.expect(t, matched.state != .Ready, "granted task is no longer ready")
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_matched"), 0)
}

// ---- (c) never notify the actor ----------------------------------------------------

@(test)
test_actor_other_than_coordinator_still_notifies :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_c_pos")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_c_pos")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "worker holds task_1") do return
	_, bok, berr := lease_block(&fx.svc, inst_auth("inst_w1"), Block_Input{lease_id = lease.lease_id, waiting_on_json = `{"kind":"user","reason":"which API?"}`})
	if !testing.expect(t, bok, fmt.tprintf("block: %s", berr.message)) do return
	testing.expect_value(t, notice_count(notices, "blocked_on human", "task_1"), 1)
}

@(test)
test_worker_closing_last_task_tells_coordinator_batch_finished :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_c_pos2")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_c_pos2")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	sub, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok && sub.outcome == "done", fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, notice_count(notices, "work_batch_finished"), 1)
}

@(test)
test_coordinator_not_told_about_its_own_block :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_c_neg")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_c_neg")
	notices := notice_capture(fx)
	_ = publish_coordinator_task(t, fx, chain, "task_1")
	res, nok, nerr := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", fmt.tprintf("lease next: %s", nerr.message)) do return
	_, bok, berr := lease_block(&fx.svc, inst_auth("inst_coord"), Block_Input{lease_id = res.lease.lease_id, waiting_on_json = `{"kind":"user","reason":"which API?"}`})
	if !testing.expect(t, bok, fmt.tprintf("block: %s", berr.message)) do return
	testing.expect_value(t, notice_count(notices, "blocked_on human"), 0)
}

// ---- (d) review_requested_from_user ----------------------------------------------------

@(test)
test_review_requested_once_per_gate_pass :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_d_pos")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_d_pos")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	notices := notice_capture(fx)
	task := seed_task(t, fx, chain, "task_1", `{"goal":"g","assignee":"agt_w"}`)
	task.requires_user_approval = true
	task.publish_state = .Published
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	testing.expect(t, task_created(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"}).code == .None, "create")
	confirm_holder(fx, "inst_w1")
	sub, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "ready", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok && sub.outcome == "in_review", fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, notice_count(notices, "review_requested_from_user", "task_1"), 1)
	// Gate re-evaluations (fleet edit, reviewer edit) do not repeat it.
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	testing.expect(t, task_updated(&fx.svc, get_task(fx, "task_1"), hub_actor(), []string{"reviewers"}).code == .None, "task_updated")
	testing.expect_value(t, notice_count(notices, "review_requested_from_user", "task_1"), 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_USER_REVIEW_REQUESTED), 1)
}

@(test)
test_review_requested_not_sent_to_author_coordinator :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_d_neg")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_d_neg")
	notices := notice_capture(fx)
	_ = publish_coordinator_task(t, fx, chain, "task_1")
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", "lease next") do return
	sub, sok, serr := lease_submit(&fx.svc, inst_auth("inst_coord"), Submit_Input{summary = "ready", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok && sub.outcome == "in_review", fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, notice_count(notices, "review_requested_from_user"), 0)
	// The user still sees it on the attention deck.
	kind, _ := user_attention(&fx.svc, get_task(fx, "task_1"))
	testing.expect_value(t, kind, User_Attention.Review)
}

// ---- (e) hold_stale -------------------------------------------------------------------

@(test)
test_hold_stale_backs_off_and_caps_at_three :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_e_cap")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_e_cap")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	_, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_AGENT, id = "inst_coord"}, "re-plan")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	// 30 min → first; +2 h → second; +8 h → third; then nothing, ever.
	delays := [3]i64{HOLD_STALE_SECONDS, HOLD_STALE_SECONDS * HOLD_STALE_BACKOFF, HOLD_STALE_SECONDS * HOLD_STALE_BACKOFF * HOLD_STALE_BACKOFF}
	for d, i in delays {
		fixture_advance(fx, d - 2)
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
		testing.expect_value(t, notice_count(notices, "hold_stale"), i)
		fixture_advance(fx, 3)
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
		testing.expect_value(t, notice_count(notices, "hold_stale"), i + 1)
	}
	fixture_advance(fx, 100 * HOLD_STALE_SECONDS)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	// A restart rebuilds the timer; the event log still caps it.
	delete(fx.svc.timers.heap)
	fx.svc.timers = Timer_Service{}
	rebuild_timers(&fx.svc)
	fixture_advance(fx, 100 * HOLD_STALE_SECONDS)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, notice_count(notices, "hold_stale"), HOLD_STALE_MAX_REMINDERS)
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), HOLD_STALE_MAX_REMINDERS)
	for r in notices.recipients do testing.expect_value(t, r, "inst_coord")
}

@(test)
test_hold_stale_user_hold_goes_to_user_not_agent :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_e_user")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_e_user")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	_, hok, _ := task_hold(&fx.svc, get_task(fx, "task_1"), actor_from_auth(user_auth()), "my call")
	if !testing.expect(t, hok, "hold") do return
	fixture_advance(fx, HOLD_STALE_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 1)
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_HOLD_STALE), `"routed_to":"user"`), last_event_payload(fx, "task_1", EV_HOLD_STALE))
	testing.expect_value(t, notice_count(notices, "hold_stale"), 0)
}

@(test)
test_hold_stale_skipped_while_a_lease_is_live :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_e_live")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_e_live")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	_, hok, _ := task_hold(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_AGENT, id = "inst_coord"}, "wait")
	if !testing.expect(t, hok, "hold") do return
	// A live lease the fold has not (yet) marked as a checkpoint request.
	live := domain.Task_Lease{lease_id = "lease_live", task_id = "task_1", chain_id = chain.chain_id, owner_user_id = "u1", attempt_no = 1, holder_instance_id = "inst_x", kind = domain.LEASE_KIND_WORK, phase = domain.LEASE_PHASE_ACTIVE, granted_at = "2026-03-01T00:00:00Z"}
	_, sok, _ := iface.taskchain_save_lease(&fx.repo, live)
	if !testing.expect(t, sok, "save live lease") do return
	testing.expect(t, !strings.contains(get_task(fx, "task_1").blocked_on_json, "checkpoint_requested"), "hold carries no checkpoint flag")
	fixture_advance(fx, HOLD_STALE_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 0)
	testing.expect_value(t, notice_count(notices, "hold_stale"), 0)
	// Once no lease is live the reminder goes out on the next arming.
	_, _ = iface.taskchain_delete_lease(&fx.repo, "lease_live")
	arm_task_timers(&fx.svc, get_task(fx, "task_1"))
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, notice_count(notices, "hold_stale"), 1)
}

// ---- (f) ready_unclaimed ----------------------------------------------------------------

@(test)
test_ready_unclaimed_notifies_for_worker_task :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_f_pos")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_f_pos")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	fixture_advance(fx, READY_UNCLAIMED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_READY_UNCLAIMED), 1)
	testing.expect_value(t, notice_count(notices, "ready_unclaimed", "task_1"), 1)
}

@(test)
test_ready_unclaimed_skipped_for_coordinator_task :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_f_neg")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_f_neg")
	notices := notice_capture(fx)
	_ = publish_coordinator_task(t, fx, chain, "task_1")
	fixture_advance(fx, READY_UNCLAIMED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_READY_UNCLAIMED), 0)
	testing.expect_value(t, notice_count(notices, "ready_unclaimed"), 0)
}

// ---- (g) agent_not_running -----------------------------------------------------------------

@(test)
test_agent_not_running_about_a_worker_reaches_coordinator :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_g_pos")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_g_pos")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	notices := notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_w1")
	testing.expect(t, is_agent_not_running_block(get_task(fx, "task_1").blocked_on_json), "parked on agent_not_running")
	testing.expect_value(t, notice_count(notices, "agent_not_running", "task_1"), 1)
	for r in notices.recipients do testing.expect_value(t, r, "inst_coord")
}

@(test)
test_agent_not_running_not_sent_to_the_unreachable_soloist :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "n1_g_neg")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_n1_g_neg")
	notices := notice_capture(fx)
	_ = publish_coordinator_task(t, fx, chain, "task_1")
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_1"), 1)
	// The soloist's own agent cannot be started: the task parks on it.
	u, _, _ := begin_uow(&fx.svc)
	blocked := block_ready_agent_in_uow(&fx.svc, &u, get_task(fx, "task_1"), "agt_c", Placement{bridge_id = "br_1", provider = "claude", model = "claude-opus-5-5"}, "unreachable")
	_, _ = end_uow(&fx.svc, &u, blocked)
	if !testing.expect(t, is_agent_not_running_block(get_task(fx, "task_1").blocked_on_json), "parked on the soloist") do return
	testing.expect_value(t, notice_count(notices, "agent_not_running"), 0)
	// It comes back: the block clears, and no "ready for you" follows at once.
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	on_start_success(&fx.svc, coord)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
	testing.expect_value(t, notice_count(notices, "coordinator_item_ready", "task_1"), 1)
}
