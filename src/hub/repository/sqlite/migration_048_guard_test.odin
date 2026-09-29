package sqlite

// REQ-SHELL-13 N1 — migration 048's guard must key on the LAST object 048 creates, so a
// PARTIAL apply cannot read back as a complete one.
//
// WHY THIS IS NOT A PARANOID TEST. run_migrations has no transaction around its apply
// loop — the only BEGIN/COMMIT tokens in migrations.odin are inside CREATE TRIGGER bodies
// — so a failure part-way through a migration leaves behind exactly what it had already
// created. 048 creates shell_sessions_agent at its line 70 and the UNIQUE index
// shell_sessions_owner_session at its line 83, the final statement in the file. A guard
// keyed on the EARLY object therefore declares 048 done in a state where the UNIQUE index
// is missing, and that index is the constraint making the owner-scoped by-session-id read
// single-row by construction rather than by LIMIT 1 choosing arbitrarily between two rows.
//
// THE PARTIAL STATE IS SIMULATED HONESTLY, not asserted about in the abstract. A real
// interrupted apply leaves two things true at once: the ledger row is ABSENT (the crash
// beat mark_migration_applied) and the objects are PARTIALLY present. The test produces
// exactly that pair by migrating fully, then deleting the ledger row and dropping the last
// index — rather than trying to interrupt a real apply, which a test cannot do
// deterministically. The end state is what the guard reads, and it is identical either way.
//
// Both cases below FAIL against a guard keyed on shell_sessions_agent.

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
m048_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_mig048_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}

// Drops 048's LAST object and forgets the ledger row: the state an apply interrupted
// between 048's line 70 and its line 83 would leave on disk.
@(private = "file")
m048_simulate_partial_apply :: proc(t: ^testing.T, conn: ^Conn) -> bool {
	ok1 := exec(conn, "DROP INDEX IF EXISTS shell_sessions_owner_session;")
	ok2 := exec(conn, "DELETE FROM schema_migrations WHERE version='048_shell_sessions_kind_and_key.sql';")
	if !testing.expect(t, ok1 && ok2, "partial-apply simulation applied") do return false
	// The state that makes this test meaningful: the EARLY object survived, the LAST did not.
	early := testing.expect(t, sqlite_object_exists(conn, "shell_sessions_agent"), "the early object 048 creates must still be present, or the test proves nothing")
	late := testing.expect(t, !sqlite_object_exists(conn, "shell_sessions_owner_session"), "the last object 048 creates must be absent")
	return early && late
}

// A half-applied 048 must NOT read back as applied. Keyed on shell_sessions_agent this
// returns true — the ledger row is gone, but the fallback finds the early index and says
// "done", leaving the UNIQUE constraint permanently missing with nothing to notice.
@(test)
m048_partial_apply_is_not_reported_as_applied :: proc(t: ^testing.T) {
	conn, ok := m048_db(t, "partial")
	if !ok do return
	defer close(&conn)

	// Sanity: a COMPLETE apply does read back as applied, so a false negative below
	// would be caught rather than mistaken for the fix working.
	testing.expect(t, migration_applied(&conn, "048_shell_sessions_kind_and_key.sql"),
		"a fully migrated database must report 048 applied")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_owner_session"),
		"a fully migrated database has the UNIQUE index")

	if !m048_simulate_partial_apply(t, &conn) do return

	testing.expect(t, !migration_applied(&conn, "048_shell_sessions_kind_and_key.sql"),
		"a 048 that stopped before its UNIQUE index must NOT report as applied")
}

// And the self-heal twin must actually re-run on that database and restore the index.
// Keyed on the early object it returns true immediately and repairs nothing — which is the
// worst place to bail out, since this path exists precisely to fix a database 048 did not
// finish.
@(test)
m048_self_heal_restores_the_unique_index_after_a_partial_apply :: proc(t: ^testing.T) {
	conn, ok := m048_db(t, "selfheal")
	if !ok do return
	defer close(&conn)

	if !m048_simulate_partial_apply(t, &conn) do return

	testing.expect(t, upgrade_shell_sessions_kind_and_key_schema(&conn), "self-heal runs clean")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_owner_session"),
		"the self-heal must restore the UNIQUE index a partial apply left missing")
	// It is idempotent: a second run on the now-complete database is a no-op, not a rebuild.
	testing.expect(t, upgrade_shell_sessions_kind_and_key_schema(&conn), "self-heal is idempotent")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_owner_session"), "index still there")
}
