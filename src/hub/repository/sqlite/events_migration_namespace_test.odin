#+private file
package sqlite

import "core:testing"
import "core:strings"

@(test)
test_events_migrations_upgrade_from_main_and_legacy_names :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for legacy in ([2]bool{false, true}) {
		conn, path, opened := tmpl_open_file_prod(t, "events_namespace_upgrade")
		if !opened do continue
		// Everything preceding events_001 is main's ordered migration list,
		// including both release syncs that originally collided with events.
		ok, err := run_migrations(&conn, stop_before = "events_001_outbox.sql")
		if !testing.expect(t, ok, err.message) {
			close(&conn)
			tmpl_remove_db(path)
			continue
		}
		testing.expect(t, !sqlite_object_exists(&conn, "event_outbox"))
		testing.expect(t, !sqlite_object_exists(&conn, "event_topics"))
		for name in migration_order {
			if name == "events_001_outbox.sql" do break
			testing.expectf(t, migration_applied(&conn, name), "main migration %s applied", name)
		}
		// Stable sentinels prove repeated startup preserves main's ledger.
		testing.expect(t, exec(&conn, "UPDATE schema_migrations SET applied_at='main-original' WHERE version IN ('221_extension_version_sync_0_5_61.sql','222_extension_version_sync_0_5_62.sql');"))
		if legacy {
			testing.expect(t, exec(&conn, MIGRATION_EVENTS_001_OUTBOX))
			testing.expect(t, exec(&conn, MIGRATION_EVENTS_002_TOPICS))
			mark_migration_applied(&conn, "221_event_outbox.sql")
			mark_migration_applied(&conn, "222_event_topics.sql")
			// Simulate events deployed before these two main releases.
			testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version IN ('221_extension_version_sync_0_5_61.sql','222_extension_version_sync_0_5_62.sql');"))
			testing.expect(t, exec(&conn, "INSERT INTO event_topics(owner_user_id,topic_key,generation,opened_event_id) VALUES ('owner','task:preserved',1,'evt-original');"))
		}
		for _ in 0..<2 {
			close(&conn)
			conn, opened, _ = open(path)
			if !testing.expect(t, opened) do break
			ok, err = run_migrations(&conn)
			if !testing.expect(t, ok, err.message) do break
			for name in migration_order {
				testing.expectf(t, migration_applied(&conn, name), "migration %s applied after upgrade", name)
			}
			testing.expect(t, sqlite_object_exists(&conn, "event_outbox_pending"))
			testing.expect(t, sqlite_object_exists(&conn, "event_outbox_published"))
			testing.expect(t, sqlite_object_exists(&conn, "event_entity_versions"))
			testing.expect(t, sqlite_object_exists(&conn, "event_topics"))
			if legacy {
				testing.expect_value(t, events_migration_text(&conn, "SELECT opened_event_id FROM event_topics WHERE topic_key='task:preserved';"), "evt-original")
				testing.expect(t, migration_applied(&conn, "221_event_outbox.sql"))
				testing.expect(t, migration_applied(&conn, "222_event_topics.sql"))
			} else {
				testing.expect_value(t, events_migration_text(&conn, "SELECT count(*) FROM schema_migrations WHERE applied_at='main-original';"), "2")
			}
		}
		close(&conn)
		tmpl_remove_db(path)
	}
}

events_migration_text :: proc(conn: ^Conn, query: string) -> string {
 stmt: sqlite3_stmt
 if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
 defer sqlite3_finalize(stmt)
 if sqlite3_step(stmt) != SQLITE_ROW do return ""
 return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}
