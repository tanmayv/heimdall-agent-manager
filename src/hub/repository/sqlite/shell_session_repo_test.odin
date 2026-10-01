package sqlite

// REQ-SHELL-1 acceptance tests for the shell_sessions rekey + kind collapse:
//   §1/§4 migration over rows of every OLD kind, on a DB that predates 048
//   §7    (bridge_id, session_id) primary key — a cross-bridge id cannot clobber
//   §5/§6 per-kind scope rules enforced by the query layer

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
shell_test_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_shell_sessions_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	return conn, true
}

@(private = "file")
shell_test_session :: proc(session_id, owner, bridge, kind: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = owner,
		bridge_id        = bridge,
		kind             = kind,
		cmd              = "echo hi",
		status           = domain.Shell_Session_Status_Running,
		started_at       = "2026-09-28T00:00:00Z",
		created_at       = "2026-09-28T00:00:00Z",
		last_activity_at = "2026-09-28T00:00:00Z",
	}
}

@(private = "file")
shell_test_scalar :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return column_text(stmt, 0)
}

// --- §4: migration over a pre-048 table holding every old kind ---------------
//
// Builds the 041-era schema by hand (bare session_id PRIMARY KEY, old kind
// vocabulary), seeds one row per old kind, then runs the migrator and checks the
// rows survived with the new vocabulary — and that the dead `agent` row is gone
// rather than remapped onto a kind that would misdescribe it.
@(test)
test_shell_sessions_migration_rewrites_every_old_kind :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "migrate")
	if !ok do return
	defer close(&conn)

	// The 041 schema verbatim, so this is a genuine upgrade rather than a fresh bootstrap.
	testing.expect(t, exec(&conn, MIGRATION_041_SHELL_SESSIONS), "041-era table created")
	seed := `INSERT INTO shell_sessions (session_id, owner_user_id, bridge_id, kind, cmd, status, started_at, created_at) VALUES
	  ('sh_cmd',  'user_a', 'brg_1', 'command',     'echo cmd',  'exited',  '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z'),
	  ('sh_int',  'user_a', 'brg_1', 'interactive', 'zsh',       'running', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z'),
	  ('sh_srv',  'user_a', 'brg_1', 'server',      'serve',     'running', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z'),
	  ('sh_agt',  'user_a', 'brg_1', 'agent',       'claude',    'running', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');`
	testing.expect(t, exec(&conn, seed), "seeded one row of every old kind")

	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok over a pre-048 table")

	// command -> run, interactive -> shell, server untouched.
	k_cmd := shell_test_scalar(&conn, "SELECT kind FROM shell_sessions WHERE session_id='sh_cmd';")
	k_int := shell_test_scalar(&conn, "SELECT kind FROM shell_sessions WHERE session_id='sh_int';")
	k_srv := shell_test_scalar(&conn, "SELECT kind FROM shell_sessions WHERE session_id='sh_srv';")
	defer delete(k_cmd); defer delete(k_int); defer delete(k_srv)
	testing.expect_value(t, k_cmd, domain.Shell_Session_Kind_Run)
	testing.expect_value(t, k_int, domain.Shell_Session_Kind_Shell)
	testing.expect_value(t, k_srv, domain.Shell_Session_Kind_Server)

	// The agent row is dropped, and no other row was lost with it.
	n_agent := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions WHERE kind='agent';")
	n_total := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions;")
	defer delete(n_agent); defer delete(n_total)
	testing.expect_value(t, n_agent, "0")
	testing.expect_value(t, n_total, "3")

	// Payload survived the table rebuild, not just the kind column.
	cmd_col := shell_test_scalar(&conn, "SELECT cmd FROM shell_sessions WHERE session_id='sh_int';")
	defer delete(cmd_col)
	testing.expect_value(t, cmd_col, "zsh")

	// Re-running is a no-op rather than a second rebuild.
	mig_ok2, _ := run_migrations(&conn)
	testing.expect(t, mig_ok2, "migrations are idempotent")
	n_total2 := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions;")
	defer delete(n_total2)
	testing.expect_value(t, n_total2, "3")
}

// --- §7: (bridge_id, session_id) primary key --------------------------------
//
// The regression this guards: session ids are minted per-bridge and carry no
// bridge or owner qualifier, so under the old bare session_id PRIMARY KEY a
// second bridge upserting the same id OVERWROTE the first bridge's row — across
// tenants, since the two rows can belong to different owners.
@(test)
test_shell_session_cross_bridge_id_collision_does_not_clobber :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "collide")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)

	// The SAME session_id on two different bridges, owned by two different users.
	a := shell_test_session("shl_collision", "user_a", "brg_1", domain.Shell_Session_Kind_Shell)
	b := shell_test_session("shl_collision", "user_b", "brg_2", domain.Shell_Session_Kind_Shell)
	b.cmd = "bash"
	ok_a, err_a := iface.shell_session_upsert(&repo, a)
	ok_b, err_b := iface.shell_session_upsert(&repo, b)
	testing.expect(t, ok_a && err_a.code == .None, "bridge 1 row stored")
	testing.expect(t, ok_b && err_b.code == .None, "bridge 2 row stored alongside it")

	// Two rows, not one overwritten row.
	n := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions WHERE session_id='shl_collision';")
	defer delete(n)
	testing.expect_value(t, n, "2")

	// Each owner still sees their own, unmodified.
	got_a, found_a, _ := iface.shell_session_get(&repo, "user_a", "shl_collision")
	testing.expect(t, found_a, "user_a's row survives")
	testing.expect_value(t, got_a.bridge_id, "brg_1")
	testing.expect_value(t, got_a.cmd, "echo hi")
	domain.shell_session_destroy(got_a)

	got_b, found_b, _ := iface.shell_session_get(&repo, "user_b", "shl_collision")
	testing.expect(t, found_b, "user_b's row survives")
	testing.expect_value(t, got_b.bridge_id, "brg_2")
	testing.expect_value(t, got_b.cmd, "bash")
	domain.shell_session_destroy(got_b)

	// The bridge-event lookup resolves within the REPORTING bridge only, so a
	// bridge cannot reach another bridge's identically-named session.
	by_id, found_by_id, _ := iface.shell_session_get_by_id(&repo, "brg_2", "shl_collision")
	testing.expect(t, found_by_id, "get_by_id resolves the reporting bridge's row")
	testing.expect_value(t, by_id.owner_user_id, "user_b")
	domain.shell_session_destroy(by_id)

	_, found_wrong, _ := iface.shell_session_get_by_id(&repo, "brg_absent", "shl_collision")
	testing.expect(t, !found_wrong, "get_by_id finds nothing for a bridge that has no such session")
}

// --- §7 (coordinator ruling U2): UNIQUE(owner_user_id, session_id) ------------
//
// The composite PK and this unique index stop two DIFFERENT failures, and neither
// implies the other. The PK stops a CROSS-TENANT clobber (the test above). This
// one keeps the OWNER-SCOPED read single-row: shell_session_get_sqlite is
// `WHERE owner_user_id = ? AND session_id = ? LIMIT 1` and backs kill, attach,
// signal, restart, set_port and log, so two same-owner rows on two bridges would
// make every one of those act on an arbitrarily chosen session, silently.
//
// The ruling accepts the trade knowingly: this converts a bad READ into a failed
// INSERT. A failed insert can orphan a process the bridge is running and the hub
// does not track — but that lands in REQ-SHELL-10's convergence net, whereas a
// wrong-row read lands in no net at all.
@(test)
test_shell_session_same_owner_id_collision_fails_at_insert :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "uniqowner")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)

	// Same owner, same session_id, two different bridges.
	first  := shell_test_session("shl_dup", "user_a", "brg_1", domain.Shell_Session_Kind_Shell)
	second := shell_test_session("shl_dup", "user_a", "brg_2", domain.Shell_Session_Kind_Shell)
	second.cmd = "bash"

	ok1, err1 := iface.shell_session_upsert(&repo, first)
	testing.expect(t, ok1 && err1.code == .None, "the first row stores normally")

	// LOUD, not silent. The composite PK does not catch this — the bridge differs,
	// so ON CONFLICT(bridge_id, session_id) sees no conflict and would happily
	// insert a second row for this owner. The unique index is what refuses it.
	ok2, err2 := iface.shell_session_upsert(&repo, second)
	testing.expect(t, !ok2, "a same-owner session_id collision across bridges FAILS at insert")
	testing.expect(t, err2.code != .None, "and reports an error rather than succeeding quietly")

	// Exactly one row, and it is the original — not half-overwritten by the reject.
	n := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions WHERE session_id='shl_dup';")
	defer delete(n)
	testing.expect_value(t, n, "1")

	got, found, _ := iface.shell_session_get(&repo, "user_a", "shl_dup")
	testing.expect(t, found, "the owner-scoped read still resolves")
	testing.expect_value(t, got.bridge_id, "brg_1")
	testing.expect_value(t, got.cmd, "echo hi")
	domain.shell_session_destroy(got)
}

// The index is UNIQUE, not merely present — a plain index would satisfy a name
// check while enforcing nothing, which is exactly the gap the ruling closed.
@(test)
test_shell_sessions_owner_session_index_is_unique :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "uniqidx")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	is_unique := shell_test_scalar(&conn, "SELECT \"unique\" FROM pragma_index_list('shell_sessions') WHERE name='shell_sessions_owner_session';")
	defer delete(is_unique)
	testing.expect_value(t, is_unique, "1")
}

// --- §5/§6: per-kind scope enforced in the query layer ----------------------
//
// The concrete leak this closes: list_by_chain(owner, "") used to bind chain_id=''
// and nothing else, so a caller asking about a chain got back every agent-scoped
// run and bridge-scoped shell, all of which legitimately have an empty chain_id.
@(test)
test_shell_session_list_respects_per_kind_scope :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "scope")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)
	owner := "user_scope"

	run := shell_test_session("sh_run", owner, "brg_1", domain.Shell_Session_Kind_Run)
	run.agent_instance_id = "inst_1"
	shell := shell_test_session("sh_shell", owner, "brg_1", domain.Shell_Session_Kind_Shell)
	server := shell_test_session("sh_server", owner, "brg_1", domain.Shell_Session_Kind_Server)
	server.chain_id = "chain_1"
	for s in ([]domain.Shell_Session{run, shell, server}) {
		up_ok, _ := iface.shell_session_upsert(&repo, s)
		testing.expect(t, up_ok, "seed upsert ok")
	}

	// A by-chain listing returns ONLY servers: chain is not a scope key for run or
	// shell, so neither may appear under a chain-narrowed query.
	by_chain, c_cursor, _ := iface.shell_session_list_by_chain(&repo, owner, "chain_1", "", "", 50)
	testing.expect_value(t, len(by_chain), 1)
	if len(by_chain) == 1 do testing.expect_value(t, by_chain[0].kind, domain.Shell_Session_Kind_Server)
	domain.shell_sessions_destroy(by_chain)
	delete(c_cursor)

	// The negative that used to leak: an EMPTY chain filter must not hand back the
	// run and the shell just because their chain_id column is empty.
	empty_chain, e_cursor, _ := iface.shell_session_list_by_chain(&repo, owner, "", "", "", 50)
	testing.expect_value(t, len(empty_chain), 0)
	domain.shell_sessions_destroy(empty_chain)
	delete(e_cursor)

	// Bridge is a scope key for shell and server, but NOT for run (run is agent
	// scoped), so a by-bridge listing returns exactly those two.
	by_bridge, b_cursor, _ := iface.shell_session_list_by_bridge(&repo, owner, "brg_1", "", "", 50)
	testing.expect_value(t, len(by_bridge), 2)
	saw_run := false
	for s in by_bridge do if s.kind == domain.Shell_Session_Kind_Run do saw_run = true
	testing.expect(t, !saw_run, "a by-bridge listing does not return agent-scoped runs")
	domain.shell_sessions_destroy(by_bridge)
	delete(b_cursor)

	// Agent is the scope key for run alone.
	by_agent, a_cursor, _ := iface.shell_session_list_by_owner(&repo, owner, iface.Shell_Session_List_Filter{agent_instance_id = "inst_1"}, "", 50)
	testing.expect_value(t, len(by_agent), 1)
	if len(by_agent) == 1 do testing.expect_value(t, by_agent[0].kind, domain.Shell_Session_Kind_Run)
	domain.shell_sessions_destroy(by_agent)
	delete(a_cursor)

	// An unfiltered owner-wide listing is unchanged: it names no scope column, so
	// it narrows by no kind and still returns everything the owner has.
	all, all_cursor, _ := iface.shell_session_list_by_owner(&repo, owner, iface.Shell_Session_List_Filter{}, "", 50)
	testing.expect_value(t, len(all), 3)
	domain.shell_sessions_destroy(all)
	delete(all_cursor)
}

// --- §5: the domain scope validator, including every negative ---------------
@(test)
test_shell_session_scope_validation :: proc(t: ^testing.T) {
	// Positive: each kind with exactly the columns its rule requires.
	good_run := shell_test_session("s1", "u", "brg_1", domain.Shell_Session_Kind_Run)
	good_run.agent_instance_id = "inst_1"
	_, _, run_ok := domain.shell_session_validate_scope(good_run)
	testing.expect(t, run_ok, "run with an agent_instance_id is valid")

	good_shell := shell_test_session("s2", "u", "brg_1", domain.Shell_Session_Kind_Shell)
	_, _, shell_ok := domain.shell_session_validate_scope(good_shell)
	testing.expect(t, shell_ok, "shell with a bridge_id alone is valid")

	good_server := shell_test_session("s3", "u", "brg_1", domain.Shell_Session_Kind_Server)
	good_server.chain_id = "chain_1"
	_, _, server_ok := domain.shell_session_validate_scope(good_server)
	testing.expect(t, server_ok, "server with chain + bridge is valid")

	// Negative: a required scope column missing.
	bad_run := shell_test_session("s4", "u", "brg_1", domain.Shell_Session_Kind_Run)
	col, missing, ok4 := domain.shell_session_validate_scope(bad_run)
	testing.expect(t, !ok4 && missing, "run without an agent_instance_id is rejected")
	testing.expect_value(t, col, "agent_instance_id")

	bad_server := shell_test_session("s5", "u", "brg_1", domain.Shell_Session_Kind_Server)
	col5, missing5, ok5 := domain.shell_session_validate_scope(bad_server)
	testing.expect(t, !ok5 && missing5, "server without a chain_id is rejected")
	testing.expect_value(t, col5, "chain_id")

	// Negative: a forbidden scope column populated with noise instead of left empty.
	noisy_shell := shell_test_session("s6", "u", "brg_1", domain.Shell_Session_Kind_Shell)
	noisy_shell.chain_id = "chain_1"
	col6, missing6, ok6 := domain.shell_session_validate_scope(noisy_shell)
	testing.expect(t, !ok6 && !missing6, "shell carrying a chain_id is rejected")
	testing.expect_value(t, col6, "chain_id")

	noisy_server := shell_test_session("s7", "u", "brg_1", domain.Shell_Session_Kind_Server)
	noisy_server.chain_id = "chain_1"
	noisy_server.agent_instance_id = "inst_1"
	col7, missing7, ok7 := domain.shell_session_validate_scope(noisy_server)
	testing.expect(t, !ok7 && !missing7, "server carrying an agent_instance_id is rejected")
	testing.expect_value(t, col7, "agent_instance_id")

	// Negative: bridge_id backs the primary key, so no kind may omit it.
	no_bridge := shell_test_session("s8", "u", "", domain.Shell_Session_Kind_Shell)
	col8, missing8, ok8 := domain.shell_session_validate_scope(no_bridge)
	testing.expect(t, !ok8 && missing8, "a session without a bridge_id is rejected")
	testing.expect_value(t, col8, "bridge_id")

	// Negative: a retired kind spelling is not silently accepted.
	retired := shell_test_session("s9", "u", "brg_1", "interactive")
	_, _, ok9 := domain.shell_session_validate_scope(retired)
	testing.expect(t, !ok9, "a retired kind spelling is rejected, not aliased")
}

// --- REQ-SHELL-10: the convergence diff's row set ----------------------------
//
// shell_session_list_live_by_bridge decides WHICH ROWS an incoming inventory is
// allowed to reason about, and the diff reads "live here, absent from the inventory"
// as death. So this query being wrong in either direction is a real failure: return
// another bridge's rows and one bridge's reconnect terminates another's sessions;
// return terminal rows and the diff revives finished ones.
//
// Asserted against real SQL rather than only through the service's fake, because the
// terminal set here is BOUND from domain.SHELL_SESSION_TERMINAL_STATUSES — a binding
// that a hand-written fake cannot get wrong and the SQL can.
@(test)
test_shell_session_list_live_by_bridge_is_scoped_and_live_only :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "livebybridge")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)

	seed :: proc(repo: ^iface.Shell_Session_Repository, id, owner, bridge, status: string) {
		s := shell_test_session(id, owner, bridge, domain.Shell_Session_Kind_Shell)
		s.status = status
		_, _ = iface.shell_session_upsert(repo, s)
	}
	seed(&repo, "shl_live_1",  "user_a", "brg_1", domain.Shell_Session_Status_Running)
	seed(&repo, "shl_live_2",  "user_a", "brg_1", domain.Shell_Session_Status_Starting)
	seed(&repo, "shl_exited",  "user_a", "brg_1", domain.Shell_Session_Status_Exited)
	seed(&repo, "shl_killed",  "user_a", "brg_1", domain.Shell_Session_Status_Killed)
	seed(&repo, "shl_failed",  "user_a", "brg_1", domain.Shell_Session_Status_Failed)
	// Another bridge AND another owner: the query is owner-unscoped by design, so the
	// bridge filter is the only thing keeping this row out.
	seed(&repo, "shl_other",   "user_b", "brg_2", domain.Shell_Session_Status_Running)

	rows, err := iface.shell_session_list_live_by_bridge(&repo, "brg_1", 100)
	testing.expect(t, err.code == .None, "live listing succeeds")
	defer domain.shell_sessions_destroy(rows)

	testing.expect_value(t, len(rows), 2)
	for row in rows {
		testing.expect_value(t, row.bridge_id, "brg_1")
		testing.expect(t, !domain.shell_session_is_terminal(row), "a terminal row must not be listed as live")
	}

	// A bridge with nothing live gets an empty set, not an error and not everyone
	// else's rows — the case a bridge that restarted clean hits on every reconnect.
	none, none_err := iface.shell_session_list_live_by_bridge(&repo, "brg_unknown", 100)
	testing.expect(t, none_err.code == .None, "an unknown bridge is not an error")
	defer domain.shell_sessions_destroy(none)
	testing.expect_value(t, len(none), 0)
}
