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

@(test)
test_actions_reset_recovers_commit_before_ledger :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	actions_reset_commit_gap_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}
actions_reset_commit_gap_scenario :: proc(t: ^testing.T) {
	conn, opened, err := open(":memory:")
	if !testing.expect(t, opened, err.message) do return
	defer close(&conn)
	ok, migration_err := run_migrations(&conn, stop_before="actions_001_reset.sql")
	if !testing.expect(t, ok, migration_err.message) do return
	// Simulate COMMIT succeeding just before the process loses its ledger write.
	if !testing.expect(t, exec(&conn, MIGRATION_ACTIONS_001_RESET)) do return
	testing.expect(t, !migration_applied(&conn, "actions_001_reset.sql"))
	seed_sql := `INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,created_at,updated_at) VALUES('survives','owner','keep me','agent','now','now');
INSERT INTO action_target_rules(action_id,position,bridge_id,provider,model) VALUES('survives',0,'*','*','*');
INSERT INTO action_triggers(trigger_id,action_id,owner_user_id,kind,event_type,subject_filter,created_at,updated_at) VALUES('trg_survives','survives','owner','event','chain.state','ev.owner.chain.*.state','now','now');
INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,created_at) VALUES('run_survives','survives','trg_survives','owner','occurrence','chain.state','queued','now');`
	if !testing.expect(t, exec(&conn, seed_sql)) do return
	ok, migration_err = run_migrations(&conn)
	if !testing.expect(t, ok, migration_err.message) do return
	testing.expect(t, migration_applied(&conn, "actions_001_reset.sql"))
	testing.expect_value(t, actions_reset_text(&conn, "SELECT prompt_text FROM actions WHERE action_id='survives';"), "keep me")
	testing.expect_value(t, actions_reset_text(&conn, "SELECT count(*) FROM action_target_rules WHERE action_id='survives';"), "1")
	testing.expect_value(t, actions_reset_text(&conn, "SELECT trigger_id FROM action_triggers;"), "trg_survives")
	testing.expect_value(t, actions_reset_text(&conn, "SELECT run_id FROM action_runs;"), "run_survives")
}
@(test)
test_actions_reset_failure_preserves_old_schema :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	actions_reset_failure_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}
actions_reset_failure_scenario :: proc(t: ^testing.T) {
	conn, opened, err := open(":memory:")
	if !testing.expect(t, opened, err.message) do return
	defer close(&conn)
	ok, migration_err := run_migrations(&conn, stop_before="actions_001_reset.sql")
	if !testing.expect(t, ok, migration_err.message) do return
	testing.expect(t, exec(&conn, `INSERT INTO actions(id,owner_user_id,target_instance_id,prompt_text,created_at,updated_at) VALUES('old_action','owner','inst','old prompt','now','now');`))
	// Fail at the LAST CREATE after all destructive statements have executed.
	// The existing old schema also prevents the commit-gap guard from matching.
	testing.expect(t, exec(&conn, "CREATE TABLE action_runs_due(collision TEXT);"))
	ok, migration_err = run_migrations(&conn)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(migration_err.message, "actions_001_reset.sql"))
	testing.expect(t, !migration_applied(&conn, "actions_001_reset.sql"))
	testing.expect(t, table_column_exists(&conn, "actions", "id"))
	testing.expect_value(t, actions_reset_text(&conn, "SELECT id FROM actions;"), "old_action")
	testing.expect(t, sqlite_object_exists(&conn, "scheduled_prompts"))
	testing.expect(t, sqlite_object_exists(&conn, "action_schedule_revision"))
	testing.expect(t, sqlite_object_exists(&conn, "action_revision_insert"))
	testing.expect(t, !sqlite_object_exists(&conn, "action_target_rules"))
	testing.expect(t, !sqlite_object_exists(&conn, "action_triggers"))
	testing.expect(t, !sqlite_object_exists(&conn, "action_runs"))
	// The apply loop rolled back, so the same connection can retry successfully.
	testing.expect(t, exec(&conn, "DROP TABLE action_runs_due;"))
	ok, migration_err = run_migrations(&conn)
	testing.expect(t, ok, migration_err.message)
	testing.expect(t, migration_applied(&conn, "actions_001_reset.sql"))
	testing.expect_value(t, actions_reset_text(&conn, "SELECT count(*) FROM actions;"), "0")
}
