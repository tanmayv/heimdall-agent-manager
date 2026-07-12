package main

import "core:c"
import "core:fmt"
import "core:strings"

// Chat approval durable record. Bound to a task chain and carries a required
// TTL so operator inbox items never get stranded forever.
Chat_Approval_Record :: struct {
	approval_id:            string,
	message_id:             string,
	chain_id:               string,
	user_id:                string,
	agent_instance_id:      string, // sender
	kind:                   string, // smart_answer | questions | approval_request
	title:                  string,
	body:                   string,
	options_json:           string,
	free_form:              bool,
	expires_at_unix_ms:     i64,
	state:                  string, // open | answered | dismissed | superseded | cancelled | expired
	answered_reply:         string,
	answered_at_unix_ms:    i64,
	dismissed_by:           string,
	dismiss_reason:         string,
	dismissed_at_unix_ms:   i64,
	superseded_by_message_id: string,
	created_unix_ms:        i64,
}

chat_approval_db_init :: proc() -> bool {
	// Piggy-back on message_db to keep chat-related storage co-located.
	if message_db.db == nil {
		fmt.println("chat_approval_db_init: message_db not initialized")
		return false
	}
	schema := `
	CREATE TABLE IF NOT EXISTS chat_approvals (
		approval_id TEXT PRIMARY KEY,
		message_id TEXT NOT NULL,
		chain_id TEXT NOT NULL,
		user_id TEXT NOT NULL,
		agent_instance_id TEXT NOT NULL,
		kind TEXT NOT NULL,
		title TEXT NOT NULL DEFAULT '',
		body TEXT NOT NULL DEFAULT '',
		options_json TEXT NOT NULL DEFAULT '',
		free_form INTEGER NOT NULL DEFAULT 0,
		expires_at_unix_ms INTEGER NOT NULL,
		state TEXT NOT NULL DEFAULT 'open',
		answered_reply TEXT NOT NULL DEFAULT '',
		answered_at_unix_ms INTEGER NOT NULL DEFAULT 0,
		dismissed_by TEXT NOT NULL DEFAULT '',
		dismiss_reason TEXT NOT NULL DEFAULT '',
		dismissed_at_unix_ms INTEGER NOT NULL DEFAULT 0,
		superseded_by_message_id TEXT NOT NULL DEFAULT '',
		created_unix_ms INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_chat_approvals_state ON chat_approvals(state, expires_at_unix_ms);
	CREATE INDEX IF NOT EXISTS idx_chat_approvals_chain ON chat_approvals(chain_id, state);
	CREATE INDEX IF NOT EXISTS idx_chat_approvals_user ON chat_approvals(user_id, state);
	`
	errmsg: cstring = nil
	rc := sqlite3_exec(message_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		if errmsg != nil {
			fmt.printfln("chat_approval_db_init: schema error: %s", errmsg)
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

chat_approval_db_insert :: proc(rec: Chat_Approval_Record) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO chat_approvals (approval_id, message_id, chain_id, user_id, agent_instance_id, kind, title, body, options_json, free_form, expires_at_unix_ms, state, created_unix_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?)`
	if rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil); rc != SQLITE_OK {
		fmt.printf("chat_approval_db_insert: prepare failed: %d (%s)\n", rc, sqlite3_errmsg(message_db.db))
		return false
	}
	defer sqlite3_finalize(stmt)
	sqlite3_bind_text(stmt, 1, cstring(raw_data(rec.approval_id)), i32(len(rec.approval_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(rec.message_id)), i32(len(rec.message_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(rec.chain_id)), i32(len(rec.chain_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(rec.user_id)), i32(len(rec.user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(rec.agent_instance_id)), i32(len(rec.agent_instance_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 6, cstring(raw_data(rec.kind)), i32(len(rec.kind)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(rec.title)), i32(len(rec.title)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 8, cstring(raw_data(rec.body)), i32(len(rec.body)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 9, cstring(raw_data(rec.options_json)), i32(len(rec.options_json)), SQLITE_TRANSIENT)
	free_form_val: c.longlong = 0
	if rec.free_form do free_form_val = 1
	sqlite3_bind_int64(stmt, 10, free_form_val)
	sqlite3_bind_int64(stmt, 11, c.longlong(rec.expires_at_unix_ms))
	sqlite3_bind_int64(stmt, 12, c.longlong(rec.created_unix_ms))
	rc := sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("chat_approval_db_insert: step failed: %d (%s) approval_id=%s message_id=%s chain_id=%s kind=%s\n", rc, sqlite3_errmsg(message_db.db), rec.approval_id, rec.message_id, rec.chain_id, rec.kind)
		return false
	}
	return true
}

chat_approval_db_get :: proc(approval_id: string) -> (rec: Chat_Approval_Record, found: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT approval_id, message_id, chain_id, user_id, agent_instance_id, kind, title, body, options_json, free_form, expires_at_unix_ms, state, answered_reply, answered_at_unix_ms, dismissed_by, dismiss_reason, dismissed_at_unix_ms, superseded_by_message_id, created_unix_ms FROM chat_approvals WHERE approval_id = ?`
	if sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return
	defer sqlite3_finalize(stmt)
	sqlite3_bind_text(stmt, 1, cstring(raw_data(approval_id)), i32(len(approval_id)), SQLITE_TRANSIENT)
	if sqlite3_step(stmt) != SQLITE_ROW do return
	rec = chat_approval_row_from_stmt(stmt)
	found = true
	return
}

// Return only currently-open, non-expired approvals for the given user, ordered by
// soonest expiry so the UI can prioritize the ones about to time out.
chat_approval_db_list_open_for_user :: proc(user_id: string, now_unix_ms: i64) -> []Chat_Approval_Record {
	stmt: sqlite3_stmt = nil
	query := `SELECT approval_id, message_id, chain_id, user_id, agent_instance_id, kind, title, body, options_json, free_form, expires_at_unix_ms, state, answered_reply, answered_at_unix_ms, dismissed_by, dismiss_reason, dismissed_at_unix_ms, superseded_by_message_id, created_unix_ms FROM chat_approvals WHERE user_id = ? AND state = 'open' AND expires_at_unix_ms > ? ORDER BY expires_at_unix_ms ASC`
	out := make([dynamic]Chat_Approval_Record)
	if sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return out[:]
	defer sqlite3_finalize(stmt)
	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 2, c.longlong(now_unix_ms))
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, chat_approval_row_from_stmt(stmt))
	}
	return out[:]
}

chat_approval_db_list_open_for_chain :: proc(chain_id: string) -> []Chat_Approval_Record {
	stmt: sqlite3_stmt = nil
	query := `SELECT approval_id, message_id, chain_id, user_id, agent_instance_id, kind, title, body, options_json, free_form, expires_at_unix_ms, state, answered_reply, answered_at_unix_ms, dismissed_by, dismiss_reason, dismissed_at_unix_ms, superseded_by_message_id, created_unix_ms FROM chat_approvals WHERE chain_id = ? AND state = 'open'`
	out := make([dynamic]Chat_Approval_Record)
	if sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return out[:]
	defer sqlite3_finalize(stmt)
	sqlite3_bind_text(stmt, 1, cstring(raw_data(chain_id)), i32(len(chain_id)), SQLITE_TRANSIENT)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, chat_approval_row_from_stmt(stmt))
	}
	return out[:]
}

chat_approval_db_list_expired :: proc(now_unix_ms: i64, limit: int) -> []Chat_Approval_Record {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(`SELECT approval_id, message_id, chain_id, user_id, agent_instance_id, kind, title, body, options_json, free_form, expires_at_unix_ms, state, answered_reply, answered_at_unix_ms, dismissed_by, dismiss_reason, dismissed_at_unix_ms, superseded_by_message_id, created_unix_ms FROM chat_approvals WHERE state = 'open' AND expires_at_unix_ms <= ? LIMIT %d`, limit)
	out := make([dynamic]Chat_Approval_Record)
	if sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return out[:]
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, c.longlong(now_unix_ms))
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, chat_approval_row_from_stmt(stmt))
	}
	return out[:]
}

// Terminal transitions are only allowed when current state = open. Returns
// (previous_state, ok). ok = false means the row was not open or not found.
chat_approval_db_terminal_transition :: proc(approval_id, new_state, reply, actor, reason, superseded_by_message_id: string, now_unix_ms: i64) -> (previous_state: string, ok: bool) {
	rec, found := chat_approval_db_get(approval_id)
	if !found do return "", false
	previous_state = strings.clone(rec.state)
	if rec.state != "open" do return previous_state, false
	stmt: sqlite3_stmt = nil
	query := `UPDATE chat_approvals SET state = ?, answered_reply = CASE WHEN ? = 'answered' THEN ? ELSE answered_reply END, answered_at_unix_ms = CASE WHEN ? = 'answered' THEN ? ELSE answered_at_unix_ms END, dismissed_by = CASE WHEN ? IN ('dismissed','superseded','cancelled') THEN ? ELSE dismissed_by END, dismiss_reason = CASE WHEN ? IN ('dismissed','superseded','cancelled') THEN ? ELSE dismiss_reason END, dismissed_at_unix_ms = CASE WHEN ? IN ('dismissed','superseded','cancelled','expired') THEN ? ELSE dismissed_at_unix_ms END, superseded_by_message_id = CASE WHEN ? = 'superseded' THEN ? ELSE superseded_by_message_id END WHERE approval_id = ? AND state = 'open'`
	if sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return previous_state, false
	defer sqlite3_finalize(stmt)
	sqlite3_bind_text(stmt, 1, cstring(raw_data(new_state)), i32(len(new_state)), SQLITE_TRANSIENT)
	// bind new_state again for CASE checks (params 2, 4, 6, 8, 10, 12)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(new_state)), i32(len(new_state)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(reply)), i32(len(reply)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(new_state)), i32(len(new_state)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 5, c.longlong(now_unix_ms))
	sqlite3_bind_text(stmt, 6, cstring(raw_data(new_state)), i32(len(new_state)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(actor)), i32(len(actor)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 8, cstring(raw_data(new_state)), i32(len(new_state)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 9, cstring(raw_data(reason)), i32(len(reason)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 10, cstring(raw_data(new_state)), i32(len(new_state)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 11, c.longlong(now_unix_ms))
	sqlite3_bind_text(stmt, 12, cstring(raw_data(new_state)), i32(len(new_state)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 13, cstring(raw_data(superseded_by_message_id)), i32(len(superseded_by_message_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 14, cstring(raw_data(approval_id)), i32(len(approval_id)), SQLITE_TRANSIENT)
	if sqlite3_step(stmt) != SQLITE_DONE do return previous_state, false
	ok = true
	return
}

chat_approval_row_from_stmt :: proc(stmt: sqlite3_stmt) -> Chat_Approval_Record {
	rec: Chat_Approval_Record
	rec.approval_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
	rec.message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
	rec.chain_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
	rec.user_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
	rec.agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
	rec.kind = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
	rec.title = strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
	rec.body = strings.clone_from_cstring(sqlite3_column_text(stmt, 7))
	rec.options_json = strings.clone_from_cstring(sqlite3_column_text(stmt, 8))
	rec.free_form = sqlite3_column_int64(stmt, 9) != 0
	rec.expires_at_unix_ms = i64(sqlite3_column_int64(stmt, 10))
	rec.state = strings.clone_from_cstring(sqlite3_column_text(stmt, 11))
	rec.answered_reply = strings.clone_from_cstring(sqlite3_column_text(stmt, 12))
	rec.answered_at_unix_ms = i64(sqlite3_column_int64(stmt, 13))
	rec.dismissed_by = strings.clone_from_cstring(sqlite3_column_text(stmt, 14))
	rec.dismiss_reason = strings.clone_from_cstring(sqlite3_column_text(stmt, 15))
	rec.dismissed_at_unix_ms = i64(sqlite3_column_int64(stmt, 16))
	rec.superseded_by_message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 17))
	rec.created_unix_ms = i64(sqlite3_column_int64(stmt, 18))
	return rec
}
