package sqlite

// REQ-SHELL-12 — the owner-scoped read must REFUSE TO GUESS, not LIMIT 1.
//
// WHY THIS LEVEL AND NOT THE SERVICE. The property under test is a property of the
// SQL and of how the statement is stepped: that the query asks for a second row at
// all, and that finding one suppresses the first. A fake repository answers "is this
// id ambiguous" by construction — it holds a map, so it cannot HAVE two rows for one
// key — which means a service-level test of this would pass against the unfixed code.
// Only a real table can be put into the state the refusal exists for.
//
// HOW THE AMBIGUOUS STATE IS REACHED, and why this is not testing an impossibility.
// Migration 048 installs `CREATE UNIQUE INDEX shell_sessions_owner_session ON
// shell_sessions(owner_user_id, session_id)`, so the second row cannot be inserted
// while that index stands. The fixture DROPS THE INDEX and inserts two rows with the
// SAME (owner_user_id, session_id) and DIFFERENT bridge_ids — distinct under the
// composite PK (bridge_id, session_id), so the PRIMARY KEY IS NEVER TOUCHED and the
// test does not weaken the very constraint the production path relies on.
//
// That dropped index IS the scenario, not a convenience: the surviving justifications
// for this work are a hand-edited database, a future migration that rebuilds the table
// without recreating the index, and a bug that drops it. The fixture reproduces the
// third directly and stands in for the other two.
//
// THIS IS DEFENCE IN DEPTH. Through every normal insert path the conflict branch is
// unreachable, and these tests do not claim otherwise — they claim that IF the state
// is reached, the read refuses instead of silently picking a row.

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
t12_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_shell_req12_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}

@(private = "file")
t12_row :: proc(session_id, bridge_id: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = "usr_t12",
		bridge_id        = bridge_id,
		kind             = "run",
		cmd              = "echo hi",
		status           = "running",
		started_at       = "2026-09-29T09:00:00Z",
		created_at       = "2026-09-29T09:00:00Z",
		last_activity_at = "2026-09-29T09:00:00Z",
	}
}

// t12_make_ambiguous forces the state the unique index normally forbids: two rows,
// same (owner_user_id, session_id), different bridge_id. The index is dropped first
// because it would otherwise reject the second insert; the composite PK is left
// intact and the differing bridge_id satisfies it.
@(private = "file")
t12_make_ambiguous :: proc(t: ^testing.T, conn: ^Conn, repo: ^iface.Shell_Session_Repository, session_id: string) -> bool {
	a_ok, _ := iface.shell_session_upsert(repo, t12_row(session_id, "brg_a"))
	if !testing.expect(t, a_ok, "first row inserted") do return false

	if !testing.expect(t, exec(conn, "DROP INDEX IF EXISTS shell_sessions_owner_session;"), "unique index dropped") do return false

	b_ok, _ := iface.shell_session_upsert(repo, t12_row(session_id, "brg_b"))
	if !testing.expect(t, b_ok, "second row inserted once the index is gone") do return false

	// Prove the fixture actually produced TWO rows. Without this the ambiguity tests
	// below could pass for the wrong reason — an upsert that silently overwrote row A
	// would leave one row, and "no conflict raised" would then look like a bug in the
	// code under test rather than a broken fixture.
	stmt: sqlite3_stmt = nil
	count_sql := cstring("SELECT COUNT(*) FROM shell_sessions WHERE owner_user_id = 'usr_t12' AND session_id = ?;")
	if !testing.expect(t, sqlite3_prepare_v2(conn.db, count_sql, -1, &stmt, nil) == SQLITE_OK, "count prepared") do return false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, session_id)
	if !testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW, "count stepped") do return false
	// Read the count as TEXT: conn.odin binds no sqlite3_column_int, and adding one
	// for a test assertion would be a change to the shared binding surface for no
	// gain. SQLite converts the integer for us and "2" is as checkable as 2.
	n := column_text_unowned(stmt, 0)
	return testing.expectf(t, n == "2", "fixture must produce exactly 2 rows, got %s", n)
}

// (a) THE NORMAL READ IS UNCHANGED. The whole risk of this change is that LIMIT 2 plus
// a second step breaks the ordinary single-row path, so that path is asserted first and
// in full rather than assumed.
@(test)
test_req12_single_row_read_is_unchanged :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "single")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	up_ok, _ := iface.shell_session_upsert(&repo, t12_row("sh_solo", "brg_a"))
	if !testing.expect(t, up_ok, "row inserted") do return

	session, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_solo")
	defer domain.shell_session_destroy(session)
	testing.expect(t, found, "unambiguous session is found")
	testing.expectf(t, err.code == .None, "no error on the normal path, got %v", err.code)
	testing.expectf(t, session.session_id == "sh_solo", "session_id round-trips, got %q", session.session_id)
	testing.expectf(t, session.bridge_id == "brg_a", "bridge_id round-trips, got %q", session.bridge_id)
	testing.expectf(t, session.cmd == "echo hi", "cmd round-trips, got %q", session.cmd)
	testing.expectf(t, session.status == "running", "status round-trips, got %q", session.status)
}

// A MISSING SESSION IS STILL A PLAIN MISS, not a conflict. This is the boundary that
// makes the conflict code meaningful: if absence also raised .Conflict, callers could
// not use the code to tell corruption from an ordinary 404.
@(test)
test_req12_absent_session_is_not_a_conflict :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "absent")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	session, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_nope")
	defer domain.shell_session_destroy(session)
	testing.expect(t, !found, "absent session is not found")
	testing.expectf(t, err.code == .None, "absence is not an error, got %v", err.code)
}

// (b) THE CORE ASSERTION. Two rows: the read must return the CONFLICT and MUST NOT
// return a row. Both halves are asserted — "raised an error" alone would still permit
// handing back a row alongside it, and a caller that checks `found` before `err` would
// then act on an arbitrary match anyway.
@(test)
test_req12_ambiguous_read_refuses_and_returns_no_row :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "ambig")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return

	session, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_dup")
	defer domain.shell_session_destroy(session)
	testing.expectf(t, err.code == .Conflict, "ambiguous read raises .Conflict, got %v (%s)", err.code, err.message)
	testing.expect(t, !found, "ambiguous read reports NOT found, so a found-first caller cannot act on a guess")
	testing.expectf(t, session.session_id == "", "ambiguous read returns NO row, got session_id %q", session.session_id)
	testing.expectf(t, session.bridge_id == "", "ambiguous read leaks no row fields, got bridge_id %q", session.bridge_id)
}

// AMBIGUITY IS SCOPED TO THE OWNER AND ID THAT ARE ACTUALLY DUPLICATED. A corrupt row
// pair must not poison unrelated reads — otherwise the refusal would take out the whole
// table rather than the one id it cannot resolve.
@(test)
test_req12_conflict_does_not_leak_to_other_ids_or_owners :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "scope")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return

	clean_ok, _ := iface.shell_session_upsert(&repo, t12_row("sh_clean", "brg_a"))
	if !testing.expect(t, clean_ok, "unrelated row inserted") do return

	clean, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_clean")
	defer domain.shell_session_destroy(clean)
	testing.expect(t, found, "a different id is still readable")
	testing.expectf(t, err.code == .None, "a different id raises no conflict, got %v", err.code)

	other, other_found, other_err := iface.shell_session_get(&repo, "usr_other", "sh_dup")
	defer domain.shell_session_destroy(other)
	testing.expect(t, !other_found, "another owner does not see the duplicated id")
	testing.expectf(t, other_err.code == .None, "another owner gets a plain miss, not a conflict, got %v", other_err.code)
}

// get_by_id IS DELIBERATELY UNCHANGED and this pins that decision. Its key
// (bridge_id, session_id) IS the composite PK T1 installed, so it is single-row by the
// PK itself rather than by LIMIT 1 — the two rows above differ in bridge_id precisely
// because the PK forces them to, which means each is individually resolvable here.
// If someone later "makes this consistent" by adding a conflict branch, this fails and
// says why.
@(test)
test_req12_get_by_id_stays_resolvable_under_owner_ambiguity :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "byid")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return

	a, a_found, a_err := iface.shell_session_get_by_id(&repo, "brg_a", "sh_dup")
	defer domain.shell_session_destroy(a)
	testing.expect(t, a_found, "bridge A resolves its own row")
	testing.expectf(t, a_err.code == .None, "bridge-qualified read is not ambiguous, got %v", a_err.code)
	testing.expectf(t, a.bridge_id == "brg_a", "bridge A got ITS row, not bridge B's, got %q", a.bridge_id)

	b, b_found, b_err := iface.shell_session_get_by_id(&repo, "brg_b", "sh_dup")
	defer domain.shell_session_destroy(b)
	testing.expect(t, b_found, "bridge B resolves its own row")
	testing.expectf(t, b_err.code == .None, "bridge-qualified read is not ambiguous, got %v", b_err.code)
	testing.expectf(t, b.bridge_id == "brg_b", "bridge B got ITS row, got %q", b.bridge_id)
}

// THE SECOND INSTANCE OF THE DEFECT SHAPE: set_kill_requested's read-back.
//
// BE PRECISE ABOUT WHAT THIS ASSERTS. The boolean this returned was already invariant
// under ambiguity — the UPDATE it follows hits EVERY matching row, so a non-empty
// kill_requested_at was true of all of them. This test does not claim a wrong answer
// was being returned. It asserts that the call now REFUSES to report success for a
// session it cannot identify, which matters because the reap path
// (shell_session_reap.odin:202) reaches this without passing through the get above.
@(test)
test_req12_kill_intent_readback_refuses_when_ambiguous :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "kill")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return

	pending, err := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_dup", "2026-09-29T09:05:00Z")
	testing.expectf(t, err.code == .Conflict, "ambiguous kill read-back raises .Conflict, got %v (%s)", err.code, err.message)
	testing.expect(t, !pending, "ambiguous kill read-back does not report success")
}

// The same call on an UNAMBIGUOUS session still works, including the idempotent second
// kill the read-back exists to make succeed. Without this, the conflict branch above
// could be passing because the whole procedure broke.
@(test)
test_req12_kill_intent_readback_unchanged_when_unambiguous :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "killok")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	up_ok, _ := iface.shell_session_upsert(&repo, t12_row("sh_solo", "brg_a"))
	if !testing.expect(t, up_ok, "row inserted") do return

	first, err1 := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_solo", "2026-09-29T09:05:00Z")
	testing.expectf(t, err1.code == .None, "first kill raises no error, got %v", err1.code)
	testing.expect(t, first, "first kill reports the intent pending")

	// The idempotent retry: first-writer-wins on the column, success on the read-back.
	second, err2 := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_solo", "2026-09-29T09:06:00Z")
	testing.expectf(t, err2.code == .None, "second kill raises no error, got %v", err2.code)
	testing.expect(t, second, "second kill still reports pending")

	// A session that does not exist for this owner is still a plain false, not a conflict.
	missing, err3 := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_nope", "2026-09-29T09:05:00Z")
	testing.expectf(t, err3.code == .None, "absent session is not an error, got %v", err3.code)
	testing.expect(t, !missing, "absent session reports false")
}
