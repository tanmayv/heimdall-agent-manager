package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_durable_ownership_survives_elapsed_time_without_heartbeat :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "durable_elapsed")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_durable_elapsed")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_durable_elapsed", brief = `{"goal":"g","acceptance":["a"],"review_roles":[],"budget":{"hard_deadline":1}}`)
	confirm_holder(fx, "inst_w1")
	before, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "worker granted") do return
	wake_log_reset(log)
	// Cross both former ownership clocks without issuing an agent API call.
	fixture_advance(fx, 24 * 60 * 60)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	after, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && after.lease_id == before.lease_id, "elapsed time cannot revoke ownership")
	testing.expect_value(t, get_task(fx, "task_durable_elapsed").state, domain.Task_State.In_Progress)
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "elapsed time does not stop the worker")
	_, submitted, err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{lease_id = before.lease_id, summary = "finished after a long operation"})
	testing.expect(t, submitted, fmt.tprintf("original claim remains writable: %s", err.message))
	testing.expect_value(t, get_task(fx, "task_durable_elapsed").state, domain.Task_State.Done)
}

@(test)
test_durable_ownership_review_rework_fencing_and_completion :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "durable_cycle")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_durable_cycle")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_r2", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_durable_cycle", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "inst_w1")
	first, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "worker granted") do return
	wake_log_reset(log)
	_, submitted, err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{lease_id = first.lease_id, summary = "first revision"})
	if !testing.expect(t, submitted, fmt.tprintf("submit: %s", err.message)) do return
	waiting, retained := lease_of(fx, "inst_w1")
	testing.expect(t, retained && waiting.task_id == task.task_id, "worker claim survives submission")
	testing.expect_value(t, waiting.phase, "waiting")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "submission preserves worker runtime")
	unrelated := publish_task(t, fx, chain, "task_durable_unrelated")
	testing.expect_value(t, unrelated.state, domain.Task_State.Ready)
	next, next_ok, next_err := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{})
	testing.expect(t, next_ok && next.status == "waiting" && next.lease.task_id == task.task_id, fmt.tprintf("waiting worker cannot claim unrelated work: %s", next_err.message))
	_, parked, park_err := task_hold(&fx.svc, unrelated, actor_from_auth(user_auth()), "keep cleanup observable")
	if !testing.expect(t, parked, fmt.tprintf("park unrelated task: %s", park_err.message)) do return
	_, duplicate, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{lease_id = first.lease_id, summary = "duplicate"})
	testing.expect(t, !duplicate, "waiting worker cannot submit again")
	confirm_holder(fx, "inst_r1")
	confirm_holder(fx, "inst_r2")
	reviewer_first, _ := lease_of(fx, "inst_r1")
	_, approved, aerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{lease_id = reviewer_first.lease_id, verdict = "approve"})
	if !testing.expect(t, approved, fmt.tprintf("review: %s", aerr.message)) do return
	reviewer_waiting, reviewer_retained := lease_of(fx, "inst_r1")
	testing.expect(t, reviewer_retained && reviewer_waiting.lease_id == reviewer_first.lease_id, "reviewer remains assigned while other verdicts are pending")
	testing.expect_value(t, reviewer_waiting.phase, "waiting")
	_, rejected, rerr := review_post(&fx.svc, inst_auth("inst_r2"), Review_Input{verdict = "request_changes", summary = "fix the edge case"})
	if !testing.expect(t, rejected, fmt.tprintf("request changes: %s", rerr.message)) do return
	second, reactivated := lease_of(fx, "inst_w1")
	testing.expect(t, reactivated && second.lease_id != first.lease_id && second.attempt_no > first.attempt_no, "same worker resumes with a fresh fenced claim")
	testing.expect_value(t, second.phase, "active")
	_, stale, stale_err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{lease_id = first.lease_id, summary = "stale writer"})
	testing.expect(t, !stale && stale_err.code == .Conflict && strings.contains(stale_err.message, "lease_lost"), "pre-rework lease is fenced out")
	confirm_holder(fx, "inst_w1")
	_, resubmitted, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{lease_id = second.lease_id, summary = "fixed edge case"})
	if !testing.expect(t, resubmitted, fmt.tprintf("resubmit: %s", serr.message)) do return
	for id in ([]string{"inst_r1", "inst_r2"}) {
		confirm_holder(fx, id)
		current, present := lease_of(fx, id)
		if !testing.expect(t, present, "reviewer claim reactivated") do return
		_, rok, review_err := review_post(&fx.svc, inst_auth(id), Review_Input{lease_id = current.lease_id, verdict = "approve"})
		if !testing.expect(t, rok, fmt.tprintf("re-review %s: %s", id, review_err.message)) do return
	}
	for id in ([]string{"inst_w1", "inst_r1", "inst_r2"}) {
		claim, present := lease_of(fx, id)
		testing.expect(t, present && claim.task_id == task.task_id, "claims retained through remaining user approval")
	}
	testing.expect_value(t, get_task(fx, string(task.task_id)).state, domain.Task_State.In_Review)
	_, user_ok, user_err := user_review(&fx.svc, user_auth(), task.task_id, Review_Input{verdict = "approve"})
	if !testing.expect(t, user_ok, fmt.tprintf("user approval: %s", user_err.message)) do return
	claims, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	testing.expect(t, len(claims) == 0, "completion clears worker and reviewer claims")
	for id in ([]string{"inst_w1", "inst_r1", "inst_r2"}) {
		inst, _, _ := iface.agent_get_instance(&fx.agents, id)
		testing.expect(t, inst.current_task_id == "" && inst.current_task_role == .None, "completion clears current-task pointers")
	}
}

@(test)
test_durable_ownership_explicit_handoff_clears_held_assignment :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "durable_release")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_durable_release")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_durable_release")
	confirm_holder(fx, "inst_w1")
	claim, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "worker assigned") do return
	_, held_ok, hold_err := task_hold(&fx.svc, task, actor_from_auth(user_auth()), "checkpoint")
	if !testing.expect(t, held_ok, fmt.tprintf("hold: %s", hold_err.message)) do return
	_, released, release_err := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{lease_id = claim.lease_id, summary = "checkpoint saved"})
	if !testing.expect(t, released, fmt.tprintf("handoff: %s", release_err.message)) do return
	_, remains := lease_of(fx, "inst_w1")
	testing.expect(t, !remains, "explicit handoff removes ownership")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, inst.current_task_id == "" && inst.current_task_role == .None, "explicit handoff clears task pointer")
}

@(test)
test_durable_ownership_waiting_survives_boot_hello_and_process_exit :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "durable_recovery")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_durable_recovery")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_durable_recovery")
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "inst_w1")
	_, submitted, err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "ready for user review"})
	if !testing.expect(t, submitted, fmt.tprintf("submit: %s", err.message)) do return
	original, owned := lease_of(fx, "inst_w1")
	if !testing.expect(t, owned && original.phase == domain.LEASE_PHASE_WAITING, "waiting worker retained") do return
	wake_log_reset(log)
	// Restart the service's transient timer projection over the same durable DB.
	fx.svc.timers = Timer_Service{}
	boot(&fx.svc)
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_coord", "inst_w1"})
	after_boot, retained := lease_of(fx, "inst_w1")
	testing.expect(t, retained && after_boot.lease_id == original.lease_id && after_boot.phase == domain.LEASE_PHASE_WAITING, "boot and bridge hello preserve waiting ownership")
	testing.expect(t, !wake_log_has_run(log, "inst_w1") && !wake_log_has_stop(log, "inst_w1"), "waiting owner is neither restarted nor treated as orphan")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_w1")
	after_exit, retained_after_exit := lease_of(fx, "inst_w1")
	testing.expect(t, retained_after_exit && after_exit.lease_id == original.lease_id, "process exit does not revoke waiting ownership")
	row := get_task(fx, string(task.task_id))
	testing.expect_value(t, row.state, domain.Task_State.In_Review)
	testing.expect(t, !is_agent_not_running_block(row.blocked_on_json), "waiting process exit does not block review")
	testing.expect_value(t, count_events(fx, string(task.task_id), EV_LEASE_EXPIRED), 0)
	testing.expect(t, !wake_log_has_run(log, "inst_w1") && !wake_log_has_stop(log, "inst_w1"), "process exit causes no automatic restart or stop")
}

@(test)
test_durable_ownership_user_stopped_holder_is_not_reactivated :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "durable_stopped")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_durable_stopped")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_durable_stopped")
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "inst_w1")
	_, submitted, err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "ready for review"})
	if !testing.expect(t, submitted, fmt.tprintf("submit: %s", err.message)) do return
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "stopped"
	inst.stopped_by = "user"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_user_stopped(&fx.svc, "inst_w1")
	_, retained := lease_of(fx, "inst_w1")
	testing.expect(t, !retained, "explicit user stop releases waiting reservation")
	after_stop := get_task(fx, string(task.task_id))
	testing.expect_value(t, after_stop.state, domain.Task_State.In_Review)
	testing.expect_value(t, after_stop.attempt_no, task.attempt_no)
	testing.expect_value(t, count_events(fx, string(task.task_id), EV_SUBMITTED), 1)
	testing.expect_value(t, count_events(fx, string(task.task_id), EV_LEASE_EXPIRED), 0)
	stopped, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, stopped.current_task_id == "" && stopped.current_task_role == .None, "user stop clears waiting task pointer")
	wake_log_reset(log)
	_, reviewed, review_err := user_review(&fx.svc, user_auth(), task.task_id, Review_Input{verdict = "request_changes", summary = "revise the implementation"})
	if !testing.expect(t, reviewed, fmt.tprintf("request changes: %s", review_err.message)) do return
	claim, owns := lease_of(fx, "inst_w1")
	testing.expect(t, !owns || claim.phase == domain.LEASE_PHASE_WAITING, "deliberately stopped worker receives no active claim")
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "request changes does not restart a deliberately stopped holder")
	after, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, after.stopped_by, "user")
}

@(test)
test_durable_ownership_migration_preserves_existing_claims :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, open_err := sqlite.open(":memory:")
	if !testing.expect(t, opened, open_err.message) do return
	defer sqlite.close(&conn)
	before_ok, before_err := sqlite.run_migrations(&conn, stop_before = "197_durable_task_claims.sql")
	if !testing.expect(t, before_ok, before_err.message) do return
	// Use the pre-migration SQL shape, so this also catches a migration that
	// accidentally requires a column that was never present in deployed databases.
	inserted := sqlite.exec(&conn, `INSERT INTO task_leases
		(lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, review_role, granted_at, confirmed_at, expires_at, hard_deadline_at, delivery)
		VALUES ('lease_old_work','task_old','chain_old','u1',3,'inst_old_work','work','','2026-01-01T00:00:00Z','2026-01-01T00:00:01Z','2026-01-01T00:15:00Z','2026-01-01T01:00:00Z','wake'),
		('lease_old_review','task_old','chain_old','u1',3,'inst_old_review','review','security','2026-01-01T00:00:00Z','','2026-01-01T00:15:00Z','2026-01-01T01:00:00Z','wake');`)
	if !testing.expect(t, inserted, "seed deployed claim rows before migration") do return
	migrated, migration_err := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated, migration_err.message) do return
	impl: sqlite.Taskchain_Repo_SQLite
	repo := sqlite.new_taskchain_repository(&impl, &conn)
	for id in ([]string{"lease_old_work", "lease_old_review"}) {
		claim, found, err := iface.taskchain_get_lease(&repo, id)
		if !testing.expect(t, found, err.message) do continue
		testing.expect_value(t, claim.phase, domain.LEASE_PHASE_ACTIVE)
		testing.expect_value(t, claim.attempt_no, 3)
		testing.expect_value(t, claim.task_id, domain.Task_ID("task_old"))
		testing.expect(t, claim.expires_at == "" && claim.hard_deadline_at == "", "migration clears obsolete deadlines")
	}
	worker, _, _ := iface.taskchain_get_lease(&repo, "lease_old_work")
	reviewer, _, _ := iface.taskchain_get_lease(&repo, "lease_old_review")
	testing.expect_value(t, worker.holder_instance_id, "inst_old_work")
	testing.expect_value(t, worker.confirmed_at, "2026-01-01T00:00:01Z")
	testing.expect_value(t, reviewer.holder_instance_id, "inst_old_review")
	testing.expect_value(t, reviewer.review_role, "security")
	// Running migrations again must preserve the upgraded claims too.
	again, again_err := sqlite.run_migrations(&conn)
	testing.expect(t, again, again_err.message)
}

@(test)
test_durable_ownership_waiting_handoff_preserves_submission_and_verdict :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "durable_wait_release")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_durable_wait_release")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_durable_wait_release", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "inst_w1")
	_, submitted, submit_err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "await review"})
	if !testing.expect(t, submitted, submit_err.message) do return
	confirm_holder(fx, "inst_r1")
	_, approved, review_err := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	if !testing.expect(t, approved, review_err.message) do return
	before := get_task(fx, string(task.task_id))
	for id in ([]string{"inst_w1", "inst_r1"}) {
		claim, held := lease_of(fx, id)
		if !testing.expect(t, held && claim.phase == domain.LEASE_PHASE_WAITING, "caller owns waiting claim") do return
		_, released, err := lease_handoff(&fx.svc, inst_auth(id), Handoff_Input{lease_id = claim.lease_id, summary = "release assignment while user reviews"})
		if !testing.expect(t, released, fmt.tprintf("waiting handoff %s: %s", id, err.message)) do return
		_, still := lease_of(fx, id)
		testing.expect(t, !still, "waiting handoff removes only caller ownership")
		inst, _, _ := iface.agent_get_instance(&fx.agents, id)
		testing.expect(t, inst.current_task_id == "" && inst.current_task_role == .None, "waiting handoff clears pointer")
		row := get_task(fx, string(task.task_id))
		testing.expect_value(t, row.state, domain.Task_State.In_Review)
		testing.expect_value(t, row.attempt_no, before.attempt_no)
	}
	reviews, _ := iface.taskchain_list_reviews_by_task(&fx.repo, task.task_id, "u1")
	testing.expect(t, len(reviews) == 1 && reviews[0].verdict == "approve", "explicit release preserves reviewer verdict")
	testing.expect_value(t, count_events(fx, string(task.task_id), EV_SUBMITTED), 1)
	_, accepted, user_err := user_review(&fx.svc, user_auth(), task.task_id, Review_Input{verdict = "approve"})
	testing.expect(t, accepted, user_err.message)
	testing.expect_value(t, get_task(fx, string(task.task_id)).state, domain.Task_State.Done)
}

@(test)
test_durable_ownership_retained_until_merge_success :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "durable_merge")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_durable_merge")
	seed_directory(fx, chain, "dir_git", "br_1", "git")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_durable_merge")
	confirm_holder(fx, "inst_w1")
	wake_log_reset(log)
	_, submitted, submit_err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "implementation complete", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, submitted, submit_err.message) do return
	done := get_task(fx, string(task.task_id))
	testing.expect_value(t, done.state, domain.Task_State.Done)
	testing.expect_value(t, task_merge_status(&fx.svc, done).state, "pending")
	claim, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held && claim.phase == domain.LEASE_PHASE_WAITING, "merge pending retains worker repair owner") do return
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "pending merge does not stop repair owner")
	// Feed the same durable event/UoW path used by the asynchronous bridge reply.
	u, uok, uerr := begin_uow(&fx.svc)
	if !testing.expect(t, uok, uerr.message) do return
	_, _, failed_ok, failed_err := record_event(&fx.svc, &u, done, hub_actor(), EV_MERGE_FAILED, `{"detail":"bridge temporarily unavailable"}`)
	if failed_ok do failed_ok, failed_err = after_chain_change(&fx.svc, &u, chain.chain_id, "u1", .Task_Updated)
	_, commit_err := end_uow(&fx.svc, &u, failed_ok)
	if !testing.expect(t, failed_ok && commit_err.code == .None, failed_err.message) do return
	after_failure, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && after_failure.lease_id == claim.lease_id, "merge failure preserves worker claim")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "failed merge does not stop repair owner")
	done = get_task(fx, string(task.task_id))
	u, uok, uerr = begin_uow(&fx.svc)
	if !testing.expect(t, uok, uerr.message) do return
	_, _, merged_ok, merged_err := record_event(&fx.svc, &u, done, hub_actor(), EV_MERGED, `{"head":"h1","into":"main"}`)
	if merged_ok do merged_ok, merged_err = after_chain_change(&fx.svc, &u, chain.chain_id, "u1", .Task_Updated)
	_, commit_err = end_uow(&fx.svc, &u, merged_ok)
	if !testing.expect(t, merged_ok && commit_err.code == .None, merged_err.message) do return
	testing.expect_value(t, task_merge_status(&fx.svc, get_task(fx, string(task.task_id))).state, "merged")
	_, remains := lease_of(fx, "inst_w1")
	testing.expect(t, !remains, "successful merge completes and clears ownership")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, inst.current_task_id == "", "successful merge clears current task")
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "final successful merge stops non-solo owner")
}
