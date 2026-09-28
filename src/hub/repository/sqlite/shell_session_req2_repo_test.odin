package sqlite

// REQ-SHELL-2 repository acceptance tests:
//   §10 / AC13  the live port-holder lookup, and the port being RELEASED when the
//               holder reaches a terminal status
//   §11 / AC14  the live-session counts the caps are built on
//   AC9         output is NEVER stored in the hub DB — asserted against the schema
//   migration 049 columns survive an upgrade and are idempotent

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
req2_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_shell_req2_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	return conn, true
}

@(private = "file")
req2_session :: proc(session_id, owner, bridge, kind: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = owner,
		bridge_id        = bridge,
		kind             = kind,
		cmd              = "serve",
		status           = domain.Shell_Session_Status_Running,
		started_at       = "2026-09-28T00:00:00Z",
		created_at       = "2026-09-28T00:00:00Z",
		last_activity_at = "2026-09-28T00:00:00Z",
	}
}

// --- AC13: a port is held while live and RELEASED when terminal --------------

@(test)
test_req2_port_is_held_while_live_and_released_when_terminal :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "port")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	holder := req2_session("sh_holder", "owner_a", "brg_1", domain.Shell_Session_Kind_Server)
	holder.chain_id = "chain_1"
	holder.server_port = 8111
	_, err := iface.shell_session_upsert(&repo, holder)
	testing.expect(t, err.code == .None, "holder stored")

	found, held, ferr := iface.shell_session_find_live_by_port(&repo, "brg_1", 8111)
	testing.expect(t, ferr.code == .None, "lookup ok")
	testing.expect(t, held, "a LIVE session holds its port")
	testing.expect_value(t, found.session_id, "sh_holder")

	// A different bridge is a different host: the same port number there is not a
	// conflict, which is why the lookup is bridge-scoped.
	_, other_bridge, _ := iface.shell_session_find_live_by_port(&repo, "brg_2", 8111)
	testing.expect(t, !other_bridge, "a port on another bridge is not this bridge's conflict")

	// RELEASE. The holder exits; the port must become free — "live" is the domain's
	// terminal-status set inverted, so this follows from the same rule that makes a
	// session terminal anywhere else.
	holder.status = domain.Shell_Session_Status_Exited
	holder.finished_at = "2026-09-28T01:00:00Z"
	_, _ = iface.shell_session_upsert(&repo, holder)

	_, still_held, _ := iface.shell_session_find_live_by_port(&repo, "brg_1", 8111)
	testing.expect(t, !still_held, "a terminal session releases its port")
}

// The lookup is owner-UNSCOPED on purpose: a TCP port belongs to the host, so a
// conflict across tenants is a real conflict. (The MESSAGE the caller sees is
// asymmetric — see the service tests — but the detection must not be.)
@(test)
test_req2_port_conflict_is_detected_across_owners :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "portcross")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	holder := req2_session("sh_tenant_b", "owner_b", "brg_1", domain.Shell_Session_Kind_Server)
	holder.chain_id = "chain_b"
	holder.server_port = 9000
	_, _ = iface.shell_session_upsert(&repo, holder)

	found, held, _ := iface.shell_session_find_live_by_port(&repo, "brg_1", 9000)
	testing.expect(t, held, "another tenant's live hold is still a conflict on this host")
	testing.expect_value(t, found.owner_user_id, "owner_b")
}

// --- AC14: the counts the caps are built on ---------------------------------

@(test)
test_req2_live_counts_are_per_kind_and_per_scope :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "counts")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	for i in 0 ..< 3 {
		run := req2_session(fmt.tprintf("sh_run_%d", i), "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
		run.agent_instance_id = "inst_a"
		_, _ = iface.shell_session_upsert(&repo, run)
	}
	// A different agent's run must not count against inst_a's cap.
	other := req2_session("sh_run_other", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	other.agent_instance_id = "inst_b"
	_, _ = iface.shell_session_upsert(&repo, other)

	n, cerr := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Run, "agent_instance_id", "inst_a")
	testing.expect(t, cerr.code == .None, "count ok")
	testing.expect_value(t, n, 3)

	// Terminal sessions do not count: the cap bounds what is LIVE, so finished runs
	// never accumulate into a permanent lockout.
	done := req2_session("sh_run_0", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	done.agent_instance_id = "inst_a"
	done.status = domain.Shell_Session_Status_Exited
	done.finished_at = "2026-09-28T01:00:00Z"
	_, _ = iface.shell_session_upsert(&repo, done)

	n2, _ := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Run, "agent_instance_id", "inst_a")
	testing.expect_value(t, n2, 2)

	// Servers are counted per chain, and a run never counts as a server.
	srv := req2_session("sh_srv_1", "owner_a", "brg_1", domain.Shell_Session_Kind_Server)
	srv.chain_id = "chain_1"
	_, _ = iface.shell_session_upsert(&repo, srv)
	sn, _ := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Server, "chain_id", "chain_1")
	testing.expect_value(t, sn, 1)
}

// The scope column is a CLOSED SET taken from the domain, never free text, so the
// concatenated identifier cannot become an injection point.
@(test)
test_req2_live_count_refuses_an_unknown_scope_column :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "badcol")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	_, err := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Run, "cmd; DROP TABLE shell_sessions", "x")
	testing.expect(t, err.code != .None, "an unrecognised scope column is refused, not interpolated")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions"), "and the table is still there")
}

// --- AC9: output is NEVER in the hub DB -------------------------------------

// AC9's "assert the no-DB property". Asserted against the SCHEMA rather than a
// code path, because that is the form the property actually takes: if there is
// nowhere to put output, no future code path can start putting it there. Output
// is streamed or read on demand from the bridge and lives only on that host.
@(test)
test_req2_the_hub_schema_has_nowhere_to_store_output :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "nooutput")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	for column in ([]string{"output", "stdout", "stderr", "log", "output_tail", "log_text"}) {
		testing.expect(t, !table_column_exists(&conn, "shell_sessions", column),
			fmt.tprintf("shell_sessions must have no %q column: output never enters the hub DB", column))
	}
}

// --- migration 049 -----------------------------------------------------------

@(test)
test_req2_migration_049_adds_its_columns_and_is_idempotent :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "mig049")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	testing.expect(t, table_column_exists(&conn, "shell_sessions", "background"), "background column added")
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "conversation_id"), "conversation_id column added")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_conversation"), "the delivery lookup index exists")

	// The self-heal twin must be safe to re-run. SQLite has no ALTER TABLE ADD
	// COLUMN IF NOT EXISTS, so a naive re-exec is a hard "duplicate column name"
	// error that would abort startup migrations — this is the guard against that.
	testing.expect(t, upgrade_shell_sessions_background_schema(&conn), "the self-heal twin is idempotent")
	testing.expect(t, upgrade_shell_sessions_background_schema(&conn), "and still idempotent on a third run")

	// Re-running the whole migrator is likewise a no-op rather than a failure.
	again, _ := run_migrations(&conn)
	testing.expect(t, again, "migrations are re-runnable")
}

// background round-trips, and — the part that matters — a bridge-event upsert
// carrying the default false does NOT clear a run the user has already
// backgrounded. That is what the MAX() in the upsert is for.
@(test)
test_req2_background_is_one_way_through_the_upsert :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "bgcol")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	run := req2_session("sh_bg", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	run.agent_instance_id = "inst_a"
	run.conversation_id = "chat_1"
	run.background = true
	_, _ = iface.shell_session_upsert(&repo, run)

	stored, found, _ := iface.shell_session_get(&repo, "owner_a", "sh_bg")
	testing.expect(t, found, "stored")
	testing.expect(t, stored.background, "background round-trips")
	testing.expect_value(t, stored.conversation_id, "chat_1")

	// A bridge exit report carries background=false by default. It must not undo the
	// user's conversion.
	exit_report := req2_session("sh_bg", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	exit_report.agent_instance_id = "inst_a"
	exit_report.status = domain.Shell_Session_Status_Exited
	exit_report.background = false
	_, _ = iface.shell_session_upsert(&repo, exit_report)

	after, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_bg")
	testing.expect(t, after.background, "a default-carrying upsert cannot clear an explicit backgrounding")
	testing.expect_value(t, after.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, after.conversation_id, "chat_1")
}
