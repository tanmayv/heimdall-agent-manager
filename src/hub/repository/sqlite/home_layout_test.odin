package sqlite

import "core:sync"
import "core:strings"
import "core:testing"
import "core:thread"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

home_layout_test_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

@(test)
test_home_layout_upgrade_reopen_and_owner_isolation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, opened := tmpl_open_file_prod(t, "home_layout_upgrade")
	defer tmpl_remove_db(path)
	if !opened do return
	migrated, err := run_migrations(&conn, stop_before = "257_user_home_layouts.sql")
	if !testing.expect(t, migrated, err.message) { close(&conn); return }
	impl: User_Repo_SQLite
	repo := new_user_repository(&impl, &conn)
	_, saved, _ := iface.user_save(&repo, {user_id = "layout_a", name = "layout_a", status = .Active})
	if !testing.expect(t, saved) { close(&conn); return }
	_, saved, _ = iface.user_save(&repo, {user_id = "layout_b", name = "layout_b", status = .Active})
	testing.expect(t, saved)
	testing.expect(t, !sqlite_object_exists(&conn, "user_home_layouts"))
	testing.expect(t, migration_applied(&conn, "255_extension_version_sync_0_5_89.sql") && migration_applied(&conn, "256_extension_version_sync_0_5_90.sql"))
	previous_ledger := home_layout_test_text(&conn, "SELECT group_concat(entry, '|') FROM (SELECT version || ':' || applied_at AS entry FROM schema_migrations ORDER BY version);")
	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) { close(&conn); return }
	testing.expect(t, migration_applied(&conn, "254_fleet_applications.sql") && migration_applied(&conn, "257_user_home_layouts.sql"))
	testing.expect_value(t, home_layout_test_text(&conn, "SELECT group_concat(entry, '|') FROM (SELECT version || ':' || applied_at AS entry FROM schema_migrations WHERE version != '257_user_home_layouts.sql' ORDER BY version);"), previous_ledger)
	_, found, read_err := iface.home_layout_get(&repo, "layout_a")
	testing.expect(t, !found && read_err.code == .None)
	testing.expect_value(t, home_layout_test_text(&conn, "SELECT count(*) FROM user_home_layouts;"), "0")
	saved, err = iface.home_layout_cas(&repo, "layout_a", 0, `{"version":1,"widgets":[]}`)
	testing.expect(t, saved && err.code == .None)
	saved, err = iface.home_layout_cas(&repo, "layout_a", 0, "loser")
	testing.expect(t, !saved && err.code == .Conflict)
	saved, err = iface.home_layout_cas(&repo, "layout_a", 1, `{"version":2,"widgets":[]}`)
	testing.expect(t, saved && err.code == .None)
	saved, err = iface.home_layout_cas(&repo, "layout_a", 1, "stale")
	testing.expect(t, !saved && err.code == .Conflict)
	saved, err = iface.home_layout_cas(&repo, "layout_b", 1, "missing")
	testing.expect(t, !saved && err.code == .Conflict)
	saved, err = iface.home_layout_cas(&repo, "layout_b", 0, `{"version":1,"widgets":[]}`)
	testing.expect(t, saved && err.code == .None)
	close(&conn)
	conn, opened, err = open(path)
	if !testing.expect(t, opened, err.message) do return
	defer close(&conn)
	for _ in 0..<2 {
		migrated, err = run_migrations(&conn)
		testing.expect(t, migrated, err.message)
	}
	repo = new_user_repository(&impl, &conn)
	row: domain.Home_Layout_Record
	row, found, err = iface.home_layout_get(&repo, "layout_a")
	testing.expect(t, found && err.code == .None && row.revision == 2 && row.payload_json == `{"version":2,"widgets":[]}`)
	delete(row.payload_json)
	row, found, err = iface.home_layout_get(&repo, "layout_b")
	testing.expect(t, found && err.code == .None && row.revision == 1)
	delete(row.payload_json)
	testing.expect_value(t, home_layout_test_text(&conn, "SELECT count(*) FROM users WHERE user_id IN ('layout_a','layout_b');"), "2")
	testing.expect_value(t, home_layout_test_text(&conn, "PRAGMA integrity_check;"), "ok")
}

Home_Layout_Race :: struct {
	repo: ^iface.User_Repository,
	start: ^sync.Barrier,
	expected: i64,
	payload: string,
	saved: bool,
	err: domain.Domain_Error,
}

home_layout_race_write :: proc(data: rawptr) {
	race := (^Home_Layout_Race)(data)
	sync.barrier_wait(race.start)
	race.saved, race.err = iface.home_layout_cas(race.repo, "layout_race", race.expected, race.payload)
}

@(test)
test_home_layout_cas_races_across_connections :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, opened := tmpl_clone_migrated_into_file(t, "home_layout_race")
	defer tmpl_remove_db(path)
	if !opened do return
	defer close(&conn)
	other, other_ok, _ := open(path)
	if !testing.expect(t, other_ok) do return
	defer close(&other)
	impl_a, impl_b: User_Repo_SQLite
	repo_a := new_user_repository(&impl_a, &conn)
	repo_b := new_user_repository(&impl_b, &other)
	_, seeded, _ := iface.user_save(&repo_a, {user_id = "layout_race", name = "layout_race", status = .Active})
	if !testing.expect(t, seeded) do return
	for expected: i64 = 0; expected < 2; expected += 1 {
		start: sync.Barrier
		sync.barrier_init(&start, 3)
		left := Home_Layout_Race{repo = &repo_a, start = &start, expected = expected, payload = "left"}
		right := Home_Layout_Race{repo = &repo_b, start = &start, expected = expected, payload = "right"}
		a := thread.create_and_start_with_data(&left, home_layout_race_write)
		b := thread.create_and_start_with_data(&right, home_layout_race_write)
		sync.barrier_wait(&start)
		thread.join(a); thread.join(b)
		thread.destroy(a); thread.destroy(b)
		testing.expect(t, left.saved != right.saved, "exactly one CAS winner")
		testing.expect(t, (left.saved && left.err.code == .None && right.err.code == .Conflict) || (right.saved && right.err.code == .None && left.err.code == .Conflict), "loser is a version conflict")
		row, found, err := iface.home_layout_get(&repo_a, "layout_race")
		testing.expect(t, found && err.code == .None && row.revision == expected + 1)
		testing.expect(t, row.payload_json == ("left" if left.saved else "right"))
		delete(row.payload_json)
	}
}
