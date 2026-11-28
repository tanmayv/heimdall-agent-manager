package sqlite

import "core:fmt"
import domain "odin_test:hub/domain"

canonical_whatsapp_receipt_store_sqlite :: proc(ctx: rawptr,event_id,external_id,recipient: string,code: int,now: string) -> (bool,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	_, err := bot_repo_write(conn,`INSERT OR IGNORE INTO bot_channel_whatsapp_receipts
		(event_id,provider_message_id,recipient,provider_code,received_at) VALUES(?,?,?,?,?);`,{event_id,external_id,recipient,fmt.tprintf("%d",code),now})
	if err.code!=.None do return false,err
	// Legacy may still track a different (unmatched) receipt as its own
	// metadata. This check cannot associate it with a new pairing.
	stmt, read_err := bot_repo_prepare(conn,`SELECT 1 FROM bot_channel_reply_parts p
		JOIN bot_channel_reply_outbox j USING(reply_message_id) JOIN channel_bindings b USING(binding_id)
		WHERE j.provider='whatsapp' AND p.provider_message_id=? AND (?=b.external_chat_id OR ?=b.external_user_id) LIMIT 1;`,
		{external_id,recipient,recipient})
	if read_err.code!=.None do return false,read_err
	defer sqlite3_finalize(stmt)
	switch sqlite3_step(stmt) {
	case SQLITE_ROW: return true,{}
	case SQLITE_DONE: return false,{}
	}
	return false,bot_repo_error(conn)
}

canonical_whatsapp_receipt_pending_sqlite :: proc(ctx: rawptr) -> ([]domain.Bot_Channel_Provider_Receipt,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn,`SELECT r.event_id,r.provider_message_id,r.provider_code,p.reply_message_id,p.part_index,
		p.window_anchor,j.owner_user_id,j.binding_id FROM bot_channel_whatsapp_receipts r
		JOIN bot_channel_reply_parts p ON p.provider_message_id=r.provider_message_id AND p.status='sent'
		JOIN bot_channel_reply_outbox j USING(reply_message_id) JOIN channel_bindings b USING(binding_id)
		WHERE r.processed=0 AND j.provider='whatsapp' AND p.provider_message_id<>'' AND (r.recipient=b.external_chat_id OR r.recipient=b.external_user_id)
		ORDER BY r.received_at,r.event_id LIMIT 16;`,{})
	if err.code!=.None do return nil,err
	defer sqlite3_finalize(stmt)
	rows:=make([dynamic]domain.Bot_Channel_Provider_Receipt,context.temp_allocator)
	for {
		step:=sqlite3_step(stmt)
		if step==SQLITE_DONE do return rows[:],{}
		if step!=SQLITE_ROW do return nil,bot_repo_error(conn)
		append(&rows,domain.Bot_Channel_Provider_Receipt{event_id=column_text(stmt,0),external_id=column_text(stmt,1),provider_code=int(sqlite3_column_int64(stmt,2)),
			reply_message_id=column_text(stmt,3),part_index=int(sqlite3_column_int64(stmt,4)),window_anchor=column_text(stmt,5),
			owner_user_id=column_text(stmt,6),binding_id=column_text(stmt,7)})
	}
}

// The supervisor applies the callback inside a UoW after validating the
// original grant. Ignore a callback for a superseded provider attempt.
canonical_whatsapp_receipt_apply_sqlite :: proc(ctx:rawptr,r: domain.Bot_Channel_Provider_Receipt,part_status,job_status: string) -> (bool,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	n, err := bot_repo_write(conn,`UPDATE bot_channel_whatsapp_receipts SET processed=1 WHERE event_id=? AND processed=0;`,{r.event_id})
	if err.code!=.None || n!=1 do return false,err
	n, err = bot_repo_write(conn,`UPDATE bot_channel_reply_parts SET status=?
		WHERE reply_message_id=? AND part_index=? AND status='sent' AND provider_message_id=?;`,
		{part_status,r.reply_message_id,fmt.tprintf("%d",r.part_index),r.external_id})
	if err.code!=.None || n!=1 do return false,err
	changed, state_err := bot_repo_write(conn,`UPDATE bot_channel_reply_outbox
		SET status=?,hold_anchor=CASE WHEN ?='held' THEN MAX(hold_anchor,?) ELSE '' END,next_attempt_ms=0
		WHERE reply_message_id=? AND binding_id=? AND provider='whatsapp' AND status IN ('pending','held','sent');`,
		{job_status,job_status,r.window_anchor,r.reply_message_id,r.binding_id})
	return changed==1,state_err
}

canonical_whatsapp_receipt_purge_sqlite :: proc(ctx:rawptr, cutoff: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_,err:=bot_repo_write(bot_repo_conn(ctx),"DELETE FROM bot_channel_whatsapp_receipts WHERE received_at<?;",{cutoff})
	return err
}
