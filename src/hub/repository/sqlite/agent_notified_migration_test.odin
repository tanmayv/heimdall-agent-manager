package sqlite

import "core:testing"
import iface "odin_test:hub/repository/iface"

// R7 rev 6 (migration 272): agent_notified_at is additive, re-runnable, monotonic,
// owner-scoped, and the conversation save never clobbers it.
@(test)
test_agent_notified_migration_and_repository :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "272_agent_notified_at.sql")
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, !table_column_exists(&conn, "chat_conversations", "agent_notified_at"))
	testing.expect(t, exec(&conn, "INSERT INTO chat_conversations(conversation_id,owner_user_id,agent_id,agent_instance_id,title,created_at,updated_at) VALUES('chat_a','u','agt','inst','t','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');"))
	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	migrated, err = run_migrations(&conn)
	testing.expect(t, migrated, err.message)
	testing.expect_value(t, migration_sql("272_agent_notified_at.sql", ""), migration_sql("272_agent_notified_at.sql", "src/hub/repository/sqlite/migrations"))

	impl: Content_Repo_SQLite
	repo := new_content_repository(&impl, &conn)
	at, _ := iface.content_agent_notified_at(&repo, "u", "chat_a")
	testing.expect_value(t, at, "")
	moved, nerr := iface.content_note_agent_notified(&repo, "u", "chat_a", "2026-01-01T00:00:10Z")
	testing.expect(t, moved && nerr.code == .None)
	moved, _ = iface.content_note_agent_notified(&repo, "u", "chat_a", "2026-01-01T00:00:10Z")
	testing.expect(t, !moved, "idempotent")
	moved, _ = iface.content_note_agent_notified(&repo, "u", "chat_a", "2026-01-01T00:00:05Z")
	testing.expect(t, !moved, "older is ignored")
	moved, _ = iface.content_note_agent_notified(&repo, "other", "chat_a", "2026-01-01T00:00:20Z")
	testing.expect(t, !moved, "owner-scoped")
	c, found, _ := iface.content_get_conversation(&repo, "chat_a")
	testing.expect(t, found)
	c.title = "renamed"
	_, saved, _ := iface.content_save_conversation(&repo, c)
	testing.expect(t, saved)
	at, _ = iface.content_agent_notified_at(&repo, "u", "chat_a")
	testing.expect_value(t, at, "2026-01-01T00:00:10Z")
	other, _ := iface.content_agent_notified_at(&repo, "other", "chat_a")
	testing.expect_value(t, other, "")
}
