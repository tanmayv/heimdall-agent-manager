package sqlite

import "core:testing"

@(test)
test_v2_migrations_preserve_versions_and_rewrite_prompts :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, _ := run_migrations(&conn, stop_before="events_007_entity_versions.sql")
	if !testing.expect(t, ok) do return
	testing.expect(t, exec(&conn, "INSERT INTO event_entity_versions VALUES('owner','chain','c',7);"))
	ok, _ = run_migrations(&conn, stop_before="actions_006_template_vars.sql")
	if !testing.expect(t, ok) do return
	testing.expect(t, exec(&conn, `INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,created_at,updated_at) VALUES('a','owner','Review {{event.chain_id}} {{event.task_id}} {{ event.chain_id }}','instance','now','now');`))
	ok, _ = run_migrations(&conn)
	if !testing.expect(t, ok) do return
	stmt: sqlite3_stmt
	testing.expect_value(t, sqlite3_prepare_v2(conn.db, "SELECT prompt_text FROM actions WHERE action_id='a';", -1, &stmt, nil), SQLITE_OK)
	testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
	prompt := column_text(stmt,0)
	testing.expect_value(t, prompt, "Review {{event.entity.id}}  {{ event.chain_id }}")
	delete(prompt)
	sqlite3_finalize(stmt)
	testing.expect_value(t, sqlite3_prepare_v2(conn.db, "SELECT version FROM event_entity_versions WHERE entity_id='c';", -1, &stmt, nil), SQLITE_OK)
	testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
	testing.expect_value(t, sqlite3_column_int64(stmt, 0), i64(7))
	sqlite3_finalize(stmt)
	testing.expect(t, exec(&conn, "INSERT INTO event_entity_versions VALUES('owner','memory','m',1);"))
	testing.expect(t, exec(&conn, "UPDATE event_entity_versions SET version=2 WHERE entity_id='m';"))
	ok, _ = run_migrations(&conn)
	testing.expect(t, ok, "idempotent upgrade")
}

@(test)
test_v2_versions_failed_copy_rolls_back_and_retries :: proc(t: ^testing.T) {
 conn, opened, _ := open(":memory:")
 if !testing.expect(t, opened) do return
 defer close(&conn)
 ok, _ := run_migrations(&conn, stop_before="events_007_entity_versions.sql")
 if !testing.expect(t, ok) do return
 // A legacy/corrupt row fails the rebuilt table's CHECK after CREATE succeeds.
 testing.expect(t, exec(&conn, "PRAGMA ignore_check_constraints=ON;"))
 testing.expect(t, exec(&conn, "INSERT INTO event_entity_versions VALUES('owner','chain','broken',0);"))
 testing.expect(t, exec(&conn, "PRAGMA ignore_check_constraints=OFF;"))
 ok, _ = run_migrations(&conn)
 testing.expect(t, !ok, "copy must fail")
 testing.expect(t, sqlite_object_exists(&conn, "event_entity_versions"))
 testing.expect(t, !sqlite_object_exists(&conn, "event_entity_versions_v2"), "failed CREATE/copy is rolled back")
 stmt: sqlite3_stmt
 testing.expect_value(t, sqlite3_prepare_v2(conn.db, "SELECT version FROM event_entity_versions WHERE entity_id='broken';", -1, &stmt, nil), SQLITE_OK)
 testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
 testing.expect_value(t, sqlite3_column_int64(stmt,0), i64(0))
 sqlite3_finalize(stmt)
 testing.expect(t, exec(&conn, "UPDATE event_entity_versions SET version=9 WHERE entity_id='broken';"))
 ok, _ = run_migrations(&conn)
 testing.expect(t, ok, "migration can be retried after the bad row is repaired")
}
