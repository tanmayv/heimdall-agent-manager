package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c"

// FFI bindings to system sqlite3 library
foreign import sqlite3_lib "system:sqlite3"

sqlite3 :: distinct rawptr
sqlite3_stmt :: distinct rawptr

SQLITE_OK       :: 0
SQLITE_ROW      :: 100
SQLITE_DONE     :: 101
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention="c")
foreign sqlite3_lib {
	sqlite3_open :: proc(filename: cstring, ppDb: [^]sqlite3) -> c.int ---
	sqlite3_close :: proc(db: sqlite3) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: sqlite3, zSql: cstring, nByte: c.int, ppStmt: [^]sqlite3_stmt, pzTail: [^]cstring) -> c.int ---
	sqlite3_finalize :: proc(pStmt: sqlite3_stmt) -> c.int ---
	sqlite3_step :: proc(pStmt: sqlite3_stmt) -> c.int ---
	sqlite3_exec :: proc(db: sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: [^]cstring) -> c.int ---
	sqlite3_bind_text :: proc(pStmt: sqlite3_stmt, index: c.int, value: cstring, n: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int64 :: proc(pStmt: sqlite3_stmt, index: c.int, value: c.longlong) -> c.int ---
	sqlite3_column_text :: proc(pStmt: sqlite3_stmt, iCol: c.int) -> cstring ---
	sqlite3_column_int64 :: proc(pStmt: sqlite3_stmt, iCol: c.int) -> c.longlong ---
	sqlite3_free :: proc(p: rawptr) ---
}

Message_Db_Service :: struct {
	db: sqlite3,
	db_path: string,
}

message_db: Message_Db_Service

message_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/chat", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/messages.db", db_dir)
	message_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &message_db.db)
	if rc != SQLITE_OK {
		fmt.println("message_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !message_db_create_schema() {
		fmt.println("message_db_init: failed to create schema")
		sqlite3_close(message_db.db)
		return false
	}

	if !message_db_migrate_read_status_schema() {
		fmt.println("message_db_init: failed to migrate read status schema")
		sqlite3_close(message_db.db)
		return false
	}

	fmt.println("message_db_init: database initialized at", db_path)
	return true
}

message_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS messages (
		message_id TEXT PRIMARY KEY,
		user_id TEXT NOT NULL,
		agent_instance_id TEXT NOT NULL,
		direction TEXT NOT NULL,
		body TEXT NOT NULL,
		delivered_unix_ms INTEGER DEFAULT 0,
		delivery_failed_unix_ms INTEGER DEFAULT 0,
		delivery_error TEXT,
		created_unix_ms INTEGER NOT NULL
	);

	CREATE TABLE IF NOT EXISTS conversation_read_status (
		user_id TEXT NOT NULL,
		agent_instance_id TEXT NOT NULL,
		last_read_unix_ms INTEGER DEFAULT 0,
		last_read_user_to_agent_ms INTEGER DEFAULT 0,
		last_read_agent_to_user_ms INTEGER DEFAULT 0,
		PRIMARY KEY (user_id, agent_instance_id)
	);

	CREATE INDEX IF NOT EXISTS idx_user_agent ON messages(user_id, agent_instance_id);
	CREATE INDEX IF NOT EXISTS idx_created ON messages(created_unix_ms);
	CREATE INDEX IF NOT EXISTS idx_unread ON messages(user_id, agent_instance_id, created_unix_ms);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(message_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("message_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}

	return true
}

message_db_migrate_read_status_schema :: proc() -> bool {
	if !message_db_has_column("conversation_read_status", "last_read_user_to_agent_ms") {
		if !message_db_add_column("conversation_read_status", "last_read_user_to_agent_ms INTEGER DEFAULT 0") {
			return false
		}
	}

	if !message_db_has_column("conversation_read_status", "last_read_agent_to_user_ms") {
		if !message_db_add_column("conversation_read_status", "last_read_agent_to_user_ms INTEGER DEFAULT 0") {
			return false
		}
	}

	if message_db_has_column("conversation_read_status", "last_read_unix_ms") {
		if !message_db_execute("UPDATE conversation_read_status SET last_read_user_to_agent_ms = COALESCE(last_read_user_to_agent_ms, last_read_unix_ms), last_read_agent_to_user_ms = COALESCE(last_read_agent_to_user_ms, last_read_unix_ms)") {
			fmt.println("message_db_migrate_read_status_schema: failed to seed direction-specific read columns")
			return false
		}
	}

	if !message_db_execute("UPDATE conversation_read_status SET last_read_unix_ms = CASE WHEN last_read_user_to_agent_ms >= last_read_agent_to_user_ms THEN last_read_user_to_agent_ms ELSE last_read_agent_to_user_ms END") {
		fmt.println("message_db_migrate_read_status_schema: failed to normalize legacy read timestamp")
		return false
	}

	return true
}

message_db_has_column :: proc(table_name, column_name: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("PRAGMA table_info(%s)", table_name)

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_has_column: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	for sqlite3_step(stmt) == SQLITE_ROW {
		name := strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
		if name == column_name {
			return true
		}
	}

	return false
}

message_db_add_column :: proc(table_name, column_definition: string) -> bool {
	query := fmt.tprintf("ALTER TABLE %s ADD COLUMN %s", table_name, column_definition)
	return message_db_execute(query)
}

message_db_execute :: proc(query: string) -> bool {
	errmsg: cstring = nil
	rc := sqlite3_exec(message_db.db, cstring(raw_data(query)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("message_db_execute failed:", rc)
		if errmsg != nil {
			fmt.println("message_db_execute:", errmsg)
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

message_db_insert :: proc(msg: Chat_Message) -> bool {
	fmt.println("DEBUG: message_db_insert called for message_id =", msg.message_id, "user_id =", msg.user_id, "agent_instance_id =", msg.agent_instance_id, "direction =", msg.direction)
	stmt: sqlite3_stmt = nil

	query := fmt.tprintf(
		`INSERT INTO messages
		(message_id, user_id, agent_instance_id, direction, body,
		 delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_insert: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(msg.message_id)), i32(len(msg.message_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(msg.user_id)), i32(len(msg.user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(msg.agent_instance_id)), i32(len(msg.agent_instance_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(msg.direction)), i32(len(msg.direction)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(msg.body)), i32(len(msg.body)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 6, msg.delivered_unix_ms)
	sqlite3_bind_int64(stmt, 7, msg.delivery_failed_unix_ms)
	sqlite3_bind_text(stmt, 8, cstring(raw_data(msg.delivery_error)), i32(len(msg.delivery_error)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 9, msg.created_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("message_db_insert: step failed:", rc)
		return false
	}

	fmt.println("DEBUG: message_db_insert succeeded for", msg.message_id)
	return true
}

message_db_mark_conversation_read :: proc(user_id, agent_instance_id, direction: string, read_unix_ms: i64) -> bool {
	user_to_agent_read, agent_to_user_read := message_db_get_last_read_status(user_id, agent_instance_id)

	switch direction {
	case "user_to_agent":
		if read_unix_ms > user_to_agent_read { user_to_agent_read = read_unix_ms }
	case "agent_to_user":
		if read_unix_ms > agent_to_user_read { agent_to_user_read = read_unix_ms }
	case:
		if read_unix_ms > user_to_agent_read { user_to_agent_read = read_unix_ms }
		if read_unix_ms > agent_to_user_read { agent_to_user_read = read_unix_ms }
	}

	legacy_read := user_to_agent_read
	if agent_to_user_read > legacy_read { legacy_read = agent_to_user_read }

	stmt: sqlite3_stmt = nil

	query := `INSERT OR REPLACE INTO conversation_read_status (user_id, agent_instance_id, last_read_unix_ms, last_read_user_to_agent_ms, last_read_agent_to_user_ms) VALUES (?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_mark_conversation_read: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 3, legacy_read)
	sqlite3_bind_int64(stmt, 4, user_to_agent_read)
	sqlite3_bind_int64(stmt, 5, agent_to_user_read)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("message_db_mark_conversation_read: step failed:", rc)
		return false
	}

	fmt.println("DEBUG: message_db_mark_conversation_read set", user_id, agent_instance_id, "to", read_unix_ms, "for", direction)
	return true
}

message_db_update_delivered :: proc(message_id: string, delivered_unix_ms: i64) -> bool {
	stmt: sqlite3_stmt = nil

	query := `UPDATE messages SET delivered_unix_ms = ? WHERE message_id = ?`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_update_delivered: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, delivered_unix_ms)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(message_id)), i32(len(message_id)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("message_db_update_delivered: step failed:", rc)
		return false
	}

	return true
}

message_db_update_delivery_failed :: proc(message_id: string, failed_unix_ms: i64, error: string) -> bool {
	stmt: sqlite3_stmt = nil

	query := `UPDATE messages SET delivery_failed_unix_ms = ?, delivery_error = ? WHERE message_id = ?`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_update_delivery_failed: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, failed_unix_ms)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(error)), i32(len(error)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(message_id)), i32(len(message_id)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("message_db_update_delivery_failed: step failed:", rc)
		return false
	}

	return true
}

message_db_get_last_read_status :: proc(user_id, agent_instance_id: string) -> (user_to_agent_read: i64, agent_to_user_read: i64) {
	stmt: sqlite3_stmt = nil

	query := `SELECT COALESCE(last_read_user_to_agent_ms, 0), COALESCE(last_read_agent_to_user_ms, 0), COALESCE(last_read_unix_ms, 0)
		FROM conversation_read_status
		WHERE user_id = ? AND agent_instance_id = ?`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_get_last_read_status: prepare failed:", rc)
		return 0, 0
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		user_to_agent_read = sqlite3_column_int64(stmt, 0)
		agent_to_user_read = sqlite3_column_int64(stmt, 1)
		legacy_read := sqlite3_column_int64(stmt, 2)
		if user_to_agent_read == 0 {
			user_to_agent_read = legacy_read
		}
		if agent_to_user_read == 0 {
			agent_to_user_read = legacy_read
		}
		fmt.println("DEBUG: message_db_get_last_read_status for", user_id, agent_instance_id, "= [", user_to_agent_read, ",", agent_to_user_read, "]")
		return
	}

	fmt.println("DEBUG: message_db_get_last_read_status for", user_id, agent_instance_id, "= [0,0] (no row)")
	return 0, 0
}

message_db_get_last_read :: proc(user_id, agent_instance_id: string) -> i64 {
	user_to_agent_read, agent_to_user_read := message_db_get_last_read_status(user_id, agent_instance_id)
	if user_to_agent_read >= agent_to_user_read {
		return user_to_agent_read
	}
	return agent_to_user_read
}

message_db_get_last_read_for_direction :: proc(user_id, agent_instance_id, direction: string) -> i64 {
	user_to_agent_read, agent_to_user_read := message_db_get_last_read_status(user_id, agent_instance_id)
	switch direction {
	case "user_to_agent": return user_to_agent_read
	case "agent_to_user": return agent_to_user_read
	}
	return message_db_get_last_read(user_id, agent_instance_id)
}

message_db_fetch_all :: proc(user_id, agent_instance_id: string, direction: string = "", limit: int = 50, cursor: i64 = 0) -> [dynamic]Chat_Message {
	messages := make([dynamic]Chat_Message)
	stmt: sqlite3_stmt = nil

	query: string
	if direction == "user_to_agent" || direction == "agent_to_user" {
		if cursor > 0 {
			query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = ? AND created_unix_ms > ? ORDER BY created_unix_ms ASC LIMIT ?`
		} else {
			query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = ? ORDER BY created_unix_ms ASC LIMIT ?`
		}
	} else {
		if cursor > 0 {
			query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND created_unix_ms > ? ORDER BY created_unix_ms ASC LIMIT ?`
		} else {
			query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? ORDER BY created_unix_ms ASC LIMIT ?`
		}
	}

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_fetch_all: prepare failed:", rc)
		return messages
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)
	
	idx := 3
	if direction == "user_to_agent" || direction == "agent_to_user" {
		sqlite3_bind_text(stmt, i32(idx), cstring(raw_data(direction)), i32(len(direction)), SQLITE_TRANSIENT)
		idx += 1
	}
	if cursor > 0 {
		sqlite3_bind_int64(stmt, i32(idx), cursor)
		idx += 1
	}
	sqlite3_bind_int64(stmt, i32(idx), i64(limit))

	for sqlite3_step(stmt) == SQLITE_ROW {
		msg := Chat_Message{
			message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			user_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			direction = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
			body = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			delivered_unix_ms = sqlite3_column_int64(stmt, 5),
			read_unix_ms = 0,
			delivery_failed_unix_ms = sqlite3_column_int64(stmt, 6),
			delivery_error = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
			created_unix_ms = sqlite3_column_int64(stmt, 8),
		}
		append(&messages, msg)
	}

	return messages
}

message_db_fetch_unread :: proc(user_id, agent_instance_id, direction: string, limit: int = 50, cursor: i64 = 0) -> [dynamic]Chat_Message {
	messages := make([dynamic]Chat_Message)
	stmt: sqlite3_stmt = nil

	user_to_agent_read, agent_to_user_read := message_db_get_last_read_status(user_id, agent_instance_id)
	
	start_time := user_to_agent_read
	if direction == "agent_to_user" do start_time = agent_to_user_read
	if cursor > start_time do start_time = cursor

	fmt.println("DEBUG: message_db_fetch_unread for", user_id, agent_instance_id, "last_read user_to_agent =", user_to_agent_read, "agent_to_user=", agent_to_user_read, "direction=", direction, "limit=", limit, "cursor=", cursor)

	query: string
	if direction == "user_to_agent" {
		query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = 'user_to_agent' AND created_unix_ms > ? ORDER BY created_unix_ms ASC LIMIT ?`
	} else if direction == "agent_to_user" {
		query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = 'agent_to_user' AND created_unix_ms > ? ORDER BY created_unix_ms ASC LIMIT ?`
	} else {
		query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND ((direction = 'user_to_agent' AND created_unix_ms > ?) OR (direction = 'agent_to_user' AND created_unix_ms > ?)) ORDER BY created_unix_ms ASC LIMIT ?`
	}

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_fetch_unread: prepare failed:", rc)
		return messages
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)
	if direction == "" {
		t1 := user_to_agent_read
		if cursor > t1 do t1 = cursor
		t2 := agent_to_user_read
		if cursor > t2 do t2 = cursor
		sqlite3_bind_int64(stmt, 3, t1)
		sqlite3_bind_int64(stmt, 4, t2)
		sqlite3_bind_int64(stmt, 5, i64(limit))
	} else if direction == "user_to_agent" {
		sqlite3_bind_int64(stmt, 3, start_time)
		sqlite3_bind_int64(stmt, 4, i64(limit))
	} else {
		sqlite3_bind_int64(stmt, 3, start_time)
		sqlite3_bind_int64(stmt, 4, i64(limit))
	}
	fmt.println("DEBUG: Query bound with user_id =", user_id, "agent_instance_id =", agent_instance_id)

	for sqlite3_step(stmt) == SQLITE_ROW {
		msg := Chat_Message{
			message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			user_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			direction = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
			body = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			delivered_unix_ms = sqlite3_column_int64(stmt, 5),
			read_unix_ms = 0,
			delivery_failed_unix_ms = sqlite3_column_int64(stmt, 6),
			delivery_error = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
			created_unix_ms = sqlite3_column_int64(stmt, 8),
		}
		fmt.println("DEBUG: Found unread message:", msg.message_id, "created at", msg.created_unix_ms)
		append(&messages, msg)
	}

	fmt.println("DEBUG: message_db_fetch_unread returning", len(messages), "messages")
	return messages
}

message_db_count_unread :: proc(user_id, agent_instance_id: string) -> int {
	stmt: sqlite3_stmt = nil

	user_to_agent_read, agent_to_user_read := message_db_get_last_read_status(user_id, agent_instance_id)

	query := `SELECT COUNT(*) FROM messages WHERE user_id = ? AND agent_instance_id = ? AND ((direction = 'user_to_agent' AND created_unix_ms > ?) OR (direction = 'agent_to_user' AND created_unix_ms > ?))`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_count_unread: prepare failed:", rc)
		return 0
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 3, user_to_agent_read)
	sqlite3_bind_int64(stmt, 4, agent_to_user_read)

	if sqlite3_step(stmt) == SQLITE_ROW {
		return int(sqlite3_column_int64(stmt, 0))
	}

	return 0
}

message_db_count_unread_for_agent :: proc(user_id, agent_instance_id: string) -> int {
	stmt: sqlite3_stmt = nil

	last_read := message_db_get_last_read_for_direction(user_id, agent_instance_id, "user_to_agent")

	query := `SELECT COUNT(*) FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = 'user_to_agent' AND created_unix_ms > ?`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_count_unread_for_agent: prepare failed:", rc)
		return 0
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 3, last_read)

	if sqlite3_step(stmt) == SQLITE_ROW {
		return int(sqlite3_column_int64(stmt, 0))
	}

	return 0
}

message_db_has_unread :: proc(user_id, agent_instance_id, direction: string) -> bool {
	stmt: sqlite3_stmt = nil

	query: string
	if direction == "user_to_agent" || direction == "agent_to_user" {
		query = `SELECT 1 FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = ? AND created_unix_ms > ? LIMIT 1`
	} else {
		query = `SELECT 1 FROM messages WHERE user_id = ? AND agent_instance_id = ? AND ((direction = 'user_to_agent' AND created_unix_ms > ?) OR (direction = 'agent_to_user' AND created_unix_ms > ?)) LIMIT 1`
	}

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_has_unread: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)
	if direction == "user_to_agent" || direction == "agent_to_user" {
		sqlite3_bind_text(stmt, 3, cstring(raw_data(direction)), i32(len(direction)), SQLITE_TRANSIENT)
		last_read := message_db_get_last_read_for_direction(user_id, agent_instance_id, direction)
		sqlite3_bind_int64(stmt, 4, last_read)
	} else {
		user_to_agent_read, agent_to_user_read := message_db_get_last_read_status(user_id, agent_instance_id)
		sqlite3_bind_int64(stmt, 3, user_to_agent_read)
		sqlite3_bind_int64(stmt, 4, agent_to_user_read)
	}

	return sqlite3_step(stmt) == SQLITE_ROW
}

message_db_get_created_time :: proc(message_id: string) -> i64 {
	stmt: sqlite3_stmt = nil

	query := `SELECT created_unix_ms FROM messages WHERE message_id = ?`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_get_created_time: prepare failed:", rc)
		return 0
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(message_id)), i32(len(message_id)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		return sqlite3_column_int64(stmt, 0)
	}

	return 0
}

message_db_get_distinct_agents :: proc(user_id: string) -> [dynamic]string {
	agents := make([dynamic]string)
	stmt: sqlite3_stmt = nil

	query := `SELECT agent_instance_id FROM messages WHERE user_id = ? GROUP BY agent_instance_id ORDER BY MAX(created_unix_ms) DESC`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_get_distinct_agents: prepare failed:", rc)
		return agents
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)

	for sqlite3_step(stmt) == SQLITE_ROW {
		agent := strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		append(&agents, agent)
	}

	return agents
}

message_db_get_max_unread_timestamp :: proc(user_id, agent_instance_id, direction: string) -> i64 {
	stmt: sqlite3_stmt = nil

	query: string
	if direction == "user_to_agent" {
		query = `SELECT MAX(created_unix_ms) FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = 'user_to_agent' AND created_unix_ms > ?`
	} else if direction == "agent_to_user" {
		query = `SELECT MAX(created_unix_ms) FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = 'agent_to_user' AND created_unix_ms > ?`
	} else {
		query = `SELECT MAX(created_unix_ms) FROM messages WHERE user_id = ? AND agent_instance_id = ? AND created_unix_ms > ?`
	}

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_get_max_unread_timestamp: prepare failed:", rc)
		return 0
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)
	if direction == "" {
		last_read := message_db_get_last_read(user_id, agent_instance_id)
		sqlite3_bind_int64(stmt, 3, last_read)
	} else {
		last_read := message_db_get_last_read_for_direction(user_id, agent_instance_id, direction)
		sqlite3_bind_int64(stmt, 3, last_read)
	}

	if sqlite3_step(stmt) == SQLITE_ROW {
		return sqlite3_column_int64(stmt, 0)
	}

	return 0
}

message_db_fetch_cursor_paginated :: proc(user_id, agent_instance_id: string, limit: int = 50, cursor: i64 = 0) -> [dynamic]Chat_Message {
	messages := make([dynamic]Chat_Message)
	stmt: sqlite3_stmt = nil

	query: string
	if cursor > 0 {
		query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND created_unix_ms < ? ORDER BY created_unix_ms DESC LIMIT ?`
	} else {
		query = `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? ORDER BY created_unix_ms DESC LIMIT ?`
	}

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_fetch_cursor_paginated: prepare failed:", rc)
		return messages
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(agent_instance_id)), i32(len(agent_instance_id)), SQLITE_TRANSIENT)

	if cursor > 0 {
		sqlite3_bind_int64(stmt, 3, cursor)
		sqlite3_bind_int64(stmt, 4, i64(limit))
	} else {
		sqlite3_bind_int64(stmt, 3, i64(limit))
	}

	for sqlite3_step(stmt) == SQLITE_ROW {
		msg := Chat_Message{
			message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			user_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			direction = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
			body = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			delivered_unix_ms = sqlite3_column_int64(stmt, 5),
			read_unix_ms = 0,
			delivery_failed_unix_ms = sqlite3_column_int64(stmt, 6),
			delivery_error = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
			created_unix_ms = sqlite3_column_int64(stmt, 8),
		}
		append(&messages, msg)
	}

	return messages
}

message_db_get_message :: proc(message_id: string) -> (Chat_Message, bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE message_id = ?`

	rc := sqlite3_prepare_v2(message_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("message_db_get_message: prepare failed:", rc)
		return Chat_Message{}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(message_id)), i32(len(message_id)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		msg := Chat_Message{
			message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			user_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			direction = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
			body = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			delivered_unix_ms = sqlite3_column_int64(stmt, 5),
			read_unix_ms = 0,
			delivery_failed_unix_ms = sqlite3_column_int64(stmt, 6),
			delivery_error = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
			created_unix_ms = sqlite3_column_int64(stmt, 8),
		}
		return msg, true
	}

	return Chat_Message{}, false
}

message_db_close :: proc() {
	if message_db.db != nil {
		sqlite3_close(message_db.db)
		message_db.db = nil
	}
}
