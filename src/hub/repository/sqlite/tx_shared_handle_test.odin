package sqlite

import "core:mem/virtual"
import "core:sync"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"

// The actual telegram batch repository path shares the request handle with UoW.
@(test)
test_uow_serializes_bot_batch_on_shared_handle :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	testing.expect(t, exec(&conn, "CREATE TABLE channel_cursors(provider TEXT PRIMARY KEY,cursor TEXT,updated_at TEXT);"))
	impl: SQLite_Unit_Of_Work_Factory
	repos: iface.Repositories
	factory := new_unit_of_work_factory(&impl, &conn, &repos)
	bot_impl: Bot_Repo_SQLite
	bot_repo := new_bot_repository(&bot_impl, &conn)
	for commit in ([]bool{false, true}) {
		uow, ok, _ := iface.unit_of_work_begin(&factory)
		if !testing.expect(t, ok) do return
		Job :: struct {repo: ^iface.Bot_Repository, started, done: bool, err: domain.Domain_Error}
		job := Job{repo=&bot_repo}
		worker := thread.create_and_start_with_data(&job, proc(data: rawptr) {
			j := (^Job)(data)
			sync.atomic_store(&j.started, true)
			rows, err := iface.inbound_store_batch(j.repo, "telegram", nil, "42", "now")
			delete(rows)
			j.err = err
			sync.atomic_store(&j.done, true)
		})
		for !sync.atomic_load(&job.started) do time.sleep(time.Millisecond)
		time.sleep(30*time.Millisecond)
		testing.expect(t, !sync.atomic_load(&job.done), "batch must wait rather than fail BEGIN inside UoW")
		if commit {committed, _ := iface.unit_of_work_commit(&uow); testing.expect(t, committed)} else {iface.unit_of_work_rollback(&uow)}
		thread.join(worker)
		thread.destroy(worker)
		testing.expect_value(t, job.err.code, domain.Error_Code.None)
		testing.expect(t, sqlite3_get_autocommit(conn.db)!=0, "batch ended its own transaction")
	}
}

@(test)
test_uow_failed_commit_with_active_returning_rolls_back_for_reuse :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	testing.expect(t, exec(&conn, "CREATE TABLE returning_probe(v INTEGER);"))
	impl: SQLite_Unit_Of_Work_Factory
	repos: iface.Repositories
	factory := new_unit_of_work_factory(&impl, &conn, &repos)
	uow, ok, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, ok) do return
	stmt: sqlite3_stmt
	testing.expect_value(t, sqlite3_prepare_v2(conn.db, "INSERT INTO returning_probe VALUES(1) RETURNING v;", -1, &stmt, nil), SQLITE_OK)
	testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
	committed, err := iface.unit_of_work_commit(&uow)
	testing.expect(t, !committed && err.code != .None, "active write reproduces statements-in-progress COMMIT failure")
	testing.expect(t, sqlite3_get_autocommit(conn.db)!=0, "failed commit rolls back before releasing locks")
	sqlite3_finalize(stmt)
	testing.expect(t, exec(&conn, "BEGIN IMMEDIATE; INSERT INTO returning_probe VALUES(2); COMMIT;"), "next bot-style transaction succeeds")
	testing.expect_value(t, sqlite3_prepare_v2(conn.db, "SELECT count(*) FROM returning_probe WHERE v=1;", -1, &stmt, nil), SQLITE_OK)
	defer sqlite3_finalize(stmt)
	testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
	testing.expect(t, sqlite3_column_int64(stmt, 0)==0, "failed write was rolled back")
}

@(test)
test_instance_returning_is_finalized_before_uow_commit :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	testing.expect(t, exec(&conn, "PRAGMA foreign_keys=OFF;"))
	impl: SQLite_Unit_Of_Work_Factory
	repos: iface.Repositories
	factory := new_unit_of_work_factory(&impl, &conn, &repos)
	uow, ok, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, ok) do return
	agent_impl: Agent_Repo_SQLite
	repo := new_agent_repository(&agent_impl, &conn)
	_, saved, err := iface.agent_save_instance(&repo, {agent_instance_id="inst_returning",owner_user_id="owner",agent_id="agent",bridge_id="bridge",runtime_status="running",created_at="now",updated_at="now"})
	testing.expect(t, saved, err.message)
	// FTS5 keeps its own cached statements; only the repository write must be gone.
	for stmt := sqlite3_next_stmt(conn.db, nil); stmt != nil; stmt = sqlite3_next_stmt(conn.db, stmt) {
		testing.expect(t, !strings.has_prefix(string(sqlite3_sql(stmt)), "INSERT INTO agent_instances "), "instance save finalizes its RETURNING statement")
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
}
