package taskchain

// REQ-AUTHZ-1/2: chain status changes and task update/cancel/hold/release/
// recheck are owner-scoped. Any agent instance of the chain's owner may perform
// them without being a member or coordinator of the chain; an instance of a
// different owner is still refused, and the non-membership guards (draft chain,
// `complete` for completion, valid transitions, lease-holder self-edit) stay.

import "core:fmt"
import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"

@(private = "file")
AZ_OWNER :: "owner_authz"
@(private = "file")
AZ_FOREIGN :: "owner_authz_other"

@(private = "file")
Az_Fx :: struct {
	conn:    sqlite.Conn,
	tc_impl: sqlite.Taskchain_Repo_SQLite,
	repo:    iface.Taskchain_Repository,
	ag_impl: sqlite.Agent_Repo_SQLite,
	agents:  iface.Agent_Repository,
	clock:   platform.Clock,
	ids:     platform.ID_Generator,
	svc:     Taskchain_Service,
	engine:  taskv2.Service,
	db_path: string,
}

@(private = "file")
az_make :: proc(fx: ^Az_Fx, t: ^testing.T, name: string) -> bool {
	fx.db_path = fmt.tprintf("%s/.cache/heimdall-tests/authz_%s_%d.db", os.get_env("HOME", context.temp_allocator), name, os.get_pid())
	os.remove(fx.db_path)
	ok: bool
	fx.conn, ok, _ = sqlite.open(fx.db_path)
	if !testing.expect(t, ok, "open database") do return false
	mig_ok, _ := sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, mig_ok, "migrations") do return false
	fx.repo = sqlite.new_taskchain_repository(&fx.tc_impl, &fx.conn)
	fx.agents = sqlite.new_agent_repository(&fx.ag_impl, &fx.conn)
	fx.clock = platform.real_clock()
	fx.ids = platform.real_id_generator()
	fx.svc = new_taskchain_service(&fx.repo, &fx.agents, &fx.clock, &fx.ids)
	fx.engine = taskv2.new_service(&fx.repo, &fx.agents, nil, &fx.clock, &fx.ids)
	fx.svc.engine = &fx.engine
	now := platform.clock_now(&fx.clock)
	// coord: member + coordinator; outsider: same owner, no membership in any
	// chain; foreign: an instance of another owner.
	seed := [?]struct{id, owner, chain: string}{
		{"inst_coord", AZ_OWNER, "chain_authz"},
		{"inst_outsider", AZ_OWNER, "chain_elsewhere"},
		{"inst_holder", AZ_OWNER, "chain_authz"},
		{"inst_foreign", AZ_FOREIGN, ""},
	}
	for s in seed {
		_, _, _ = iface.agent_save_instance(&fx.agents, domain.Agent_Instance{agent_instance_id = s.id, owner_user_id = domain.User_ID(s.owner), agent_id = "agt_authz", chain_id = s.chain, created_at = now, updated_at = now})
	}
	return true
}

@(private = "file")
az_free :: proc(fx: ^Az_Fx) {
	sqlite.close(&fx.conn)
	os.remove(fx.db_path)
}

@(private = "file")
az_chain :: proc(fx: ^Az_Fx, chain_id: string, publish := domain.Publish_State.Published) -> domain.Task_Chain {
	now := platform.clock_now(&fx.clock)
	chain, _, _ := iface.taskchain_save_chain(&fx.repo, domain.Task_Chain{
		chain_id = domain.Task_Chain_ID(chain_id), owner_user_id = AZ_OWNER, title = "authz",
		publish_state = publish, status = .Active, kind = domain.CHAIN_KIND_MIXED_WORK,
		created_at = now, updated_at = now,
	})
	_, _, _ = iface.taskchain_save_member(&fx.repo, domain.Task_Chain_Member{chain_id = chain.chain_id, owner_user_id = AZ_OWNER, agent_instance_id = "inst_coord", agent_id = "agt_authz", role = "coordinator", created_at = now})
	_, _, _ = iface.taskchain_save_member(&fx.repo, domain.Task_Chain_Member{chain_id = chain.chain_id, owner_user_id = AZ_OWNER, agent_instance_id = "inst_holder", agent_id = "agt_authz", role = "worker", created_at = now})
	return chain
}

@(private = "file")
az_task :: proc(fx: ^Az_Fx, chain_id: string, task_id: string) -> domain.Task {
	task := domain.Task{task_id = domain.Task_ID(task_id), chain_id = domain.Task_Chain_ID(chain_id), owner_user_id = AZ_OWNER,
		title = "authz task", kind = .Task, publish_state = .Published, state = .Ready,
		brief_json = `{"goal":"g","acceptance":["a"],"review_roles":[]}`}
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	_, _, _ = iface.taskchain_append_event(&fx.repo, domain.Task_Event{task_id = task.task_id, chain_id = task.chain_id,
		owner_user_id = AZ_OWNER, kind = taskv2.EV_MIGRATED, payload_json = `{"state":"ready","published":true}`})
	return task
}

@(private = "file")
az_instance :: proc(id: string, owner := AZ_OWNER) -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = owner, agent_instance_id = id}
}

@(test)
test_authz_non_member_same_owner_changes_chain_status :: proc(t: ^testing.T) {
	fx: Az_Fx
	if !az_make(&fx, t, "status") do return
	defer az_free(&fx)
	chain := az_chain(&fx, "chain_authz")
	outsider := az_instance("inst_outsider")
	testing.expect(t, !is_instance_member_or_coordinator(&fx.svc, chain, "inst_outsider"), "fixture: outsider is not a member")

	// Cross-owner: an instance of another owner is refused and nothing changes.
	_, fok, ferr := change_chain_status(&fx.svc, az_instance("inst_foreign", AZ_FOREIGN), chain.chain_id, .Cancelled)
	testing.expectf(t, !fok && (ferr.code == .Not_Found || ferr.code == .Forbidden), "foreign instance refused: %v %s", ferr.code, ferr.message)
	// Completion still goes through `complete`.
	_, cok, cerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Completed)
	testing.expect(t, !cok && cerr.code == .Validation_Failed, "completed still requires complete")
	after, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, after.status, domain.Task_Chain_Status.Active)

	// archive -> unarchive -> cancel, all by a same-owner non-member.
	archived, aok, aerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Archived)
	testing.expectf(t, aok, "non-member archives: %s", aerr.message)
	testing.expect_value(t, archived.status, domain.Task_Chain_Status.Archived)
	active, uok, uerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Active)
	testing.expectf(t, uok, "non-member unarchives: %s", uerr.message)
	testing.expect_value(t, active.status, domain.Task_Chain_Status.Active)
	cancelled, xok, xerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Cancelled)
	testing.expectf(t, xok, "non-member cancels: %s", xerr.message)
	testing.expect_value(t, cancelled.status, domain.Task_Chain_Status.Cancelled)

	// Draft chains still have no execution status, whoever asks.
	draft := az_chain(&fx, "chain_authz_draft", .Draft)
	_, dok, derr := change_chain_status(&fx.svc, outsider, draft.chain_id, .Cancelled)
	testing.expect(t, !dok && derr.code == .Conflict, "draft chain guard unchanged")
}

@(test)
test_authz_non_member_same_owner_updates_and_cancels_task :: proc(t: ^testing.T) {
	fx: Az_Fx
	if !az_make(&fx, t, "task") do return
	defer az_free(&fx)
	chain := az_chain(&fx, "chain_authz")
	task := az_task(&fx, string(chain.chain_id), "task_authz_cancel")
	outsider := az_instance("inst_outsider")
	stranger := az_instance("inst_foreign", AZ_FOREIGN)

	// update: foreign refused, same-owner non-member accepted.
	_, fu_ok, fu_err := update_task(&fx.svc, stranger, task.task_id, Update_Task_Input{priority = .P0, has_priority = true})
	testing.expectf(t, !fu_ok && (fu_err.code == .Not_Found || fu_err.code == .Forbidden), "foreign update refused: %v", fu_err.code)
	updated, u_ok, u_err := update_task(&fx.svc, outsider, task.task_id, Update_Task_Input{priority = .P0, has_priority = true})
	testing.expectf(t, u_ok, "non-member updates task: %s", u_err.message)
	testing.expect_value(t, updated.priority, domain.Task_Priority.P0)

	// hold / release / recheck through the engine with the non-member actor.
	actor := engine_actor(outsider)
	_, h_ok, h_err := taskv2.task_hold(&fx.engine, updated, actor, "pause for re-plan")
	testing.expectf(t, h_ok, "non-member holds: %s", h_err.message)
	held, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	_, r_ok, r_err := taskv2.task_release(&fx.engine, held, actor)
	testing.expectf(t, r_ok, "non-member releases: %s", r_err.message)
	released, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	_, rc_ok, rc_err := taskv2.task_recheck(&fx.engine, released, actor)
	testing.expectf(t, rc_ok, "non-member rechecks: %s", rc_err.message)
	_, fh_ok, fh_err := taskv2.task_hold(&fx.engine, released, engine_actor(stranger), "nope")
	testing.expect(t, !fh_ok && fh_err.code == .Forbidden, "foreign instance cannot hold")

	// cancel: foreign refused (task stays), same-owner non-member cancels.
	_, fc_ok, fc_err := cancel_task(&fx.svc, stranger, task.task_id, "not yours")
	testing.expectf(t, !fc_ok && (fc_err.code == .Not_Found || fc_err.code == .Forbidden), "foreign cancel refused: %v", fc_err.code)
	still, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	testing.expect(t, still.state != .Cancelled, "foreign cancel changed nothing")
	cancelled, c_ok, c_err := cancel_task(&fx.svc, outsider, task.task_id, "obsolete")
	testing.expectf(t, c_ok, "non-member cancels task: %s", c_err.message)
	testing.expect_value(t, cancelled.state, domain.Task_State.Cancelled)

	// The native v2 cancel verb (POST .../cancel) authorizes the same way.
	v2 := az_task(&fx, string(chain.chain_id), "task_authz_v2_cancel")
	_, v2f_ok, v2f_err := taskv2.task_cancel(&fx.engine, v2, engine_actor(stranger), taskv2.Task_Cancel_Input{reason = "x", request_id = "req_f", expected_generation = 0})
	testing.expect(t, !v2f_ok && v2f_err.code == .Forbidden, "foreign actor refused by v2 cancel")
	res, v2_ok, v2_err := taskv2.task_cancel(&fx.engine, v2, actor, taskv2.Task_Cancel_Input{reason = "obsolete", request_id = "req_o", expected_generation = 0})
	testing.expectf(t, v2_ok, "non-member v2 cancel: %s", v2_err.message)
	testing.expect_value(t, res.task.state, domain.Task_State.Cancelled)
}

@(test)
test_authz_lease_holder_still_cannot_update_its_own_task :: proc(t: ^testing.T) {
	fx: Az_Fx
	if !az_make(&fx, t, "holder") do return
	defer az_free(&fx)
	chain := az_chain(&fx, "chain_authz")
	task := az_task(&fx, string(chain.chain_id), "task_authz_held")
	now := platform.clock_now(&fx.clock)
	_, lok, lerr := iface.taskchain_save_lease(&fx.repo, domain.Task_Lease{lease_id = "lease_authz", task_id = task.task_id, chain_id = chain.chain_id, owner_user_id = AZ_OWNER, holder_instance_id = "inst_holder", attempt_no = 1, kind = domain.LEASE_KIND_WORK, delivery = "inline", granted_at = now, confirmed_at = now})
	if !testing.expectf(t, lok, "seed lease: %s", lerr.message) do return
	_, hok, herr := update_task(&fx.svc, az_instance("inst_holder"), task.task_id, Update_Task_Input{brief_json = `{"acceptance":["weaker"]}`})
	testing.expect(t, !hok && herr.code == .Forbidden, "holder cannot rewrite the task it holds")
	_, ook, oerr := update_task(&fx.svc, az_instance("inst_outsider"), task.task_id, Update_Task_Input{brief_json = `{"acceptance":["corrected"]}`})
	testing.expectf(t, ook, "another same-owner instance may correct acceptance: %s", oerr.message)
}
