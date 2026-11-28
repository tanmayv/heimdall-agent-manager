package sqlite

import domain "odin_test:hub/domain"

// agent_notified_at storage (migration 272). See iface/agent_notified.odin.

content_note_agent_notified_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id, at: string) -> (bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	impl := cast(^Content_Repo_SQLite)ctx
	// Canonical RFC 3339 UTC strings order lexically; only a later time lands.
	q := "UPDATE chat_conversations SET agent_notified_at=?1 WHERE conversation_id=?2 AND owner_user_id=?3 AND agent_notified_at<?1;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed agent notified save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, at); bind_text(stmt, 2, conversation_id); bind_text(stmt, 3, string(owner))
	rc, changes := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "agent notified could not be saved")
	return changes == 1, {}
}

content_agent_notified_at_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (string, domain.Domain_Error) {
	impl := cast(^Content_Repo_SQLite)ctx
	q := "SELECT agent_notified_at FROM chat_conversations WHERE conversation_id=? AND owner_user_id=?;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return "", domain.domain_error(.Internal_Error, "failed agent notified lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, conversation_id); bind_text(stmt, 2, string(owner))
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return "", {}
	if rc != SQLITE_ROW do return "", domain.domain_error(.Internal_Error, "failed agent notified lookup")
	return column_text(stmt, 0), {}
}
