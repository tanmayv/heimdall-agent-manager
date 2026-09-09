// Storage-level coverage for memory targeting lists (migration 025):
//   1. A fresh migrated DB has the memories.agent_ids/project_ids/template_ids/
//      bridge_ids columns (and no scalar scope columns).
//   2. Saving a memory with list targeting round-trips back through get/list as
//      JSON-array-backed slices, preserving order and multiplicity; empty lists
//      round-trip as empty slices.
//   3. run_migrations is idempotent for the new migration.
//   4. A legacy DB carrying the OLD scalar scope columns is upgraded in place:
//      the scalars are backfilled into single-element lists and dropped.
package hub_memory_scope_lists_test

import "core:fmt"
import "core:os"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

column_exists :: proc(conn: ^sqlite.Conn, table, column: string) -> bool {
	return sqlite.table_column_exists(conn, table, column)
}

main :: proc() {
	fresh_db_migrates_to_lists()
	list_targeting_round_trips()
	legacy_scalar_db_upgrades_in_place()
	fmt.println("PASS: hub memory scope lists")
}

fresh_db_migrates_to_lists :: proc() {
	db_path := "/tmp/hub_memory_scope_lists_fresh.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	// Idempotent.
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations idempotent: %s", mig_err2.message))

	check(column_exists(&conn, "memories", "agent_ids"), "memories.agent_ids must exist")
	check(column_exists(&conn, "memories", "project_ids"), "memories.project_ids must exist")
	check(column_exists(&conn, "memories", "template_ids"), "memories.template_ids must exist")
	check(column_exists(&conn, "memories", "bridge_ids"), "memories.bridge_ids must exist")
	check(column_exists(&conn, "memories", "description"), "memories.description must exist")
	check(!column_exists(&conn, "memories", "agent_id"), "scalar memories.agent_id must be dropped")
	check(!column_exists(&conn, "memories", "project_id"), "scalar memories.project_id must be dropped")
	check(!column_exists(&conn, "memories", "template_id"), "scalar memories.template_id must be dropped")
	check(!column_exists(&conn, "memories", "bridge_id"), "scalar memories.bridge_id must be dropped")
}

list_targeting_round_trips :: proc() {
	db_path := "/tmp/hub_memory_scope_lists_roundtrip.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	repo_impl: sqlite.Content_Repo_SQLite
	repo := sqlite.new_content_repository(&repo_impl, &conn)

	targeted := domain.Memory{
		memory_id = "mem_lists_1",
		owner_user_id = domain.User_ID("usr_1"),
		agent_ids = []string{"agt_a", "agt_b"},
		project_ids = []domain.Project_ID{domain.Project_ID("proj_x")},
		template_ids = []string{},
		bridge_ids = []string{"brg_1"},
		type = .Fact,
		status = "active",
		title = "Targeted",
		description = "targeted description",
		body = "targeted body",
		created_at = "2026-01-01T00:00:00Z",
		updated_at = "2026-01-01T00:00:00Z",
	}
	_, saved, save_err := iface.content_save_memory(&repo, targeted)
	check(saved, fmt.tprintf("save targeted memory: %s", save_err.message))

	got, got_ok, get_err := iface.content_get_memory(&repo, "mem_lists_1")
	check(got_ok, fmt.tprintf("get targeted memory: %s", get_err.message))
	check(got.description == "targeted description", "description must round-trip")
	check(len(got.agent_ids) == 2 && got.agent_ids[0] == "agt_a" && got.agent_ids[1] == "agt_b", "agent_ids must round-trip in order")
	check(len(got.project_ids) == 1 && string(got.project_ids[0]) == "proj_x", "project_ids must round-trip")
	check(len(got.template_ids) == 0, "empty template_ids must round-trip as empty")
	check(len(got.bridge_ids) == 1 && got.bridge_ids[0] == "brg_1", "bridge_ids must round-trip")

	// A global memory (all lists empty) round-trips as empty slices.
	global := domain.Memory{memory_id = "mem_lists_global", owner_user_id = domain.User_ID("usr_1"), type = .Habit, status = "active", title = "Global", body = "global body", created_at = "2026-01-02T00:00:00Z", updated_at = "2026-01-02T00:00:00Z"}
	_, gsaved, gerr := iface.content_save_memory(&repo, global)
	check(gsaved, fmt.tprintf("save global memory: %s", gerr.message))
	gg, gg_ok, _ := iface.content_get_memory(&repo, "mem_lists_global")
	check(gg_ok, "get global memory")
	check(len(gg.agent_ids) == 0 && len(gg.project_ids) == 0 && len(gg.template_ids) == 0 && len(gg.bridge_ids) == 0, "global memory targeting lists must all be empty")

	// list_memories returns the owner's rows plus seeded system memories; count
	// only the two we inserted for this owner and confirm their lists survive.
	rows, list_err := iface.content_list_memories(&repo, domain.User_ID("usr_1"))
	check(list_err.code == .None, "list memories")
	owned := 0
	for r in rows {
		if r.memory_id == "mem_lists_1" {
			owned += 1
			check(len(r.agent_ids) == 2, "listed targeted memory keeps agent_ids")
		}
		if r.memory_id == "mem_lists_global" {
			owned += 1
			check(len(r.agent_ids) == 0, "listed global memory keeps empty agent_ids")
		}
	}
	check(owned == 2, fmt.tprintf("expected our 2 memories in list, found %d", owned))
}

legacy_scalar_db_upgrades_in_place :: proc() {
	db_path := "/tmp/hub_memory_scope_lists_legacy.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	// Simulate a pre-025 memories table: scalar scope columns, a couple of rows.
	check(sqlite.exec(&conn, "CREATE TABLE memories (memory_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, agent_id TEXT NOT NULL DEFAULT '', project_id TEXT NOT NULL DEFAULT '', template_id TEXT NOT NULL DEFAULT '', bridge_id TEXT NOT NULL DEFAULT '', type TEXT NOT NULL DEFAULT 'fact', status TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL, evidence TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);"), "create legacy memories table")
	check(sqlite.exec(&conn, "INSERT INTO memories (memory_id, owner_user_id, agent_id, project_id, template_id, bridge_id, type, status, title, body, created_at, updated_at) VALUES ('mem_legacy_scoped', 'usr_1', 'agt_a', 'proj_x', '', 'brg_1', 'fact', 'active', 'Scoped', 'b', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"), "insert scoped legacy row")
	check(sqlite.exec(&conn, "INSERT INTO memories (memory_id, owner_user_id, agent_id, project_id, template_id, bridge_id, type, status, title, body, created_at, updated_at) VALUES ('mem_legacy_global', 'usr_1', '', '', '', '', 'fact', 'active', 'Global', 'b', '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z');"), "insert global legacy row")

	// The idempotent end-of-run guard converts scalars -> lists in place.
	check(sqlite.upgrade_memory_scope_lists_schema(&conn), "upgrade_memory_scope_lists_schema")
	// Idempotent on a second call.
	check(sqlite.upgrade_memory_scope_lists_schema(&conn), "upgrade_memory_scope_lists_schema idempotent")
	check(sqlite.upgrade_memory_description_schema(&conn), "upgrade_memory_description_schema")

	check(column_exists(&conn, "memories", "agent_ids"), "agent_ids added")
	check(column_exists(&conn, "memories", "description"), "memories.description added in legacy upgrade")
	check(!column_exists(&conn, "memories", "agent_id"), "scalar agent_id dropped")

	repo_impl: sqlite.Content_Repo_SQLite
	repo := sqlite.new_content_repository(&repo_impl, &conn)
	scoped, ok1, _ := iface.content_get_memory(&repo, "mem_legacy_scoped")
	check(ok1, "get upgraded scoped row")
	check(len(scoped.agent_ids) == 1 && scoped.agent_ids[0] == "agt_a", "legacy agent_id backfilled to single-element list")
	check(len(scoped.project_ids) == 1 && string(scoped.project_ids[0]) == "proj_x", "legacy project_id backfilled")
	check(len(scoped.template_ids) == 0, "empty legacy template_id backfilled to empty list")
	check(len(scoped.bridge_ids) == 1 && scoped.bridge_ids[0] == "brg_1", "legacy bridge_id backfilled")

	global, ok2, _ := iface.content_get_memory(&repo, "mem_legacy_global")
	check(ok2, "get upgraded global row")
	check(len(global.agent_ids) == 0 && len(global.project_ids) == 0 && len(global.template_ids) == 0 && len(global.bridge_ids) == 0, "legacy global row upgrades to all-empty lists")
}
