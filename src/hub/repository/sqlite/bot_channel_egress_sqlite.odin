package sqlite

import "core:fmt"
import domain "odin_test:hub/domain"

bot_channel_reply_enqueue_sqlite :: proc(ctx: rawptr, id, owner, provider: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := bot_repo_write(bot_repo_conn(ctx),
		"INSERT INTO bot_channel_reply_outbox (reply_message_id,owner_user_id,provider) VALUES (?,?,?);",{id,owner,provider})
	return err
}

bot_channel_reply_recover_sqlite :: proc(ctx: rawptr, provider: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	_, err := bot_repo_write(conn,`UPDATE bot_channel_reply_outbox AS job SET status='unknown'
		WHERE provider=? AND status='pending' AND EXISTS (
			SELECT 1 FROM bot_channel_reply_parts p WHERE p.reply_message_id=job.reply_message_id AND p.status='sending');`,{provider})
	if err.code!=.None do return err
	// If the process stopped after writing the job outcome, finish the part
	// idempotently on the next tick; the job is already barred from sending.
	_, err = bot_repo_write(conn,`UPDATE bot_channel_reply_parts AS p SET status='unknown'
		WHERE status='sending' AND EXISTS (
			SELECT 1 FROM bot_channel_reply_outbox job WHERE job.reply_message_id=p.reply_message_id AND job.provider=? AND job.status='unknown');`,{provider})
	return err
}

bot_channel_reply_pending_sqlite :: proc(ctx: rawptr, provider: string, now_ms: i64) -> ([]domain.Bot_Channel_Reply_Job,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn,`SELECT reply_message_id,owner_user_id FROM bot_channel_reply_outbox
		WHERE provider=? AND status='pending' AND next_attempt_ms<=CAST(? AS INTEGER)
		ORDER BY next_attempt_ms,reply_message_id LIMIT 8;`,{provider,fmt.tprintf("%d",now_ms)})
	if err.code!=.None do return nil,err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Bot_Channel_Reply_Job,context.temp_allocator)
	for {
		step := sqlite3_step(stmt)
		if step==SQLITE_DONE do return rows[:],{}
		if step!=SQLITE_ROW do return nil,bot_repo_error(conn)
		append(&rows,domain.Bot_Channel_Reply_Job{column_text(stmt,0),column_text(stmt,1),provider})
	}
}

bot_channel_reply_state_sqlite :: proc(ctx: rawptr, id, owner: string) -> (string,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn,"SELECT status FROM bot_channel_reply_outbox WHERE reply_message_id=? AND owner_user_id=?;",{id,owner})
	if err.code!=.None do return "",err
	defer sqlite3_finalize(stmt)
	switch sqlite3_step(stmt) {
	case SQLITE_ROW: return column_text(stmt,0),{}
	case SQLITE_DONE: return "",{}
	}
	return "",bot_repo_error(conn)
}

bot_channel_reply_finish_sqlite :: proc(ctx: rawptr, id, status: string, next_attempt_ms: i64) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := bot_repo_write(bot_repo_conn(ctx),
		"UPDATE bot_channel_reply_outbox SET status=?,next_attempt_ms=? WHERE reply_message_id=? AND status='pending';",
		{status,fmt.tprintf("%d",next_attempt_ms),id})
	return err
}

bot_channel_reply_part_claim_sqlite :: proc(ctx: rawptr, id: string, index: int) -> (string,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	n := fmt.tprintf("%d",index)
	count, err := bot_repo_write(conn,`INSERT OR IGNORE INTO bot_channel_reply_parts (reply_message_id,part_index,status)
		SELECT reply_message_id,?,'sending' FROM bot_channel_reply_outbox WHERE reply_message_id=? AND status='pending';`,{n,id})
	if err.code!=.None do return "",err
	if count==1 do return "claimed",{}
	stmt, read_err := bot_repo_prepare(conn,"SELECT status FROM bot_channel_reply_parts WHERE reply_message_id=? AND part_index=?;",{id,n})
	if read_err.code!=.None do return "",read_err
	defer sqlite3_finalize(stmt)
	switch sqlite3_step(stmt) {
	case SQLITE_ROW: return column_text(stmt,0),{}
	case SQLITE_DONE: return "",domain.domain_error(.Conflict,"channel reply is no longer pending")
	}
	return "",bot_repo_error(conn)
}

bot_channel_reply_part_finish_sqlite :: proc(ctx: rawptr, id: string, index: int, status, external_id: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := bot_repo_write(bot_repo_conn(ctx),
		"UPDATE bot_channel_reply_parts SET status=?,provider_message_id=? WHERE reply_message_id=? AND part_index=? AND status='sending';",
		{status,external_id,id,fmt.tprintf("%d",index)})
	return err
}

bot_channel_queue_feedback_sqlite :: proc(ctx: rawptr, id: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := bot_repo_write(bot_repo_conn(ctx),`INSERT OR IGNORE INTO bot_channel_feedback(inbound_message_id,reaction)
		SELECT inbound_message_id,'queued' FROM bot_channel_conversion_origins WHERE inbound_message_id=? AND external_message_id<>'';`,{id})
	return err
}

bot_channel_feedback_pending_sqlite :: proc(ctx: rawptr, provider: string) -> ([]domain.Bot_Channel_Feedback,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn,`SELECT f.inbound_message_id,b.binding_id,b.owner_user_id,b.external_chat_id,o.external_message_id,f.reaction
		FROM bot_channel_feedback f JOIN bot_channel_conversion_origins o USING(inbound_message_id)
		JOIN channel_bindings b ON b.binding_id=o.binding_id
		WHERE f.dispatched=0 AND b.provider=? ORDER BY f.inbound_message_id LIMIT 16;`,{provider})
	if err.code!=.None do return nil,err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Bot_Channel_Feedback,context.temp_allocator)
	for {
		step := sqlite3_step(stmt)
		if step==SQLITE_DONE do return rows[:],{}
		if step!=SQLITE_ROW do return nil,bot_repo_error(conn)
		append(&rows,domain.Bot_Channel_Feedback{column_text(stmt,0),column_text(stmt,1),column_text(stmt,2),column_text(stmt,3),column_text(stmt,4),column_text(stmt,5)})
	}
}

bot_channel_feedback_claim_sqlite :: proc(ctx: rawptr, id, reaction: string) -> (bool,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	changed, err := bot_repo_write(bot_repo_conn(ctx),`UPDATE bot_channel_feedback SET dispatched=1
		WHERE inbound_message_id=? AND reaction=? AND dispatched=0;`,{id,reaction})
	return changed==1,err
}
