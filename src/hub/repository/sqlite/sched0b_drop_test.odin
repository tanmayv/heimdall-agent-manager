#+private file
package sqlite

import "core:fmt"
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

// SCHED-0a/0b migrations (259, 260) on a database carrying the owner legacy
// source fences (v0.5.92 crash-looped on Mundus: 260 aborted with 'legacy
// canonical source is frozen'). Rows of 'frozen' / 'imported' chains are
// read-only and must be left alone; 'draining' and unfenced chains migrate as
// usual; the fence triggers are untouched; task_leases.review_role stays
// because owner_legacy_no_replaced_lease reads it.

OWNER_LEGACY_FENCES_SQL :: #load("../../../../tests/fixtures/owner_legacy_fences.sql", string)

OL_DIGEST :: "0000000000000000000000000000000000000000000000000000000000000000"

// Fleet rows (partial pause) and 'named' agent verdicts on four chains. The
// fleet columns depend on whether 259 (`paused`) has run.
ol_seed_rows :: proc(t: ^testing.T, conn: ^Conn, with_paused: bool) -> bool {
	ok := exec(conn, "PRAGMA foreign_keys=OFF;")
	for chain in ([]string{"chain_live", "chain_drain", "chain_frozen", "chain_imported"}) {
		if with_paused {
			ok = exec(conn, fmt.tprintf(`INSERT INTO task_chain_fleets (task_chain_id, agent_id, created_at, updated_at, roles_json, paused_roles_json, paused) VALUES ('%s', 'agt_partial', 'now', 'now', '["worker","sec"]', '["sec"]', 0);`, chain)) && ok
		} else {
			ok = exec(conn, fmt.tprintf(`INSERT INTO task_chain_fleets (task_chain_id, agent_id, created_at, updated_at, roles_json, paused_roles_json) VALUES ('%s', 'agt_partial', 'now', 'now', '["worker","sec"]', '["sec"]');`, chain)) && ok
		}
		ok = exec(conn, fmt.tprintf(`INSERT INTO task_reviews (task_id, chain_id, owner_user_id, attempt_no, role, reviewer_kind, reviewer_agent_id, verdict, created_at) VALUES ('task_%s', '%s', 'user_ol', 1, 'named', 'agent', 'agt_r', 'approve', 'now');`, chain, chain)) && ok
	}
	ok = exec(conn, "PRAGMA foreign_keys=ON;") && ok
	return testing.expect(t, ok, "seed fleet rows and verdicts")
}

// The fence tables, triggers and legacy state go in last: once a chain is
// frozen its rows cannot be written, not even by a fixture.
ol_install_fences :: proc(t: ^testing.T, conn: ^Conn) -> bool {
	if !testing.expect(t, exec(conn, OWNER_LEGACY_FENCES_SQL), "install owner legacy fences") do return false
	d := OL_DIGEST
	return testing.expect(t, exec(conn, fmt.tprintf(`INSERT INTO owner_legacy_source_generations (chain_id, account_id, generation) VALUES ('chain_drain', 'acct', 1), ('chain_frozen', 'acct', 1), ('chain_imported', 'acct', 1);
INSERT INTO owner_legacy_migrations (migration_id, chain_id, account_id, owner_bridge_id, owner_key_id, selection_digest, state, revision, frozen_generation, quiescence_digest, manifest_digest, receipt_digest) VALUES
 ('olm_drain', 'chain_drain', 'acct', 'brg_o', 'key_o', '%s', 'draining', 1, 0, '', '', ''),
 ('olm_frozen', 'chain_frozen', 'acct', 'brg_o', 'key_o', '%s', 'frozen', 2, 1, '%s', '', ''),
 ('olm_imported', 'chain_imported', 'acct', 'brg_o', 'key_o', '%s', 'imported', 3, 1, '%s', '%s', '%s');`, d, d, d, d, d, d, d)), "seed owner legacy migrations")
}

ol_fences_digest :: proc(conn: ^Conn) -> string {
	return s0b_text(conn, "SELECT count(*) || ':' || group_concat(name || '=' || sql, ';') FROM (SELECT name, sql FROM sqlite_master WHERE name LIKE 'owner_legacy%' ORDER BY name);")
}

ol_expect_migrated :: proc(t: ^testing.T, conn: ^Conn, pass, fences_before: string) {
	testing.expectf(t, migration_applied(conn, "259_agent_id_assignment.sql") && migration_applied(conn, S0B_DROP), "%s: 259 and 260 recorded", pass)
	testing.expectf(t, !table_column_exists(conn, "task_chain_fleets", "roles_json") && !table_column_exists(conn, "task_chain_fleets", "paused_roles_json"), "%s: fleet role columns dropped", pass)
	testing.expectf(t, table_column_exists(conn, "task_leases", "review_role"), "%s: review_role kept (owner_legacy_no_replaced_lease reads it)", pass)
	for chain in ([]string{"chain_live", "chain_drain"}) {
		testing.expectf(t, s0b_text(conn, fmt.tprintf("SELECT paused FROM task_chain_fleets WHERE task_chain_id='%s';", chain)) == "1", "%s: %s partial pause is a full pause", pass, chain)
		testing.expectf(t, s0b_text(conn, fmt.tprintf("SELECT role FROM task_reviews WHERE chain_id='%s';", chain)) == "review", "%s: %s verdict renamed", pass, chain)
	}
	for chain in ([]string{"chain_frozen", "chain_imported"}) {
		testing.expectf(t, s0b_text(conn, fmt.tprintf("SELECT paused FROM task_chain_fleets WHERE task_chain_id='%s';", chain)) == "0", "%s: %s fleet row untouched", pass, chain)
		testing.expectf(t, s0b_text(conn, fmt.tprintf("SELECT role FROM task_reviews WHERE chain_id='%s';", chain)) == "named", "%s: %s verdict untouched", pass, chain)
	}
	testing.expectf(t, ol_fences_digest(conn) == fences_before, "%s: fence triggers and tables unchanged", pass)
	testing.expectf(t, s0b_text(conn, "SELECT generation FROM owner_legacy_source_generations WHERE chain_id='chain_frozen';") == "1", "%s: frozen generation unchanged", pass)
	testing.expectf(t, s0b_text(conn, "SELECT count(*) FROM sqlite_temp_master WHERE name='owner_legacy_frozen_chains';") == "0", "%s: migration view dropped", pass)
}

// The v0.5.92 deploy path: a pre-259 database gains 259 and 260 in one boot.
@(test)
test_sched0_migrations_skip_owner_legacy_frozen_chains_from_258 :: proc(t: ^testing.T) {
	conn, path, ok := tmpl_open_file_prod(t, "s0_ol_258")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn, stop_before = "259_agent_id_assignment.sql")
	if !testing.expect(t, mig_ok, err.message) do return
	if !ol_seed_rows(t, &conn, false) || !ol_install_fences(t, &conn) do return
	fences := ol_fences_digest(&conn)
	testing.expect(t, strings.has_prefix(fences, "40:"), fences[:min(len(fences), 8)])
	for pass in ([]string{"upgrade", "restart"}) {
		mig_ok, err = run_migrations(&conn)
		if !testing.expectf(t, mig_ok, "%s: %s", pass, err.message) do return
		ol_expect_migrated(t, &conn, pass, fences)
	}
}

// Mundus after the failed v0.5.92 deploy: 259 is applied, 260 is not.
@(test)
test_sched0_260_skips_owner_legacy_frozen_chains_after_259 :: proc(t: ^testing.T) {
	conn, path, ok := tmpl_open_file_prod(t, "s0_ol_259")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn, stop_before = S0B_DROP)
	if !testing.expect(t, mig_ok, err.message) do return
	if !ol_seed_rows(t, &conn, true) || !ol_install_fences(t, &conn) do return
	fences := ol_fences_digest(&conn)

	// The fixture reproduces both failures of the v0.5.92 260: the unfiltered
	// verdict rename and the review_role drop abort.
	testing.expect(t, !exec(&conn, "UPDATE OR IGNORE task_reviews SET role = 'review' WHERE reviewer_kind = 'agent' AND role = 'named';"), "unfiltered rename hits the frozen guard")
	testing.expect(t, exec(&conn, "SAVEPOINT ol_drop;"))
	testing.expect(t, !exec(&conn, "ALTER TABLE task_leases DROP COLUMN review_role;"), "review_role drop refused while the fence trigger reads it")
	testing.expect(t, exec(&conn, "ROLLBACK TO ol_drop; RELEASE ol_drop;"))
	testing.expect(t, s0b_text(&conn, "SELECT count(*) FROM task_reviews WHERE role='named';") == "4", "nothing renamed by the failed attempt")

	for pass in ([]string{"upgrade", "restart"}) {
		mig_ok, err = run_migrations(&conn)
		if !testing.expectf(t, mig_ok, "%s: %s", pass, err.message) do return
		ol_expect_migrated(t, &conn, pass, fences)
	}
}

// Without the fences the view is empty and 260 still drops review_role.
@(test)
test_sched0_migrations_without_owner_legacy_fences_drop_review_role :: proc(t: ^testing.T) {
	conn, path, ok := tmpl_open_file_prod(t, "s0_ol_none")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, err.message) do return
	testing.expect(t, !owner_legacy_fences_present(&conn), "no fences")
	testing.expect(t, !table_column_exists(&conn, "task_leases", "review_role"), "review_role dropped")
	testing.expect(t, s0b_text(&conn, "SELECT count(*) FROM sqlite_temp_master WHERE name='owner_legacy_frozen_chains';") == "0", "migration view dropped")
}
