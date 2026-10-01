package sqlite

// REQ-SHELL-9 — the two queries behind the reaps, tested against real SQL.
//
// WHY THIS LEVEL IS NEEDED and the service-level fakes are not enough. Both reaps depend
// on properties that live entirely in the query, and a fake repository answers them by
// construction, i.e. not at all:
//   - list_live_by_kind's KIND and LIVE narrowing, and its oldest-first ORDER. The order
//     is not cosmetic: `limit` is a runaway backstop, so a truncated page must contain
//     the oldest rows or a cap could starve the very servers the age reap exists for.
//   - list_by_chain's KIND SCOPE CLAUSE, built from domain.SHELL_SESSION_SCOPE_RULES.
//     Server is the only kind whose scope key includes .Chain, which is what makes it
//     STRUCTURALLY impossible for a run or a shell to reach the chain reap. That is the
//     strongest form of AC3 available, and it is a claim about this SQL, not about the
//     service.
// Both would fail SILENTLY if wrong: no error, just rows quietly not reaped, or — far
// worse — a user's interactive shell quietly reaped.

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
t9_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_shell_req9_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}

@(private = "file")
t9_row :: proc(session_id, kind, chain_id, agent_id, status, started_at: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = "usr_t9",
		bridge_id         = "brg_t9",
		chain_id          = chain_id,
		agent_instance_id = agent_id,
		kind              = kind,
		cmd               = "npm run dev",
		status            = status,
		started_at        = started_at,
		created_at        = "2026-09-29T09:00:00Z",
		last_activity_at  = "2026-09-29T09:00:00Z",
	}
}

@(private = "file")
t9_ids :: proc(rows: [dynamic]domain.Shell_Session) -> [dynamic]string {
	out := make([dynamic]string)
	for r in rows do append(&out, r.session_id)
	return out
}

@(private = "file")
t9_has :: proc(rows: [dynamic]domain.Shell_Session, want: string) -> bool {
	for r in rows do if r.session_id == want do return true
	return false
}

// list_live_by_kind returns live rows of the asked-for kind only, from every owner and
// every bridge, and it returns them OLDEST FIRST.
@(test)
t9_live_by_kind_filters_and_orders :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "kind")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)

	// Inserted in a deliberately scrambled order so a passing ORDER BY cannot be an
	// accident of insertion order.
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_mid",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_old",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-27T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_new",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T11:00:00Z"))
	// Must NOT appear: wrong kind, and terminal.
	_, _ = iface.shell_session_upsert(&repo, t9_row("run_1",     domain.Shell_Session_Kind_Run,    "",        "inst_1", domain.Shell_Session_Status_Running, "2026-09-20T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("shell_1",   domain.Shell_Session_Kind_Shell,  "",        "",       domain.Shell_Session_Status_Running, "2026-09-20T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_dead",  domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Exited,  "2026-09-20T08:00:00Z"))

	rows, err := iface.shell_session_list_live_by_kind(&repo, domain.Shell_Session_Kind_Server, 100)
	defer domain.shell_sessions_destroy(rows)

	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 3)
	// Oldest first, exactly.
	ids := t9_ids(rows); defer delete(ids)
	testing.expect_value(t, ids[0], "srv_old")
	testing.expect_value(t, ids[1], "srv_mid")
	testing.expect_value(t, ids[2], "srv_new")
	testing.expect(t, !t9_has(rows, "run_1"),    "a run must never be a candidate")
	testing.expect(t, !t9_has(rows, "shell_1"),  "a shell must never be a candidate")
	testing.expect(t, !t9_has(rows, "srv_dead"), "a terminal server is not live")
}

// THE ORDER IS WHAT MAKES THE CAP SAFE. With a limit of one, the row returned must be the
// OLDEST — the one most likely to need reaping. Newest-first would let a cap starve the
// oldest servers indefinitely, which is the one failure an age reap must not have.
@(test)
t9_live_by_kind_limit_keeps_the_oldest :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "limit")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)

	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_new", domain.Shell_Session_Kind_Server, "chain_1", "", domain.Shell_Session_Status_Running, "2026-09-29T11:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_old", domain.Shell_Session_Kind_Server, "chain_1", "", domain.Shell_Session_Status_Running, "2026-09-27T08:00:00Z"))

	rows, _ := iface.shell_session_list_live_by_kind(&repo, domain.Shell_Session_Kind_Server, 1)
	defer domain.shell_sessions_destroy(rows)

	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].session_id, "srv_old")
}

// The terminal set is BOUND from domain.SHELL_SESSION_TERMINAL_STATUSES rather than
// spelled in the SQL, so every terminal status is excluded without this query naming any
// of them. Asserted by walking the domain's own table, which means a fourth terminal
// status added there is covered by this test the day it is added.
@(test)
t9_live_by_kind_excludes_every_terminal_status :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "terminal")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)

	for status, i in domain.SHELL_SESSION_TERMINAL_STATUSES {
		id := fmt.tprintf("srv_term_%d", i)
		_, _ = iface.shell_session_upsert(&repo, t9_row(id, domain.Shell_Session_Kind_Server, "chain_1", "", status, "2026-09-20T08:00:00Z"))
	}
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_live", domain.Shell_Session_Kind_Server, "chain_1", "", domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))

	rows, _ := iface.shell_session_list_live_by_kind(&repo, domain.Shell_Session_Kind_Server, 100)
	defer domain.shell_sessions_destroy(rows)

	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].session_id, "srv_live")
}

// AC3 IN ITS STRONGEST FORM. The chain reap's candidate query is list_by_chain, which
// AND-s in a kind clause derived from domain.SHELL_SESSION_SCOPE_RULES. Server is the
// only kind keyed by .Chain, so a run or a shell CANNOT be returned — even one wrongly
// carrying a chain_id, which is what is seeded here. The service also refuses them, but
// this is the layer at which they are unreachable rather than merely refused.
@(test)
t9_by_chain_can_only_ever_return_servers :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "scope")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)

	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_1",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	// Mis-scoped on purpose: a real run never carries a chain_id, and the point is that
	// even one that did could not be reached through a by-chain listing.
	_, _ = iface.shell_session_upsert(&repo, t9_row("run_1",   domain.Shell_Session_Kind_Run,    "chain_1", "inst_1", domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("shell_1", domain.Shell_Session_Kind_Shell,  "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))

	rows, _, err := iface.shell_session_list_by_chain(&repo, "usr_t9", "chain_1", domain.Shell_Session_Status_Group_Live, "", 100)
	defer domain.shell_sessions_destroy(rows)

	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].session_id, "srv_1")
	testing.expect(t, !t9_has(rows, "run_1"),   "a by-chain listing must never return a run")
	testing.expect(t, !t9_has(rows, "shell_1"), "a by-chain listing must never return a shell")
}
