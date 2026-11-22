package sqlite

import "core:mem"
import "core:testing"
import "core:strings"

@(test)
test_actions_reset_from_old_schema :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	actions_reset_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

actions_reset_scenario :: proc(t: ^testing.T) {
	conn, opened, err := open(":memory:")
	if !testing.expect(t, opened, err.message) do return
	defer close(&conn)
	ok, migration_err := run_migrations(&conn, stop_before = "actions_001_reset.sql")
	if !testing.expect(t, ok, migration_err.message) do return
	testing.expect(t, exec(&conn, `INSERT INTO actions(id, owner_user_id, target_instance_id, prompt_text, created_at, updated_at) VALUES ('old_action','owner','inst','old prompt','2026-01-01','2026-01-01');`))
	testing.expect(t, exec(&conn, `INSERT INTO scheduled_prompts(id, owner_user_id, target_instance_id, prompt_text, target_run_at, created_at, updated_at) VALUES ('old_prompt','owner','inst','old prompt','2026-01-01','2026-01-01','2026-01-01');`))
	old_triggers := [?]string{"action_revision_insert", "action_revision_update", "action_revision_delete", "action_revision_member_insert", "action_revision_member_delete", "action_revision_member_update"}
	for name in old_triggers do testing.expect(t, sqlite_object_exists(&conn, name), name)
	ok, migration_err = run_migrations(&conn)
	if !testing.expect(t, ok, migration_err.message) do return
	for name in old_triggers do testing.expect(t, !sqlite_object_exists(&conn, name), name)
	testing.expect(t, !sqlite_object_exists(&conn, "scheduled_prompts"))
	testing.expect(t, !sqlite_object_exists(&conn, "action_schedule_revision"))
	testing.expect(t, !table_column_exists(&conn, "actions", "id"))
	tables := [?]string{"actions", "action_target_rules", "action_triggers", "action_runs"}
	for table in tables {
		testing.expect(t, sqlite_object_exists(&conn, table), table)
	}
	testing.expect_value(t, actions_reset_text(&conn, "SELECT count(*) FROM actions;"), "0")
	testing.expect_value(t, actions_reset_text(&conn, "SELECT count(*) FROM action_target_rules;"), "0")
	testing.expect_value(t, actions_reset_text(&conn, "SELECT count(*) FROM action_triggers;"), "0")
	testing.expect_value(t, actions_reset_text(&conn, "SELECT count(*) FROM action_runs;"), "0")
	// A second startup preserves new rows and never recreates the old schema.
	testing.expect(t, exec(&conn, `INSERT INTO actions(action_id, owner_user_id, prompt_text, target_kind, created_at, updated_at) VALUES ('new_action','owner','new prompt','agent','2026-01-01','2026-01-01');`))
	ok, migration_err = run_migrations(&conn)
	testing.expect(t, ok, migration_err.message)
	testing.expect_value(t, actions_reset_text(&conn, "SELECT action_id FROM actions;"), "new_action")
	testing.expect(t, !sqlite_object_exists(&conn, "scheduled_prompts"))
	testing.expect(t, !sqlite_object_exists(&conn, "action_schedule_revision"))
}

// Return a temporary copy before finalizing the statement.
actions_reset_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}
