package sqlite

import "core:testing"
import "core:strings"
import domain "odin_test:hub/domain"

@(test)
test_web_migration_preserves_external_bindings_and_history :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, _, err := open(":memory:")
	if !testing.expect(t, err.code == .None) do return
	defer close(&conn)
	ok, e := run_migrations(&conn, stop_before = "bots_web_001_channel.sql")
	if !testing.expect(t, ok && e.code == .None) do return
	testing.expect(t, exec(&conn, `INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,external_display,state,created_at,last_inbound_at,reengage_sent_at,reengage_error) VALUES ('wa_keep','alice','bot_a','whatsapp','100','200','Alice','active','2026-11-17T00:00:00Z','2026-11-18T00:00:00Z','2026-11-19T00:00:00Z','send_failed'); INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at,revoked_at) VALUES ('tg_keep','alice','bot_a','telegram','300','400','revoked','2026-11-17T00:00:00Z','2026-11-18T00:00:00Z'); INSERT INTO channel_messages(message_id,binding_id,owner_user_id,bot_id,direction,body,created_at) VALUES('keep_msg','wa_keep','alice','bot_a','inbound','keep me','2026-11-18T00:00:00Z');`))
	before := web_migration_text(&conn, "SELECT group_concat(binding_id || ':' || provider || ':' || state || ':' || created_at || ':' || revoked_at || ':' || last_inbound_at || ':' || reengage_sent_at || ':' || reengage_error || ':' || external_display) FROM channel_bindings ORDER BY binding_id;")
	ok, e = run_migrations(&conn)
	testing.expect(t, ok && e.code == .None)
	after := web_migration_text(&conn, "SELECT group_concat(binding_id || ':' || provider || ':' || state || ':' || created_at || ':' || revoked_at || ':' || last_inbound_at || ':' || reengage_sent_at || ':' || reengage_error || ':' || external_display) FROM channel_bindings ORDER BY binding_id;")
	testing.expect_value(t, after, before)
	testing.expect_value(t, web_migration_text(&conn, "SELECT body FROM channel_messages WHERE message_id='keep_msg';"), "keep me")
	testing.expect(t, sqlite_object_exists(&conn, "channel_bindings_active_owner") && sqlite_object_exists(&conn, "channel_bindings_active_chat") && sqlite_object_exists(&conn, "channel_messages_history_page"))
	testing.expect(t, exec(&conn, "INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at) VALUES('web_a','alice','bot_a','web','bot_a','alice','active','now');"))
	testing.expect(t, !exec(&conn, "INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at) VALUES('web_dup','alice','bot_a','web','bot_a','alice','active','now');"))
	testing.expect(t, !exec(&conn, "INSERT INTO channel_pairings(code_hash,owner_user_id,bot_id,provider,created_at,expires_at) VALUES('web_pair','alice','bot_a','web','now','later');"), "web has no pairing")
	ok, e = run_migrations(&conn)
	testing.expect(t, ok && e.code == domain.Error_Code.None)
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='bots_web_001_channel.sql';"))
	ok, e = run_migrations(&conn, migrations_dir = "")
	testing.expect(t, ok && e.code == .None && migration_applied(&conn, "bots_web_001_channel.sql"))
	testing.expect_value(t, web_migration_text(&conn, "SELECT body FROM channel_messages WHERE message_id='keep_msg';"), "keep me")
}

web_migration_text :: proc(conn: ^Conn, query: string) -> string {
	stmt, err := bot_repo_prepare(conn, query, nil)
	if err.code != .None do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}
