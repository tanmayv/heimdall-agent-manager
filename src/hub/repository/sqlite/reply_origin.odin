package sqlite

import domain "odin_test:hub/domain"

// Reply origin storage (R7, migration 271). See iface/reply_origin.odin.

content_record_input_consumption_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id, message_id, kind, consumed_at: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	impl := cast(^Content_Repo_SQLite)ctx
	// Only a user->agent row of this conversation and owner qualifies (never a
	// rollover handoff: the agent wrote it to itself, nobody awaits a reply);
	// the first consumption wins (UNIQUE message_id).
	q := "INSERT OR IGNORE INTO chat_input_consumptions(message_id,owner_user_id,conversation_id,kind,consumed_at) " +
		"SELECT message_id,owner_user_id,conversation_id,?,? FROM chat_messages WHERE message_id=? AND owner_user_id=? AND conversation_id=? AND direction='user_to_agent' AND COALESCE(message_type,'text')<>'previous_context';"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed input consumption save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, kind); bind_text(stmt, 2, consumed_at); bind_text(stmt, 3, message_id); bind_text(stmt, 4, string(owner)); bind_text(stmt, 5, conversation_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "input consumption could not be saved")
	return {}
}

content_list_input_consumptions_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string, after_seq: i64) -> ([]domain.Input_Consumption, domain.Domain_Error) {
	impl := cast(^Content_Repo_SQLite)ctx
	q := "SELECT c.seq,c.message_id,c.owner_user_id,c.conversation_id,c.kind,c.consumed_at,COALESCE(NULLIF(m.origin,''),'" + domain.REPLY_ORIGIN_LOCAL + "') " +
		"FROM chat_input_consumptions c JOIN chat_messages m ON m.message_id=c.message_id " +
		"WHERE c.owner_user_id=? AND c.conversation_id=? AND c.seq>? ORDER BY c.seq;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed input consumption list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner)); bind_text(stmt, 2, conversation_id); sqlite3_bind_int64(stmt, 3, after_seq)
	rows := make([dynamic]domain.Input_Consumption)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return nil, domain.domain_error(.Internal_Error, "failed input consumption list")
		append(&rows, domain.Input_Consumption{seq=sqlite3_column_int64(stmt,0), message_id=column_text(stmt,1), owner_user_id=column_text(stmt,2),
			conversation_id=column_text(stmt,3), kind=column_text(stmt,4), consumed_at=column_text(stmt,5), origin=column_text(stmt,6)})
	}
	return rows[:], {}
}

content_get_reply_watermark_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (domain.Reply_Watermark, bool, domain.Domain_Error) {
	impl := cast(^Content_Repo_SQLite)ctx
	q := "SELECT conversation_id,owner_user_id,through_seq,reply_message_id,updated_at FROM chat_reply_watermarks WHERE owner_user_id=? AND conversation_id=?;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed reply watermark lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner)); bind_text(stmt, 2, conversation_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, {}
	if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed reply watermark lookup")
	return {conversation_id=column_text(stmt,0), owner_user_id=column_text(stmt,1), through_seq=sqlite3_column_int64(stmt,2), reply_message_id=column_text(stmt,3), updated_at=column_text(stmt,4)}, true, {}
}

content_advance_reply_watermark_sqlite :: proc(ctx: rawptr, next: domain.Reply_Watermark, expected_seq: i64) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	impl := cast(^Content_Repo_SQLite)ctx
	// A missing row counts as through_seq 0; the upsert only lands while the
	// stored point still equals expected_seq.
	q := "INSERT INTO chat_reply_watermarks(conversation_id,owner_user_id,through_seq,reply_message_id,updated_at) SELECT ?,?,?,?,? " +
		"WHERE ?=0 OR EXISTS (SELECT 1 FROM chat_reply_watermarks WHERE conversation_id=?1) " +
		"ON CONFLICT(conversation_id) DO UPDATE SET through_seq=excluded.through_seq,reply_message_id=excluded.reply_message_id,updated_at=excluded.updated_at " +
		"WHERE chat_reply_watermarks.owner_user_id=excluded.owner_user_id AND chat_reply_watermarks.through_seq=?6;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed reply watermark save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, next.conversation_id); bind_text(stmt, 2, next.owner_user_id); sqlite3_bind_int64(stmt, 3, next.through_seq)
	bind_text(stmt, 4, next.reply_message_id); bind_text(stmt, 5, next.updated_at); sqlite3_bind_int64(stmt, 6, expected_seq)
	rc, changes := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "reply watermark could not be saved")
	if changes != 1 do return domain.domain_error(.Conflict, "reply watermark moved concurrently")
	return {}
}

content_message_origin_sqlite :: proc(ctx: rawptr, message_id: string) -> (string, domain.Domain_Error) {
	impl := cast(^Content_Repo_SQLite)ctx
	q := "SELECT COALESCE(NULLIF(origin,''),'" + domain.REPLY_ORIGIN_LOCAL + "') FROM chat_messages WHERE message_id=?;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return "", domain.domain_error(.Internal_Error, "failed message origin lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, message_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return "", domain.domain_error(.Not_Found, "message not found")
	if rc != SQLITE_ROW do return "", domain.domain_error(.Internal_Error, "failed message origin lookup")
	return column_text(stmt, 0), {}
}

content_conversation_has_channel_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (bool, domain.Domain_Error) {
	impl := cast(^Content_Repo_SQLite)ctx
	q := "SELECT EXISTS (SELECT 1 FROM chat_messages WHERE owner_user_id=? AND conversation_id=? AND direction='user_to_agent' AND origin IS NOT NULL AND origin<>'' AND origin<>'" + domain.REPLY_ORIGIN_LOCAL + "');"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed conversation channel lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner)); bind_text(stmt, 2, conversation_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return false, domain.domain_error(.Internal_Error, "failed conversation channel lookup")
	return sqlite3_column_int64(stmt, 0) != 0, {}
}
