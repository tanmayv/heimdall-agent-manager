package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Migration 272: the unread tray's message high-water mark is additive,
// re-runnable, resolved only from a user->agent message of the conversation,
// monotonic in transcript order, owner-scoped, and the conversation save never
// clobbers it.
@(test)
test_agent_notified_migration_and_repository :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "272_agent_notified_through.sql")
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, !table_column_exists(&conn, "chat_conversations", "agent_notified_message_id"))
	testing.expect(t, exec(&conn, "INSERT INTO chat_conversations(conversation_id,owner_user_id,agent_id,agent_instance_id,title,created_at,updated_at) VALUES('chat_a','u','agt','inst','t','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');"))
	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	migrated, err = run_migrations(&conn)
	testing.expect(t, migrated, err.message)
	testing.expect_value(t, migration_sql("272_agent_notified_through.sql", ""), migration_sql("272_agent_notified_through.sql", "src/hub/repository/sqlite/migrations"))

	impl: Content_Repo_SQLite
	repo := new_content_repository(&impl, &conn)
	through, _ := iface.content_agent_notified_through(&repo, "u", "chat_a")
	testing.expect_value(t, through.message_id, "")
	_, moved, nerr := iface.content_note_agent_notified(&repo, "u", "chat_a", "")
	testing.expect(t, !moved && nerr.code == .None, "no user message yet: nothing moves")

	_, ok, _ := iface.content_save_conversation(&repo, domain.Chat_Conversation{conversation_id="chat_b", owner_user_id="u", agent_id="agt", agent_instance_id="inst_b", title="b", created_at="2026-01-01T00:00:00Z", updated_at="2026-01-01T00:00:00Z"})
	testing.expect(t, ok)
	save :: proc(t: ^testing.T, repo: ^iface.Content_Repository, id, cid, direction, at: string) {
		_, ok, _ := iface.content_save_message(repo, domain.Chat_Message{message_id=id, conversation_id=cid, owner_user_id="u", direction=direction, body="hi", artifact_ids_json="[]", message_type="text", metadata_json="{}", created_at=at})
		testing.expect(t, ok, id)
	}
	// Two in the same second: message_id breaks the tie (transcript order).
	save(t, &repo, "msg_1", "chat_a", "user_to_agent", "2026-01-01T00:00:10Z")
	save(t, &repo, "msg_2", "chat_a", "user_to_agent", "2026-01-01T00:00:10Z")
	save(t, &repo, "msg_3", "chat_a", "user_to_agent", "2026-01-01T00:00:20Z")
	save(t, &repo, "msg_r", "chat_a", "agent_to_user", "2026-01-01T00:00:30Z")
	save(t, &repo, "msg_b", "chat_b", "user_to_agent", "2026-01-01T00:00:40Z")

	// Rejected: another conversation's message, an agent->user message, unknown.
	for bad in ([]string{"msg_b", "msg_r", "msg_none"}) {
		_, moved, nerr = iface.content_note_agent_notified(&repo, "u", "chat_a", bad)
		testing.expect(t, !moved && nerr.code == .Not_Found, bad)
	}
	_, moved, nerr = iface.content_note_agent_notified(&repo, "other", "chat_a", "msg_2")
	testing.expect(t, !moved && nerr.code == .Not_Found, "owner-scoped")

	through, moved, nerr = iface.content_note_agent_notified(&repo, "u", "chat_a", "msg_2")
	testing.expect(t, moved && nerr.code == .None)
	testing.expect_value(t, through, iface.Agent_Notified_Through{"msg_2", "2026-01-01T00:00:10Z"})
	_, moved, _ = iface.content_note_agent_notified(&repo, "u", "chat_a", "msg_2")
	testing.expect(t, !moved, "idempotent")
	_, moved, _ = iface.content_note_agent_notified(&repo, "u", "chat_a", "msg_1")
	testing.expect(t, !moved, "an earlier message (same second) never moves it back")
	// "" stamps the latest user->agent message (a delivered notice Send now).
	through, moved, _ = iface.content_note_agent_notified(&repo, "u", "chat_a", "")
	testing.expect(t, moved)
	testing.expect_value(t, through.message_id, "msg_3")

	c, found, _ := iface.content_get_conversation(&repo, "chat_a")
	testing.expect(t, found)
	c.title = "renamed"
	_, saved, _ := iface.content_save_conversation(&repo, c)
	testing.expect(t, saved)
	through, _ = iface.content_agent_notified_through(&repo, "u", "chat_a")
	testing.expect_value(t, through, iface.Agent_Notified_Through{"msg_3", "2026-01-01T00:00:20Z"})
	other, _ := iface.content_agent_notified_through(&repo, "other", "chat_a")
	testing.expect_value(t, other.message_id, "")
}
