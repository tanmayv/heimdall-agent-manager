package sqlite

// REQ-SHELL-3 repository acceptance tests — the DURABLE half of "a kill must
// survive a disconnected bridge":
//   AC1  the intent PERSISTS (round-trip through the column)
//   AC3  re-requesting a kill is idempotent: first-writer-wins keeps the original
//        timestamp rather than sliding it forward
//   §5   a terminal status CLEARS the intent, via the upsert rather than a caller
//        remembering to, and a bridge-event upsert that knows nothing about the
//        column cannot silently drop a pending kill
//   the replay query: outstanding only, oldest first, bridge-scoped
//   migration 050 + its self-heal twin, including the PARTIAL-APPLY case that
//   keying the guard on the last object exists to catch

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
req3_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_shell_req3_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	return conn, true
}

@(private = "file")
req3_session :: proc(session_id, owner, bridge: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = owner,
		bridge_id        = bridge,
		kind             = domain.Shell_Session_Kind_Shell,
		cmd              = "zsh",
		status           = domain.Shell_Session_Status_Running,
		started_at       = "2026-09-28T00:00:00Z",
		created_at       = "2026-09-28T00:00:00Z",
		last_activity_at = "2026-09-28T00:00:00Z",
	}
}

@(private = "file")
req3_repo :: proc(t: ^testing.T, conn: ^Conn, impl: ^Shell_Session_Repo_SQLite) -> (iface.Shell_Session_Repository, bool) {
	migrated, _ := run_migrations(conn)
	if !testing.expect(t, migrated, "migrations ran") do return {}, false
	return new_shell_session_repository(impl, conn), true
}

// --- AC1 + AC3: the intent persists, and a second request keeps the first time --

@(test)
test_req3_kill_intent_persists_and_is_first_writer_wins :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "persist")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return

	_, err := iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	testing.expect(t, err.code == .None, "session stored")

	// A fresh session carries no intent.
	before, found, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect(t, found, "session readable")
	testing.expect_value(t, before.kill_requested_at, "")
	testing.expect(t, !domain.shell_session_kill_intent_pending(before), "nothing pending yet")

	// AC1: accepting a kill writes the intent, and it reads back.
	set, set_err := iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	testing.expect(t, set_err.code == .None, "intent write ok")
	testing.expect(t, set, "intent reported outstanding")

	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.kill_requested_at, "2026-09-28T10:00:00Z")
	testing.expect(t, domain.shell_session_kill_intent_pending(stored), "intent is pending on a live session")

	// AC3, the hub half: a SECOND kill is a success and does NOT move the
	// timestamp. "Pending since" must be when the user first asked, or a retried
	// kill would look newer than it is forever.
	again, again_err := iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T11:30:00Z")
	testing.expect(t, again_err.code == .None, "second intent write ok")
	testing.expect(t, again, "second request still reports outstanding — a retry is not a failure")

	after, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, after.kill_requested_at, "2026-09-28T10:00:00Z")
}

// A kill intent cannot be written for someone else's session: the write is
// owner-scoped, so a wrong owner matches no row and reports false rather than
// touching it.
@(test)
test_req3_kill_intent_write_is_owner_scoped :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "owner")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return

	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))

	set, _ := iface.shell_session_set_kill_requested(&repo, "owner_b", "sh_1", "2026-09-28T10:00:00Z")
	testing.expect(t, !set, "another owner cannot request a kill on this session")

	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.kill_requested_at, "")
}

// --- §5: a terminal status clears the intent, through the upsert ---------------

// The intent must be retired the moment the session is over, and it must happen in
// the upsert rather than in a caller: a spent intent left set would be re-delivered
// on the next reconnect, and the pid it named may by then belong to another process.
@(test)
test_req3_terminal_status_clears_the_intent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "clear")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return

	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")

	// The shape a bridge shell_exited upsert has: a terminal status, and
	// kill_requested_at left at its zero value because the bridge never sets it.
	exited := req3_session("sh_1", "owner_a", "brg_1")
	exited.status      = domain.Shell_Session_Status_Killed
	exited.finished_at = "2026-09-28T10:00:05Z"
	_, exit_err := iface.shell_session_upsert(&repo, exited)
	testing.expect(t, exit_err.code == .None, "exit upsert ok")

	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Killed)
	testing.expect_value(t, stored.kill_requested_at, "")
	testing.expect(t, !domain.shell_session_kill_intent_pending(stored), "a spent intent is not pending")

	// Every terminal status clears it, not just "killed" — the set comes from
	// domain.SHELL_SESSION_TERMINAL_STATUSES, so this holds for whatever is in it.
	for terminal_status in domain.SHELL_SESSION_TERMINAL_STATUSES {
		live := req3_session("sh_loop", "owner_a", "brg_1")
		_, _ = iface.shell_session_upsert(&repo, live)
		_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_loop", "2026-09-28T10:00:00Z")
		pending, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_loop")
		testing.expect(t, pending.kill_requested_at != "", "intent set before the terminal write")

		done := req3_session("sh_loop", "owner_a", "brg_1")
		done.status = terminal_status
		_, _ = iface.shell_session_upsert(&repo, done)
		cleared, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_loop")
		testing.expect(t, cleared.kill_requested_at == "",
			fmt.tprintf("terminal status %q must clear the intent", terminal_status))

		_, _ = iface.shell_session_delete(&repo, "owner_a", "sh_loop")
	}
}

// The other direction, and the one a careless CASE would break: an upsert that is
// NOT terminal and carries no intent must LEAVE a pending one alone. Every
// bridge-event write has exactly that shape, so getting this wrong would drop the
// pending kill on the next status ping.
@(test)
test_req3_a_non_terminal_upsert_does_not_drop_a_pending_intent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "keep")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return

	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")

	ping := req3_session("sh_1", "owner_a", "brg_1")
	ping.last_activity_at = "2026-09-28T10:00:09Z"
	_, _ = iface.shell_session_upsert(&repo, ping)

	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.kill_requested_at, "2026-09-28T10:00:00Z")
}

// --- the replay query --------------------------------------------------------

// The reconnect replay must see exactly the OUTSTANDING kills on ITS bridge:
// oldest first, no spent intents, no other bridge's sessions, nothing without an
// intent at all.
@(test)
test_req3_pending_kill_listing_is_outstanding_only_and_bridge_scoped :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "list")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return

	// Two outstanding on brg_1, requested in a known order.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_newer", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_newer", "2026-09-28T10:05:00Z")
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_older", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_older", "2026-09-28T10:00:00Z")

	// No intent at all.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_quiet", "owner_a", "brg_1"))

	// Intent that was spent — the session terminated. Written as a kill request
	// followed by a terminal upsert, i.e. exactly how a real one is spent.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_done", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_done", "2026-09-28T09:00:00Z")
	done := req3_session("sh_done", "owner_a", "brg_1")
	done.status = domain.Shell_Session_Status_Exited
	_, _ = iface.shell_session_upsert(&repo, done)

	// Another bridge's outstanding kill, which this bridge must never be handed.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_elsewhere", "owner_a", "brg_2"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_elsewhere", "2026-09-28T08:00:00Z")

	pending, list_err := iface.shell_session_list_pending_kills(&repo, "brg_1", 100)
	testing.expect(t, list_err.code == .None, "listing ok")
	defer domain.shell_sessions_destroy(pending)

	if !testing.expect_value(t, len(pending), 2) do return
	// Oldest first: the longest-waiting kill is delivered first.
	testing.expect_value(t, pending[0].session_id, "sh_older")
	testing.expect_value(t, pending[1].session_id, "sh_newer")
	for s in pending {
		testing.expect(t, domain.shell_session_kill_intent_pending(s), "every listed intent is outstanding")
	}
}

// A session whose status is terminal but which somehow still carries an intent (a
// row written before the auto-clear existed, or edited by hand) is excluded by the
// QUERY as well as by the domain predicate. Belt and braces on purpose: replaying a
// spent kill is how a signal reaches a recycled pid.
@(test)
test_req3_pending_kill_listing_excludes_a_terminal_row_that_still_carries_an_intent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "stale")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return

	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	// Force the state the upsert would never leave behind, bypassing it entirely.
	testing.expect(t, exec(&conn, "UPDATE shell_sessions SET status='exited' WHERE session_id='sh_1';"),
		"status forced terminal behind the upsert's back")

	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect(t, stored.kill_requested_at != "", "the stale intent is really still there")
	testing.expect(t, !domain.shell_session_kill_intent_pending(stored), "but it is not OUTSTANDING")

	pending, _ := iface.shell_session_list_pending_kills(&repo, "brg_1", 100)
	defer domain.shell_sessions_destroy(pending)
	testing.expect_value(t, len(pending), 0)
}

// --- migration 050 -----------------------------------------------------------

@(test)
test_req3_migration_050_adds_its_objects_and_is_idempotent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "mig050")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	testing.expect(t, table_column_exists(&conn, "shell_sessions", "kill_requested_at"), "kill_requested_at column added")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_pending_kill"), "the replay lookup index exists")

	testing.expect(t, upgrade_shell_sessions_kill_intent_schema(&conn), "the self-heal twin is idempotent")
	testing.expect(t, upgrade_shell_sessions_kill_intent_schema(&conn), "and still idempotent on a third run")

	again, _ := run_migrations(&conn)
	testing.expect(t, again, "migrations are re-runnable")
}

// THE PARTIAL-APPLY CASE (REQ-SHELL-13 N1), which is why 050's skip guard is keyed
// on the INDEX — the last object it creates — rather than on the column.
//
// run_migrations is not transactional, so a pass that added the column and died
// before the index is a reachable state, and on a database that reached 050 through
// the pre-ledger recovery path there is no ledger row to fall back on either. A guard
// keyed on the column would declare that database finished and the replay lookup
// would have no index, forever.
//
// Simulated exactly: drop the index AND the ledger row, leaving the column. Then the
// whole migrator must (a) not report it as already applied, (b) not die on the
// duplicate column the migration file would re-add, and (c) end with both objects
// present. (b) is the reason the guard has a repair branch rather than only a skip:
// the self-heal twins run after the loop, so a fall-through here would abort startup
// on the very state the guard exists to catch.
@(test)
test_req3_migration_050_guard_catches_and_repairs_a_partial_apply :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "partial")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	testing.expect(t, exec(&conn, "DROP INDEX IF EXISTS shell_sessions_pending_kill;"), "index dropped")
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='050_shell_sessions_kill_intent.sql';"),
		"ledger row removed — the pre-ledger recovery path has none either")
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "kill_requested_at"), "the column is still there")
	testing.expect(t, !sqlite_object_exists(&conn, "shell_sessions_pending_kill"), "…and the index is not")

	// (a) Keyed on the last object, this half-applied database does NOT read back as
	// applied. A column-keyed check would have said it did.
	testing.expect(t, !migration_applied(&conn, "050_shell_sessions_kill_intent.sql"),
		"a half-applied 050 must not read back as applied")

	// (b) + (c) The migrator repairs it instead of dying on the duplicate column.
	repaired, rerr := run_migrations(&conn)
	testing.expect(t, repaired, fmt.tprintf("the migrator must repair a half-applied 050, not fail: %s", rerr.message))
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_pending_kill"), "index restored")
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "kill_requested_at"), "column untouched")
	testing.expect(t, migration_applied(&conn, "050_shell_sessions_kill_intent.sql"), "and now it is applied")

	// The repaired index really is the one the replay lookup needs: a pending-kill
	// listing works against it.
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	pending, _ := iface.shell_session_list_pending_kills(&repo, "brg_1", 100)
	defer domain.shell_sessions_destroy(pending)
	testing.expect_value(t, len(pending), 1)
}
