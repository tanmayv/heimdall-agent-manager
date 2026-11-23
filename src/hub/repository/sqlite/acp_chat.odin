package sqlite

import domain "odin_test:hub/domain"

content_get_assistant_turn_sqlite :: proc(ctx: rawptr, instance, epoch, turn: string) -> (domain.ACP_Assistant_Turn, bool, domain.Domain_Error) {
    impl := cast(^Content_Repo_SQLite)ctx
    q := "SELECT message_id,revision,payload_hash FROM acp_assistant_turns WHERE agent_instance_id=? AND launch_epoch=? AND turn_id=?;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed assistant turn lookup")
    defer sqlite3_finalize(stmt)
    bind_text(stmt, 1, instance); bind_text(stmt, 2, epoch); bind_text(stmt, 3, turn)
    rc := sqlite3_step(stmt)
    if rc == SQLITE_DONE do return {}, false, {}
    if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed assistant turn lookup")
    return {agent_instance_id=instance, launch_epoch=epoch, turn_id=turn, message_id=column_text(stmt,0), revision=sqlite3_column_int64(stmt,1), payload_hash=column_text(stmt,2)}, true, {}
}

// The service owns the encompassing unit of work, including the message and
// conversation mutation. The unique message_id also prevents cross-turn reuse.
content_save_assistant_turn_sqlite :: proc(ctx: rawptr, turn: domain.ACP_Assistant_Turn) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)

    impl := cast(^Content_Repo_SQLite)ctx
    q := "INSERT INTO acp_assistant_turns(agent_instance_id,launch_epoch,turn_id,message_id,revision,payload_hash) VALUES(?,?,?,?,?,?) ON CONFLICT(agent_instance_id,launch_epoch,turn_id) DO UPDATE SET revision=excluded.revision,payload_hash=excluded.payload_hash WHERE message_id=excluded.message_id;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed assistant turn save")
    defer sqlite3_finalize(stmt)
    bind_text(stmt,1,turn.agent_instance_id); bind_text(stmt,2,turn.launch_epoch); bind_text(stmt,3,turn.turn_id)
    bind_text(stmt,4,turn.message_id); sqlite3_bind_int64(stmt,5,turn.revision); bind_text(stmt,6,turn.payload_hash)
    if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Conflict, "assistant turn could not be saved")
    return {}
}
