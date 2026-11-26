#+private file
package sqlite

import "core:strings"
import "core:testing"

// SCHED-0b (migration 260): the role columns are dropped, a partial per-role
// pause survives as the `paused` boolean, interim 'named' agent verdicts become
// 'review', and a second boot neither re-adds the columns nor re-runs 131.

S0B_DROP :: "260_drop_fleet_roles.sql"

s0b_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

@(test)
test_sched0b_drops_role_columns_once :: proc(t: ^testing.T) {
	conn, path, ok := tmpl_open_file_prod(t, "s0b_drop")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn, stop_before = S0B_DROP)
	if !testing.expect(t, mig_ok, err.message) do return
	testing.expect(t, table_column_exists(&conn, "task_chain_fleets", "roles_json"), "before 260: roles_json exists")
	testing.expect(t, exec(&conn, "PRAGMA foreign_keys=OFF;"))
	testing.expect(t, exec(&conn, `INSERT INTO task_chain_fleets (task_chain_id, agent_id, created_at, updated_at, roles_json, paused_roles_json) VALUES ('chain_s0b', 'agt_partial', 'now', 'now', '["worker","security"]', '["security"]');`))
	testing.expect(t, exec(&conn, `INSERT INTO task_chain_fleets (task_chain_id, agent_id, created_at, updated_at, roles_json, paused_roles_json) VALUES ('chain_s0b', 'agt_live', 'now', 'now', '["worker"]', '');`))
	testing.expect(t, exec(&conn, `INSERT INTO task_reviews (task_id, chain_id, owner_user_id, attempt_no, role, reviewer_kind, reviewer_agent_id, verdict, created_at) VALUES ('task_s0b', 'chain_s0b', 'user_s0b', 1, 'named', 'agent', 'agt_r', 'approve', 'now');`))
	testing.expect(t, exec(&conn, "PRAGMA foreign_keys=ON;"))

	for pass in ([]string{"upgrade", "restart"}) {
		mig_ok, err = run_migrations(&conn)
		if !testing.expectf(t, mig_ok, "%s: %s", pass, err.message) do return
		testing.expectf(t, migration_applied(&conn, S0B_DROP), "%s: 260 recorded", pass)
		testing.expectf(t, !table_column_exists(&conn, "task_chain_fleets", "roles_json"), "%s: roles_json stays dropped", pass)
		testing.expectf(t, !table_column_exists(&conn, "task_chain_fleets", "paused_roles_json"), "%s: paused_roles_json stays dropped", pass)
		testing.expectf(t, !table_column_exists(&conn, "task_leases", "review_role"), "%s: review_role stays dropped", pass)
		testing.expectf(t, s0b_text(&conn, "SELECT paused FROM task_chain_fleets WHERE agent_id='agt_partial';") == "1", "%s: a partial pause is a full pause", pass)
		testing.expectf(t, s0b_text(&conn, "SELECT paused FROM task_chain_fleets WHERE agent_id='agt_live';") == "0", "%s: an unpaused row stays unpaused", pass)
		testing.expectf(t, s0b_text(&conn, "SELECT role FROM task_reviews WHERE task_id='task_s0b';") == "review", "%s: agent verdict role is review", pass)
		testing.expectf(t, s0b_text(&conn, "SELECT count(*) FROM schema_migrations WHERE version='131_fleet_pause.sql';") == "1", "%s: 131 is not re-run", pass)
	}
}

// SCHED-0a/0b ran on development databases as 257_agent_id_assignment.sql and
// 258_drop_fleet_roles.sql before release 0.5.91 took 257/258. Such a database
// then gains the release's 257/258 and must neither re-run SCHED-0a (duplicate
// `paused` column) nor SCHED-0b (dropping columns that are gone) under 259/260.
@(test)
test_sched0_legacy_numbers_are_not_rerun :: proc(t: ^testing.T) {
	conn, path, ok := tmpl_open_file_prod(t, "s0_legacy_numbers")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, err.message) do return
	testing.expect(t, exec(&conn, `UPDATE schema_migrations SET version='257_agent_id_assignment.sql' WHERE version='259_agent_id_assignment.sql';
UPDATE schema_migrations SET version='258_drop_fleet_roles.sql' WHERE version='260_drop_fleet_roles.sql';
DELETE FROM schema_migrations WHERE version IN ('257_user_home_layouts.sql', '258_extension_version_sync_0_5_91.sql');
DROP TABLE user_home_layouts;`), "rewind to a development database")

	for pass in ([]string{"upgrade", "restart"}) {
		mig_ok, err = run_migrations(&conn)
		if !testing.expectf(t, mig_ok, "%s: %s", pass, err.message) do return
		testing.expectf(t, s0b_text(&conn, "SELECT count(*) FROM schema_migrations WHERE version IN ('257_user_home_layouts.sql', '258_extension_version_sync_0_5_91.sql');") == "2", "%s: release 257/258 applied", pass)
		testing.expectf(t, sqlite_object_exists(&conn, "user_home_layouts"), "%s: user_home_layouts created", pass)
		testing.expectf(t, s0b_text(&conn, "SELECT count(*) FROM schema_migrations WHERE version IN ('259_agent_id_assignment.sql', '260_drop_fleet_roles.sql');") == "0", "%s: 259/260 not re-run", pass)
		testing.expectf(t, migration_applied(&conn, "259_agent_id_assignment.sql") && migration_applied(&conn, S0B_DROP), "%s: legacy names count as 259/260", pass)
		testing.expectf(t, table_column_exists(&conn, "task_chain_fleets", "paused"), "%s: paused kept", pass)
		testing.expectf(t, !table_column_exists(&conn, "task_chain_fleets", "paused_roles_json"), "%s: paused_roles_json stays dropped", pass)
		testing.expectf(t, s0b_text(&conn, "SELECT count(*) FROM schema_migrations WHERE version='131_fleet_pause.sql';") == "1", "%s: 131 is not re-run", pass)
	}
}
