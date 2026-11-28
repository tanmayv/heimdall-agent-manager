package sqlite

import "core:fmt"
import domain "odin_test:hub/domain"

bot_conversion_binding_insert_sqlite :: proc(ctx: rawptr, p: domain.Bot_Channel_Fresh_Binding) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := bot_repo_write(bot_repo_conn(ctx),
		"INSERT INTO bot_channel_conversion_bindings VALUES (?, ?, ?);",
		{p.binding_id,fmt.tprintf("%d",p.activation_generation),fmt.tprintf("%d",p.binding_generation)})
	return err
}

bot_conversion_binding_get_sqlite :: proc(ctx: rawptr, id: string) -> (domain.Bot_Channel_Fresh_Binding,bool,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn, "SELECT activation_generation,binding_generation FROM bot_channel_conversion_bindings WHERE binding_id=?;", {id})
	if err.code != .None do return {},false,err
	defer sqlite3_finalize(stmt)
	switch sqlite3_step(stmt) {
	case SQLITE_DONE: return {},false,{}
	case SQLITE_ROW: return {id,i64(sqlite3_column_int64(stmt,0)),i64(sqlite3_column_int64(stmt,1))},true,{}
	}
	return {},false,bot_repo_error(conn)
}

bot_conversion_origin_insert_sqlite :: proc(ctx: rawptr, p: domain.Bot_Channel_Origin) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := bot_repo_write(bot_repo_conn(ctx),
		"INSERT INTO bot_channel_conversion_origins VALUES (?, ?, ?);",
		{p.inbound_message_id,p.binding_id,p.provider_update_key})
	return err
}

bot_conversion_reply_insert_sqlite :: proc(ctx: rawptr, reply_id,inbound_id,source_proof: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := bot_repo_write(bot_repo_conn(ctx),
		"INSERT INTO bot_channel_conversion_replies VALUES (?, ?, ?);",
		{reply_id,inbound_id,source_proof})
	return err
}

bot_conversion_reply_source_sqlite :: proc(ctx: rawptr, reply_id: string) -> (domain.Bot_Channel_Reply_Source,bool,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn, `SELECT o.inbound_message_id,o.binding_id,o.provider_update_key,r.source_proof
		FROM bot_channel_conversion_replies r JOIN bot_channel_conversion_origins o USING(inbound_message_id)
		WHERE r.reply_message_id=?;`,{reply_id})
	if err.code != .None do return {},false,err
	defer sqlite3_finalize(stmt)
	switch sqlite3_step(stmt) {
	case SQLITE_DONE: return {},false,{}
	case SQLITE_ROW: return {{column_text(stmt,0),column_text(stmt,1),column_text(stmt,2)},column_text(stmt,3)},true,{}
	}
	return {},false,bot_repo_error(conn)
}

bot_conversion_origin_exists_sqlite :: proc(ctx: rawptr, binding_id, event_id, inbound_id: string) -> (bool,domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn, `SELECT 1 FROM bot_channel_conversion_origins
		WHERE inbound_message_id=? OR (binding_id=? AND provider_update_key=?) LIMIT 1;`,{inbound_id,binding_id,event_id})
	if err.code != .None do return false,err
	defer sqlite3_finalize(stmt)
	switch sqlite3_step(stmt) {
	case SQLITE_DONE: return false,{}
	case SQLITE_ROW: return true,{}
	}
	return false,bot_repo_error(conn)
}
