package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// F1/B1: on a non-solo chain, an explicit requires_user_approval is satisfied
// only by the user's own verdict. A coordinator's on-behalf approval is refused,
// and a relayed review row (reviewer_instance_id set) never passes the gate.
@(test)
test_flagged_task_needs_real_user_approval_on_non_solo_chain :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "relay_flagged")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_relay_flagged")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_solo_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[],"requires_user_approval":true}`)
	testing.expect(t, !chain_is_solo(&fx.svc, chain), "non-solo chain")
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)

	_, rok, rerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{task_id = "task_1", verdict = "approve", on_behalf_of = "user"})
	testing.expect(t, !rok && rerr.code == .Forbidden && strings.contains(rerr.details_json, "user_approval_required"), "relay of an approval is refused")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)

	// A relayed row (written by an older hub, say) does not pass the gate either.
	task := get_task(fx, "task_1")
	_, _, _ = iface.taskchain_save_review(&fx.repo, domain.Task_Review{task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, attempt_no = task.attempt_no, role = "user", reviewer_kind = "user", reviewer_instance_id = "inst_coord", reviewer_agent_id = "agt_c", verdict = "approve", findings_json = "[]", created_at = platform.clock_now(&fx.clock)})
	u, _, _ := begin_uow(&fx.svc)
	res, _, _ := evaluate_gate_in_uow(&fx.svc, &u, chain, task, Actor{kind = ACTOR_COORDINATOR, id = "inst_coord"})
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect_value(t, res, Gate_Result.Waiting)
	testing.expect(t, awaits_user_review(&fx.svc, get_task(fx, "task_1")), "still the user's turn")

	// The user's own approval completes it.
	_, uok, uerr := user_review(&fx.svc, user_auth(), "task_1", Review_Input{verdict = "approve"})
	testing.expect(t, uok, uerr.message)
	testing.expect(t, get_task(fx, "task_1").state != .In_Review, "real user approval passes the gate")
}

// Relay keeps working for an unflagged task: the coordinator may still post
// the user's verdict on its behalf.
@(test)
test_relay_still_works_for_unflagged_task :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "relay_unflagged")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_relay_unflagged")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	_, rok, rerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{task_id = "task_1", verdict = "approve", on_behalf_of = "user"})
	testing.expect(t, rok, fmt.tprintf("relay on an unflagged task: %s", rerr.message))
}
