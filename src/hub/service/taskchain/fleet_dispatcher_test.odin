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
test_durable_actor_ids_filter_and_deduplicate :: proc(t: ^testing.T) {
	task := domain.Task{
		assignee_ref_json = `{"type":"agent_id","agent_id":"agt_assignee"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_reviewer"},{"type":"agent_id","agent_id":"agt_assignee"},{"type":"user","agent_id":"agt_user"},{"type":"agent_instance","agent_id":"agt_instance"},{"type":"agent_id","agent_id":""}]`,
	}
	ids := durable_actor_ids(task)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect_value(t, len(ids), 2)
	if len(ids) == 2 {
		testing.expect_value(t, ids[0], "agt_assignee")
		testing.expect_value(t, ids[1], "agt_reviewer")
	}
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
	override_bridge := bridge
	override_bridge.bridge_id = "brg_jit_task_override"
	_, _, _ = iface.bridge_save_bridge(&br_repo, override_bridge)

	// REQ-TB-3 regression fixture: a project with distinct per-bridge paths so a
	// task-level bridge pin keeps the inherited project context (from the
	// coordinator instance) while resolving project_path on the pinned bridge.
	jit_project := domain.Project{
		project_id    = domain.Project_ID("prj_jit"),
		owner_user_id = owner,
		name          = "JIT Project",
		slug          = "jit-project",
		default_path  = "/srv/jit/default",
		state         = .Active,
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.project_save(&pr_repo, jit_project)
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = jit_project.project_id,
		bridge_id     = "brg_jit",
		owner_user_id = owner,
		path          = "/srv/jit/primary",
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	})
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = jit_project.project_id,
		bridge_id     = override_bridge.bridge_id,
		owner_user_id = owner,
		path          = "/srv/jit/override",
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	})

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
	override_support := support
	override_support.bridge_id = override_bridge.bridge_id
	_, _, _ = iface.agent_save_support(&ag_repo, override_support)

	// Set up bridge runtime registry and agent service
	registry := project_service.Bridge_Runtime_Registry{}
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_jit", false, "")
	project_service.bridge_runtime_registry_mark_live(&registry, override_bridge.bridge_id, false, "")

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
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
		project_id        = domain.Project_ID("prj_jit"),
		display_name      = "coordinator #1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Set fleet capacity = 2 for agt_jit_worker with a per-role provider/tier
	// (tier "cheap" differs from the agent default "normal" so the assertions
	// below prove the fleet selection wins).
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_jit_worker",
		capacity         = 2,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		provider         = "jetski",
		tier             = "cheap",
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
		bridge_id          = override_bridge.bridge_id,
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
	testing.expect_value(t, spawned_inst.bridge_id, override_bridge.bridge_id)
	// REQ-TB-3: the pinned bridge overrides only the bridge; the coordinator's
	// project context is inherited and project_path resolves on the pinned bridge.
	testing.expect_value(t, string(spawned_inst.project_id), "prj_jit")
	testing.expect_value(t, spawned_inst.project_path, "/srv/jit/override")

	// REQ-FLEET-PT-2: the fleet row's provider/tier must reach the JIT-provisioned
	// instance (worker call site).
	testing.expect_value(t, spawned_inst.provider, "jetski")
	testing.expect_value(t, spawned_inst.tier, "cheap")

	// Check instance is enrolled as chain member
	is_member := is_instance_member_or_coordinator(&svc, chain, spawned_id)
	testing.expect(t, is_member, "spawned instance must be enrolled as chain member")

	// Fleet provider/tier cleared back to "" -> inherit. The next JIT instance must
	// fall back to the standard resolution order (agent default jetski/normal).
	cleared := fleet
	cleared.provider = ""
	cleared.tier = ""
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, cleared)

	task2 := domain.Task{
		task_id            = "task_jit_2",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "JIT Task 2",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:02:00Z",
		updated_at         = "2026-09-23T10:02:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task2)

	promoted2 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted2, 1)

	saved_t2, t2_ok, _ := iface.taskchain_get_task(&tc_repo, "task_jit_2")
	testing.expect(t, t2_ok, "get task 2 ok")
	testing.expect_value(t, saved_t2.status, domain.Task_Status.In_Progress)
	spawned2_id := primary_assignee_instance(saved_t2.assignee_ref_json)
	defer delete(spawned2_id)
	testing.expect(t, spawned2_id != spawned_id, "second JIT spawn must be a distinct instance")

	inherited_inst, inherited_ok, _ := iface.agent_get_instance(&ag_repo, spawned2_id)
	testing.expect(t, inherited_ok, "second spawned instance must exist in repository")
	testing.expect_value(t, inherited_inst.bridge_id, "brg_jit")
	testing.expect_value(t, inherited_inst.provider, "jetski")
	testing.expect_value(t, inherited_inst.tier, "normal")
	// REQ-TB-3: with no task pin the same inherited project context resolves its
	// path on the fallback bridge (coordinator bridge), not the override bridge.
	testing.expect_value(t, string(inherited_inst.project_id), "prj_jit")
	testing.expect_value(t, inherited_inst.project_path, "/srv/jit/primary")

	// Reviewer call site: a fleet row for the reviewer agent must reach the
	// reviewer JIT provision in the REVIEWER DISPATCH PASS (tier "smart" differs
	// from the reviewer agent's default "normal").
	reviewer_agent := domain.Agent{
		agent_id         = "agt_jit_reviewer",
		owner_user_id    = owner,
		name             = "JIT Reviewer",
		slug             = "jit-reviewer",
		default_provider = "jetski",
		default_tier     = "normal",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, reviewer_agent)

	reviewer_support := domain.Agent_Bridge_Support{
		agent_id      = "agt_jit_reviewer",
		bridge_id     = "brg_jit",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, reviewer_support)
	reviewer_override_support := reviewer_support
	reviewer_override_support.bridge_id = override_bridge.bridge_id
	_, _, _ = iface.agent_save_support(&ag_repo, reviewer_override_support)

	reviewer_fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_jit_reviewer",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		provider         = "jetski",
		tier             = "smart",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, reviewer_fleet)

	review_task := domain.Task{
		task_id            = "task_jit_review",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "JIT Review Task",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_worker"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_jit_reviewer"}]`,
		bridge_id          = override_bridge.bridge_id,
		created_at         = "2026-09-23T10:03:00Z",
		updated_at         = "2026-09-23T10:03:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, review_task)

	_ = reconcile_chain(&svc, chain)

	saved_rev_task, rev_task_ok, _ := iface.taskchain_get_task(&tc_repo, "task_jit_review")
	testing.expect(t, rev_task_ok, "review task must exist")
	// extract_instances_from_ref_blob returns interior subslices of the blob —
	// only the array itself is deletable.
	rev_instances := extract_instances_from_ref_blob(saved_rev_task.reviewer_refs_json)
	defer delete(rev_instances)
	testing.expect_value(t, len(rev_instances), 1)
	if len(rev_instances) == 1 {
		testing.expect(t, rev_instances[0] != spawned_id, "reviewer instance must differ from the worker instance")
		rev_inst, rev_ok, _ := iface.agent_get_instance(&ag_repo, rev_instances[0])
		testing.expect(t, rev_ok, "reviewer JIT instance must exist in repository")
		testing.expect_value(t, rev_inst.agent_id, "agt_jit_reviewer")
		testing.expect_value(t, rev_inst.bridge_id, override_bridge.bridge_id)
		testing.expect_value(t, rev_inst.provider, "jetski")
		testing.expect_value(t, rev_inst.tier, "smart")
		testing.expect_value(t, rev_inst.current_task_id, "task_jit_review")
		testing.expect_value(t, rev_inst.current_task_role, domain.Current_Task_Role.Review)
		// REQ-TB-3: reviewer JIT spawn keeps the inherited project context and
		// resolves its path on the task-pinned bridge, same as the worker spawn.
		testing.expect_value(t, string(rev_inst.project_id), "prj_jit")
		testing.expect_value(t, rev_inst.project_path, "/srv/jit/override")
	}

	saved_t1.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_t1)
	saved_t2.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_t2)
	saved_rev_task.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_rev_task)
	_ = reconcile_chain(&svc, chain)

	offline_bridge := bridge
	offline_bridge.bridge_id = "brg_jit_offline"
	offline_bridge.status = .Offline
	_, _, _ = iface.bridge_save_bridge(&br_repo, offline_bridge)
	offline_agent := domain.Agent{
		agent_id         = "agt_jit_offline",
		owner_user_id    = owner,
		name             = "Offline JIT Worker",
		slug             = "offline-jit-worker",
		default_provider = "jetski",
		default_tier     = "normal",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, offline_agent)
	offline_support := domain.Agent_Bridge_Support{
		agent_id      = offline_agent.agent_id,
		bridge_id     = offline_bridge.bridge_id,
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, offline_support)
	offline_fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = offline_agent.agent_id,
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, offline_fleet)
	offline_task := domain.Task{
		task_id            = "task_jit_offline",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Offline JIT Task",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_offline"}`,
		reviewer_refs_json = "[]",
		bridge_id          = offline_bridge.bridge_id,
		created_at         = "2026-09-23T10:04:00Z",
		updated_at         = "2026-09-23T10:04:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, offline_task)

	commands_before_hold := len(captured_cmds)
	promoted_while_offline := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted_while_offline, 0)
	held_task, held_ok, _ := iface.taskchain_get_task(&tc_repo, offline_task.task_id)
	testing.expect(t, held_ok, "offline task must exist")
	testing.expect_value(t, held_task.status, domain.Task_Status.Assigned)
	testing.expect_value(t, held_task.updated_at, offline_task.updated_at)
	held_assignee := primary_assignee_instance(held_task.assignee_ref_json)
	testing.expect_value(t, held_assignee, "")
	testing.expect_value(t, len(captured_cmds), commands_before_hold)

	offline_bridge.status = .Online
	_, _, _ = iface.bridge_save_bridge(&br_repo, offline_bridge)
	project_service.bridge_runtime_registry_mark_live(&registry, offline_bridge.bridge_id, false, "")
	promoted_after_resume := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted_after_resume, 1)
	resumed_task, resumed_ok, _ := iface.taskchain_get_task(&tc_repo, offline_task.task_id)
	testing.expect(t, resumed_ok, "resumed task must exist")
	testing.expect_value(t, resumed_task.status, domain.Task_Status.In_Progress)
	resumed_assignee := primary_assignee_instance(resumed_task.assignee_ref_json)
	defer delete(resumed_assignee)
	resumed_inst, resumed_inst_ok, _ := iface.agent_get_instance(&ag_repo, resumed_assignee)
	testing.expect(t, resumed_inst_ok, "offline task must JIT provision once its bridge returns")
	testing.expect_value(t, resumed_inst.bridge_id, offline_bridge.bridge_id)
	testing.expect(t, len(captured_cmds) > commands_before_hold, "resumed task must enqueue a wake command")
}

@(test)
test_stopped_warm_instance_reuse_and_auto_start :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_stopped_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)

	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for c in captured_cmds {
			delete(c.body_json)
		}
		delete(captured_cmds)
	}

	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			list := (^[dynamic]project_service.Runtime_Command)(ctx)
			c_copy := cmd
			c_copy.body_json = strings.clone(cmd.body_json)
			append(list, c_copy)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_stopped_test")
	chain_id := domain.Task_Chain_ID("chain_stopped_test")

	// Set up Bridge in repo
	bridge := domain.Bridge{
		bridge_id         = "brg_stopped_test",
		owner_user_id     = owner,
		machine_hostname  = "localhost",
		status            = .Online,
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, bridge)

	// Set up Agents in repo
	worker_agent := domain.Agent{
		agent_id         = "agt_w",
		owner_user_id    = owner,
		name             = "Worker Agent",
		slug             = "worker-agent",
		default_provider = "jetski",
		default_tier     = "normal",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	reviewer_agent := domain.Agent{
		agent_id         = "agt_r",
		owner_user_id    = owner,
		name             = "Reviewer Agent",
		slug             = "reviewer-agent",
		default_provider = "jetski",
		default_tier     = "normal",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, reviewer_agent)

	// Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Stopped Warm Pool Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_test",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_test",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_stopped_test",
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Pre-create a STOPPED warm instance for agt_w
	w_inst := domain.Agent_Instance{
		agent_instance_id = "inst_w_stopped",
		owner_user_id     = owner,
		agent_id          = "agt_w",
		bridge_id         = "brg_stopped_test",
		display_name      = "stopped worker",
		runtime_status    = "stopped",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, w_inst)
	w_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_w_stopped",
		agent_id          = "agt_w",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, w_member)

	// Pre-create a STOPPED warm instance for agt_r
	r_inst := domain.Agent_Instance{
		agent_instance_id = "inst_r_stopped",
		owner_user_id     = owner,
		agent_id          = "agt_r",
		bridge_id         = "brg_stopped_test",
		display_name      = "stopped reviewer",
		runtime_status    = "stopped",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, r_inst)
	r_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_r_stopped",
		agent_id          = "agt_r",
		owner_user_id     = owner,
		role              = "reviewer",
		created_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, r_member)

	// Fleet capacity = 1 for agt_w and agt_r
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, domain.Task_Chain_Fleet{
		task_chain_id = chain_id,
		agent_id      = "agt_w",
		capacity      = 1,
	})
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, domain.Task_Chain_Fleet{
		task_chain_id = chain_id,
		agent_id      = "agt_r",
		capacity      = 1,
	})

	// Task 1: work task targeting agt_w
	task1 := domain.Task{
		task_id            = "task_work_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Work Task 1",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_w"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task1)

	// Task 2: review task in In_Validation targeting agt_r
	task2 := domain.Task{
		task_id            = "task_rev_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Review Task 1",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_other"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_r"}]`,
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task2)

	// Reconcile
	promoted := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted, 1)

	// 1. Verify Task 1 bound to inst_w_stopped (reused warm stopped instance, NOT new instance)
	saved_t1, _, _ := iface.taskchain_get_task(&tc_repo, "task_work_1")
	testing.expect_value(t, saved_t1.status, domain.Task_Status.In_Progress)
	testing.expect(t, strings.contains(saved_t1.assignee_ref_json, "inst_w_stopped"), "task_work_1 must be bound to inst_w_stopped")

	// 2. Verify Task 2 bound to inst_r_stopped (reused warm stopped instance)
	saved_t2, _, _ := iface.taskchain_get_task(&tc_repo, "task_rev_1")
	testing.expect(t, strings.contains(saved_t2.reviewer_refs_json, "inst_r_stopped"), "task_rev_1 must be bound to inst_r_stopped")

	// 3. Verify wake commands emitted for both stopped instances and NO stops
	wake_w_found := false
	wake_r_found := false
	stop_w_found := false
	stop_r_found := false

	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"type":"wake_agent"`) {
			if strings.contains(cmd.body_json, "inst_w_stopped") && strings.contains(cmd.body_json, "task_work_1") {
				wake_w_found = true
			}
			if strings.contains(cmd.body_json, "inst_r_stopped") && strings.contains(cmd.body_json, "task_rev_1") {
				wake_r_found = true
			}
			if strings.contains(cmd.body_json, `"stops":[`) {
				if strings.contains(cmd.body_json, `"inst_w_stopped"`) {
					stop_w_found = true
				}
				if strings.contains(cmd.body_json, `"inst_r_stopped"`) {
					stop_r_found = true
				}
			}
		}
	}

	testing.expect(t, wake_w_found, "wake_agent must be emitted for stopped worker instance inst_w_stopped")
	testing.expect(t, wake_r_found, "wake_agent must be emitted for stopped reviewer instance inst_r_stopped")
	testing.expect(t, !stop_w_found, "inst_w_stopped must NEVER appear in stops")
	testing.expect(t, !stop_r_found, "inst_r_stopped must NEVER appear in stops")

	// 4. Verify instances have focus updated in repo
	saved_w_inst, _, _ := iface.agent_get_instance(&ag_repo, "inst_w_stopped")
	testing.expect_value(t, saved_w_inst.current_task_id, "task_work_1")
	testing.expect_value(t, saved_w_inst.current_task_role, domain.Current_Task_Role.Work)

	saved_r_inst, _, _ := iface.agent_get_instance(&ag_repo, "inst_r_stopped")
	testing.expect_value(t, saved_r_inst.current_task_id, "task_rev_1")
	testing.expect_value(t, saved_r_inst.current_task_role, domain.Current_Task_Role.Review)
}
