package taskchain

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"

// REQ-CIS-1: a USER's requirement change on a chain task resets the chain
// coordinator's idle-stop stamp; a non-requirement edit and a coordinator's
// own edit do not.
@(test)
test_user_requirement_change_resets_coordinator_idle_stamp :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "cis_requirements") do return
	defer brief_contract_close(&f)
	task, ok, err := create_task(&f.svc, f.owner, {chain_id = f.chain.chain_id, title = "cis", brief_json = FULL_BRIEF})
	if !testing.expectf(t, ok, "create: %s", err.message) do return
	now := platform.clock_now(&f.clock)
	_, iok, ierr := iface.agent_save_instance(&f.agents, domain.Agent_Instance{agent_instance_id = "inst_cis_coord", owner_user_id = "owner", agent_id = "agt_worker", bridge_id = "brg_cis", runtime_status = "running", chain_id = string(f.chain.chain_id), created_at = now, updated_at = now})
	if !testing.expectf(t, iok, "save coordinator: %s", ierr.message) do return
	_, mok, _ := iface.taskchain_save_member(&f.repo, domain.Task_Chain_Member{chain_id = f.chain.chain_id, agent_instance_id = "inst_cis_coord", agent_id = "agt_worker", owner_user_id = "owner", role = "coordinator", created_at = now})
	if !testing.expect(t, mok, "save coordinator member") do return
	bridges_impl: sqlite.Bridge_Repo_SQLite
	bridges := sqlite.new_bridge_repository(&bridges_impl, &f.conn)
	engine := taskv2.new_service(&f.repo, &f.agents, &bridges, &f.clock, &f.ids)
	set_engine(&f.svc, &engine)
	stamp :: proc(f: ^Brief_Contract_Fixture) -> string {
		at, _, _ := iface.agent_get_user_activity(&f.agents, "inst_cis_coord")
		return at
	}

	_, pok, perr := update_task(&f.svc, f.owner, task.task_id, {has_priority = true, priority = .P1})
	testing.expectf(t, pok, "priority edit: %s", perr.message)
	testing.expect_value(t, stamp(&f), "") // not a requirement change

	coord := contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "inst_cis_coord"}
	_, cok, cerr := update_task(&f.svc, coord, task.task_id, {brief_json = `{"goal":"coordinator goal","acceptance":["a1"]}`, expected_requirements_revision = 1, requirements_reason = "coordinator"})
	testing.expectf(t, cok, "coordinator edit: %s", cerr.message)
	testing.expect_value(t, stamp(&f), "") // an agent's edit is not a user event

	_, uok, uerr := update_task(&f.svc, f.owner, task.task_id, {brief_json = `{"goal":"user goal","acceptance":["a1","a2"]}`, expected_requirements_revision = 2, requirements_reason = "user"})
	if !testing.expectf(t, uok, "user edit: %s", uerr.message) do return
	testing.expect(t, stamp(&f) != "", "the user's requirement change stamps the coordinator")
}
