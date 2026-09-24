package taskchain

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

@(test)
test_declarative_actor_refs_normalize :: proc(t: ^testing.T) {
	svc: Taskchain_Service
	chain := domain.Task_Chain{
		chain_id = "chain_test_decl",
		owner_user_id = "user_decl",
	}

	raw_assignee := `{"type":"agent_id","agent_id":"agt_worker"}`
	norm, ok, err := normalize_actor_refs(&svc, chain, raw_assignee)
	testing.expect(t, ok, "normalize_actor_refs should succeed for declarative agent_id")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, norm, raw_assignee)

	agt_id := primary_assignee_agent_id(raw_assignee)
	defer delete(agt_id)
	testing.expect_value(t, agt_id, "agt_worker")

	raw_reviewers := `[{"type":"agent_id","agent_id":"agt_reviewer"}]`
	rev_norm, rev_ok, rev_err := normalize_actor_refs(&svc, chain, raw_reviewers)
	testing.expect(t, rev_ok, "normalize_actor_refs should succeed for declarative reviewer ref array")
	testing.expect_value(t, rev_err.code, domain.Error_Code.None)
	testing.expect_value(t, rev_norm, raw_reviewers)

	rev_ids := extract_agent_ids_from_ref_blob(raw_reviewers)
	defer {
		for r in rev_ids do delete(r)
		delete(rev_ids)
	}
	testing.expect_value(t, len(rev_ids), 1)
	if len(rev_ids) == 1 {
		testing.expect_value(t, rev_ids[0], "agt_reviewer")
	}

	bound_assignee := bind_agent_id_to_instance(raw_assignee, "agt_worker", "inst_worker_42")
	defer delete(bound_assignee)
	testing.expect(t, strings.contains(bound_assignee, `"type":"agent_instance"`), "must replace type with agent_instance")
	testing.expect(t, strings.contains(bound_assignee, `"agent_instance_id":"inst_worker_42"`), "must contain instance id")

	bound_reviewers := bind_agent_id_to_instance(raw_reviewers, "agt_reviewer", "inst_rev_99")
	defer delete(bound_reviewers)
	testing.expect(t, strings.contains(bound_reviewers, `"agent_instance_id":"inst_rev_99"`), "must bind reviewer instance")
}

@(test)
test_dynamic_fleet_scheduling_and_queuing_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_dispatch_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	owner := domain.User_ID("user_dispatcher")
	chain_id := domain.Task_Chain_ID("chain_dispatcher_test")

	// 1. Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Fleet Dispatcher Chain",
		description                   = "Fleet test",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, c_ok, c_err := iface.taskchain_save_chain(&tc_repo, chain)
	testing.expect(t, c_ok, "save chain ok")
	testing.expect_value(t, c_err.code, domain.Error_Code.None)

	// Coordinator instance
	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_local",
		display_name      = "coordinator #1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// 2. Set fleet capacity = 1 for agt_worker
	fleet1 := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_worker",
		capacity         = 1,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet1)

	// 3. Create one idle worker instance inst_w1 in warm pool
	w1_inst := domain.Agent_Instance{
		agent_instance_id = "inst_w1",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_local",
		display_name      = "worker #1",
		runtime_status    = "idle",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, w1_inst)
	w1_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_w1",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, w1_member)

	// 4. Create Task 1 targeting agt_worker
	t1 := domain.Task{
		task_id            = "task_w1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Task 1",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t1)

	// Reconcile pass 1: Task 1 should be bound to idle warm pool instance inst_w1 and promoted to In_Progress
	promoted1 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted1, 1)

	saved_t1, t1_ok, _ := iface.taskchain_get_task(&tc_repo, "task_w1")
	testing.expect(t, t1_ok, "get task 1 ok")
	testing.expect_value(t, saved_t1.status, domain.Task_Status.In_Progress)
	testing.expect(t, strings.contains(saved_t1.assignee_ref_json, "inst_w1"), "task 1 must be bound to inst_w1")

	saved_w1, _, _ := iface.agent_get_instance(&ag_repo, "inst_w1")
	testing.expect_value(t, saved_w1.current_task_id, "task_w1")
	testing.expect_value(t, saved_w1.current_task_role, domain.Current_Task_Role.Work)

	// 5. Create Task 2 (P2) and Task 3 (P0) while inst_w1 is busy on Task 1
	t2 := domain.Task{
		task_id            = "task_w2",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Task 2 (Low Priority)",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P2,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:02:00Z",
		updated_at         = "2026-09-23T10:02:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t2)

	t3 := domain.Task{
		task_id            = "task_w3",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Task 3 (High Priority P0)",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P0,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:03:00Z",
		updated_at         = "2026-09-23T10:03:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t3)

	// Reconcile pass 2: capacity = 1 and inst_w1 is busy, so tasks 2 and 3 must remain Queued
	promoted2 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted2, 0)

	saved_t2, _, _ := iface.taskchain_get_task(&tc_repo, "task_w2")
	testing.expect_value(t, saved_t2.status, domain.Task_Status.Queued)

	saved_t3, _, _ := iface.taskchain_get_task(&tc_repo, "task_w3")
	testing.expect_value(t, saved_t3.status, domain.Task_Status.Queued)

	// 6. Free slot: Complete Task 1
	saved_t1.status = .Completed
	saved_t1.completed_at = "2026-09-23T10:05:00Z"
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_t1)

	// Reconcile pass 3: inst_w1 is now idle. Higher priority P0 task (Task 3) must be dispatched immediately
	promoted3 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted3, 1)

	saved_t3_after, _, _ := iface.taskchain_get_task(&tc_repo, "task_w3")
	testing.expect_value(t, saved_t3_after.status, domain.Task_Status.In_Progress)
	testing.expect(t, strings.contains(saved_t3_after.assignee_ref_json, "inst_w1"), "task 3 must be bound to inst_w1")

	// Task 2 should still be Queued awaiting the next free slot
	saved_t2_after, _, _ := iface.taskchain_get_task(&tc_repo, "task_w2")
	testing.expect_value(t, saved_t2_after.status, domain.Task_Status.Queued)

	saved_w1_after, _, _ := iface.agent_get_instance(&ag_repo, "inst_w1")
	testing.expect_value(t, saved_w1_after.current_task_id, "task_w3")
}

@(test)
test_dynamic_fleet_jit_provisioning :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_jit_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	pr_impl := sqlite.Project_Repo_SQLite{conn = &conn}
	pr_repo := sqlite.new_project_repository(&pr_impl, &conn)

	co_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	co_repo := sqlite.new_content_repository(&co_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	owner := domain.User_ID("user_jit")
	chain_id := domain.Task_Chain_ID("chain_jit_test")

	// Set up Bridge in repo
	bridge := domain.Bridge{
		bridge_id         = "brg_jit",
		owner_user_id     = owner,
		machine_hostname  = "localhost",
		status            = .Online,
		capabilities_json = `{"capabilities":[{"provider":"jetski","tiers":["cheap","normal","smart"],"default_tier":"normal"}],"provider":"jetski","default_tier":"normal"}`,
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, bridge)

	// Set up Agent in repo
	worker_agent := domain.Agent{
		agent_id         = "agt_jit_worker",
		owner_user_id    = owner,
		name             = "JIT Worker",
		slug             = "jit-worker",
		default_provider = "jetski",
		default_tier     = "normal",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	// Set up Agent Bridge Support
	support := domain.Agent_Bridge_Support{
		agent_id      = "agt_jit_worker",
		bridge_id     = "brg_jit",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, support)

	// Set up bridge runtime registry and agent service
	registry := project_service.Bridge_Runtime_Registry{}
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_jit", false, "")

	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&conn),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			return true, domain.Domain_Error{}
		},
	}

	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, &pr_repo, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	svc.agent_service = &ag_service

	// Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "JIT Fleet Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_jit",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_jit",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_jit",
		display_name      = "coordinator #1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Set fleet capacity = 2 for agt_jit_worker
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_jit_worker",
		capacity         = 2,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet)

	// Create Task 1 targeting agt_jit_worker
	task1 := domain.Task{
		task_id            = "task_jit_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "JIT Task 1",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task1)

	// Reconcile: 0 instances exist, count < capacity (0 < 2) -> JIT provision instance 1!
	promoted := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted, 1)

	saved_t1, _, _ := iface.taskchain_get_task(&tc_repo, "task_jit_1")
	testing.expect_value(t, saved_t1.status, domain.Task_Status.In_Progress)
	spawned_id := primary_assignee_instance(saved_t1.assignee_ref_json)
	defer delete(spawned_id)
	testing.expect(t, strings.has_prefix(spawned_id, "inst_"), "must have spawned a concrete instance")

	// Check instance exists in ag_repo and has focus
	spawned_inst, inst_ok, _ := iface.agent_get_instance(&ag_repo, spawned_id)
	testing.expect(t, inst_ok, "spawned instance must exist in repository")
	testing.expect_value(t, spawned_inst.agent_id, "agt_jit_worker")
	testing.expect_value(t, spawned_inst.chain_id, string(chain_id))
	testing.expect_value(t, spawned_inst.current_task_id, "task_jit_1")
	testing.expect_value(t, spawned_inst.current_task_role, domain.Current_Task_Role.Work)

	// Check instance is enrolled as chain member
	is_member := is_instance_member_or_coordinator(&svc, chain, spawned_id)
	testing.expect(t, is_member, "spawned instance must be enrolled as chain member")
}
