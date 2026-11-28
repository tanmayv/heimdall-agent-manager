package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// The unread tray's message high-water mark (migration 272). See
// iface/agent_notified.odin.

content_note_agent_notified_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id, message_id: string) -> (iface.Agent_Notified_Through, bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	impl := cast(^Content_Repo_SQLite)ctx
	// Resolve the message: a user->agent row of this conversation, or its latest.
	q := "SELECT message_id, created_at FROM chat_messages WHERE conversation_id=?1 AND owner_user_id=?2 AND direction='user_to_agent' AND (?3='' OR message_id=?3) ORDER BY created_at DESC, message_id DESC LIMIT 1;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed agent notified lookup")
	bind_text(stmt, 1, conversation_id); bind_text(stmt, 2, string(owner)); bind_text(stmt, 3, message_id)
	rc := sqlite3_step(stmt)
	through: iface.Agent_Notified_Through
	if rc == SQLITE_ROW do through = {column_text(stmt, 0), column_text(stmt, 1)}
	sqlite3_finalize(stmt)
	if rc == SQLITE_DONE {
		if message_id == "" do return {}, false, {}
		return {}, false, domain.domain_error(.Not_Found, "no such user message in this conversation")
	}
	if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed agent notified lookup")
	// Only a later message in transcript order moves the mark.
	u := "UPDATE chat_conversations SET agent_notified_message_id=?1, agent_notified_message_at=?2 WHERE conversation_id=?3 AND owner_user_id=?4 AND (agent_notified_message_at, agent_notified_message_id) < (?2, ?1);"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(u)), -1, &stmt, nil) != SQLITE_OK do return through, false, domain.domain_error(.Internal_Error, "failed agent notified save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, through.message_id); bind_text(stmt, 2, through.created_at); bind_text(stmt, 3, conversation_id); bind_text(stmt, 4, string(owner))
	urc, changes := step_changes(impl.conn.db, stmt)
	if urc != SQLITE_DONE do return through, false, domain.domain_error(.Internal_Error, "agent notified could not be saved")
	return through, changes == 1, {}
}

content_agent_notified_through_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (iface.Agent_Notified_Through, domain.Domain_Error) {
	impl := cast(^Content_Repo_SQLite)ctx
	q := "SELECT agent_notified_message_id, agent_notified_message_at FROM chat_conversations WHERE conversation_id=? AND owner_user_id=?;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, domain.domain_error(.Internal_Error, "failed agent notified lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, conversation_id); bind_text(stmt, 2, string(owner))
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, {}
	if rc != SQLITE_ROW do return {}, domain.domain_error(.Internal_Error, "failed agent notified lookup")
	return {column_text(stmt, 0), column_text(stmt, 1)}, {}
}
