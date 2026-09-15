package hub_project_archive_repo_test

// Repo-level coverage for REQ-PROJ-ARCHIVE-1: proves migration 037 (projects.state)
// is idempotent under a double run_migrations + upgrade guard, and that the project
// repo round-trips the new `state` field (defaults to Active; persists Archived).

import "core:fmt"
import "core:os"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

main :: proc() {
	db_path := "/tmp/project_archive_repo_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	// Test 1: full migration run (includes 037_project_state.sql).
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	// Test 2: idempotency — a second run_migrations must not error (037 self-heal).
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations 2nd run: %s", mig_err2.message))

	// Test 3: the end-of-run upgrade guard is itself idempotent.
	check(sqlite.upgrade_projects_state_schema(&conn), "upgrade_projects_state_schema should be idempotent (run 1)")
	check(sqlite.upgrade_projects_state_schema(&conn), "upgrade_projects_state_schema should be idempotent (run 2)")

	repo_impl: sqlite.Project_Repo_SQLite
	repo := sqlite.new_project_repository(&repo_impl, &conn)

	// Test 4: a saved project with no explicit state defaults to Active and round-trips.
	active := domain.Project{
		project_id = domain.Project_ID("proj_arch_active"),
		owner_user_id = domain.User_ID("usr_arch"),
		name = "Active Project",
		slug = "active-project",
		default_path = "/tmp/active",
		created_at = "2026-09-15T00:00:00Z",
		updated_at = "2026-09-15T00:00:00Z",
	}
	_, save_ok, save_err := iface.project_save(&repo, active)
	check(save_ok, fmt.tprintf("save active project: %s", save_err.message))
	got_active, got_active_ok, _ := iface.project_get(&repo, active.project_id)
	check(got_active_ok && got_active.state == .Active, "project must default to Active state on read")

	// Test 5: archiving (state=Archived) persists and reads back as Archived.
	archived := got_active
	archived.state = .Archived
	archived.updated_at = "2026-09-15T01:00:00Z"
	_, upd_ok, upd_err := iface.project_update(&repo, archived)
	check(upd_ok, fmt.tprintf("update project to archived: %s", upd_err.message))
	got_archived, got_archived_ok, _ := iface.project_get(&repo, active.project_id)
	check(got_archived_ok && got_archived.state == .Archived, "archived project must read back as Archived")

	// Test 6: soft-only — the row still exists (archive is not a delete) and remains
	// in the owner's list.
	listed, list_err := iface.project_list_by_owner(&repo, domain.User_ID("usr_arch"), 50, "")
	check(list_err.code == .None, fmt.tprintf("list projects: %s", list_err.message))
	found := false
	for p in listed { if p.project_id == active.project_id { found = true; check(p.state == .Archived, "listed archived project must carry Archived state") } }
	check(found, "archived project must still be listed (soft-archive, no row removal)")

	fmt.println("PASS: hub project archive repo test")
}
