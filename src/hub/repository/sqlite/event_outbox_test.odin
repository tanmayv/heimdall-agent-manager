package sqlite

import "core:mem"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_event_outbox_transactions :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	outbox_transaction_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}
outbox_transaction_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, _ := run_migrations(&conn)
	if !testing.expect(t, ok) do return
	ok, _ = run_migrations(&conn)
	testing.expect(t, ok, "migration idempotent")
	impl: Event_Outbox_Repo_SQLite
	repos := iface.Repositories{event_outbox = new_event_outbox_repository(&impl, &conn)}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	row := domain.Event_Outbox_Row{event_id = "evt_1", owner_user_id = "alice", subject = "ev.alice.task.t.state", envelope_json = "{}", created_at = "2026-11-19T00:00:00Z"}
	testing.expect(t, repos.event_outbox.append(repos.event_outbox.ctx, row).code != .None, "append outside UoW rejected")
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	testing.expect_value(t, repos.event_outbox.append(repos.event_outbox.ctx, row).code, domain.Error_Code.None)
	iface.unit_of_work_rollback(&uow)
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	count, err := repos.event_outbox.backlog(repos.event_outbox.ctx)
	testing.expect(t, count == 0 && err.code == .None, "rollback removes event")
	testing.expect_value(t, repos.event_outbox.append(repos.event_outbox.ctx, row).code, domain.Error_Code.None)
	nested, nested_ok, _ := iface.unit_of_work_begin(&factory)
	if nested_ok {
		row.event_id = "evt_rolled_back"
		testing.expect_value(t, repos.event_outbox.append(repos.event_outbox.ctx, row).code, domain.Error_Code.None)
		iface.unit_of_work_rollback(&nested)
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	count, err = repos.event_outbox.backlog(repos.event_outbox.ctx)
	testing.expect(t, count == 1 && err.code == .None, "commit persists only outer event")
	next, found, read_err := repos.event_outbox.next(repos.event_outbox.ctx)
	testing.expect(t, found && read_err.code == .None && next.event_id == "evt_1")
	testing.expect_value(t, repos.event_outbox.mark_published(repos.event_outbox.ctx, next.outbox_seq, "2026-11-18T00:00:00Z").code, domain.Error_Code.None)
	domain.event_outbox_row_destroy(&next)
	row.event_id = "evt_pending_old"
	testing.expect_value(t, repos.event_outbox.append(repos.event_outbox.ctx, row).code, domain.Error_Code.None)
	testing.expect_value(t, repos.event_outbox.prune(repos.event_outbox.ctx, "2026-11-19T00:00:00Z").code, domain.Error_Code.None)
	count, err = repos.event_outbox.backlog(repos.event_outbox.ctx)
	testing.expect(t, count == 1 && err.code == .None, "prune preserves unpublished events")
	testing.expect(t, exec(&conn, "CREATE TEMP TABLE outbox_probe AS SELECT * FROM event_outbox;"))
	stmt: sqlite3_stmt
	testing.expect_value(t, sqlite3_prepare_v2(conn.db, "SELECT count(*) FROM outbox_probe;", -1, &stmt, nil), SQLITE_OK)
	testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
	testing.expect_value(t, sqlite3_column_int64(stmt, 0), i64(1))
	sqlite3_finalize(stmt)
	iface.unit_of_work_rollback(&uow)
}
