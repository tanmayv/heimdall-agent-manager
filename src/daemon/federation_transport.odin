package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:strings"
import contracts "odin_test:contracts"
import http "odin_test:lib/http_client"
import mp "odin_test:lib/message_provider"

FEDERATION_ROUTE_INBOX :: "inbox"
FEDERATION_ROUTE_CALLBACK :: "callback"
FEDERATION_HTTP_TIMEOUT_MS :: 5000
FEDERATION_DEDUPE_SCOPE_INBOX :: "inbox"
FEDERATION_DEDUPE_SCOPE_CALLBACK :: "callback"
FEDERATION_ENVELOPE_NOTIFICATION :: "notification"
FEDERATION_ENVELOPE_INBOX_MESSAGE :: "inbox_message"
FEDERATION_ENVELOPE_READ_RECEIPT :: "read_receipt"
FEDERATION_ENVELOPE_TASK_COMMENT :: "comment"
FEDERATION_ENVELOPE_TASK_VOTE :: "vote"
FEDERATION_ENVELOPE_TASK_STATUS :: "status"
FEDERATION_REPLAY_LIMIT :: 100

Federation_Remote_Message_Record :: struct {
	record_key: string,
	message_id: string,
	owner_peer_id: string,
	owner_daemon_id: string,
	local_agent_instance_id: string,
	remote_agent_instance_id: string,
	proxy_agent_instance_id: string,
	conversation_id: string,
	origin_conversation_id: string,
	body: string,
	body_available: bool,
	created_unix_ms: i64,
	read_unix_ms: i64,
}

federation_peer_id_for_request :: proc(peer_token, peer_daemon_id: string) -> (string, bool) {
	trimmed_token := strings.trim_space(peer_token)
	trimmed_daemon_id := strings.trim_space(peer_daemon_id)
	if trimmed_token == "" || trimmed_daemon_id == "" do return "", false
	for i in 0..<peer_link_record_count {
		rec := peer_link_records[i]
		if rec.removed_at_unix_ms != 0 do continue
		if rec.peer_token != trimmed_token do continue
		if rec.daemon_id != trimmed_daemon_id do continue
		return strings.clone(rec.peer_id), true
	}
	return "", false
}

registry_send_ws_text_or_remote :: proc(agent_instance_id, text: string) -> bool {
	if peer_id, remote_agent_instance_id, ok := agent_remote_proxy_lookup(agent_instance_id); ok {
		idempotency_key := extract_json_string(text, "event_id", "")
		if idempotency_key == "" do idempotency_key = notification_outbox_payload_event_id(agent_instance_id, text)
		payload := federation_inbox_notification_json(remote_agent_instance_id, text, idempotency_key)
		return federation_forward(peer_id, FEDERATION_ROUTE_INBOX, payload, idempotency_key)
	}
	return registry_send_ws_text(agent_instance_id, text)
}

federation_forward :: proc(peer_id, route_kind, payload, idempotency_key: string) -> bool {
	rec, ok := peer_link_find(peer_id)
	if !ok do return false
	path := "/federation/inbox"
	if route_kind == FEDERATION_ROUTE_CALLBACK do path = "/federation/callback"
	path = fmt.tprintf("%s?peer_token=%s&peer_daemon_id=%s", path, rec.peer_token, server_daemon_id)
	resp, forward_ok := http.post_with_timeout(rec.peer_url, path, payload, FEDERATION_HTTP_TIMEOUT_MS)
	if !forward_ok || resp.status != 200 {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.last_checked_unix_ms = router_now_unix_ms()
		return false
	}
	rec.status = strings.clone(PEER_STATUS_LINKED)
	rec.last_checked_unix_ms = router_now_unix_ms()
	return true
}

// federation_forward_start asks the owning peer to start the real agent that a
// local remote_proxy stands in for. Returns (ok, status_code, response_body).
// Synchronous request/response (not the delivery outbox) so the operator/UI gets
// immediate feedback on whether the remote start succeeded.
federation_forward_start :: proc(peer_id, remote_agent_instance_id, provider_profile, model_tier: string) -> (bool, int, string) {
	rec, ok := peer_link_find(peer_id)
	if !ok do return false, 404, `{"ok":false,"message":"peer not found"}`
	if rec.status != PEER_STATUS_LINKED {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"agent_instance_id":"`)
	json_write_string(&b, remote_agent_instance_id)
	if provider_profile != "" {
		strings.write_string(&b, `","provider_profile":"`)
		json_write_string(&b, provider_profile)
	}
	if model_tier != "" {
		strings.write_string(&b, `","model_tier":"`)
		json_write_string(&b, model_tier)
	}
	strings.write_string(&b, `"}`)
	payload := strings.to_string(b)
	path := fmt.tprintf("/federation/start?peer_token=%s&peer_daemon_id=%s", rec.peer_token, server_daemon_id)
	resp, forward_ok := http.post_with_timeout(rec.peer_url, path, payload, FEDERATION_HTTP_TIMEOUT_MS)
	if !forward_ok {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.last_checked_unix_ms = router_now_unix_ms()
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	rec.last_checked_unix_ms = router_now_unix_ms()
	return resp.status == 200, resp.status, strings.clone(resp.body)
}

federation_delivery_outbox_insert_pending :: proc(peer_id, route_kind, idempotency_key, payload: string) -> bool {
	if peer_id == "" || route_kind == "" || idempotency_key == "" || payload == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO federation_delivery_outbox (
		peer_id, route_kind, idempotency_key, payload, created_unix_ms,
		delivered_unix_ms, attempts, last_attempt_unix_ms
	) VALUES (?, ?, ?, ?, ?, 0, 0, 0)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, peer_id)
	task_db_bind_text(stmt, 2, route_kind)
	task_db_bind_text(stmt, 3, idempotency_key)
	task_db_bind_text(stmt, 4, payload)
	sqlite3_bind_int64(stmt, 5, router_now_unix_ms())
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_delivery_outbox_mark_attempt :: proc(peer_id, route_kind, idempotency_key: string, delivered: bool) -> bool {
	if peer_id == "" || route_kind == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `UPDATE federation_delivery_outbox
		SET attempts = attempts + 1,
		    last_attempt_unix_ms = ?,
		    delivered_unix_ms = CASE WHEN ? != 0 THEN ? ELSE delivered_unix_ms END
		WHERE peer_id = ? AND route_kind = ? AND idempotency_key = ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	now := router_now_unix_ms()
	sqlite3_bind_int64(stmt, 1, now)
	sqlite3_bind_int64(stmt, 2, 1 if delivered else 0)
	sqlite3_bind_int64(stmt, 3, now)
	task_db_bind_text(stmt, 4, peer_id)
	task_db_bind_text(stmt, 5, route_kind)
	task_db_bind_text(stmt, 6, idempotency_key)
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_delivery_outbox_pending_exists :: proc(peer_id, route_kind, idempotency_key: string) -> bool {
	if peer_id == "" || route_kind == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `SELECT 1 FROM federation_delivery_outbox WHERE peer_id = ? AND route_kind = ? AND idempotency_key = ? AND delivered_unix_ms = 0 LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, peer_id)
	task_db_bind_text(stmt, 2, route_kind)
	task_db_bind_text(stmt, 3, idempotency_key)
	return sqlite3_step(stmt) == SQLITE_ROW
}

federation_delivery_outbox_replay_peer :: proc(peer_id: string) -> int {
	if peer_id == "" || !task_db_ready do return 0
	route_kinds := make([dynamic]string)
	idempotency_keys := make([dynamic]string)
	payloads := make([dynamic]string)
	defer {
		for v in route_kinds do delete(v)
		for v in idempotency_keys do delete(v)
		for v in payloads do delete(v)
		delete(route_kinds)
		delete(idempotency_keys)
		delete(payloads)
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT route_kind, idempotency_key, payload
		FROM federation_delivery_outbox
		WHERE peer_id = ? AND delivered_unix_ms = 0
		ORDER BY created_unix_ms ASC, idempotency_key ASC
		LIMIT ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return 0
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, peer_id)
	sqlite3_bind_int64(stmt, 2, FEDERATION_REPLAY_LIMIT)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&route_kinds, strings.clone_from_cstring(sqlite3_column_text(stmt, 0)))
		append(&idempotency_keys, strings.clone_from_cstring(sqlite3_column_text(stmt, 1)))
		append(&payloads, strings.clone_from_cstring(sqlite3_column_text(stmt, 2)))
	}
	delivered := 0
	for i in 0..<len(route_kinds) {
		sent := federation_forward(peer_id, route_kinds[i], payloads[i], idempotency_keys[i])
		_ = federation_delivery_outbox_mark_attempt(peer_id, route_kinds[i], idempotency_keys[i], sent)
		if !sent do break
		delivered += 1
	}
	return delivered
}

federation_delivery_dedupe_scope :: proc(scope_kind, peer_id, kind: string) -> string {
	return fmt.tprintf("%s:%s:%s", scope_kind, peer_id, kind)
}

federation_delivery_dedupe_completed :: proc(scope, idempotency_key: string) -> bool {
	if scope == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `SELECT 1 FROM federation_delivery_dedupe WHERE scope = ? AND idempotency_key = ? LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, scope)
	task_db_bind_text(stmt, 2, idempotency_key)
	return sqlite3_step(stmt) == SQLITE_ROW
}

federation_delivery_dedupe_record_completed :: proc(scope, idempotency_key: string) -> bool {
	if scope == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO federation_delivery_dedupe (scope, idempotency_key, created_unix_ms) VALUES (?, ?, ?)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, scope)
	task_db_bind_text(stmt, 2, idempotency_key)
	sqlite3_bind_int64(stmt, 3, router_now_unix_ms())
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_idempotency_key :: proc(kind, daemon_id, message_id: string) -> string {
	return fmt.tprintf("%s:%s:%s", kind, daemon_id, message_id)
}

federation_remote_message_record_key :: proc(owner_daemon_id, message_id: string) -> string {
	return fmt.tprintf("%s:%s", owner_daemon_id, message_id)
}

federation_remote_message_upsert :: proc(rec: Federation_Remote_Message_Record) -> bool {
	if rec.record_key == "" || rec.message_id == "" || rec.local_agent_instance_id == "" || rec.remote_agent_instance_id == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO federation_remote_messages (
		record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id,
		proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available,
		created_unix_ms, read_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, rec.record_key)
	task_db_bind_text(stmt, 2, rec.message_id)
	task_db_bind_text(stmt, 3, rec.owner_peer_id)
	task_db_bind_text(stmt, 4, rec.owner_daemon_id)
	task_db_bind_text(stmt, 5, rec.local_agent_instance_id)
	task_db_bind_text(stmt, 6, rec.remote_agent_instance_id)
	task_db_bind_text(stmt, 7, rec.proxy_agent_instance_id)
	task_db_bind_text(stmt, 8, rec.conversation_id)
	task_db_bind_text(stmt, 9, rec.origin_conversation_id)
	task_db_bind_text(stmt, 10, rec.body)
	sqlite3_bind_int64(stmt, 11, 1 if rec.body_available else 0)
	sqlite3_bind_int64(stmt, 12, rec.created_unix_ms)
	sqlite3_bind_int64(stmt, 13, rec.read_unix_ms)
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_remote_message_get :: proc(record_key: string) -> (Federation_Remote_Message_Record, bool) {
	if record_key == "" || !task_db_ready do return Federation_Remote_Message_Record{}, false
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms FROM federation_remote_messages WHERE record_key = ? LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return Federation_Remote_Message_Record{}, false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, record_key)
	if sqlite3_step(stmt) != SQLITE_ROW do return Federation_Remote_Message_Record{}, false
	return Federation_Remote_Message_Record{
		record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
		proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
		conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		body_available = sqlite3_column_int64(stmt, 10) != 0,
		created_unix_ms = sqlite3_column_int64(stmt, 11),
		read_unix_ms = sqlite3_column_int64(stmt, 12),
	}, true
}

federation_remote_message_find_origin :: proc(owner_peer_id, message_id: string) -> (Federation_Remote_Message_Record, bool) {
	if owner_peer_id == "" || message_id == "" || !task_db_ready do return Federation_Remote_Message_Record{}, false
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms FROM federation_remote_messages WHERE owner_peer_id = ? AND message_id = ? LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return Federation_Remote_Message_Record{}, false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, owner_peer_id)
	task_db_bind_text(stmt, 2, message_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return Federation_Remote_Message_Record{}, false
	return Federation_Remote_Message_Record{
		record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
		proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
		conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		body_available = sqlite3_column_int64(stmt, 10) != 0,
		created_unix_ms = sqlite3_column_int64(stmt, 11),
		read_unix_ms = sqlite3_column_int64(stmt, 12),
	}, true
}

federation_remote_message_mark_read :: proc(record_key: string, read_unix_ms: i64) -> bool {
	if record_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `UPDATE federation_remote_messages SET read_unix_ms = ? WHERE record_key = ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, read_unix_ms)
	task_db_bind_text(stmt, 2, record_key)
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_remote_message_find_reply_route :: proc(local_agent_instance_id, remote_agent_instance_id: string) -> (Federation_Remote_Message_Record, bool) {
	if local_agent_instance_id == "" || remote_agent_instance_id == "" || !task_db_ready do return Federation_Remote_Message_Record{}, false
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms
		FROM federation_remote_messages
		WHERE local_agent_instance_id = ? AND remote_agent_instance_id = ? AND owner_daemon_id != ?
		ORDER BY created_unix_ms DESC
		LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return Federation_Remote_Message_Record{}, false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, local_agent_instance_id)
	task_db_bind_text(stmt, 2, remote_agent_instance_id)
	task_db_bind_text(stmt, 3, server_daemon_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return Federation_Remote_Message_Record{}, false
	return Federation_Remote_Message_Record{
		record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
		proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
		conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		body_available = sqlite3_column_int64(stmt, 10) != 0,
		created_unix_ms = sqlite3_column_int64(stmt, 11),
		read_unix_ms = sqlite3_column_int64(stmt, 12),
	}, true
}

federation_remote_messages_for_fetch :: proc(local_agent_instance_id, conversation_id: string, include_read: bool, limit: int) -> []Federation_Remote_Message_Record {
	rows := make([dynamic]Federation_Remote_Message_Record)
	if local_agent_instance_id == "" || conversation_id == "" || !task_db_ready do return rows[:]
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms
		FROM federation_remote_messages
		WHERE local_agent_instance_id = ? AND conversation_id = ? AND owner_daemon_id != ?
		ORDER BY created_unix_ms ASC
		LIMIT ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return rows[:]
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, local_agent_instance_id)
	task_db_bind_text(stmt, 2, conversation_id)
	task_db_bind_text(stmt, 3, server_daemon_id)
	sqlite3_bind_int64(stmt, 4, i64(limit if limit > 0 else 100))
	for sqlite3_step(stmt) == SQLITE_ROW {
		row := Federation_Remote_Message_Record{
			record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
			local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
			proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
			conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
			origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
			body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
			body_available = sqlite3_column_int64(stmt, 10) != 0,
			created_unix_ms = sqlite3_column_int64(stmt, 11),
			read_unix_ms = sqlite3_column_int64(stmt, 12),
		}
		if !include_read && row.read_unix_ms > 0 do continue
		append(&rows, row)
	}
	return rows[:]
}

federation_remote_message_body_fetch :: proc(peer_id, message_id: string) -> (string, bool) {
	rec, ok := peer_link_find(peer_id)
	if !ok do return "", false
	path := fmt.tprintf("/federation/messages/%s?peer_token=%s&peer_daemon_id=%s", message_id, rec.peer_token, server_daemon_id)
	resp, fetch_ok := http.get_with_timeout(rec.peer_url, path, FEDERATION_HTTP_TIMEOUT_MS)
	if !fetch_ok || resp.status != 200 do return "", false
	return extract_json_string(resp.body, "body", ""), true
}

federation_inbox_notification_json :: proc(target_agent_instance_id, payload, idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"notification","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","payload":"`)
	json_write_string(&b, payload)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

federation_inbox_message_json :: proc(message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"inbox_message","idempotency_key":"`)
	json_write_string(&b, federation_idempotency_key("msg", server_daemon_id, message_id))
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","message_id":"`)
	json_write_string(&b, message_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","from_native_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","origin_conversation_id":"`)
	json_write_string(&b, origin_conversation_id)
	// Inbox message bodies are immutable, single-recipient content: ship the body
	// on the daemon-to-daemon push (plain HTTP, no WS size limit) and store it
	// durably on the receiver so reads are offline-capable (store-and-forward).
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `","created_unix_ms":`)
	strings.write_string(&b, fmt.tprintf("%d", created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_callback_message_json :: proc(message_id, origin_message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"inbox_message","idempotency_key":"`)
	json_write_string(&b, federation_idempotency_key("reply", server_daemon_id, message_id))
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","message_id":"`)
	json_write_string(&b, message_id)
	strings.write_string(&b, `","origin_message_id":"`)
	json_write_string(&b, origin_message_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","from_native_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","origin_conversation_id":"`)
	json_write_string(&b, origin_conversation_id)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `","created_unix_ms":`)
	strings.write_string(&b, fmt.tprintf("%d", created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_callback_read_receipt_json :: proc(message_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, read_by_agent_instance_id: string, read_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"read_receipt","idempotency_key":"`)
	json_write_string(&b, federation_idempotency_key("read", server_daemon_id, message_id))
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","message_id":"`)
	json_write_string(&b, message_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","origin_conversation_id":"`)
	json_write_string(&b, origin_conversation_id)
	strings.write_string(&b, `","read_by_agent_instance_id":"`)
	json_write_string(&b, read_by_agent_instance_id)
	strings.write_string(&b, `","read_by_native_id":"`)
	json_write_string(&b, read_by_agent_instance_id)
	strings.write_string(&b, `","read_unix_ms":`)
	strings.write_string(&b, fmt.tprintf("%d", read_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_remote_message_receive_placeholder :: proc(owner_peer_id, owner_daemon_id, message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> bool {
	// Key the stored message by the RECIPIENT's conversation id so the recipient's
	// own fetch_messages (which queries registry_conversation_id(self)) finds it.
	// The local agent-to-agent model keys a message by the target's conversation;
	// mirror that here. Store the body inline (store-and-forward) so reads work even
	// when the origin daemon/link is down.
	return federation_remote_message_upsert(Federation_Remote_Message_Record{
		record_key = federation_remote_message_record_key(owner_daemon_id, message_id),
		message_id = strings.clone(message_id),
		owner_peer_id = strings.clone(owner_peer_id),
		owner_daemon_id = strings.clone(owner_daemon_id),
		local_agent_instance_id = strings.clone(target_agent_instance_id),
		remote_agent_instance_id = strings.clone(from_agent_instance_id),
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		conversation_id = conversation_id_for_instance(target_agent_instance_id),
		origin_conversation_id = strings.clone(origin_conversation_id),
		body = strings.clone(body),
		body_available = strings.trim_space(body) != "",
		created_unix_ms = created_unix_ms,
		read_unix_ms = 0,
	})
}

federation_remote_message_store_origin_copy :: proc(peer_id, message_id, from_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> bool {
	return federation_remote_message_upsert(Federation_Remote_Message_Record{
		record_key = federation_remote_message_record_key(server_daemon_id, message_id),
		message_id = strings.clone(message_id),
		owner_peer_id = strings.clone(peer_id),
		owner_daemon_id = strings.clone(server_daemon_id),
		local_agent_instance_id = strings.clone(from_agent_instance_id),
		remote_agent_instance_id = strings.clone(remote_agent_instance_id),
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		conversation_id = strings.clone(origin_conversation_id),
		origin_conversation_id = strings.clone(origin_conversation_id),
		body = strings.clone(body),
		body_available = true,
		created_unix_ms = created_unix_ms,
		read_unix_ms = 0,
	})
}

federation_remote_message_store_reply_if_absent :: proc(owner_peer_id, owner_daemon_id, message_id, remote_agent_instance_id, local_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> (bool, bool) {
	if owner_peer_id == "" || owner_daemon_id == "" || message_id == "" || remote_agent_instance_id == "" || local_agent_instance_id == "" || proxy_agent_instance_id == "" || origin_conversation_id == "" || !task_db_ready {
		return false, false
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO federation_remote_messages (
		record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id,
		proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available,
		created_unix_ms, read_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false, false
	defer sqlite3_finalize(stmt)
	record_key := federation_remote_message_record_key(owner_daemon_id, message_id)
	task_db_bind_text(stmt, 1, record_key)
	task_db_bind_text(stmt, 2, message_id)
	task_db_bind_text(stmt, 3, owner_peer_id)
	task_db_bind_text(stmt, 4, owner_daemon_id)
	task_db_bind_text(stmt, 5, local_agent_instance_id)
	task_db_bind_text(stmt, 6, remote_agent_instance_id)
	task_db_bind_text(stmt, 7, proxy_agent_instance_id)
	task_db_bind_text(stmt, 8, origin_conversation_id)
	task_db_bind_text(stmt, 9, origin_conversation_id)
	task_db_bind_text(stmt, 10, body)
	sqlite3_bind_int64(stmt, 11, 1)
	sqlite3_bind_int64(stmt, 12, created_unix_ms)
	sqlite3_bind_int64(stmt, 13, 0)
	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE do return false, false
	return sqlite3_changes(task_db.db) > 0, true
}

federation_remote_send_message :: proc(from_agent_instance_id, proxy_agent_instance_id, body: string) -> Service_Result {
	peer_id, remote_agent_instance_id, ok := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"unknown remote proxy"}`, status_code = 404, status_text = "Not Found"}
	}
	request := contracts.Send_Message_Request{
		from_agent_instance_id = contracts.Agent_Instance_ID(from_agent_instance_id),
		target_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
		conversation_id = contracts.Conversation_ID(conversation_id_for_instance(proxy_agent_instance_id)),
		body = body,
	}
	response := mp.send_message(&message_provider, request)
	if !response.ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"message provider send failed"}`, status_code = 500, status_text = "Internal Server Error", send_response = response}
	}
	if !federation_remote_message_store_origin_copy(peer_id, string(response.message_id), from_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, string(response.conversation_id), body, response.created_unix_ms) {
		return Service_Result{ok = false, message = `{"ok":false,"message":"failed to persist remote message body"}`, status_code = 500, status_text = "Internal Server Error"}
	}
	payload := federation_inbox_message_json(string(response.message_id), from_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, string(response.conversation_id), body, response.created_unix_ms)
	idempotency_key := federation_idempotency_key("msg", server_daemon_id, string(response.message_id))
	_ = federation_delivery_outbox_insert_pending(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key, payload)
	sent := federation_forward(peer_id, FEDERATION_ROUTE_INBOX, payload, idempotency_key)
	_ = federation_delivery_outbox_mark_attempt(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key, sent)
	if !sent && !federation_delivery_outbox_pending_exists(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key) {
		return Service_Result{ok = false, message = `{"ok":false,"message":"failed to queue remote message"}`, status_code = 503, status_text = "Service Unavailable"}
	}
	return Service_Result{ok = true, status_code = 202, status_text = "Accepted", send_response = response, pending_count = 1, notified = sent}
}

federation_remote_route_reply :: proc(from_agent_instance_id, target_agent_instance_id, body: string) -> Service_Result {
	route, ok := federation_remote_message_find_reply_route(from_agent_instance_id, target_agent_instance_id)
	if !ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"unknown target agent instance"}`, status_code = 404, status_text = "Not Found"}
	}
	request := contracts.Send_Message_Request{
		from_agent_instance_id = contracts.Agent_Instance_ID(from_agent_instance_id),
		target_agent_instance_id = contracts.Agent_Instance_ID(target_agent_instance_id),
		conversation_id = contracts.Conversation_ID(route.conversation_id),
		body = body,
	}
	response := mp.send_message(&message_provider, request)
	if !response.ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"message provider send failed"}`, status_code = 500, status_text = "Internal Server Error", send_response = response}
	}
	payload := federation_callback_message_json(string(response.message_id), route.message_id, from_agent_instance_id, target_agent_instance_id, route.proxy_agent_instance_id, route.origin_conversation_id, body, response.created_unix_ms)
	idempotency_key := federation_idempotency_key("reply", server_daemon_id, string(response.message_id))
	_ = federation_delivery_outbox_insert_pending(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, payload)
	sent := federation_forward(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
	_ = federation_delivery_outbox_mark_attempt(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, sent)
	if !sent && !federation_delivery_outbox_pending_exists(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key) {
		return Service_Result{ok = false, message = `{"ok":false,"message":"failed to queue remote reply"}`, status_code = 503, status_text = "Service Unavailable"}
	}
	return Service_Result{ok = true, status_code = 202, status_text = "Accepted", send_response = response, pending_count = 1, notified = sent}
}

federation_callback_origin_message_authorize :: proc(peer_id, origin_message_id, proxy_agent_instance_id, remote_agent_instance_id, local_agent_instance_id, origin_conversation_id: string) -> (Federation_Remote_Message_Record, bool) {
	if peer_id == "" || origin_message_id == "" || proxy_agent_instance_id == "" || remote_agent_instance_id == "" || local_agent_instance_id == "" || origin_conversation_id == "" {
		return Federation_Remote_Message_Record{}, false
	}
	rec, ok := federation_remote_message_find_origin(peer_id, origin_message_id)
	if !ok do return Federation_Remote_Message_Record{}, false
	if !rec.body_available do return Federation_Remote_Message_Record{}, false
	if rec.owner_peer_id != peer_id do return Federation_Remote_Message_Record{}, false
	if rec.proxy_agent_instance_id != proxy_agent_instance_id do return Federation_Remote_Message_Record{}, false
	if rec.remote_agent_instance_id != remote_agent_instance_id do return Federation_Remote_Message_Record{}, false
	if rec.local_agent_instance_id != local_agent_instance_id do return Federation_Remote_Message_Record{}, false
	if rec.origin_conversation_id != origin_conversation_id do return Federation_Remote_Message_Record{}, false
	if rec.conversation_id != origin_conversation_id do return Federation_Remote_Message_Record{}, false
	return rec, true
}

federation_remote_fetch_messages :: proc(request: contracts.Fetch_Messages_Request) -> contracts.Fetch_Messages_Response {
	rows := federation_remote_messages_for_fetch(string(request.agent_instance_id), string(request.conversation_id), request.include_read, request.limit)
	messages := make([dynamic]contracts.Message)
	for row in rows {
		body := row.body
		if !row.body_available {
			fetched_body, ok := federation_remote_message_body_fetch(row.owner_peer_id, row.message_id)
			if ok do body = fetched_body
		}
		read_unix_ms := row.read_unix_ms
		if !request.include_read && read_unix_ms == 0 {
			read_unix_ms = router_now_unix_ms()
			_ = federation_remote_message_mark_read(row.record_key, read_unix_ms)
			payload := federation_callback_read_receipt_json(row.message_id, row.remote_agent_instance_id, row.proxy_agent_instance_id, row.origin_conversation_id, row.local_agent_instance_id, read_unix_ms)
			idempotency_key := federation_idempotency_key("read", server_daemon_id, row.message_id)
			_ = federation_delivery_outbox_insert_pending(row.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, payload)
			sent := federation_forward(row.owner_peer_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
			_ = federation_delivery_outbox_mark_attempt(row.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, sent)
		}
		append(&messages, contracts.Message{
			id = contracts.Message_ID(strings.clone(row.record_key)),
			conversation_id = contracts.Conversation_ID(strings.clone(row.conversation_id)),
			from_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(row.remote_agent_instance_id)),
			target_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(row.local_agent_instance_id)),
			body = strings.clone(body),
			created_unix_ms = row.created_unix_ms,
			updated_unix_ms = row.created_unix_ms,
			read_unix_ms = read_unix_ms,
		})
	}
	return contracts.Fetch_Messages_Response{ok = true, message = "fetched", messages = messages[:], has_more = false}
}

federation_status_text :: proc(status_code: int) -> string {
	switch status_code {
	case 200, 201, 202:
		return "OK"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 409:
		return "Conflict"
	case 500:
		return "Internal Server Error"
	case 503:
		return "Service Unavailable"
	}
	return "OK"
}

federation_response_path_with_auth :: proc(path, peer_token, peer_daemon_id: string) -> string {
	sep := "?"
	if strings.index_byte(path, '?') >= 0 do sep = "&"
	return fmt.tprintf("%s%speer_token=%s&peer_daemon_id=%s", path, sep, peer_token, peer_daemon_id)
}

federation_remote_get :: proc(peer_id, path: string) -> (http.Response, bool) {
	rec, ok := peer_link_find(peer_id)
	if !ok do return http.Response{}, false
	full_path := federation_response_path_with_auth(path, rec.peer_token, server_daemon_id)
	resp, fetch_ok := http.get_with_timeout(rec.peer_url, full_path, FEDERATION_HTTP_TIMEOUT_MS)
	if !fetch_ok {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.last_checked_unix_ms = router_now_unix_ms()
		return http.Response{}, false
	}
	rec.status = strings.clone(PEER_STATUS_LINKED)
	rec.last_checked_unix_ms = router_now_unix_ms()
	return resp, true
}

federation_remote_post_callback :: proc(peer_id, payload, idempotency_key: string) -> (http.Response, bool) {
	rec, ok := peer_link_find(peer_id)
	if !ok do return http.Response{}, false
	full_path := federation_response_path_with_auth("/federation/callback", rec.peer_token, server_daemon_id)
	resp, post_ok := http.post_with_timeout(rec.peer_url, full_path, payload, FEDERATION_HTTP_TIMEOUT_MS)
	if !post_ok {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.last_checked_unix_ms = router_now_unix_ms()
		return http.Response{}, false
	}
	rec.status = strings.clone(PEER_STATUS_LINKED)
	rec.last_checked_unix_ms = router_now_unix_ms()
	_ = idempotency_key
	return resp, true
}

federation_write_forwarded_response :: proc(client: net.TCP_Socket, resp: http.Response, ok: bool) {
	if !ok {
		write_response(client, 503, "Service Unavailable", `{"ok":false,"message":"peer unreachable"}`)
		return
	}
	write_response(client, resp.status, federation_status_text(resp.status), resp.body)
}

federation_remote_work_track_notification :: proc(owner_peer_id, origin_daemon_id, local_agent_instance_id, payload: string) -> bool {
	if extract_json_string(payload, "type", "") != "task_event" do return true
	task_id := extract_json_string(payload, "task_id", extract_json_string(payload, "fetch_task_id", ""))
	if task_id == "" do return true
	proxy_agent_instance_id := extract_json_string(payload, "target_agent_instance_id", "")
	if proxy_agent_instance_id == "" do return false
	chain_id := extract_json_string(payload, "chain_id", extract_json_string(payload, "fetch_chain_id", ""))
	status := extract_json_string(payload, "status", "")
	owner_origin_daemon_id := extract_json_string(payload, "origin_daemon_id", origin_daemon_id)
	if owner_origin_daemon_id == "" do return false
	created_unix_ms := i64(extract_json_int(payload, "created_unix_ms", int(router_now_unix_ms())))
	if existing, ok := federation_remote_work_find_task(owner_origin_daemon_id, task_id, local_agent_instance_id); ok {
		if existing.created_unix_ms != 0 do created_unix_ms = existing.created_unix_ms
		federation_remote_work_delete_record(existing)
	}
	return federation_remote_work_upsert(Federation_Remote_Work_Record{
		task_id = strings.clone(task_id),
		chain_id = strings.clone(chain_id),
		owner_peer_id = strings.clone(owner_peer_id),
		origin_daemon_id = strings.clone(owner_origin_daemon_id),
		local_agent_instance_id = strings.clone(local_agent_instance_id),
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		status = strings.clone(status),
		created_unix_ms = created_unix_ms,
		updated_unix_ms = router_now_unix_ms(),
	})
}

federation_remote_task_read_allowed :: proc(state: Task_State, proxy_agent_instance_id: string) -> bool {
	if proxy_agent_instance_id == "" do return false
	if task_actor_has_role(state, proxy_agent_instance_id, "assignee") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "coordinator") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_required") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_optional") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "subscriber") do return true
	if task_reviewer_agent_instance_id(state) == proxy_agent_instance_id do return true
	return false
}

federation_remote_task_authorized :: proc(peer_id, proxy_agent_instance_id, task_id, action: string) -> bool {
	mapped_peer_id, remote_agent_instance_id, mapped := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !mapped || mapped_peer_id != peer_id || remote_agent_instance_id == "" do return false
	state, found := store_get_task(task_id)
	if !found do return false
	switch action {
	case "read", "comment":
		return federation_remote_task_read_allowed(state, proxy_agent_instance_id)
	case "vote":
		if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_required") do return true
		if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_optional") do return true
		return task_reviewer_agent_instance_id(state) == proxy_agent_instance_id
	case "status":
		return federation_remote_task_read_allowed(state, proxy_agent_instance_id)
	}
	return false
}

federation_remote_chain_authorized :: proc(peer_id, proxy_agent_instance_id, chain_id: string) -> bool {
	mapped_peer_id, remote_agent_instance_id, mapped := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !mapped || mapped_peer_id != peer_id || remote_agent_instance_id == "" do return false
	for state in store_tasks_in_chain(chain_id) {
		if federation_remote_task_read_allowed(state, proxy_agent_instance_id) do return true
	}
	return false
}

federation_json_value_extract :: proc(body, key: string) -> (string, bool) {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return "", false
	start := idx + len(pattern)
	for start < len(body) && (body[start] == ' ' || body[start] == '\n' || body[start] == '\r' || body[start] == '\t') {
		start += 1
	}
	if start >= len(body) do return "", false
	open := body[start]
	close := byte('}')
	if open == '[' do close = ']'
	if open != '{' && open != '[' do return "", false
	depth := 0
	in_string := false
	escaped := false
	for i := start; i < len(body); i += 1 {
		ch := body[i]
		if in_string {
			if escaped {
				escaped = false
				continue
			}
			if ch == '\\' {
				escaped = true
				continue
			}
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' {
			in_string = true
			continue
		}
		if ch == open {
			depth += 1
		} else if ch == close {
			depth -= 1
			if depth == 0 do return strings.clone(body[start:i + 1]), true
		}
	}
	return "", false
}

federation_json_object_append_string :: proc(object_json, key, value: string) -> string {
	if object_json == "" || key == "" do return strings.clone(object_json)
	end := len(object_json) - 1
	for end >= 0 && (object_json[end] == ' ' || object_json[end] == '\n' || object_json[end] == '\r' || object_json[end] == '\t') {
		end -= 1
	}
	if end < 0 || object_json[end] != '}' do return strings.clone(object_json)
	b := strings.builder_make()
	strings.write_string(&b, object_json[:end])
	strings.write_string(&b, `,"`)
	strings.write_string(&b, key)
	strings.write_string(&b, `":"`)
	json_write_string(&b, value)
	strings.write_string(&b, `"`)
	strings.write_string(&b, object_json[end:])
	return strings.to_string(b)
}

federation_remote_task_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("/federation/tasks/%s?as_agent_instance_id=%s", work.task_id, work.proxy_agent_instance_id))
}

federation_remote_task_comments_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("/federation/tasks/%s/comments?as_agent_instance_id=%s", work.task_id, work.proxy_agent_instance_id))
}

federation_remote_chain_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("/federation/task-chains/%s?as_agent_instance_id=%s", work.chain_id, work.proxy_agent_instance_id))
}

federation_remote_chain_tasks_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("/federation/task-chains/%s/tasks?as_agent_instance_id=%s", work.chain_id, work.proxy_agent_instance_id))
}

federation_remote_tasks_state_json :: proc(local_agent_instance_id: string) -> string {
	rows := federation_remote_work_list_for_agent(local_agent_instance_id)
	defer {
		for row in rows {
			delete(row.task_id)
			delete(row.chain_id)
			delete(row.owner_peer_id)
			delete(row.origin_daemon_id)
			delete(row.local_agent_instance_id)
			delete(row.proxy_agent_instance_id)
			delete(row.status)
		}
		delete(rows)
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"task_count":0,"chain_count":0,"event_count":0,"tasks":[`)
	first := true
	count := 0
	for row in rows {
		resp, ok := federation_remote_task_fetch_response(row)
		if !ok || resp.status != 200 do continue
		task_json, extracted := federation_json_value_extract(resp.body, "task")
		if !extracted do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, task_json)
		delete(task_json)
		count += 1
	}
	strings.write_string(&b, `],"participants":[],"chains":[]}`)
	out := strings.to_string(b)
	count_str := fmt.tprintf(`"task_count":%d`, count)
	replaced, _ := strings.replace_all(out, `"task_count":0`, count_str)
	return replaced
}

federation_remote_task_next_json :: proc(local_agent_instance_id: string) -> (string, bool) {
	rows := federation_remote_work_list_for_agent(local_agent_instance_id)
	defer {
		for row in rows {
			delete(row.task_id)
			delete(row.chain_id)
			delete(row.owner_peer_id)
			delete(row.origin_daemon_id)
			delete(row.local_agent_instance_id)
			delete(row.proxy_agent_instance_id)
			delete(row.status)
		}
		delete(rows)
	}
	for row in rows {
		resp, ok := federation_remote_task_fetch_response(row)
		if !ok || resp.status != 200 do continue
		status := extract_json_string(resp.body, "status", "")
		if status != "review_ready" && status != "in_progress" && status != "queued" do continue
		task_json, extracted := federation_json_value_extract(resp.body, "task")
		if !extracted do continue
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":true,"task":`)
		strings.write_string(&b, task_json)
		strings.write_string(&b, `}`)
		delete(task_json)
		return strings.to_string(b), true
	}
	return `{"ok":true,"task":null}`, true
}

federation_task_callback_pending_json :: proc(kind, task_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"queued":true,"kind":"`)
		json_write_string(&b, kind)
	strings.write_string(&b, `","task_id":"`)
		json_write_string(&b, task_id)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

federation_task_comment_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, body, idempotency_key: string, artifact: Artifact_Record) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"comment","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","task_id":"`)
	json_write_string(&b, work.task_id)
	strings.write_string(&b, `","chain_id":"`)
	json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `"`)
	if artifact.artifact_id != "" {
		strings.write_string(&b, `,"artifact_ref":{`)
		strings.write_string(&b, `"artifact_id":"`); json_write_string(&b, artifact.artifact_id)
		strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
		strings.write_string(&b, `","name":"`); json_write_string(&b, artifact.name)
		strings.write_string(&b, `","kind":"`); json_write_string(&b, artifact.kind)
		strings.write_string(&b, `","mime":"`); json_write_string(&b, artifact.mime)
		strings.write_string(&b, `","ext":"`); json_write_string(&b, artifact.ext)
		strings.write_string(&b, `","sha256":"`); json_write_string(&b, artifact.sha256)
		strings.write_string(&b, `","description":"`); json_write_string(&b, artifact.description)
		strings.write_string(&b, `","size_bytes":`); strings.write_string(&b, fmt.tprintf("%d", artifact.size_bytes))
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_task_vote_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, comment, result, idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"vote","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","task_id":"`)
	json_write_string(&b, work.task_id)
	strings.write_string(&b, `","chain_id":"`)
	json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","result":"`)
	json_write_string(&b, result)
	strings.write_string(&b, `","comment":"`)
	json_write_string(&b, comment)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

federation_task_status_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, status, body, idempotency_key: string, force: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"status","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","task_id":"`)
	json_write_string(&b, work.task_id)
	strings.write_string(&b, `","chain_id":"`)
	json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","status":"`)
	json_write_string(&b, status)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `","force":`)
	strings.write_string(&b, "true" if force else "false")
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

handle_get_federation_task :: proc(client: net.TCP_Socket, task_id: string, ctx: ^Route_Context) {
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "read") {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote task read"}`)
		return
	}
	state, found := store_get_task(task_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"task not found"}`)
		return
	}
	task_builder := strings.builder_make()
	task_write_state_json(&task_builder, state)
	task_json := strings.to_string(task_builder)
	annotated_task_json := federation_json_object_append_string(task_json, "origin_daemon_id", server_daemon_id)
	delete(task_json)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"task":`)
	strings.write_string(&b, annotated_task_json)
	strings.write_string(&b, `}`)
	delete(annotated_task_json)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_get_federation_task_comments :: proc(client: net.TCP_Socket, task_id: string, ctx: ^Route_Context) {
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "read") {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote task read"}`)
		return
	}
	unresolved_only := query_param_value(ctx.query, "unresolved") == "true"
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"comments":[`)
	first := true
	comments := store_comments_of(task_id)
	defer delete(comments)
	for c in comments {
		if unresolved_only && c.resolved do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, `{"comment_id":"`); json_write_string(&b, c.comment_id)
		strings.write_string(&b, `","body":"`); json_write_string(&b, c.body)
		strings.write_string(&b, `","author_agent_instance_id":"`); json_write_string(&b, c.author_agent_instance_id)
		strings.write_string(&b, `","resolved":`); strings.write_string(&b, "true" if c.resolved else "false")
		strings.write_string(&b, `,"created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", c.created_unix_ms))
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_get_federation_task_chain :: proc(client: net.TCP_Socket, chain_id: string, ctx: ^Route_Context) {
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_chain_authorized(peer_id, proxy_agent_instance_id, chain_id) {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote chain read"}`)
		return
	}
	chain, found := store_get_chain(chain_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"chain not found"}`)
		return
	}
	chain_builder := strings.builder_make()
	task_write_chain_json(&chain_builder, chain)
	chain_json := strings.to_string(chain_builder)
	annotated_chain_json := federation_json_object_append_string(chain_json, "origin_daemon_id", server_daemon_id)
	delete(chain_json)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"chain":`)
	strings.write_string(&b, annotated_chain_json)
	delete(annotated_chain_json)
	strings.write_string(&b, `,"events":[`)
	first := true
	for event in store_all_events() {
		if event.chain_id != chain_id || event.task_id != "" do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, task_event_json(event))
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_get_federation_task_chain_tasks :: proc(client: net.TCP_Socket, chain_id: string, ctx: ^Route_Context) {
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_chain_authorized(peer_id, proxy_agent_instance_id, chain_id) {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote chain read"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"chain_id":"`)
	json_write_string(&b, chain_id)
	strings.write_string(&b, `","tasks":[`)
	first := true
	for state in store_tasks_in_chain(chain_id) {
		if !federation_remote_task_read_allowed(state, proxy_agent_instance_id) do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		task_builder := strings.builder_make()
		task_write_state_json(&task_builder, state)
		task_json := strings.to_string(task_builder)
		annotated_task_json := federation_json_object_append_string(task_json, "origin_daemon_id", server_daemon_id)
		delete(task_json)
		strings.write_string(&b, annotated_task_json)
		delete(annotated_task_json)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_post_federation_inbox :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	kind := extract_json_string(body, "kind", "")
	idempotency_key := extract_json_string(body, "idempotency_key", "")
	if kind == "" || idempotency_key == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"kind and idempotency_key required"}`)
		return
	}
	scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_INBOX, peer_id, kind)
	if federation_delivery_dedupe_completed(scope, idempotency_key) {
		write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
		return
	}
	switch kind {
	case FEDERATION_ENVELOPE_NOTIFICATION:
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		payload := extract_json_string(body, "payload", "")
		if target_agent_instance_id == "" || payload == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"notification target/payload required"}`)
			return
		}
		if !federation_remote_work_track_notification(peer_id, query_param_value(ctx.query, "peer_daemon_id"), target_agent_instance_id, payload) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist remote work mapping"}`)
			return
		}
		event_id := notification_outbox_insert_pending(target_agent_instance_id, payload)
		if event_id == "" {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to durably queue notification"}`)
			return
		}
		sent := registry_send_ws_text(target_agent_instance_id, payload)
		_ = notification_outbox_mark_attempt(target_agent_instance_id, event_id, sent)
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record notification dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_INBOX_MESSAGE:
		message_id := extract_json_string(body, "message_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		proxy_agent_instance_id := extract_json_string(body, "proxy_agent_instance_id", "")
		origin_conversation_id := extract_json_string(body, "origin_conversation_id", "")
		message_body := extract_json_string(body, "body", "")
		created_unix_ms := i64(extract_json_int(body, "created_unix_ms", int(router_now_unix_ms())))
		if !federation_remote_message_receive_placeholder(peer_id, query_param_value(ctx.query, "peer_daemon_id"), message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, message_body, created_unix_ms) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist remote placeholder"}`)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record inbox dedupe"}`)
			return
		}
		notified := message_bus_emit(Message_Event{
			kind = .Messages_Available,
			message_id = contracts.Message_ID(strings.clone(message_id)),
			conversation_id = contracts.Conversation_ID(conversation_id_for_instance(target_agent_instance_id)),
			from_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(from_agent_instance_id)),
			target_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(target_agent_instance_id)),
			pending_count = 1,
			created_unix_ms = created_unix_ms,
		})
		_ = notified
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case:
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported federation inbox kind"}`)
	}
}

handle_get_federation_message :: proc(client: net.TCP_Socket, message_id: string, ctx: ^Route_Context) {
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	rec, found := federation_remote_message_find_origin(peer_id, message_id)
	if !found || !rec.body_available {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"message not found"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"message_id":"`)
	json_write_string(&b, rec.message_id)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, rec.body)
	strings.write_string(&b, `"}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// handle_post_federation_start starts a REAL local agent on request from a peer
// that holds a remote_proxy pointing at it. Authenticated by the peer link. The
// target must be a genuine local agent (not itself a remote_proxy), preventing a
// peer from asking us to relay a start onward.
handle_post_federation_start :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_instance_id required"}`)
		return
	}
	idx := agent_record_index_by_instance(agent_instance_id)
	if idx < 0 {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"target agent not found on owner daemon"}`)
		return
	}
	if agent_record_is_remote_proxy(agent_instance_records[idx]) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"target is itself a remote proxy; refusing to relay start"}`)
		return
	}
	// Delegate to the normal local start path. It writes the /agents/start
	// response straight back to the requesting peer.
	handle_agents_start(client, body)
}

handle_post_federation_callback :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), query_param_value(ctx.query, "peer_daemon_id"))
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	kind := extract_json_string(body, "kind", "")
	idempotency_key := extract_json_string(body, "idempotency_key", "")
	if kind == "" || idempotency_key == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"kind and idempotency_key required"}`)
		return
	}
	proxy_agent_instance_id := extract_json_string(body, "proxy_agent_instance_id", "")
	mapped_peer_id, remote_agent_instance_id, mapped := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !mapped || mapped_peer_id != peer_id {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
		return
	}
	switch kind {
	case FEDERATION_ENVELOPE_INBOX_MESSAGE:
		origin_message_id := extract_json_string(body, "origin_message_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		origin_conversation_id := extract_json_string(body, "origin_conversation_id", "")
		payload := extract_json_string(body, "body", "")
		if from_agent_instance_id == "" || target_agent_instance_id == "" || payload == "" || origin_conversation_id == "" || origin_message_id == "" || from_agent_instance_id != remote_agent_instance_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		origin_rec, authorized := federation_callback_origin_message_authorize(peer_id, origin_message_id, proxy_agent_instance_id, remote_agent_instance_id, target_agent_instance_id, origin_conversation_id)
		if !authorized {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, kind)
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		callback_message_id := extract_json_string(body, "message_id", "")
		created_unix_ms := i64(extract_json_int(body, "created_unix_ms", int(router_now_unix_ms())))
		if callback_message_id == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"callback message_id required"}`)
			return
		}
		inserted, stored := federation_remote_message_store_reply_if_absent(peer_id, query_param_value(ctx.query, "peer_daemon_id"), callback_message_id, remote_agent_instance_id, origin_rec.local_agent_instance_id, proxy_agent_instance_id, origin_rec.origin_conversation_id, payload, created_unix_ms)
		if !stored {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to store remote reply"}`)
			return
		}
		if !inserted {
			_ = federation_delivery_dedupe_record_completed(scope, idempotency_key)
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		_ = message_bus_emit(Message_Event{
			kind = .Messages_Available,
			message_id = contracts.Message_ID(federation_remote_message_record_key(query_param_value(ctx.query, "peer_daemon_id"), callback_message_id)),
			conversation_id = contracts.Conversation_ID(origin_rec.origin_conversation_id),
			from_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
			target_agent_instance_id = contracts.Agent_Instance_ID(origin_rec.local_agent_instance_id),
			pending_count = 1,
			created_unix_ms = created_unix_ms,
		})
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_READ_RECEIPT:
		message_id := extract_json_string(body, "message_id", "")
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		origin_conversation_id := extract_json_string(body, "origin_conversation_id", "")
		read_by_agent_instance_id := extract_json_string(body, "read_by_agent_instance_id", "")
		read_unix_ms := i64(extract_json_int(body, "read_unix_ms", int(router_now_unix_ms())))
		if target_agent_instance_id == "" || origin_conversation_id == "" || message_id == "" || read_by_agent_instance_id != remote_agent_instance_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		origin_rec, authorized := federation_callback_origin_message_authorize(peer_id, message_id, proxy_agent_instance_id, remote_agent_instance_id, target_agent_instance_id, origin_conversation_id)
		if !authorized {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, kind)
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		mark := mp.mark_read(&message_provider, contracts.Mark_Read_Request{agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id), conversation_id = contracts.Conversation_ID(origin_rec.origin_conversation_id), through_message_id = contracts.Message_ID(origin_rec.message_id)})
		if !mark.ok {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to apply remote read receipt"}`)
			return
		}
		_ = message_bus_emit(Message_Event{
			kind = .Message_Read,
			message_id = contracts.Message_ID(message_id),
			conversation_id = contracts.Conversation_ID(origin_conversation_id),
			from_agent_instance_id = contracts.Agent_Instance_ID(target_agent_instance_id),
			target_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
			read_by_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
			read_unix_ms = read_unix_ms,
		})
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_TASK_COMMENT:
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		task_id := extract_json_string(body, "task_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		comment_body := extract_json_string(body, "body", "")
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || task_id == "" || comment_body == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "comment") {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s", kind, task_id))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		if artifact_ref_json, has_artifact_ref := federation_json_value_extract(body, "artifact_ref"); has_artifact_ref {
			remote_artifact_id := extract_json_string(artifact_ref_json, "artifact_id", "")
			artifact_origin_daemon_id := extract_json_string(artifact_ref_json, "origin_daemon_id", "")
			project_id := ""
			if chain, found := store_get_chain(chain_id); found do project_id = chain.project_id
			local_artifact_id, upsert_ok := artifact_federation_reference_upsert(
				peer_id,
				artifact_origin_daemon_id,
				remote_artifact_id,
				extract_json_string(artifact_ref_json, "name", ""),
				extract_json_string(artifact_ref_json, "kind", ""),
				extract_json_string(artifact_ref_json, "mime", ""),
				extract_json_string(artifact_ref_json, "ext", ""),
				extract_json_string(artifact_ref_json, "description", ""),
				project_id,
				proxy_agent_instance_id,
				extract_json_i64(artifact_ref_json, "size_bytes", 0),
				extract_json_string(artifact_ref_json, "sha256", ""),
			)
			delete(artifact_ref_json)
			if !upsert_ok {
				write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist remote artifact reference"}`)
				return
			}
			if local_artifact_id != "" && local_artifact_id != remote_artifact_id {
				replaced, _ := strings.replace_all(comment_body, contracts.artifact_make_link(remote_artifact_id), contracts.artifact_make_link(local_artifact_id))
				comment_body = replaced
			}
		}
		result := task_service_comment(task_id, chain_id, comment_body, proxy_agent_instance_id)
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case FEDERATION_ENVELOPE_TASK_VOTE:
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		task_id := extract_json_string(body, "task_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		result_str := extract_json_string(body, "result", "")
		comment_body := extract_json_string(body, "comment", "")
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || task_id == "" || comment_body == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "vote") {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s", kind, task_id))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		result := task_service_review_vote(Task_Review_Vote_Command{task_id = task_id, chain_id = chain_id, approved = result_str == "lgtm" || result_str == "approved" || result_str == "true", comment = comment_body, author_agent_instance_id = proxy_agent_instance_id, author_is_user = false})
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case FEDERATION_ENVELOPE_TASK_STATUS:
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		task_id := extract_json_string(body, "task_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		status_value := extract_json_string(body, "status", "")
		status_body := extract_json_string(body, "body", "")
		force := extract_json_bool(body, "force", false)
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || task_id == "" || status_value == "" || status_body == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "status") {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s:%s", kind, task_id, status_value))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		result := task_service_status_command(Task_Status_Command{task_id = task_id, chain_id = chain_id, status = status_value, body = status_body, force = force, author_agent_instance_id = proxy_agent_instance_id})
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case:
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported federation callback kind"}`)
	}
}
