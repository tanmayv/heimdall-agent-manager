package sqlite

import "core:fmt"
import domain "odin_test:hub/domain"

// Caller-supplied binding identity is authenticated and constructed by the service.
// A transaction protects both on-demand binding creation and durable idempotency.
web_message_store_sqlite :: proc(ctx: rawptr, binding: domain.Channel_Binding, message: domain.Channel_Message, attachments: []domain.Channel_Attachment) -> (domain.Channel_Message, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	if conn == nil || conn.db == nil do return {}, false, bot_repo_error(conn)
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	mutex := sqlite3_db_mutex(conn.db)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, false, bot_repo_error(conn)
	committed := false
	defer if !committed do exec(conn, "ROLLBACK;")
	// external_message_id retains a payload hash after message body retention.
	old, old_err := bot_repo_list_channel_message(conn,
		"SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at, action_ids_json FROM channel_messages WHERE owner_user_id = ? AND bot_id = ? AND provider_update_key = ?;",
		{message.owner_user_id, message.bot_id, message.provider_update_key})
	defer {for &m in old do domain.channel_message_destroy(&m); delete(old)}
	if old_err.code != .None do return {}, false, old_err
	if len(old) > 0 {
		if old[0].external_message_id != message.external_message_id do return {}, false, domain.domain_error(.Conflict, "idempotency key was already used with different text")
		if !exec(conn, "COMMIT;") do return {}, false, bot_repo_error(conn)
		committed = true
		result := old[0]; old[0] = {}
		return result, false, {}
	}
	_, bind_err := bot_repo_write(conn,
		"INSERT INTO channel_bindings (binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, state, created_at, last_inbound_at) VALUES (?, ?, ?, 'web', ?, ?, 'active', ?, ?) ON CONFLICT(owner_user_id, provider) WHERE state = 'active' DO NOTHING;",
		{binding.binding_id, binding.owner_user_id, binding.bot_id, binding.external_chat_id, binding.external_user_id, binding.created_at, message.created_at})
	if bind_err.code != .None do return {}, false, bind_err
	active, found, e := binding_get_active_by_owner_sqlite(ctx, binding.owner_user_id, "web")
	defer domain.channel_binding_destroy(&active)
	if e.code != .None do return {}, false, e
	if !found || active.bot_id != message.bot_id do return {}, false, domain.domain_error(.Conflict, "web binding does not match bot")
	row := message
	row.binding_id = active.binding_id
	_, insert_err := bot_repo_write(conn,
		"INSERT INTO channel_messages (message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, created_at) VALUES (?, ?, ?, ?, 'inbound', ?, ?, ?, ?);",
		{row.message_id, row.binding_id, row.owner_user_id, row.bot_id, row.provider_update_key, row.external_message_id, row.body, row.created_at})
	if insert_err.code != .None do return {}, false, insert_err
	for a in attachments {
		row.attachment = a
		if e := bot_repo_insert_attachment(conn, row); e.code != .None do return {}, false, e
	}
	_, touch_err := bot_repo_write(conn, "UPDATE channel_bindings SET last_inbound_at = ? WHERE binding_id = ?;", {message.created_at, active.binding_id})
	if touch_err.code != .None do return {}, false, touch_err
	if !exec(conn, "COMMIT;") do return {}, false, bot_repo_error(conn)
	committed = true
	// Use the common row decoder to return a wholly owned snapshot.
	stored, get_err := bot_repo_list_channel_message(conn,
		"SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at, action_ids_json FROM channel_messages WHERE message_id = ?;",
		{message.message_id})
	defer delete(stored)
	if get_err.code != .None do return {}, false, get_err
	if len(stored) != 1 do return {}, false, domain.domain_error(.Internal_Error, "stored web message missing")
	return stored[0], true, {}
}

messages_page_sqlite :: proc(ctx: rawptr, owner, bot_id, before: string, limit: int) -> ([]domain.Channel_Message, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	if before != "" {
		cursor, err := bot_repo_list_channel_message(conn,
			"SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at, action_ids_json FROM channel_messages WHERE message_id = ? AND owner_user_id = ? AND bot_id = ?;",
			{before, owner, bot_id})
		defer {for &m in cursor do domain.channel_message_destroy(&m); delete(cursor)}
		if err.code != .None do return nil, err
		if len(cursor) != 1 do return nil, domain.domain_error(.Validation_Failed, "invalid history cursor")
		return bot_repo_list_channel_message(conn,
			"SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at, action_ids_json FROM channel_messages WHERE owner_user_id = ? AND bot_id = ? AND (created_at < ? OR (created_at = ? AND message_id < ?)) ORDER BY created_at DESC, message_id DESC LIMIT ?;",
			{owner, bot_id, cursor[0].created_at, cursor[0].created_at, before, fmt.tprintf("%d", limit)})
	}
	return bot_repo_list_channel_message(conn,
		"SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at, action_ids_json FROM channel_messages WHERE owner_user_id = ? AND bot_id = ? ORDER BY created_at DESC, message_id DESC LIMIT ?;",
		{owner, bot_id, fmt.tprintf("%d", limit)})
}
