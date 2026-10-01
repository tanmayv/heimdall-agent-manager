package sqlite

// REQ-SHELL-8 item 6 — retention for TERMINAL shell_sessions rows.
//
// Output got a 5-day window and the rows got none, so every run a bridge ever
// executed left a row behind forever and every list query degraded permanently.
// These tests pin the two halves of the rule that matters: old terminal rows go,
// and LIVE rows never do, whatever their age.
//
// Ages are injected as timestamps, never slept: the cutoff is a parameter, so a
// test places it wherever it needs the boundary to fall.

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
retention_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_shell_retention_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}

@(private = "file")
retention_row :: proc(session_id, status, finished_at: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = "usr_ret",
		bridge_id        = "brg_ret",
		kind             = domain.Shell_Session_Kind_Run,
		cmd              = "echo hi",
		status           = status,
		started_at       = "2026-01-01T00:00:00Z",
		created_at       = "2026-01-01T00:00:00Z",
		last_activity_at = finished_at,
		finished_at      = finished_at,
	}
}

@(private = "file")
retention_count :: proc(conn: ^Conn) -> string {
	stmt: sqlite3_stmt = nil
	query := "SELECT COUNT(*) FROM shell_sessions;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return column_text(stmt, 0)
}

@(private = "file")
retention_exists :: proc(conn: ^Conn, session_id: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("SELECT 1 FROM shell_sessions WHERE session_id = '%s';", session_id)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW
}

// AC7, both halves in one table so the delete has to DISCRIMINATE rather than
// merely run: four rows of identical vintage, only the terminal ones eligible.
//
// The running and starting rows are the ones that matter. A server legitimately runs
// for weeks, so an age-only sweep would delete the row of a process that is still
// alive — the row whose loss is least recoverable, since the session then exists on
// the bridge with nothing on the hub describing it.
@(test)
test_shell_session_row_retention_spares_live_rows :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "live")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	old := "2026-01-02T00:00:00Z" // ancient, by any window
	for row in ([]domain.Shell_Session{
		retention_row("shl_exited", domain.Shell_Session_Status_Exited, old),
		retention_row("shl_killed", domain.Shell_Session_Status_Killed, old),
		retention_row("shl_failed", domain.Shell_Session_Status_Failed, old),
		retention_row("shl_running", domain.Shell_Session_Status_Running, old),
		retention_row("shl_starting", domain.Shell_Session_Status_Starting, old),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}

	deleted, err := iface.shell_session_delete_terminal_before(&repo, "2026-06-01T00:00:00Z")
	testing.expect(t, err.code == .None, "retention sweep succeeded")
	testing.expectf(t, deleted == 3, "only the three TERMINAL rows went, got %d", deleted)

	testing.expect(t, !retention_exists(&conn, "shl_exited"), "exited row reclaimed")
	testing.expect(t, !retention_exists(&conn, "shl_killed"), "killed row reclaimed")
	testing.expect(t, !retention_exists(&conn, "shl_failed"), "failed row reclaimed")
	testing.expect(t, retention_exists(&conn, "shl_running"), "a RUNNING row is never removed, whatever its age")
	testing.expect(t, retention_exists(&conn, "shl_starting"), "a STARTING row is never removed, whatever its age")
}

// The boundary itself: the same terminal row survives a cutoff before it and goes at
// a cutoff after it. Without this, a sweep that deleted every terminal row would pass
// the test above.
@(test)
test_shell_session_row_retention_respects_the_cutoff :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "cutoff")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	row := retention_row("shl_boundary", domain.Shell_Session_Status_Exited, "2026-03-10T00:00:00Z")
	saved, serr := iface.shell_session_upsert(&repo, row)
	testing.expect(t, saved && serr.code == .None, "row seeded")

	deleted, err := iface.shell_session_delete_terminal_before(&repo, "2026-03-01T00:00:00Z")
	testing.expect(t, err.code == .None && deleted == 0, "a row that ended AFTER the cutoff is kept")
	testing.expect(t, retention_exists(&conn, "shl_boundary"), "still there")

	deleted2, err2 := iface.shell_session_delete_terminal_before(&repo, "2026-03-20T00:00:00Z")
	testing.expect(t, err2.code == .None && deleted2 == 1, "the same row past the cutoff is removed")
	testing.expect(t, !retention_exists(&conn, "shl_boundary"), "and is gone")
}

// A terminal row with no finished_at must still age out. Terminal status can be
// INFERRED — a bridge that never returned, a reconcile reaping an orphan — and such a
// row carries no end time. Without the COALESCE fallback it would compare against
// NULL, match nothing, and become immortal: the exact unbounded growth this exists to
// stop, hiding in the rows least likely to be noticed.
@(test)
test_shell_session_row_retention_handles_missing_finished_at :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "nofinish")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	row := retention_row("shl_nofinish", domain.Shell_Session_Status_Failed, "")
	row.last_activity_at = ""
	row.started_at = "2026-01-05T00:00:00Z"
	saved, serr := iface.shell_session_upsert(&repo, row)
	testing.expect(t, saved && serr.code == .None, "row seeded")

	deleted, err := iface.shell_session_delete_terminal_before(&repo, "2026-06-01T00:00:00Z")
	testing.expect(t, err.code == .None, "sweep succeeded")
	testing.expectf(t, deleted == 1, "a terminal row with no end time ages out on started_at, got %d", deleted)
}

// An empty cutoff is a caller that failed to read a clock. It must be REFUSED, not
// treated as "delete nothing" and certainly not as a comparison that could match:
// a silent no-op would hide a broken sweep for as long as nobody looked at row counts.
@(test)
test_shell_session_row_retention_refuses_an_empty_cutoff :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "nocutoff")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	row := retention_row("shl_safe", domain.Shell_Session_Status_Exited, "2026-01-02T00:00:00Z")
	saved, _ := iface.shell_session_upsert(&repo, row)
	testing.expect(t, saved, "row seeded")

	deleted, err := iface.shell_session_delete_terminal_before(&repo, "")
	testing.expect(t, err.code == .Validation_Failed, "an empty cutoff is refused, not silently ignored")
	testing.expect(t, deleted == 0, "and nothing was deleted")
	testing.expect(t, retention_exists(&conn, "shl_safe"), "the row is untouched")
	// column_text allocates; the count is compared and then freed so the suite's
	// memory tracking stays clean.
	count := retention_count(&conn)
	defer delete(count)
	testing.expect(t, count == "1", "the table is intact")
}
