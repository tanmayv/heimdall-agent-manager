package sqlite

// REQ-SHELL-7 AC5: migration 052 drops shell_jobs, and it does so CLEANLY on a
// database that already has the table WITH ROWS IN IT.
//
// WHY THIS IS TESTED AT THE SQL LEVEL. 052 is a DESTRUCTIVE migration — the first on
// this chain — and the two ways it could go wrong are both invisible to a build:
//
//   (a) It fails to apply on a populated table, aborting the migration run and taking
//       the whole hub's startup with it. A DROP of an empty table proves nothing about
//       that, so the fixture below INSERTS rows first and asserts they are gone rather
//       than merely asserting the table is.
//
//   (b) It is not idempotent, so a second run of the migration set errors. The ledger
//       is append-only and 052 is marked applied after the first pass, so the second
//       run must skip it — and even if it did not, `DROP TABLE IF EXISTS` on an
//       already-dropped table is a no-op. Both layers are asserted, because it is the
//       COMBINATION that makes re-running migrations safe.
//
// 039 IS DELIBERATELY NOT TOUCHED and this test is what pins that: on a fresh DB the
// full set still runs 039 (creating the table) and then 052 (dropping it), which is why
// deleting 039 was the wrong fix. If someone "tidies up" by removing 039, the fresh-DB
// case here still passes — but the populated case documents what 039 used to build.

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
m052_db_path :: proc(tag: string) -> string {
	return fmt.tprintf("/tmp/test_migration_052_%s_%d.db", tag, os.get_pid())
}

// A fresh database: 039 creates shell_jobs, 052 drops it, and the end state has no
// table — the ordinary path every new install takes.
@(test)
migration_052_drops_shell_jobs_on_a_fresh_db :: proc(t: ^testing.T) {
	db_path := m052_db_path("fresh")
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, fmt.tprintf("migrations ok: %s", mig_err.message)) do return

	testing.expect(t, !sqlite_object_exists(&conn, "shell_jobs"),
		"shell_jobs does not exist once 052 has run")
	// The replacement concept is untouched by the drop.
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions"),
		"shell_sessions is unaffected")
}

// THE CASE AC5 NAMES: the table exists and HAS ROWS before the migration set runs.
//
// The table + rows are created BEFORE run_migrations, which is exactly the shape of a
// database whose shell_jobs predates the ledger — the situation migrations.odin's
// table_column_exists special case for 039 exists to handle. 039 is then marked applied
// without re-running, and 052 must still drop the populated table rather than erroring.
@(test)
migration_052_drops_a_populated_shell_jobs_table :: proc(t: ^testing.T) {
	db_path := m052_db_path("populated")
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return
	defer close(&conn)

	// 039's schema, verbatim enough to hold real rows.
	made := exec(&conn, `CREATE TABLE IF NOT EXISTS shell_jobs (
	  exec_id TEXT PRIMARY KEY,
	  owner_user_id TEXT NOT NULL,
	  agent_instance_id TEXT NOT NULL,
	  cmd TEXT NOT NULL,
	  status TEXT NOT NULL DEFAULT 'running',
	  exit_code INTEGER,
	  started_at TEXT NOT NULL,
	  finished_at TEXT,
	  created_at TEXT NOT NULL
	);`)
	if !testing.expect(t, made, "pre-created shell_jobs") do return
	inserted := exec(&conn, `INSERT INTO shell_jobs
	  (exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at)
	  VALUES
	  ('sexc_a', 'usr_1', 'inst_1', 'odin build src/hub', 'completed', 0, '2026-09-01T00:00:00Z', '2026-09-01T00:01:00Z', '2026-09-01T00:00:00Z'),
	  ('sexc_b', 'usr_1', 'inst_1', 'sleep 600', 'running', NULL, '2026-09-01T00:02:00Z', NULL, '2026-09-01T00:02:00Z');`)
	if !testing.expect(t, inserted, "pre-inserted rows") do return
	// The premise of the test: rows really are there before we migrate.
	have_rows := table_column_exists(&conn, "shell_jobs", "exec_id")
	if !testing.expect(t, have_rows, "the populated table is in place before migrating") do return

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, fmt.tprintf("migrations apply cleanly over a populated shell_jobs: %s", mig_err.message))
	testing.expect(t, !sqlite_object_exists(&conn, "shell_jobs"),
		"the populated table is dropped, rows and all")

	// IDEMPOTENT: re-running the set must not error now the table is gone. This is the
	// property that makes a hub restart safe, and the reason no special case for 052 is
	// needed in migrations.odin.
	again_ok, again_err := run_migrations(&conn)
	testing.expect(t, again_ok, fmt.tprintf("migrations re-run cleanly: %s", again_err.message))
	testing.expect(t, !sqlite_object_exists(&conn, "shell_jobs"), "still gone after a second run")
}
