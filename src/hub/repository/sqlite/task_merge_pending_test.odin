#+private file
package sqlite

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Scale B (migration 262): tasks.merge_pending mirrors taskv2.merge_pending
// (events). The migration backfills it once from the event log, the event
// append keeps it in sync in the same transaction, and the boot/hello lookup
// returns only Done tasks that carry it.

TMP_MIGRATION :: "262_task_merge_pending.sql"

TMP_SEED :: `
BEGIN;
INSERT INTO users(user_id, name, display_name, status, created_at, updated_at) VALUES ('u1','u1','u1','active','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO task_chains(chain_id, owner_user_id, title, created_at, updated_at) VALUES ('chain_mp','u1','Merge pending','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
COMMIT;
`

tmp_text :: proc(conn: ^Conn, query: string, column := 0) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, column), context.temp_allocator)
}

tmp_task :: proc(conn: ^Conn, id, state: string, created: int) -> bool {
	return exec(conn, fmt.tprintf(`INSERT INTO tasks(task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, brief_json, created_at, updated_at)
 VALUES ('%s','chain_mp','u1','t','','published','%s','task','{"goal":"g"}','2026-01-01T00:00:%02dZ','2026-01-01T00:00:00Z');`, id, state, created))
}

// Raw event rows bypass the repository, as a pre-262 database holds them.
tmp_raw_events :: proc(conn: ^Conn, id: string, kinds: ..string) -> bool {
	for k in kinds {
		if !exec(conn, fmt.tprintf(`INSERT INTO task_events(task_id, chain_id, owner_user_id, ts_ms, kind, payload_json) VALUES ('%s','chain_mp','u1',1,'%s','{}');`, id, k)) do return false
	}
	return true
}

tmp_pending :: proc(conn: ^Conn, id: string) -> string {
	return tmp_text(conn, fmt.tprintf("SELECT merge_pending FROM tasks WHERE task_id='%s';", id))
}

tmp_listed :: proc(t: ^testing.T, repo: ^iface.Taskchain_Repository) -> string {
	tasks, err := iface.taskchain_list_merge_pending_done_tasks(repo)
	testing.expect(t, err.code == .None, err.message)
	ids := make([dynamic]string, context.temp_allocator)
	for task in tasks do append(&ids, string(task.task_id))
	return strings.join(ids[:], ",", context.temp_allocator)
}

@(test)
test_merge_pending_backfill_from_events_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "merge_pending_backfill")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn, stop_before = TMP_MIGRATION)
	if !testing.expect(t, mig_ok, err.message) do return
	testing.expect(t, !table_column_exists(&conn, "tasks", "merge_pending"), "before 262: no column")
	// A database already on release 0.5.92 (its 261) picks 262 up cleanly.
	testing.expect(t, migration_applied(&conn, "261_extension_version_sync_0_5_92.sql"), "release 261 applied first")
	if !testing.expect(t, exec(&conn, TMP_SEED), "seed chain") do return
	Case :: struct { id, state: string, kinds: []string, want: string }
	cases := []Case{
		{"t_pending",  "done",      {"created", "lease_granted", "submitted", "comment"}, "1"},
		{"t_approved", "done",      {"submitted", "approved", "merge_snapshot"}, "1"},
		{"t_merged",   "done",      {"submitted", "merged", "comment"}, "0"},
		{"t_conflict", "done",      {"approved", "merge_conflict"}, "0"},
		{"t_failed",   "done",      {"submitted", "merge_failed"}, "1"},
		{"t_reopened", "done",      {"submitted", "merged", "reopened", "submitted"}, "1"},
		{"t_late",     "done",      {"submitted", "merged", "late_merge_outcome"}, "0"},
		{"t_never",    "done",      {"created"}, "0"},
		{"t_review",   "in_review", {"submitted"}, "1"},
	}
	for c, i in cases {
		if !testing.expect(t, tmp_task(&conn, c.id, c.state, i), c.id) do return
		if !testing.expect(t, tmp_raw_events(&conn, c.id, ..c.kinds), c.id) do return
	}
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	for pass in ([]string{"upgrade", "restart"}) {
		mig_ok, err = run_migrations(&conn)
		if !testing.expectf(t, mig_ok, "%s: %s", pass, err.message) do return
		testing.expectf(t, tmp_text(&conn, fmt.tprintf("SELECT count(*) FROM schema_migrations WHERE version='%s';", TMP_MIGRATION)) == "1", "%s: 262 recorded once", pass)
		for c in cases do testing.expectf(t, tmp_pending(&conn, c.id) == c.want, "%s: %s merge_pending=%s, want %s", pass, c.id, tmp_pending(&conn, c.id), c.want)
		// Only Done rows are listed (in_review t_review is pending but not Done), oldest first.
		testing.expect_value(t, tmp_listed(t, &repo), "t_pending,t_approved,t_failed,t_reopened")
	}
	// The lookup is served by the partial index, not a scan of every task.
	plan := tmp_text(&conn, "EXPLAIN QUERY PLAN SELECT task_id FROM tasks WHERE merge_pending = 1 AND state = 'done' ORDER BY created_at ASC;", 3)
	testing.expectf(t, strings.contains(plan, "idx_tasks_merge_pending"), "plan uses the partial index: %s", plan)
}

@(test)
test_merge_pending_set_and_cleared_by_event_append :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "merge_pending_sync")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, err.message) do return
	if !testing.expect(t, exec(&conn, TMP_SEED), "seed chain") do return
	if !testing.expect(t, tmp_task(&conn, "t_a", "done", 1), "task a") do return
	if !testing.expect(t, tmp_task(&conn, "t_b", "done", 2), "task b") do return
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	append_kind :: proc(t: ^testing.T, repo: ^iface.Taskchain_Repository, id, kind: string) {
		_, ok, err := iface.taskchain_append_event(repo, domain.Task_Event{task_id = domain.Task_ID(id), chain_id = "chain_mp", owner_user_id = "u1", ts_ms = 1, kind = kind, payload_json = "{}"})
		testing.expectf(t, ok, "append %s to %s: %s", kind, id, err.message)
	}
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "0")
	testing.expect_value(t, tmp_listed(t, &repo), "")

	// Set: a completion makes the merge pending.
	append_kind(t, &repo, "t_a", "submitted")
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "1")
	testing.expect_value(t, tmp_listed(t, &repo), "t_a")
	// Unrelated events and a failed merge (retried on hello) leave it set.
	for k in ([]string{"comment", "merge_snapshot", "merge_failed", "late_merge_outcome"}) do append_kind(t, &repo, "t_a", k)
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "1")
	// Clear: a merge outcome settles it.
	append_kind(t, &repo, "t_a", "merged")
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "0")
	testing.expect_value(t, tmp_listed(t, &repo), "")
	// A reopen and a new approval set it again; a conflict clears it.
	append_kind(t, &repo, "t_a", "approved")
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "1")
	append_kind(t, &repo, "t_a", "merge_conflict")
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "0")
	// Per task: b's completion does not touch a.
	append_kind(t, &repo, "t_b", "approved")
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "0")
	testing.expect_value(t, tmp_listed(t, &repo), "t_b")

	// Same transaction: a rolled-back append leaves no projection behind.
	testing.expect(t, exec(&conn, "BEGIN;"), "begin")
	append_kind(t, &repo, "t_a", "submitted")
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "1")
	testing.expect(t, exec(&conn, "ROLLBACK;"), "rollback")
	testing.expect_value(t, tmp_pending(&conn, "t_a"), "0")

	// A later task save (upsert) never resets the projection.
	task, found, gerr := iface.taskchain_get_task(&repo, "t_b")
	if !testing.expect(t, found, gerr.message) do return
	task.title = "renamed"
	_, sok, serr := iface.taskchain_save_task(&repo, task)
	testing.expect(t, sok, serr.message)
	testing.expect_value(t, tmp_pending(&conn, "t_b"), "1")

	// A failed projection write fails the append (never a silent drift).
	testing.expect(t, exec(&conn, "DROP INDEX idx_tasks_merge_pending; ALTER TABLE tasks DROP COLUMN merge_pending;"), "drop projection")
	_, aok, _ := iface.taskchain_append_event(&repo, domain.Task_Event{task_id = "t_a", chain_id = "chain_mp", owner_user_id = "u1", ts_ms = 1, kind = "submitted", payload_json = "{}"})
	testing.expect(t, !aok, "append fails closed without the projection")
	testing.expect_value(t, tmp_text(&conn, "SELECT count(*) FROM task_events WHERE task_id='t_a' AND kind='submitted';"), "1")
}

// A database carrying the owner legacy source fences (bridge-owned legacy
// chain export, as on Mundus): the owner_legacy_guard_* triggers make every
// row of a 'frozen' / 'imported' chain read-only. 262's backfill skips those
// chains (they cannot have a live merge), 'draining' and unfenced chains are
// backfilled as usual, and the fences are left untouched.

TMP_OL_FENCES_SQL :: #load("../../../../tests/fixtures/owner_legacy_fences.sql", string)
TMP_OL_DIGEST :: "0000000000000000000000000000000000000000000000000000000000000000"
TMP_OL_CHAINS :: [4]string{"chain_live", "chain_drain", "chain_frozen", "chain_imported"}

tmp_ol_fences_digest :: proc(conn: ^Conn) -> string {
	return tmp_text(conn, "SELECT count(*) || ':' || group_concat(name || '=' || sql, ';') FROM (SELECT name, sql FROM sqlite_master WHERE name LIKE 'owner_legacy%' ORDER BY name);")
}

@(test)
test_merge_pending_backfill_skips_owner_legacy_frozen_chains :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "merge_pending_owner_legacy")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn, stop_before = TMP_MIGRATION)
	if !testing.expect(t, mig_ok, err.message) do return
	if !testing.expect(t, exec(&conn, `INSERT INTO users(user_id, name, display_name, status, created_at, updated_at) VALUES ('u1','u1','u1','active','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');`), "seed user") do return
	// One Done task per chain whose merge never settled.
	chains := TMP_OL_CHAINS
	for chain, i in chains {
		seeded := exec(&conn, fmt.tprintf(`INSERT INTO task_chains(chain_id, owner_user_id, title, created_at, updated_at) VALUES ('%s','u1','c','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO tasks(task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, brief_json, created_at, updated_at)
 VALUES ('t_%s','%s','u1','t','','published','done','task','{"goal":"g"}','2026-01-01T00:00:%02dZ','2026-01-01T00:00:00Z');
INSERT INTO task_events(task_id, chain_id, owner_user_id, ts_ms, kind, payload_json) VALUES ('t_%s','%s','u1',1,'submitted','{}');`, chain, chain, chain, i, chain, chain))
		if !testing.expect(t, seeded, chain) do return
	}
	// A fenced database keeps task_leases.review_role (owner_legacy_no_replaced_lease
	// reads it, so 260's fenced variant does not drop it).
	if !table_column_exists(&conn, "task_leases", "review_role") {
		if !testing.expect(t, exec(&conn, "ALTER TABLE task_leases ADD COLUMN review_role TEXT NOT NULL DEFAULT '';"), "fenced schema keeps review_role") do return
	}
	// Fences and legacy state go in last: a frozen chain's rows cannot be written.
	if !testing.expect(t, exec(&conn, TMP_OL_FENCES_SQL), "install owner legacy fences") do return
	d := TMP_OL_DIGEST
	legacy := fmt.tprintf(`INSERT INTO owner_legacy_source_generations (chain_id, account_id, generation) VALUES ('chain_drain', 'acct', 1), ('chain_frozen', 'acct', 1), ('chain_imported', 'acct', 1);
INSERT INTO owner_legacy_migrations (migration_id, chain_id, account_id, owner_bridge_id, owner_key_id, selection_digest, state, revision, frozen_generation, quiescence_digest, manifest_digest, receipt_digest) VALUES
 ('olm_drain', 'chain_drain', 'acct', 'brg_o', 'key_o', '%s', 'draining', 1, 0, '', '', ''),
 ('olm_frozen', 'chain_frozen', 'acct', 'brg_o', 'key_o', '%s', 'frozen', 2, 1, '%s', '', ''),
 ('olm_imported', 'chain_imported', 'acct', 'brg_o', 'key_o', '%s', 'imported', 3, 1, '%s', '%s', '%s');`, d, d, d, d, d, d, d)
	if !testing.expect(t, exec(&conn, legacy), "seed owner legacy migrations") do return
	fences := tmp_ol_fences_digest(&conn)
	// The fixture reproduces the failure an unfiltered backfill would hit.
	testing.expect(t, !exec(&conn, "UPDATE tasks SET updated_at = updated_at WHERE task_id = 't_chain_frozen';"), "frozen task rows are read-only")

	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	for pass in ([]string{"upgrade", "restart"}) {
		mig_ok, err = run_migrations(&conn)
		if !testing.expectf(t, mig_ok, "%s: %s", pass, err.message) do return
		testing.expectf(t, migration_applied(&conn, TMP_MIGRATION), "%s: 262 recorded", pass)
		testing.expectf(t, tmp_pending(&conn, "t_chain_live") == "1", "%s: unfenced chain backfilled", pass)
		testing.expectf(t, tmp_pending(&conn, "t_chain_drain") == "1", "%s: draining chain backfilled", pass)
		testing.expectf(t, tmp_pending(&conn, "t_chain_frozen") == "0", "%s: frozen chain untouched", pass)
		testing.expectf(t, tmp_pending(&conn, "t_chain_imported") == "0", "%s: imported chain untouched", pass)
		testing.expect_value(t, tmp_listed(t, &repo), "t_chain_live,t_chain_drain")
		testing.expectf(t, tmp_ol_fences_digest(&conn) == fences, "%s: fence tables and triggers unchanged", pass)
		testing.expectf(t, tmp_text(&conn, "SELECT generation FROM owner_legacy_source_generations WHERE chain_id='chain_frozen';") == "1", "%s: frozen generation unchanged", pass)
	}

	// At runtime the projection write rides on the event insert: a frozen
	// chain's event is refused by its guard, so no projection write follows;
	// a draining chain settles as usual.
	_, fok, _ := iface.taskchain_append_event(&repo, domain.Task_Event{task_id = "t_chain_frozen", chain_id = "chain_frozen", owner_user_id = "u1", ts_ms = 2, kind = "approved", payload_json = "{}"})
	testing.expect(t, !fok, "frozen chain event refused by its guard")
	testing.expect_value(t, tmp_pending(&conn, "t_chain_frozen"), "0")
	_, dok, derr := iface.taskchain_append_event(&repo, domain.Task_Event{task_id = "t_chain_drain", chain_id = "chain_drain", owner_user_id = "u1", ts_ms = 2, kind = "merged", payload_json = "{}"})
	testing.expect(t, dok, derr.message)
	testing.expect_value(t, tmp_pending(&conn, "t_chain_drain"), "0")
	testing.expect_value(t, tmp_listed(t, &repo), "t_chain_live")
}
