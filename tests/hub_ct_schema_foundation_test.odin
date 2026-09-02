package hub_ct_schema_foundation_test

// Phase 1 (CT-1, CT-2, CT-3) schema-foundation verification.
//
// Runs the real migration runner against a fresh on-disk SQLite database and
// asserts:
//   - agent_instances gained current_task_id + current_task_role columns (CT-1)
//   - tasks gained a priority column defaulting to 'p2' (CT-3)
//   - an Agent_Instance round-trips its current_task_id/current_task_role (CT-1)
//   - a Task round-trips its priority, and the new Queued status maps both ways (CT-2/CT-3)

import "core:fmt"
import "core:os"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

main :: proc() {
	db_path := "/tmp/ct_schema_foundation_test.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	// CT-1 + CT-3: new columns exist after migration.
	check(sqlite.table_column_exists(&conn, "agent_instances", "current_task_id"), "agent_instances.current_task_id column must exist")
	check(sqlite.table_column_exists(&conn, "agent_instances", "current_task_role"), "agent_instances.current_task_role column must exist")
	check(sqlite.table_column_exists(&conn, "tasks", "priority"), "tasks.priority column must exist")

	// Migration is idempotent: running again is a no-op.
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations idempotent: %s", mig_err2.message))

	owner := domain.User_ID("usr_ct1")

	// CT-1: Agent_Instance round-trips current_task_id + role.
	agent_impl: sqlite.Agent_Repo_SQLite
	agents := sqlite.new_agent_repository(&agent_impl, &conn)
	inst := domain.Agent_Instance{
		agent_instance_id = "inst_ct1",
		owner_user_id     = owner,
		agent_id          = "agt_ct1",
		bridge_id         = "brg_ct1",
		runtime_status    = "running",
		current_task_id   = "task_ct1",
		current_task_role = .Review,
		created_at        = "2026-07-22T10:00:00Z",
		updated_at        = "2026-07-22T10:00:00Z",
	}
	_, save_ok, save_err := iface.agent_save_instance(&agents, inst)
	check(save_ok, fmt.tprintf("save instance: %s", save_err.message))
	got_inst, get_ok, _ := iface.agent_get_instance(&agents, "inst_ct1")
	check(get_ok, "get instance must succeed")
	check(got_inst.current_task_id == "task_ct1", "current_task_id must round-trip")
	check(got_inst.current_task_role == .Review, "current_task_role must round-trip as Review")

	// CT-2 string maps for Queued.
	check(domain.current_task_role_string(.Work) == "work", "role Work -> work")
	check(domain.current_task_role_string(.None) == "none", "role None -> none")
	check(domain.current_task_role_from_string("review") == .Review, "review -> Review")

	// CT-3: Task round-trips priority; CT-2: Queued status round-trips.
	tc_impl: sqlite.Taskchain_Repo_SQLite
	taskchains := sqlite.new_taskchain_repository(&tc_impl, &conn)
	task := domain.Task{
		task_id       = "task_ct1",
		chain_id      = "chain_ct1",
		owner_user_id = owner,
		title         = "ct task",
		publish_state = .Published,
		status        = .Queued,
		priority      = .P0,
		created_at    = "2026-07-22T10:00:00Z",
		updated_at    = "2026-07-22T10:00:00Z",
	}
	_, tsave_ok, tsave_err := iface.taskchain_save_task(&taskchains, task)
	check(tsave_ok, fmt.tprintf("save task: %s", tsave_err.message))
	got_task, tget_ok, _ := iface.taskchain_get_task(&taskchains, "task_ct1")
	check(tget_ok, "get task must succeed")
	check(got_task.status == .Queued, "task status must round-trip as Queued")
	check(got_task.priority == .P0, "task priority must round-trip as P0")

	// Default priority string / parse behavior.
	check(domain.task_priority_string(.P2) == "p2", "P2 -> p2")
	check(domain.task_priority_from_string("p0") == .P0, "p0 -> P0")
	check(domain.task_priority_from_string("") == .P2, "unknown priority defaults to P2")
	check(domain.task_priority_from_string("bogus") == .P2, "bogus priority defaults to P2")

	fmt.println("PASS: hub CT-1/CT-2/CT-3 schema foundation (migration + current_task + priority + Queued round-trip)")
}
