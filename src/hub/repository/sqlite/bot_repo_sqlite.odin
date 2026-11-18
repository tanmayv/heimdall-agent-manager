package sqlite

import "core:c"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Multi-statement mutations hold SQLite's recursive connection mutex for the
// entire transaction, preventing other users of the shared connection joining it.
Bot_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_bot_repository :: proc(impl: ^Bot_Repo_SQLite, conn: ^Conn) -> iface.Bot_Repository {
	impl.conn = conn
	return iface.Bot_Repository {
		ctx = rawptr(impl),
		bot_list = bot_list_sqlite,
		bot_insert = bot_insert_sqlite,
		bot_get_by_owner = bot_get_by_owner_sqlite,
		bot_get = bot_get_sqlite,
		bot_get_by_instance = bot_get_by_instance_sqlite,
		bot_set_instance = bot_set_instance_sqlite,
		bot_delete = bot_delete_sqlite,
		bot_list_owners_with_open_deliveries = bot_list_owners_with_open_deliveries_sqlite,
		placement_list = placement_list_sqlite,
		placement_replace = placement_replace_sqlite,
		binding_get_active_by_owner = binding_get_active_by_owner_sqlite,
		binding_get_active_by_chat = binding_get_active_by_chat_sqlite,
		binding_activate = binding_activate_sqlite,
		binding_revoke = binding_revoke_sqlite,
		pairing_consume = pairing_consume_sqlite,
		pairing_insert = pairing_insert_sqlite,
		pairing_get = pairing_get_sqlite,
		pairing_delete_for_owner = pairing_delete_for_owner_sqlite,
		cursor_get = cursor_get_sqlite,
		inbound_store_batch = inbound_store_batch_sqlite,
		message_insert_outbound = message_insert_outbound_sqlite,
		message_set_send_result = message_set_send_result_sqlite,
		messages_pending = messages_pending_sqlite,
		messages_mark_read = messages_mark_read_sqlite,
		messages_mark_replied = messages_mark_replied_sqlite,
		messages_history = messages_history_sqlite,
		messages_purge_binding = messages_purge_binding_sqlite,
		messages_purge_older_than = messages_purge_older_than_sqlite,
		delivery_get_open = delivery_get_open_sqlite,
		delivery_get = delivery_get_sqlite,
		delivery_insert = delivery_insert_sqlite,
		delivery_update = delivery_update_sqlite,
		delivery_list_open = delivery_list_open_sqlite,
		delivery_list_recent = delivery_list_recent_sqlite,
		attempt_insert = attempt_insert_sqlite,
		attempt_get = attempt_get_sqlite,
		attempt_update = attempt_update_sqlite,
		attempt_list_for_delivery = attempt_list_for_delivery_sqlite,
		attempt_list_open = attempt_list_open_sqlite,
		attempt_list_open_on_bridge = attempt_list_open_on_bridge_sqlite,
	}
}

bot_repo_error :: proc(conn: ^Conn) -> domain.Domain_Error {
	if conn != nil && conn.db != nil && (sqlite3_extended_errcode(conn.db) & 255) == 19 do return domain.domain_error(.Conflict, "bot storage constraint conflict")
	return domain.domain_error(.Internal_Error, "bot storage operation failed")
}

bot_repo_conn :: proc(ctx: rawptr) -> ^Conn {
	impl := (^Bot_Repo_SQLite)(ctx)
	if impl == nil do return nil
	return impl.conn
}

bot_repo_prepare :: proc(conn: ^Conn, query: string, args: []string) -> (sqlite3_stmt, domain.Domain_Error) {
	if conn == nil || conn.db == nil do return nil, bot_repo_error(conn)
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return nil, bot_repo_error(conn)
	for arg, i in args {
		if bind_rc := sqlite3_bind_text(
			stmt,
			c.int(i + 1),
			strings.clone_to_cstring(arg, context.temp_allocator),
			c.int(len(arg)),
			SQLITE_TRANSIENT,
		); bind_rc != SQLITE_OK {
			sqlite3_finalize(stmt)
			return nil, bot_repo_error(conn)
		}
	}
	return stmt, {}
}

bot_repo_write :: proc(conn: ^Conn, query: string, args: []string) -> (int, domain.Domain_Error) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return 0, err
	defer sqlite3_finalize(stmt)
	rc, changes := step_changes(conn.db, stmt)
	if rc != SQLITE_DONE do return 0, bot_repo_error(conn)
	return changes, {}
}

bot_repo_scan_bot :: proc(stmt: sqlite3_stmt) -> domain.Bot {
	value: domain.Bot
	value.bot_id = column_text(stmt, 0)
	value.owner_user_id = column_text(stmt, 1)
	value.agent_id = column_text(stmt, 2)
	value.agent_instance_id = column_text(stmt, 3)
	value.display_name = column_text(stmt, 4)
	value.placement_revision = int(sqlite3_column_int64(stmt, 5))
	value.created_at = column_text(stmt, 6)
	value.updated_at = column_text(stmt, 7)
	return value
}

bot_repo_list_bot :: proc(conn: ^Conn, query: string, args: []string) -> ([]domain.Bot, domain.Domain_Error) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Bot)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.bot_destroy(&row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, bot_repo_scan_bot(stmt))
	}
	return rows[:], {}
}

bot_repo_scan_bot_placement_candidate :: proc(stmt: sqlite3_stmt) -> domain.Bot_Placement_Candidate {
	value: domain.Bot_Placement_Candidate
	value.position = int(sqlite3_column_int64(stmt, 0))
	value.bridge_id = column_text(stmt, 1)
	value.provider = column_text(stmt, 2)
	value.model = column_text(stmt, 3)
	value.tier, _ = domain.bot_placement_tier_from_text(column_text_unowned(stmt, 4))
	return value
}

bot_repo_list_bot_placement_candidate :: proc(
	conn: ^Conn,
	query: string,
	args: []string,
) -> (
	[]domain.Bot_Placement_Candidate,
	domain.Domain_Error,
) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Bot_Placement_Candidate)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.bot_placement_candidate_destroy(&row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, bot_repo_scan_bot_placement_candidate(stmt))
	}
	return rows[:], {}
}

bot_repo_scan_channel_binding :: proc(stmt: sqlite3_stmt) -> domain.Channel_Binding {
	value: domain.Channel_Binding
	value.binding_id = column_text(stmt, 0)
	value.owner_user_id = column_text(stmt, 1)
	value.bot_id = column_text(stmt, 2)
	value.provider = column_text(stmt, 3)
	value.external_chat_id = column_text(stmt, 4)
	value.external_user_id = column_text(stmt, 5)
	value.external_display = column_text(stmt, 6)
	value.state, _ = domain.channel_binding_state_from_text(column_text_unowned(stmt, 7))
	value.created_at = column_text(stmt, 8)
	value.revoked_at = column_text(stmt, 9)
	return value
}

bot_repo_list_channel_binding :: proc(
	conn: ^Conn,
	query: string,
	args: []string,
) -> (
	[]domain.Channel_Binding,
	domain.Domain_Error,
) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Channel_Binding)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.channel_binding_destroy(&row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, bot_repo_scan_channel_binding(stmt))
	}
	return rows[:], {}
}

bot_repo_scan_channel_pairing :: proc(stmt: sqlite3_stmt) -> domain.Channel_Pairing {
	value: domain.Channel_Pairing
	value.code_hash = column_text(stmt, 0)
	value.owner_user_id = column_text(stmt, 1)
	value.bot_id = column_text(stmt, 2)
	value.provider = column_text(stmt, 3)
	value.created_at = column_text(stmt, 4)
	value.expires_at = column_text(stmt, 5)
	value.consumed_at = column_text(stmt, 6)
	return value
}

bot_repo_list_channel_pairing :: proc(
	conn: ^Conn,
	query: string,
	args: []string,
) -> (
	[]domain.Channel_Pairing,
	domain.Domain_Error,
) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Channel_Pairing)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.channel_pairing_destroy(&row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, bot_repo_scan_channel_pairing(stmt))
	}
	return rows[:], {}
}

bot_repo_scan_channel_message :: proc(stmt: sqlite3_stmt) -> domain.Channel_Message {
	value: domain.Channel_Message
	value.message_id = column_text(stmt, 0)
	value.binding_id = column_text(stmt, 1)
	value.owner_user_id = column_text(stmt, 2)
	value.bot_id = column_text(stmt, 3)
	value.direction, _ = domain.channel_direction_from_text(column_text_unowned(stmt, 4))
	value.provider_update_key = column_text(stmt, 5)
	value.external_message_id = column_text(stmt, 6)
	value.body = column_text(stmt, 7)
	value.body_purged = sqlite3_column_int64(stmt, 8) != 0
	value.send_state, _ = domain.channel_send_state_from_text(column_text_unowned(stmt, 9))
	value.send_error = column_text(stmt, 10)
	value.created_at = column_text(stmt, 11)
	value.read_at = column_text(stmt, 12)
	value.replied_at = column_text(stmt, 13)
	return value
}

bot_repo_list_channel_message :: proc(
	conn: ^Conn,
	query: string,
	args: []string,
) -> (
	[]domain.Channel_Message,
	domain.Domain_Error,
) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Channel_Message)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.channel_message_destroy(&row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, bot_repo_scan_channel_message(stmt))
	}
	return rows[:], {}
}

bot_repo_scan_bot_delivery :: proc(stmt: sqlite3_stmt) -> domain.Bot_Delivery {
	value: domain.Bot_Delivery
	value.delivery_id = column_text(stmt, 0)
	value.bot_id = column_text(stmt, 1)
	value.owner_user_id = column_text(stmt, 2)
	value.through_message_id = column_text(stmt, 3)
	value.state, _ = domain.bot_delivery_state_from_text(column_text_unowned(stmt, 4))
	value.round = int(sqlite3_column_int64(stmt, 5))
	value.waiting_reason = column_text(stmt, 6)
	value.waiting_notice_at = column_text(stmt, 7)
	value.finish_reason = column_text(stmt, 8)
	value.created_at = column_text(stmt, 9)
	value.updated_at = column_text(stmt, 10)
	value.finished_at = column_text(stmt, 11)
	return value
}

bot_repo_list_bot_delivery :: proc(
	conn: ^Conn,
	query: string,
	args: []string,
) -> (
	[]domain.Bot_Delivery,
	domain.Domain_Error,
) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Bot_Delivery)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.bot_delivery_destroy(&row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, bot_repo_scan_bot_delivery(stmt))
	}
	return rows[:], {}
}

bot_repo_scan_bot_delivery_attempt :: proc(stmt: sqlite3_stmt) -> domain.Bot_Delivery_Attempt {
	value: domain.Bot_Delivery_Attempt
	value.attempt_id = column_text(stmt, 0)
	value.delivery_id = column_text(stmt, 1)
	value.round = int(sqlite3_column_int64(stmt, 2))
	value.bridge_id = column_text(stmt, 3)
	value.state, _ = domain.bot_attempt_state_from_text(column_text_unowned(stmt, 4))
	value.relocation_key = column_text(stmt, 5)
	value.candidates_json = column_text(stmt, 6)
	value.report_json = column_text(stmt, 7)
	value.report_seq = int(sqlite3_column_int64(stmt, 8))
	value.sent_at = column_text(stmt, 9)
	value.accepted_at = column_text(stmt, 10)
	value.last_report_at = column_text(stmt, 11)
	value.disconnected_at = column_text(stmt, 12)
	value.created_at = column_text(stmt, 13)
	value.finished_at = column_text(stmt, 14)
	return value
}

bot_repo_list_bot_delivery_attempt :: proc(
	conn: ^Conn,
	query: string,
	args: []string,
) -> (
	[]domain.Bot_Delivery_Attempt,
	domain.Domain_Error,
) {
	stmt, err := bot_repo_prepare(conn, query, args)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]domain.Bot_Delivery_Attempt)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.bot_delivery_attempt_destroy(&row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, bot_repo_scan_bot_delivery_attempt(stmt))
	}
	return rows[:], {}
}

bot_insert_sqlite :: proc(ctx: rawptr, bot: domain.Bot) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`INSERT INTO bots (bot_id, owner_user_id, agent_id, agent_instance_id, display_name, placement_revision, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);`,
		{
			bot.bot_id,
			bot.owner_user_id,
			bot.agent_id,
			bot.agent_instance_id,
			bot.display_name,
			fmt.tprintf("%d", bot.placement_revision),
			bot.created_at,
			bot.updated_at,
		},
	)
	_ = changes
	return err
}

bot_get_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: string) -> (domain.Bot, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_bot(
		conn,
		`SELECT bot_id, owner_user_id, agent_id, agent_instance_id, display_name, placement_revision, created_at, updated_at FROM bots WHERE owner_user_id = ? ;`,
		{owner_user_id},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

bot_get_sqlite :: proc(ctx: rawptr, bot_id: string) -> (domain.Bot, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_bot(
		conn,
		`SELECT bot_id, owner_user_id, agent_id, agent_instance_id, display_name, placement_revision, created_at, updated_at FROM bots WHERE bot_id = ? ;`,
		{bot_id},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

bot_get_by_instance_sqlite :: proc(ctx: rawptr, agent_instance_id: string) -> (domain.Bot, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_bot(
		conn,
		`SELECT bot_id, owner_user_id, agent_id, agent_instance_id, display_name, placement_revision, created_at, updated_at FROM bots WHERE agent_instance_id = ? AND agent_instance_id <> '' ;`,
		{agent_instance_id},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

bot_set_instance_sqlite :: proc(
	ctx: rawptr,
	bot_id: string,
	agent_instance_id: string,
	updated_at: string,
) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`UPDATE bots SET agent_instance_id = ?, updated_at = ? WHERE bot_id = ?;`,
		{agent_instance_id, updated_at, bot_id},
	)
	_ = changes
	return err
}

bot_delete_sqlite :: proc(ctx: rawptr, bot_id: string) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(conn, `DELETE FROM bots WHERE bot_id = ?;`, {bot_id})
	_ = changes
	return err
}

placement_list_sqlite :: proc(ctx: rawptr, bot_id: string) -> ([]domain.Bot_Placement_Candidate, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_bot_placement_candidate(
		conn,
		`SELECT position, bridge_id, provider, model, tier FROM bot_placement_candidates WHERE bot_id = ? ORDER BY position;`,
		{bot_id},
	)
}

binding_get_active_by_owner_sqlite :: proc(
	ctx: rawptr,
	owner_user_id: string,
	provider: string,
) -> (
	domain.Channel_Binding,
	bool,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_channel_binding(
		conn,
		`SELECT binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at FROM channel_bindings WHERE owner_user_id = ? AND provider = ? AND state = 'active' ;`,
		{owner_user_id, provider},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

binding_get_active_by_chat_sqlite :: proc(
	ctx: rawptr,
	provider: string,
	external_chat_id: string,
) -> (
	domain.Channel_Binding,
	bool,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_channel_binding(
		conn,
		`SELECT binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at FROM channel_bindings WHERE provider = ? AND external_chat_id = ? AND state = 'active' ;`,
		{provider, external_chat_id},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

binding_revoke_sqlite :: proc(ctx: rawptr, binding_id: string, revoked_at: string) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`UPDATE channel_bindings SET state = 'revoked', revoked_at = ? WHERE binding_id = ? AND state = 'active';`,
		{revoked_at, binding_id},
	)
	_ = changes
	return err
}

pairing_insert_sqlite :: proc(ctx: rawptr, p: domain.Channel_Pairing) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`INSERT INTO channel_pairings (code_hash, owner_user_id, bot_id, provider, created_at, expires_at, consumed_at) VALUES (?, ?, ?, ?, ?, ?, ?);`,
		{p.code_hash, p.owner_user_id, p.bot_id, p.provider, p.created_at, p.expires_at, p.consumed_at},
	)
	_ = changes
	return err
}

pairing_get_sqlite :: proc(ctx: rawptr, code_hash: string) -> (domain.Channel_Pairing, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_channel_pairing(
		conn,
		`SELECT code_hash, owner_user_id, bot_id, provider, created_at, expires_at, consumed_at FROM channel_pairings WHERE code_hash = ? ;`,
		{code_hash},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

pairing_delete_for_owner_sqlite :: proc(ctx: rawptr, owner_user_id: string, provider: string) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`DELETE FROM channel_pairings WHERE owner_user_id = ? AND provider = ?;`,
		{owner_user_id, provider},
	)
	_ = changes
	return err
}

message_insert_outbound_sqlite :: proc(ctx: rawptr, msg: domain.Channel_Message) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`INSERT INTO channel_messages (message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);`,
		{
			msg.message_id,
			msg.binding_id,
			msg.owner_user_id,
			msg.bot_id,
			domain.channel_direction_text(msg.direction),
			msg.provider_update_key,
			msg.external_message_id,
			msg.body,
			("1" if msg.body_purged else "0"),
			domain.channel_send_state_text(msg.send_state),
			msg.send_error,
			msg.created_at,
			msg.read_at,
			msg.replied_at,
		},
	)
	_ = changes
	return err
}

message_set_send_result_sqlite :: proc(
	ctx: rawptr,
	message_id: string,
	state: domain.Channel_Send_State,
	external_message_id: string,
	send_error: string,
) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`UPDATE channel_messages SET send_state = ?, external_message_id = ?, send_error = ? WHERE message_id = ? AND direction = 'outbound';`,
		{domain.channel_send_state_text(state), external_message_id, send_error, message_id},
	)
	_ = changes
	return err
}

messages_pending_sqlite :: proc(
	ctx: rawptr,
	bot_id: string,
	limit: int,
) -> (
	[]domain.Channel_Message,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_channel_message(
		conn,
		`SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at FROM channel_messages WHERE bot_id = ? AND direction = 'inbound' AND replied_at = '' ORDER BY created_at, message_id LIMIT ?;`,
		{bot_id, fmt.tprintf("%d", limit)},
	)
}

messages_history_sqlite :: proc(
	ctx: rawptr,
	bot_id: string,
	limit: int,
) -> (
	[]domain.Channel_Message,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_channel_message(
		conn,
		`SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at FROM channel_messages WHERE bot_id = ? ORDER BY created_at DESC, message_id DESC LIMIT ?;`,
		{bot_id, fmt.tprintf("%d", limit)},
	)
}

messages_mark_replied_sqlite :: proc(
	ctx: rawptr,
	bot_id: string,
	replied_at: string,
) -> (
	count: int,
	err: domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	return bot_repo_write(
		conn,
		`UPDATE channel_messages SET replied_at = ? WHERE bot_id = ? AND direction = 'inbound' AND read_at <> '' AND replied_at = '';`,
		{replied_at, bot_id},
	)
}

messages_purge_binding_sqlite :: proc(ctx: rawptr, binding_id: string) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`UPDATE channel_messages SET body = '', body_purged = 1 WHERE binding_id = ?;`,
		{binding_id},
	)
	_ = changes
	return err
}

messages_purge_older_than_sqlite :: proc(ctx: rawptr, cutoff: string) -> (int, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	return bot_repo_write(
		conn,
		`UPDATE channel_messages SET body = '', body_purged = 1 WHERE created_at < ? AND body_purged = 0;`,
		{cutoff},
	)
}

delivery_get_open_sqlite :: proc(ctx: rawptr, bot_id: string) -> (domain.Bot_Delivery, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_bot_delivery(
		conn,
		`SELECT delivery_id, bot_id, owner_user_id, through_message_id, state, round, waiting_reason, waiting_notice_at, finish_reason, created_at, updated_at, finished_at FROM bot_deliveries WHERE bot_id = ? AND state IN ('pending','dispatched','waiting') ;`,
		{bot_id},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

delivery_get_sqlite :: proc(ctx: rawptr, delivery_id: string) -> (domain.Bot_Delivery, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_bot_delivery(
		conn,
		`SELECT delivery_id, bot_id, owner_user_id, through_message_id, state, round, waiting_reason, waiting_notice_at, finish_reason, created_at, updated_at, finished_at FROM bot_deliveries WHERE delivery_id = ? ;`,
		{delivery_id},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

delivery_insert_sqlite :: proc(ctx: rawptr, d: domain.Bot_Delivery) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`INSERT INTO bot_deliveries (delivery_id, bot_id, owner_user_id, through_message_id, state, round, waiting_reason, waiting_notice_at, finish_reason, created_at, updated_at, finished_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);`,
		{
			d.delivery_id,
			d.bot_id,
			d.owner_user_id,
			d.through_message_id,
			domain.bot_delivery_state_text(d.state),
			fmt.tprintf("%d", d.round),
			d.waiting_reason,
			d.waiting_notice_at,
			d.finish_reason,
			d.created_at,
			d.updated_at,
			d.finished_at,
		},
	)
	_ = changes
	return err
}

delivery_list_open_sqlite :: proc(ctx: rawptr) -> ([]domain.Bot_Delivery, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_bot_delivery(
		conn,
		`SELECT delivery_id, bot_id, owner_user_id, through_message_id, state, round, waiting_reason, waiting_notice_at, finish_reason, created_at, updated_at, finished_at FROM bot_deliveries WHERE state IN ('pending','dispatched','waiting') ORDER BY created_at, delivery_id;`,
		{},
	)
}

delivery_list_recent_sqlite :: proc(
	ctx: rawptr,
	bot_id: string,
	limit: int,
) -> (
	[]domain.Bot_Delivery,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_bot_delivery(
		conn,
		`SELECT delivery_id, bot_id, owner_user_id, through_message_id, state, round, waiting_reason, waiting_notice_at, finish_reason, created_at, updated_at, finished_at FROM bot_deliveries WHERE bot_id = ? ORDER BY created_at DESC, delivery_id DESC LIMIT ?;`,
		{bot_id, fmt.tprintf("%d", limit)},
	)
}

attempt_insert_sqlite :: proc(ctx: rawptr, a: domain.Bot_Delivery_Attempt) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`INSERT INTO bot_delivery_attempts (attempt_id, delivery_id, round, bridge_id, state, relocation_key, candidates_json, report_json, report_seq, sent_at, accepted_at, last_report_at, disconnected_at, created_at, finished_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);`,
		{
			a.attempt_id,
			a.delivery_id,
			fmt.tprintf("%d", a.round),
			a.bridge_id,
			domain.bot_attempt_state_text(a.state),
			a.relocation_key,
			a.candidates_json,
			a.report_json,
			fmt.tprintf("%d", a.report_seq),
			a.sent_at,
			a.accepted_at,
			a.last_report_at,
			a.disconnected_at,
			a.created_at,
			a.finished_at,
		},
	)
	_ = changes
	return err
}

attempt_get_sqlite :: proc(
	ctx: rawptr,
	attempt_id: string,
) -> (
	domain.Bot_Delivery_Attempt,
	bool,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	rows, err := bot_repo_list_bot_delivery_attempt(
		conn,
		`SELECT attempt_id, delivery_id, round, bridge_id, state, relocation_key, candidates_json, report_json, report_seq, sent_at, accepted_at, last_report_at, disconnected_at, created_at, finished_at FROM bot_delivery_attempts WHERE attempt_id = ? ;`,
		{attempt_id},
	)
	if err.code != .None do return {}, false, err
	defer delete(rows)
	if len(rows) == 0 do return {}, false, {}
	return rows[0], true, {}
}

attempt_list_for_delivery_sqlite :: proc(
	ctx: rawptr,
	delivery_id: string,
) -> (
	[]domain.Bot_Delivery_Attempt,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_bot_delivery_attempt(
		conn,
		`SELECT attempt_id, delivery_id, round, bridge_id, state, relocation_key, candidates_json, report_json, report_seq, sent_at, accepted_at, last_report_at, disconnected_at, created_at, finished_at FROM bot_delivery_attempts WHERE delivery_id = ? ORDER BY created_at, attempt_id;`,
		{delivery_id},
	)
}

attempt_list_open_sqlite :: proc(ctx: rawptr) -> ([]domain.Bot_Delivery_Attempt, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_bot_delivery_attempt(
		conn,
		`SELECT attempt_id, delivery_id, round, bridge_id, state, relocation_key, candidates_json, report_json, report_seq, sent_at, accepted_at, last_report_at, disconnected_at, created_at, finished_at FROM bot_delivery_attempts WHERE state IN ('relocating','sent','accepted') ORDER BY created_at, attempt_id;`,
		{},
	)
}

attempt_list_open_on_bridge_sqlite :: proc(
	ctx: rawptr,
	bridge_id: string,
) -> (
	[]domain.Bot_Delivery_Attempt,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	return bot_repo_list_bot_delivery_attempt(
		conn,
		`SELECT attempt_id, delivery_id, round, bridge_id, state, relocation_key, candidates_json, report_json, report_seq, sent_at, accepted_at, last_report_at, disconnected_at, created_at, finished_at FROM bot_delivery_attempts WHERE bridge_id = ? AND state IN ('relocating','sent','accepted') ORDER BY created_at, attempt_id;`,
		{bridge_id},
	)
}

delivery_update_sqlite :: proc(
	ctx: rawptr,
	d: domain.Bot_Delivery,
	expected_state: domain.Bot_Delivery_State,
) -> (
	bool,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`UPDATE bot_deliveries SET bot_id = ?, owner_user_id = ?, through_message_id = ?, state = ?, round = ?, waiting_reason = ?, waiting_notice_at = ?, finish_reason = ?, created_at = ?, updated_at = ?, finished_at = ? WHERE delivery_id = ? AND state = ?;`,
		{
			d.bot_id,
			d.owner_user_id,
			d.through_message_id,
			domain.bot_delivery_state_text(d.state),
			fmt.tprintf("%d", d.round),
			d.waiting_reason,
			d.waiting_notice_at,
			d.finish_reason,
			d.created_at,
			d.updated_at,
			d.finished_at,
			d.delivery_id,
			domain.bot_delivery_state_text(expected_state),
		},
	)
	return changes > 0, err
}

attempt_update_sqlite :: proc(
	ctx: rawptr,
	a: domain.Bot_Delivery_Attempt,
	expected_state: domain.Bot_Attempt_State,
) -> (
	bool,
	domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	changes, err := bot_repo_write(
		conn,
		`UPDATE bot_delivery_attempts SET delivery_id = ?, round = ?, bridge_id = ?, state = ?, relocation_key = ?, candidates_json = ?, report_json = ?, report_seq = ?, sent_at = ?, accepted_at = ?, last_report_at = ?, disconnected_at = ?, created_at = ?, finished_at = ? WHERE attempt_id = ? AND state = ?;`,
		{
			a.delivery_id,
			fmt.tprintf("%d", a.round),
			a.bridge_id,
			domain.bot_attempt_state_text(a.state),
			a.relocation_key,
			a.candidates_json,
			a.report_json,
			fmt.tprintf("%d", a.report_seq),
			a.sent_at,
			a.accepted_at,
			a.last_report_at,
			a.disconnected_at,
			a.created_at,
			a.finished_at,
			a.attempt_id,
			domain.bot_attempt_state_text(expected_state),
		},
	)
	return changes > 0, err
}

cursor_get_sqlite :: proc(ctx: rawptr, provider: string) -> (string, bool, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn, "SELECT cursor FROM channel_cursors WHERE provider = ?;", {provider})
	if err.code != .None do return "", false, err
	defer sqlite3_finalize(stmt)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return "", false, {}
	if rc != SQLITE_ROW do return "", false, bot_repo_error(conn)
	return column_text(stmt, 0), true, {}
}

bot_list_owners_with_open_deliveries_sqlite :: proc(ctx: rawptr) -> ([]string, domain.Domain_Error) {
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(
		conn,
		"SELECT DISTINCT owner_user_id FROM bot_deliveries WHERE state IN ('pending','dispatched','waiting') ORDER BY owner_user_id;",
		{},
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]string)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for row in rows do delete(row)
			delete(rows)
			return nil, bot_repo_error(conn)
		}
		append(&rows, column_text(stmt, 0))
	}
	return rows[:], {}
}

placement_replace_sqlite :: proc(
	ctx: rawptr,
	bot_id: string,
	expected_revision: int,
	rows: []domain.Bot_Placement_Candidate,
	updated_at: string,
) -> (
	new_revision: int,
	err: domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	if conn == nil || conn.db == nil do return 0, bot_repo_error(conn)
	mutex := sqlite3_db_mutex(conn.db)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if !exec(conn, "BEGIN IMMEDIATE;") do return 0, bot_repo_error(conn)
	committed := false
	defer if !committed do exec(conn, "ROLLBACK;")

	revision_changes, revision_err := bot_repo_write(
		conn,
		"UPDATE bots SET placement_revision = placement_revision + 1, updated_at = ? WHERE bot_id = ? AND placement_revision = ?;",
		{updated_at, bot_id, fmt.tprintf("%d", expected_revision)},
	)
	if revision_err.code != .None do return 0, revision_err
	if revision_changes != 1 do return 0, domain.domain_error(.Conflict, "bot placement revision conflict")
	if _, err := bot_repo_write(conn, "DELETE FROM bot_placement_candidates WHERE bot_id = ?;", {bot_id}); err.code != .None do return 0, err
	for row in rows {
		_, err := bot_repo_write(
			conn,
			"INSERT INTO bot_placement_candidates (bot_id, position, bridge_id, provider, model, tier) VALUES (?, ?, ?, ?, ?, ?);",
			{
				bot_id,
				fmt.tprintf("%d", row.position),
				row.bridge_id,
				row.provider,
				row.model,
				domain.bot_placement_tier_text(row.tier),
			},
		)
		if err.code != .None do return 0, err
	}
	if !exec(conn, "COMMIT;") do return 0, bot_repo_error(conn)
	committed = true
	return expected_revision + 1, {}
}

binding_activate_sqlite :: proc(
	ctx: rawptr,
	binding: domain.Channel_Binding,
	pairing_code_hash: string,
	consumed_at: string,
) -> (
	revoked_previous: domain.Channel_Binding,
	had_previous: bool,
	err: domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	if conn == nil || conn.db == nil do return {}, false, bot_repo_error(conn)
	mutex := sqlite3_db_mutex(conn.db)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, false, bot_repo_error(conn)
	committed := false
	defer if !committed do exec(conn, "ROLLBACK;")

	// Pairing ownership and expiry are checked atomically with consumption.
	count, consume_err := bot_repo_write(
		conn,
		"UPDATE channel_pairings SET consumed_at = ? WHERE code_hash = ? AND owner_user_id = ? AND bot_id = ? AND provider = ? AND consumed_at = '' AND expires_at > ?;",
		{consumed_at, pairing_code_hash, binding.owner_user_id, binding.bot_id, binding.provider, consumed_at},
	)
	if consume_err.code != .None do return {}, false, consume_err
	if count != 1 do return {}, false, domain.domain_error(.Conflict, "pairing is unavailable")
	previous, found_previous, previous_err := binding_get_active_by_owner_sqlite(
		ctx,
		binding.owner_user_id,
		binding.provider,
	)
	if previous_err.code != .None do return {}, false, previous_err
	keep_previous := false
	defer if found_previous && !keep_previous do domain.channel_binding_destroy(&previous)
	if found_previous {
		if err := binding_revoke_sqlite(ctx, previous.binding_id, consumed_at); err.code != .None do return {}, false, err
	}
	_, insert_err := bot_repo_write(
		conn,
		"INSERT INTO channel_bindings (binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
		{
			binding.binding_id,
			binding.owner_user_id,
			binding.bot_id,
			binding.provider,
			binding.external_chat_id,
			binding.external_user_id,
			binding.external_display,
			domain.channel_binding_state_text(binding.state),
			binding.created_at,
			binding.revoked_at,
		},
	)
	if insert_err.code != .None do return {}, false, insert_err
	if !exec(conn, "COMMIT;") do return {}, false, bot_repo_error(conn)
	committed = true
	keep_previous = true
	return previous, found_previous, {}
}

inbound_store_batch_sqlite :: proc(
	ctx: rawptr,
	provider: string,
	rows: []domain.Channel_Message,
	next_cursor: string,
	now: string,
) -> (
	inserted: []string,
	err: domain.Domain_Error,
) {
	conn := bot_repo_conn(ctx)
	if conn == nil || conn.db == nil do return nil, bot_repo_error(conn)
	mutex := sqlite3_db_mutex(conn.db)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if !exec(conn, "BEGIN IMMEDIATE;") do return nil, bot_repo_error(conn)
	committed := false
	defer if !committed do exec(conn, "ROLLBACK;")

	inserted_rows := make([dynamic]string)
	keep_rows := false
	defer if !keep_rows {
		for id in inserted_rows do delete(id)
		delete(inserted_rows)
	}
	for row in rows {
		// Ignore only duplicate update keys; other constraint errors must roll back.
		changes, err := bot_repo_write(
			conn,
			"INSERT INTO channel_messages (message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(provider_update_key) WHERE provider_update_key <> '' DO NOTHING;",
			{
				row.message_id,
				row.binding_id,
				row.owner_user_id,
				row.bot_id,
				domain.channel_direction_text(row.direction),
				row.provider_update_key,
				row.external_message_id,
				row.body,
				("1" if row.body_purged else "0"),
				domain.channel_send_state_text(row.send_state),
				row.send_error,
				row.created_at,
				row.read_at,
				row.replied_at,
			},
		)
		if err.code != .None do return nil, err
		if changes == 1 do append(&inserted_rows, strings.clone(row.message_id))
	}
	_, cursor_err := bot_repo_write(
		conn,
		"INSERT INTO channel_cursors (provider, cursor, updated_at) VALUES (?, ?, ?) ON CONFLICT(provider) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at;",
		{provider, next_cursor, now},
	)
	if cursor_err.code != .None do return nil, cursor_err
	if !exec(conn, "COMMIT;") do return nil, bot_repo_error(conn)
	committed = true
	keep_rows = true
	return inserted_rows[:], {}
}

messages_mark_read_sqlite :: proc(
	ctx: rawptr,
	bot_id: string,
	message_ids: []string,
	read_at: string,
) -> domain.Domain_Error {
	conn := bot_repo_conn(ctx)
	if conn == nil || conn.db == nil do return bot_repo_error(conn)
	mutex := sqlite3_db_mutex(conn.db)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if !exec(conn, "BEGIN IMMEDIATE;") do return bot_repo_error(conn)
	committed := false
	defer if !committed do exec(conn, "ROLLBACK;")

	for id in message_ids {
		_, err := bot_repo_write(
			conn,
			"UPDATE channel_messages SET read_at = ? WHERE bot_id = ? AND message_id = ? AND direction = 'inbound' AND read_at = '';",
			{read_at, bot_id, id},
		)
		if err.code != .None do return err
	}
	if !exec(conn, "COMMIT;") do return bot_repo_error(conn)
	committed = true
	return {}
}

pairing_consume_sqlite :: proc(ctx: rawptr, code_hash, consumed_at: string) -> (bool, domain.Domain_Error) {
	count, err := bot_repo_write(bot_repo_conn(ctx),
	"UPDATE channel_pairings SET consumed_at = ? WHERE code_hash = ? AND consumed_at = '' AND expires_at > ?;",
	{consumed_at, code_hash, consumed_at})
	return count == 1, err
}

bot_list_sqlite :: proc(ctx: rawptr) -> ([]domain.Bot, domain.Domain_Error) {
	return bot_repo_list_bot(bot_repo_conn(ctx), `SELECT bot_id, owner_user_id, agent_id, agent_instance_id, display_name, placement_revision, created_at, updated_at FROM bots ORDER BY bot_id;`, nil)
}
