package sqlite

// REQ-SHELL-14 — the candidate query behind the gone-bridge sweep:
// shell_session_list_live_bridge_ids, "which bridges hold at least one LIVE session".
//
// WHY THIS NEEDS A REAL-SQL TEST and the service-level fakes are not enough. Both
// REQ-SHELL-14 test files reimplement the live predicate in Odin
// (domain.shell_session_is_terminal inverted) in order to stand in for this query. That
// makes them agree with each other by construction and says nothing about whether THIS
// SQL agrees with either. The parts only real SQL can check are exactly the parts that
// would silently break the sweep:
//   - the terminal set is BOUND, not spelled in the query, so a new status added to
//     domain.SHELL_SESSION_TERMINAL_STATUSES must narrow this result automatically
//   - DISTINCT, so a bridge with fifty live sessions is one candidate and not fifty
//     bridge reads on every 20-second tick
//   - the bridge_id != '' guard, which keeps a corrupt row from handing the sweep an id
//     that resolves to no bridge
// A sweep whose candidate query wrongly omitted a bridge would fail SILENTLY: no error,
// no reaped rows, and the invariant-(b) hole this task closes would simply stay open.
//
// Its two documented neighbours (delete_terminal_before, find_live_by_port) are
// owner-unscoped sweep/host reads tested at this level for the same reason.

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
t14_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := fmt.tprintf("/tmp/test_shell_req14_%s_%d.db", tag, os.get_pid())
	os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}

@(private = "file")
t14_row :: proc(session_id, bridge_id, status: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = "usr_t14",
		bridge_id        = bridge_id,
		kind             = domain.Shell_Session_Kind_Shell,
		cmd              = "zsh",
		status           = status,
		started_at       = "2026-09-28T09:00:00Z",
		created_at       = "2026-09-28T09:00:00Z",
		last_activity_at = "2026-09-28T09:00:00Z",
	}
}

@(private = "file")
t14_has :: proc(ids: [dynamic]string, want: string) -> bool {
	for id in ids {
		if id == want do return true
	}
	return false
}

// The discriminating case: five bridges, only two of which hold anything live. A query
// that returned every bridge mentioned in the table would pass a weaker test and would
// make the sweep read every bridge ever enrolled on every tick — the cost the shape was
// chosen to avoid.
//
// EVERY terminal status is represented, and each on its OWN bridge, so a status missing
// from the bound set shows up as an extra candidate rather than being masked by a live
// sibling on the same bridge.
@(test)
test_req14_live_bridge_ids_lists_only_bridges_with_live_sessions :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "live")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	for row in ([]domain.Shell_Session{
		t14_row("shl_run",      "brg_live_a", domain.Shell_Session_Status_Running),
		t14_row("shl_starting", "brg_live_b", domain.Shell_Session_Status_Starting),
		t14_row("shl_exited",   "brg_dead_x", domain.Shell_Session_Status_Exited),
		t14_row("shl_killed",   "brg_dead_y", domain.Shell_Session_Status_Killed),
		t14_row("shl_failed",   "brg_dead_z", domain.Shell_Session_Status_Failed),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}

	ids, err := iface.shell_session_list_live_bridge_ids(&repo, 100)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect(t, err.code == .None, "candidate listing succeeded")

	testing.expectf(t, len(ids) == 2, "only the two bridges with LIVE rows are candidates, got %d", len(ids))
	testing.expect(t, t14_has(ids, "brg_live_a"), "a running session makes its bridge a candidate")
	testing.expect(t, t14_has(ids, "brg_live_b"), "a starting session makes its bridge a candidate")
	// A bridge whose every session already ended needs no reaping, and reading it would
	// be pure waste on a 20-second loop.
	testing.expect(t, !t14_has(ids, "brg_dead_x"), "exited-only bridge is not a candidate")
	testing.expect(t, !t14_has(ids, "brg_dead_y"), "killed-only bridge is not a candidate")
	testing.expect(t, !t14_has(ids, "brg_dead_z"), "failed-only bridge is not a candidate")
}

// DISTINCT, and a mixed bridge. Three live rows on one bridge must yield ONE candidate —
// the sweep does a bridge read per returned id, so duplicates would multiply that read
// by the number of sessions. The mixed bridge also pins the direction of the predicate:
// one live row is enough to make a bridge a candidate even though terminal rows sit
// beside it, which is what makes the sweep able to finish a partially-ended bridge.
@(test)
test_req14_live_bridge_ids_are_distinct :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "distinct")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	for row in ([]domain.Shell_Session{
		t14_row("shl_1", "brg_busy",  domain.Shell_Session_Status_Running),
		t14_row("shl_2", "brg_busy",  domain.Shell_Session_Status_Running),
		t14_row("shl_3", "brg_busy",  domain.Shell_Session_Status_Starting),
		t14_row("shl_4", "brg_mixed", domain.Shell_Session_Status_Exited),
		t14_row("shl_5", "brg_mixed", domain.Shell_Session_Status_Running),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}

	ids, err := iface.shell_session_list_live_bridge_ids(&repo, 100)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect(t, err.code == .None, "candidate listing succeeded")

	testing.expectf(t, len(ids) == 2, "three live rows on one bridge is ONE candidate, got %d", len(ids))
	testing.expect(t, t14_has(ids, "brg_busy"), "the busy bridge appears exactly once")
	testing.expect(t, t14_has(ids, "brg_mixed"), "one live row among terminals still makes a candidate")
}

// Empty table: no candidates, no error. This is the steady state on a quiet host and the
// path the sweep takes on most of its ticks, so it must be boring rather than an error
// the reaper swallows.
@(test)
test_req14_live_bridge_ids_is_empty_when_nothing_is_live :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "empty")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	ids, err := iface.shell_session_list_live_bridge_ids(&repo, 100)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect(t, err.code == .None, "an empty table is not an error")
	testing.expect_value(t, len(ids), 0)
}

// The limit is a runaway backstop, so it must actually bound the result — and with the
// ORDER BY it must bound it to a STABLE prefix. An arbitrary subset that rotated between
// ticks would make a gone bridge reachable on some sweeps and not others, which is a far
// worse failure than a truncated list: it would be intermittent.
@(test)
test_req14_live_bridge_ids_limit_bounds_a_stable_prefix :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "limit")
	if !ok do return
	defer close(&conn)

	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)

	for row in ([]domain.Shell_Session{
		t14_row("shl_a", "brg_a", domain.Shell_Session_Status_Running),
		t14_row("shl_b", "brg_b", domain.Shell_Session_Status_Running),
		t14_row("shl_c", "brg_c", domain.Shell_Session_Status_Running),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}

	first, err1 := iface.shell_session_list_live_bridge_ids(&repo, 2)
	defer { for id in first do delete(id); delete(first) }
	testing.expect(t, err1.code == .None, "limited listing succeeded")
	testing.expectf(t, len(first) == 2, "limit must bound the result, got %d", len(first))
	testing.expect(t, t14_has(first, "brg_a") && t14_has(first, "brg_b"), "ORDER BY bridge_id makes the prefix the two lowest ids")

	second, err2 := iface.shell_session_list_live_bridge_ids(&repo, 2)
	defer { for id in second do delete(id); delete(second) }
	testing.expect(t, err2.code == .None, "repeat listing succeeded")
	testing.expect(t, t14_has(second, "brg_a") && t14_has(second, "brg_b"), "the same prefix every tick, not a rotating subset")
}
