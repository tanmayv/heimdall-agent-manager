package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// REQ-TV2-5: task hold / release and fleet pause.

@(test)
test_hold_leased_task_handoff_parks_until_release :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_checkpoint")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	confirm_holder(fx, "inst_w1")
	l1, leased := lease_of(fx, "inst_w1")
	if !testing.expect(t, leased, "task_1 granted to inst_w1") do return
	owner := actor_from_auth(user_auth())

	// Hold while leased: the lease is kept, a checkpoint is requested.
	hr, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), owner, "repair the brief")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	testing.expect(t, hr.changed && hr.checkpoint_requested, "hold on a leased task requests a checkpoint")
	row := get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.In_Progress)
	testing.expect(t, task_is_held(row) && strings.contains(row.blocked_on_json, `"checkpoint_requested":true`), "held badge with checkpoint request")
	_, still := lease_of(fx, "inst_w1")
	testing.expect(t, still, "hold never revokes the lease")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	pack := build_pack_json(&fx.svc, chain, row, l1, inst)
	testing.expect(t, strings.contains(pack, `"checkpoint":{"reason":"repair the brief"}`), "pack carries the checkpoint request")
	// A second hold is a no-op.
	again, aok, _ := task_hold(&fx.svc, row, owner, "again")
	testing.expect(t, aok && !again.changed, "hold on a held task is a no-op")

	// The holder hands off: the task parks instead of being re-dispatched.
	_, dok, derr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "checkpointed"})
	if !testing.expect(t, dok, fmt.tprintf("handoff: %s", derr.message)) do return
	row = get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.Backlog)
	testing.expect(t, task_is_held(row) && !strings.contains(row.blocked_on_json, "checkpoint_requested"), "parked as blocked_on {kind: hold}")
	_, w1 := lease_of(fx, "inst_w1")
	_, w2 := lease_of(fx, "inst_w2")
	testing.expect(t, !w1 && !w2, "a held task gets no new lease after handoff")
	// The matcher re-running (e.g. a fleet change) still grants nothing; a
	// hold is not cleared by answer.
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	_, w1 = lease_of(fx, "inst_w1")
	_, w2 = lease_of(fx, "inst_w2")
	testing.expect(t, !w1 && !w2, "no dispatch race while held")
	_, ansok, anserr := task_answer(&fx.svc, row, owner, "")
	testing.expect(t, !ansok && anserr.code == .Conflict, "answer does not clear a hold")

	// Release: the task dispatches again as the same (handoff) attempt.
	rr, rok, rerr := task_release(&fx.svc, row, owner)
	if !testing.expect(t, rok, fmt.tprintf("release: %s", rerr.message)) do return
	testing.expect(t, rr.changed, "release changed the task")
	row = get_task(fx, "task_1")
	testing.expect(t, !task_is_held(row), "hold cleared")
	holder := ""
	if l, h := lease_of(fx, "inst_w1"); h { holder = "inst_w1"; testing.expect_value(t, l.attempt_no, 1) }
	if l, h := lease_of(fx, "inst_w2"); h { holder = "inst_w2"; testing.expect_value(t, l.attempt_no, 1) }
	testing.expect(t, holder != "", "released task is dispatched")
	testing.expect_value(t, row.state, domain.Task_State.In_Progress)

	// Releasing an unheld task is a no-op with a message.
	nr, nok, _ := task_release(&fx.svc, row, owner)
	testing.expect(t, nok && !nr.changed && strings.contains(nr.message, "not held"), "release of an unheld task is a no-op")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "hold/release")
}

@(test)
test_hold_unleased_task_never_dispatches :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_unleased")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold2")
	seed_fleet(fx, chain, "agt_w")
	task := seed_task(t, fx, chain, "task_1", `{"goal":"g","acceptance":["a"]}`)
	owner := actor_from_auth(user_auth())
	_, hok, herr := task_hold(&fx.svc, task, owner, "fix brief first")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	// Publish + a free instance: still no lease while held.
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	row := get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.Backlog)
	testing.expect(t, task_is_held(row), "held badge")
	_, leased := lease_of(fx, "inst_w1")
	testing.expect(t, !leased, "a held task is never granted")
	// Grants are refused at the source too (belt and braces).
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	u, _, _ := begin_uow(&fx.svc)
	_, gok, gerr := grant_in_uow(&fx.svc, &u, Grant_Request{chain = chain, task = row, instance = inst, kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_INLINE, placement = Placement{bridge_id = "br_1"}, actor = hub_actor()})
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect(t, !gok && strings.contains(gerr.message, "held"), "grant_in_uow refuses a held task")
	_, rok, _ := task_release(&fx.svc, row, owner)
	testing.expect(t, rok, "release")
	_, leased = lease_of(fx, "inst_w1")
	testing.expect(t, leased, "released task is dispatched")
}

@(test)
test_fleet_pause_stops_new_grants_keeps_live_work :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "fleet_pause")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_pause")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	confirm_holder(fx, "inst_w1")
	_, live := lease_of(fx, "inst_w1")
	if !testing.expect(t, live, "task_1 granted before the pause") do return

	set_paused :: proc(fx: ^Fixture, chain: domain.Task_Chain, paused: bool) {
		now := platform.clock_now(&fx.clock)
		_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = "agt_w", capacity = 2, paused = paused, created_at = now, updated_at = now})
		_ = fleet_changed(&fx.svc, chain)
	}
	set_paused(fx, chain, true)
	_ = publish_task(t, fx, chain, "task_2", brief = `{"goal":"g","acceptance":["a"]}`)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Ready)
	_, w2 := lease_of(fx, "inst_w2")
	testing.expect(t, !w2, "a paused row gets no new grant")
	_, live = lease_of(fx, "inst_w1")
	testing.expect(t, live, "the existing lease continues")
	// Pull is refused too.
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w2")
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_w2"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", fmt.tprintf("lease next while paused: %s", res.status))
	_ = inst
	// Resume dispatches the queued work.
	set_paused(fx, chain, false)
	_, w2 = lease_of(fx, "inst_w2")
	testing.expect(t, w2, "resume of the row dispatches task_2")
}

// Review holders get the checkpoint too: a hold on an in-review task nudges
// every live review lease, a review holder may hand off (no verdict, reviews
// kept), the held task gets no new review lease, and the gate does not move
// until release re-evaluates it.
@(test)
test_hold_review_lease_handoff_parks_until_release :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_review")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold_review")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r")
	seed_fleet(fx, chain, "agt_r2")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r","agt_r2"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	rl1, r1 := lease_of(fx, "inst_r1")
	_, r2 := lease_of(fx, "inst_r2")
	if !testing.expect(t, r1 && r2, "both reviewers leased") do return
	owner := actor_from_auth(user_auth())

	hr, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), owner, "fix the brief")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	testing.expect(t, hr.checkpoint_requested, "hold on a review-leased task requests a checkpoint")
	row := get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.In_Review)
	testing.expect(t, strings.contains(row.blocked_on_json, `"checkpoint_requested":true`), "checkpoint visible while review leases are live")
	inst_r1, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	pack := build_pack_json(&fx.svc, chain, row, rl1, inst_r1)
	testing.expect(t, strings.contains(pack, `"checkpoint":{"reason":"fix the brief"}`), "review pack carries the checkpoint request")

	// r1 checkpoints: lease released with no verdict, no new review lease.
	_, dok, derr := lease_handoff(&fx.svc, inst_auth("inst_r1"), Handoff_Input{summary = "half reviewed"})
	if !testing.expect(t, dok, fmt.tprintf("review handoff: %s", derr.message)) do return
	_, r1 = lease_of(fx, "inst_r1")
	testing.expect(t, !r1, "held task gets no new review lease")
	reviews, _ := iface.taskchain_list_reviews_by_task(&fx.repo, "task_1", "u1")
	testing.expect_value(t, len(reviews), 0)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)

	// r2 still finishes its review; the gate cannot advance while held.
	g2, g2ok, _ := review_post(&fx.svc, inst_auth("inst_r2"), Review_Input{verdict = "approve"})
	testing.expect(t, g2ok && g2.gate == .Waiting, "verdict recorded, gate waits")

	// Release: r1 is re-granted its owed review.
	_, rok, rerr := task_release(&fx.svc, get_task(fx, "task_1"), owner)
	if !testing.expect(t, rok, fmt.tprintf("release: %s", rerr.message)) do return
	rl1b, r1b := lease_of(fx, "inst_r1")
	testing.expect(t, r1b && rl1b.kind == domain.LEASE_KIND_REVIEW, "released task re-dispatches the owed review")
	// Off-hold, a review lease still ends only with review post.
	_, hok2, herr2 := lease_handoff(&fx.svc, inst_auth("inst_r1"), Handoff_Input{summary = "x"})
	testing.expect(t, !hok2 && herr2.code == .Conflict, "review handoff refused on an unheld task")

	// Hold again; the last approval lands while held: still in review until release.
	_, hok3, _ := task_hold(&fx.svc, get_task(fx, "task_1"), owner, "one more fix")
	testing.expect(t, hok3, "hold again")
	g1, g1ok, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	testing.expect(t, g1ok && g1.gate == .Waiting, "all approvals in, gate held")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	_, rok2, _ := task_release(&fx.svc, get_task(fx, "task_1"), owner)
	testing.expect(t, rok2, "release")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "review hold/release")
}

// Pause is one boolean per row (REQ-SCHED-2): a paused reviewer row gets no
// review lease by wake or by inline pull; resume dispatches the owed review.
@(test)
test_fleet_pause_blocks_review_grants :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "pause_review_row")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_pause_review")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", paused = true)
	now := platform.clock_now(&fx.clock)
	set_r :: proc(fx: ^Fixture, chain: domain.Task_Chain, paused: bool, now: string) {
		_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = "agt_r", capacity = 1, paused = paused, created_at = now, updated_at = now})
		_ = fleet_changed(&fx.svc, chain)
	}
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	_, rheld := lease_of(fx, "inst_r1")
	testing.expect(t, !rheld, "a paused reviewer row gets no review lease (wake)")
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_r1"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", fmt.tprintf("paused reviewer gets no inline grant: %s", res.status))
	testing.expect(t, res.refused_task_id == "task_1" && strings.contains(res.reason, "paused"), fmt.tprintf("the refusal names the task and the pause: %s %s", res.refused_task_id, res.reason))
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	set_r(fx, chain, false, now)
	rl, rheld2 := lease_of(fx, "inst_r1")
	testing.expect(t, rheld2 && rl.kind == domain.LEASE_KIND_REVIEW, "resume dispatches the owed review")
}

// A hold survives a concurrent infrastructure block (review round 2): one of
// two reviewers dies (agent_not_running stays the visible blocked_on) and the
// surviving reviewer still gets the checkpoint and may hand off; release
// clears only the hold. Covers hold after the failure and failure after hold.
@(test)
test_hold_with_infrastructure_block_keeps_checkpoint :: proc(t: ^testing.T) {
	for fail_first in ([]bool{true, false}) {
		fx, log, ok := lease_fixture(t, "hold_infra_first" if fail_first else "hold_infra_after")
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := seed_live_chain(t, fx, "chain_hold_infra")
		seed_agent(fx, "agt_r2")
		seed_fleet(fx, chain, "agt_w")
		seed_fleet(fx, chain, "agt_r")
		seed_fleet(fx, chain, "agt_r2")
		seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
		seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
		seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
		_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r","agt_r2"]}`)
		confirm_holder(fx, "inst_w1")
		_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
		if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
		rl1, r1 := lease_of(fx, "inst_r1")
		_, r2 := lease_of(fx, "inst_r2")
		if !testing.expect(t, r1 && r2, "both reviewers leased") do return
		owner := actor_from_auth(user_auth())
		fail_r2 :: proc(fx: ^Fixture) {
			confirm_holder(fx, "inst_r2")
			inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_r2")
			inst.runtime_status = "failed"
			_, _, _ = iface.agent_save_instance(&fx.agents, inst)
			on_instance_terminal(&fx.svc, "inst_r2")
		}

		if fail_first do fail_r2(fx)
		_, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), owner, "fix the brief")
		if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
		if !fail_first do fail_r2(fx)
		_, r1 = lease_of(fx, "inst_r1")
		if !testing.expect(t, r1, "surviving reviewer keeps its lease") do return

		row := get_task(fx, "task_1")
		testing.expect(t, is_agent_not_running_block(row.blocked_on_json), fmt.tprintf("infrastructure block stays visible: %s", row.blocked_on_json))
		testing.expect(t, task_is_held(row), fmt.tprintf("hold seen under the infrastructure block: %s", row.blocked_on_json))
		infra := blocked_on_without_hold(row.blocked_on_json)
		testing.expect(t, !strings.contains(infra, `"hold"`), "hold member strips cleanly")
		inst_r1, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
		pack := build_pack_json(&fx.svc, chain, row, rl1, inst_r1)
		testing.expect(t, strings.contains(pack, `"checkpoint":{"reason":"fix the brief"}`), "surviving reviewer's pack carries the checkpoint request")

		// The surviving reviewer checkpoints; the task stays parked and held
		// (state is whatever the infrastructure block made it).
		parked_state := row.state
		_, dok, derr := lease_handoff(&fx.svc, inst_auth("inst_r1"), Handoff_Input{summary = "half reviewed"})
		if !testing.expect(t, dok, fmt.tprintf("review handoff: %s", derr.message)) do return
		_, r1 = lease_of(fx, "inst_r1")
		testing.expect(t, !r1, "held task gets no new review lease")
		row = get_task(fx, "task_1")
		testing.expect_value(t, row.state, parked_state)
		testing.expect(t, task_is_held(row) && is_agent_not_running_block(row.blocked_on_json), "still held, infrastructure block still visible")
		testing.expect(t, !strings.contains(row.blocked_on_json, `"checkpoint_requested"`), "no live lease: checkpoint no longer requested")

		// Release clears only the hold; the unresolved infrastructure block stays.
		_, rok, rerr := task_release(&fx.svc, row, owner)
		if !testing.expect(t, rok, fmt.tprintf("release: %s", rerr.message)) do return
		row = get_task(fx, "task_1")
		testing.expect(t, !task_is_held(row), "hold released")
		testing.expect_value(t, row.blocked_on_json, infra)
		assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "hold with infrastructure block")
	}
}

// A hold is an operator pause, never a question for the user: a held task gets
// no Blocked attention (task_answer refuses it), even over a user block, and
// the block's card comes back on release. A held review awaiting the user
// keeps its Review attention (the verdict is still recorded).
@(test)
test_hold_is_not_user_attention :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_attention")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold_att")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	confirm_holder(fx, "inst_w1")
	owner := actor_from_auth(user_auth())

	// The worker asks the user: a Blocked question.
	_, bok, berr := lease_block(&fx.svc, inst_auth("inst_w1"), Block_Input{waiting_on_json = `{"kind":"human","reason":"which db?"}`, summary = "asking"})
	if !testing.expect(t, bok, fmt.tprintf("block: %s", berr.message)) do return
	kind, badge := user_attention(&fx.svc, get_task(fx, "task_1"))
	testing.expect(t, kind == .Blocked && badge == "question", "a user block is a question")

	// Held over the block: no Blocked attention, and answer is refused.
	_, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), owner, "re-route to another identity")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	row := get_task(fx, "task_1")
	testing.expect(t, task_is_held(row), "held")
	kind, _ = user_attention(&fx.svc, row)
	testing.expect_value(t, kind, User_Attention.None)
	_, ansok, _ := task_answer(&fx.svc, row, owner, "continue")
	testing.expect(t, !ansok, "answer is refused while held")

	// Release: the user block's question card returns.
	_, rok, _ := task_release(&fx.svc, row, owner)
	testing.expect(t, rok, "release")
	kind, badge = user_attention(&fx.svc, get_task(fx, "task_1"))
	testing.expect(t, kind == .Blocked && badge == "question", "the question returns on release")

	// A bare hold (no other block) is never attention either.
	_ = publish_task(t, fx, chain, "task_2", brief = `{"goal":"g","acceptance":["a"]}`)
	_, hok, _ = task_hold(&fx.svc, get_task(fx, "task_2"), owner, "later")
	testing.expect(t, hok, "hold task_2")
	row = get_task(fx, "task_2")
	testing.expect(t, task_is_held(row), "task_2 held")
	kind, _ = user_attention(&fx.svc, row)
	testing.expect_value(t, kind, User_Attention.None)
	blocked, _ := blocked_on_user(row)
	testing.expect(t, !blocked, "a primary hold is not blocked on the user")
}

@(test)
test_hold_keeps_user_review_attention :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_review_att")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold_rev")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := seed_task(t, fx, chain, "task_1", `{"goal":"g","acceptance":["a"]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	lease, leased := lease_of(fx, "inst_w1")
	if !testing.expect(t, leased, "task_1 granted") do return
	row := get_task(fx, "task_1")
	row.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, row)
	submit_via_release(t, fx, lease)
	if !testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review) do return

	_, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), actor_from_auth(user_auth()), "wait for the release train")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	row = get_task(fx, "task_1")
	testing.expect(t, task_is_held(row) && row.state == .In_Review, "held in review")
	kind, badge := user_attention(&fx.svc, row)
	testing.expect(t, kind == .Review && badge == "review", "a held review awaiting the user keeps its Review attention")
}

// A forgotten coordinator hold reminds the coordinator: once the hold has
// stood hold_stale_seconds with no live lease, one hold_stale notice, the next
// one HOLD_STALE_BACKOFF times later, and none after release. A live holder (checkpoint requested) is
// not reminded about, even past the interval.
@(test)
test_hold_stale_reminds_coordinator :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_stale")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold_stale")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	notices := make([dynamic]string, context.temp_allocator)
	fx.svc.notify_observer_ctx = &notices
	fx.svc.notify_observer = proc(ctx: rawptr, coord_id, trigger, line: string) {
		if trigger == "hold_stale" do append((^[dynamic]string)(ctx), strings.clone(line, context.temp_allocator))
	}
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	confirm_holder(fx, "inst_w1")
	// The coordinator places the hold, so the reminders are its own to act on
	// (a user-placed hold is routed to the user: notice_relevance_test).
	owner := Actor{kind = ACTOR_AGENT, id = "inst_coord"}

	// Held while leased: no reminder while the holder is asked to checkpoint,
	// even past a (short) interval.
	fx.svc.hold_stale_seconds = 5 * 60
	_, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), owner, "re-route")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	fixture_advance(fx, 10 * 60)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, len(notices), 0)
	fx.svc.hold_stale_seconds = 0

	// The holder hands off; once the hold has stood the interval with no
	// lease, the coordinator is reminded exactly once.
	_, dok, derr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "checkpointed"})
	if !testing.expect(t, dok, fmt.tprintf("handoff: %s", derr.message)) do return
	fixture_advance(fx, HOLD_STALE_SECONDS - 10 * 60 + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	if !testing.expect_value(t, len(notices), 1) do return
	testing.expect(t, strings.contains(notices[0], "hold_stale: task task_1") && strings.contains(notices[0], "task release task_1") && strings.contains(notices[0], "re-route"), notices[0])
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 1)
	kind, _ := user_attention(&fx.svc, get_task(fx, "task_1"))
	testing.expect_value(t, kind, User_Attention.None)

	// Deduplicated and backed off: nothing before the next (4x) interval,
	// one more after it.
	fixture_advance(fx, HOLD_STALE_SECONDS * HOLD_STALE_BACKOFF / 2)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, len(notices), 1)
	fixture_advance(fx, HOLD_STALE_SECONDS * HOLD_STALE_BACKOFF / 2 + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, len(notices), 2)

	// Released: no further reminders.
	_, rok, _ := task_release(&fx.svc, get_task(fx, "task_1"), owner)
	testing.expect(t, rok, "release")
	fixture_advance(fx, 32 * HOLD_STALE_SECONDS)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, len(notices), 2)
}

// hold_stale_seconds overrides the default interval; an unleased hold is
// reminded about only after the interval.
@(test)
test_hold_stale_interval_is_configurable :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_stale_cfg")
	defer lease_fixture_close(fx, log)
	if !ok do return
	fx.svc.hold_stale_seconds = 120
	chain := seed_live_chain(t, fx, "chain_hold_stale_cfg")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	_, hok, _ := task_hold(&fx.svc, get_task(fx, "task_1"), actor_from_auth(user_auth()), "wait")
	if !testing.expect(t, hok, "hold") do return
	fixture_advance(fx, 60)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 0)
	fixture_advance(fx, 61)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 1)
}

// A hub restart between reminders: the boot rebuild arms the hold for "now",
// the dedupe skips it, and the next reminder still comes one backed-off
// interval after the last one.
@(test)
test_hold_stale_survives_restart_between_reminders :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_stale_restart")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold_stale_restart")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	_, hok, _ := task_hold(&fx.svc, get_task(fx, "task_1"), actor_from_auth(user_auth()), "wait")
	if !testing.expect(t, hok, "hold") do return
	fixture_advance(fx, HOLD_STALE_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 1)

	// Restart halfway through the (backed-off) interval: empty heap, rebuilt
	// from the columns.
	fixture_advance(fx, HOLD_STALE_SECONDS * HOLD_STALE_BACKOFF / 2)
	delete(fx.svc.timers.heap)
	fx.svc.timers = Timer_Service{}
	rebuild_timers(&fx.svc)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 1)
	fixture_advance(fx, HOLD_STALE_SECONDS * HOLD_STALE_BACKOFF / 2 + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_HOLD_STALE), 2)
}
