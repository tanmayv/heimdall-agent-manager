package main

import "core:fmt"
import "core:os"
import "core:strings"
import sqlite "core:sys/sqlite"

Message_Db_Service :: struct {
	db: sqlite.sqlite3,
	db_path: string,
}

message_db: Message_Db_Service

message_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/chat", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/messages.db", db_dir)
	message_db.db_path = strings.clone(db_path)

	rc := sqlite.open(strings.clone(db_path), &message_db.db)
	if rc != sqlite.OK {
		fmt.println("message_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !message_db_create_schema() {
		fmt.println("message_db_init: failed to create schema")
		sqlite.close(message_db.db)
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
		PRIMARY KEY (user_id, agent_instance_id)
	);

	CREATE INDEX IF NOT EXISTS idx_user_agent ON messages(user_id, agent_instance_id);
	CREATE INDEX IF NOT EXISTS idx_created ON messages(created_unix_ms);
	CREATE INDEX IF NOT EXISTS idx_unread ON messages(user_id, agent_instance_id, created_unix_ms);
	`

	errmsg: cstring = nil
	rc := sqlite.exec(message_db.db, strings.clone(schema), nil, nil, &errmsg)
	if rc != sqlite.OK {
		fmt.println("message_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite.free(errmsg)
		}
		return false
	}

	return true
}

message_db_insert :: proc(msg: Chat_Message) -> bool {
	stmt: [^]sqlite.stmt = nil

	query := fmt.tprintf(
		`INSERT INTO messages
		(message_id, user_id, agent_instance_id, direction, body,
		 delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_insert: prepare failed:", rc)
		return false
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(msg.message_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 2, strings.clone(msg.user_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 3, strings.clone(msg.agent_instance_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 4, strings.clone(msg.direction), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 5, strings.clone(msg.body), -1, sqlite.TRANSIENT)
	sqlite.bind_int64(stmt, 6, msg.delivered_unix_ms)
	sqlite.bind_int64(stmt, 7, msg.delivery_failed_unix_ms)
	sqlite.bind_text(stmt, 8, strings.clone(msg.delivery_error), -1, sqlite.TRANSIENT)
	sqlite.bind_int64(stmt, 9, msg.created_unix_ms)

	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {
		fmt.println("message_db_insert: step failed:", rc)
		return false
	}

	return true
}

message_db_mark_conversation_read :: proc(user_id, agent_instance_id: string, read_unix_ms: i64) -> bool {
	stmt: [^]sqlite.stmt = nil

	query := `INSERT OR REPLACE INTO conversation_read_status (user_id, agent_instance_id, last_read_unix_ms) VALUES (?, ?, ?)`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_mark_conversation_read: prepare failed:", rc)
		return false
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(user_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 2, strings.clone(agent_instance_id), -1, sqlite.TRANSIENT)
	sqlite.bind_int64(stmt, 3, read_unix_ms)

	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {
		fmt.println("message_db_mark_conversation_read: step failed:", rc)
		return false
	}

	return true
}

message_db_update_delivered :: proc(message_id: string, delivered_unix_ms: i64) -> bool {
	stmt: [^]sqlite.stmt = nil

	query := `UPDATE messages SET delivered_unix_ms = ? WHERE message_id = ?`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_update_delivered: prepare failed:", rc)
		return false
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_int64(stmt, 1, delivered_unix_ms)
	sqlite.bind_text(stmt, 2, strings.clone(message_id), -1, sqlite.TRANSIENT)

	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {
		fmt.println("message_db_update_delivered: step failed:", rc)
		return false
	}

	return true
}

message_db_update_delivery_failed :: proc(message_id: string, failed_unix_ms: i64, error: string) -> bool {
	stmt: [^]sqlite.stmt = nil

	query := `UPDATE messages SET delivery_failed_unix_ms = ?, delivery_error = ? WHERE message_id = ?`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_update_delivery_failed: prepare failed:", rc)
		return false
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_int64(stmt, 1, failed_unix_ms)
	sqlite.bind_text(stmt, 2, strings.clone(error), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 3, strings.clone(message_id), -1, sqlite.TRANSIENT)

	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {
		fmt.println("message_db_update_delivery_failed: step failed:", rc)
		return false
	}

	return true
}

message_db_get_last_read :: proc(user_id, agent_instance_id: string) -> i64 {
	stmt: [^]sqlite.stmt = nil

	query := `SELECT last_read_unix_ms FROM conversation_read_status WHERE user_id = ? AND agent_instance_id = ?`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_get_last_read: prepare failed:", rc)
		return 0
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(user_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 2, strings.clone(agent_instance_id), -1, sqlite.TRANSIENT)

	if sqlite.step(stmt) == sqlite.ROW {
		return sqlite.column_int64(stmt, 0)
	}

	return 0
}

message_db_fetch_all :: proc(user_id, agent_instance_id: string) -> [dynamic]Chat_Message {
	messages := make([dynamic]Chat_Message)
	stmt: [^]sqlite.stmt = nil

	query := `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? ORDER BY created_unix_ms ASC`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_fetch_all: prepare failed:", rc)
		return messages
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(user_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 2, strings.clone(agent_instance_id), -1, sqlite.TRANSIENT)

	for sqlite.step(stmt) == sqlite.ROW {
		msg := Chat_Message{
			message_id = strings.clone(cstring(sqlite.column_text(stmt, 0))),
			user_id = strings.clone(cstring(sqlite.column_text(stmt, 1))),
			agent_instance_id = strings.clone(cstring(sqlite.column_text(stmt, 2))),
			direction = strings.clone(cstring(sqlite.column_text(stmt, 3))),
			body = strings.clone(cstring(sqlite.column_text(stmt, 4))),
			delivered_unix_ms = sqlite.column_int64(stmt, 5),
			read_unix_ms = 0,
			delivery_failed_unix_ms = sqlite.column_int64(stmt, 6),
			delivery_error = strings.clone(cstring(sqlite.column_text(stmt, 7))),
			created_unix_ms = sqlite.column_int64(stmt, 8),
		}
		append(&messages, msg)
	}

	return messages
}

message_db_fetch_unread :: proc(user_id, agent_instance_id: string) -> [dynamic]Chat_Message {
	messages := make([dynamic]Chat_Message)
	stmt: [^]sqlite.stmt = nil

	last_read := message_db_get_last_read(user_id, agent_instance_id)

	query := `SELECT message_id, user_id, agent_instance_id, direction, body, delivered_unix_ms, delivery_failed_unix_ms, delivery_error, created_unix_ms FROM messages WHERE user_id = ? AND agent_instance_id = ? AND created_unix_ms > ? ORDER BY created_unix_ms ASC`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_fetch_unread: prepare failed:", rc)
		return messages
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(user_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 2, strings.clone(agent_instance_id), -1, sqlite.TRANSIENT)
	sqlite.bind_int64(stmt, 3, last_read)

	for sqlite.step(stmt) == sqlite.ROW {
		msg := Chat_Message{
			message_id = strings.clone(cstring(sqlite.column_text(stmt, 0))),
			user_id = strings.clone(cstring(sqlite.column_text(stmt, 1))),
			agent_instance_id = strings.clone(cstring(sqlite.column_text(stmt, 2))),
			direction = strings.clone(cstring(sqlite.column_text(stmt, 3))),
			body = strings.clone(cstring(sqlite.column_text(stmt, 4))),
			delivered_unix_ms = sqlite.column_int64(stmt, 5),
			read_unix_ms = 0,
			delivery_failed_unix_ms = sqlite.column_int64(stmt, 6),
			delivery_error = strings.clone(cstring(sqlite.column_text(stmt, 7))),
			created_unix_ms = sqlite.column_int64(stmt, 8),
		}
		append(&messages, msg)
	}

	return messages
}

message_db_count_unread :: proc(user_id, agent_instance_id: string) -> int {
	stmt: [^]sqlite.stmt = nil

	last_read := message_db_get_last_read(user_id, agent_instance_id)

	query := `SELECT COUNT(*) FROM messages WHERE user_id = ? AND agent_instance_id = ? AND created_unix_ms > ?`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_count_unread: prepare failed:", rc)
		return 0
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(user_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 2, strings.clone(agent_instance_id), -1, sqlite.TRANSIENT)
	sqlite.bind_int64(stmt, 3, last_read)

	if sqlite.step(stmt) == sqlite.ROW {
		return int(sqlite.column_int64(stmt, 0))
	}

	return 0
}

message_db_has_unread :: proc(user_id, agent_instance_id, direction: string) -> bool {
	stmt: [^]sqlite.stmt = nil

	last_read := message_db_get_last_read(user_id, agent_instance_id)

	query := `SELECT 1 FROM messages WHERE user_id = ? AND agent_instance_id = ? AND direction = ? AND created_unix_ms > ? LIMIT 1`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_has_unread: prepare failed:", rc)
		return false
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(user_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 2, strings.clone(agent_instance_id), -1, sqlite.TRANSIENT)
	sqlite.bind_text(stmt, 3, strings.clone(direction), -1, sqlite.TRANSIENT)
	sqlite.bind_int64(stmt, 4, last_read)

	return sqlite.step(stmt) == sqlite.ROW
}

message_db_get_created_time :: proc(message_id: string) -> i64 {
	stmt: [^]sqlite.stmt = nil

	query := `SELECT created_unix_ms FROM messages WHERE message_id = ?`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_get_created_time: prepare failed:", rc)
		return 0
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(message_id), -1, sqlite.TRANSIENT)

	if sqlite.step(stmt) == sqlite.ROW {
		return sqlite.column_int64(stmt, 0)
	}

	return 0
}

message_db_get_distinct_agents :: proc(user_id: string) -> [dynamic]string {
	agents := make([dynamic]string)
	stmt: [^]sqlite.stmt = nil

	query := `SELECT DISTINCT agent_instance_id FROM messages WHERE user_id = ? ORDER BY MAX(created_unix_ms) DESC`

	rc := sqlite.prepare_v2(message_db.db, strings.clone(query), -1, &stmt, nil)
	if rc != sqlite.OK {
		fmt.println("message_db_get_distinct_agents: prepare failed:", rc)
		return agents
	}
	defer sqlite.finalize(stmt)

	sqlite.bind_text(stmt, 1, strings.clone(user_id), -1, sqlite.TRANSIENT)

	for sqlite.step(stmt) == sqlite.ROW {
		agent := strings.clone(cstring(sqlite.column_text(stmt, 0)))
		append(&agents, agent)
	}

	return agents
}

message_db_close :: proc() {
	if message_db.db != nil {
		sqlite.close(message_db.db)
		message_db.db = nil
	}
}
