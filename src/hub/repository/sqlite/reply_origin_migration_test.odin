package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// R7 reply origin (migration 271): additive over existing chat rows, re-runnable,
// and the repository reads a NULL origin as local.
@(test)
test_reply_origin_migration_and_repository :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "271_reply_origin.sql")
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, !table_column_exists(&conn, "chat_messages", "origin"))
	testing.expect(t, exec(&conn, "INSERT INTO chat_conversations(conversation_id,owner_user_id,agent_id,agent_instance_id,title,created_at,updated_at) VALUES('chat_a','u','agt','inst','t','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');"))
	testing.expect(t, exec(&conn, "INSERT INTO chat_messages(message_id,conversation_id,owner_user_id,direction,sender_agent_id,sender_agent_instance_id,body,artifact_ids_json,created_at) VALUES('msg_old','chat_a','u','user_to_agent','agt','inst','hi','[]','2026-01-01T00:00:00Z');"))
	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	migrated, err = run_migrations(&conn) // ledger + completion guard
	testing.expect(t, migrated, err.message)
	testing.expect_value(t, migration_sql("271_reply_origin.sql", ""), migration_sql("271_reply_origin.sql", "src/hub/repository/sqlite/migrations"))

	impl: Content_Repo_SQLite
	repo := new_content_repository(&impl, &conn)
	testing.expect(t, iface.content_reply_origin_supported(&repo))
	origin, oerr := iface.content_message_origin(&repo, "msg_old")
	testing.expect_value(t, oerr.code, domain.Error_Code.None)
	testing.expect_value(t, origin, domain.REPLY_ORIGIN_LOCAL)
	has, _ := iface.content_conversation_has_channel(&repo, "u", "chat_a")
	testing.expect(t, !has)
	testing.expect_value(t, iface.content_record_input_consumption(&repo, "u", "chat_a", "msg_old", domain.INPUT_CONSUMED_READ, "2026-01-01T00:00:01Z").code, domain.Error_Code.None)
	// Another owner or conversation never records it; a repeat keeps the first.
	_ = iface.content_record_input_consumption(&repo, "other", "chat_a", "msg_old", domain.INPUT_CONSUMED_DELIVERED, "2026-01-01T00:00:02Z")
	_ = iface.content_record_input_consumption(&repo, "u", "chat_a", "msg_old", domain.INPUT_CONSUMED_DELIVERED, "2026-01-01T00:00:03Z")
	rows, lerr := iface.content_list_input_consumptions(&repo, "u", "chat_a", 0)
	testing.expect_value(t, lerr.code, domain.Error_Code.None)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0].kind, domain.INPUT_CONSUMED_READ)
		testing.expect_value(t, rows[0].origin, domain.REPLY_ORIGIN_LOCAL)
		after, _ := iface.content_list_input_consumptions(&repo, "u", "chat_a", rows[0].seq)
		testing.expect_value(t, len(after), 0)
	}
	testing.expect(t, exec(&conn, "UPDATE chat_messages SET origin='telegram' WHERE message_id='msg_old';"))
	has, _ = iface.content_conversation_has_channel(&repo, "u", "chat_a")
	testing.expect(t, has)
	origin, _ = iface.content_message_origin(&repo, "msg_old")
	testing.expect_value(t, origin, "telegram")
}
