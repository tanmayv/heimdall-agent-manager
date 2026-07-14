package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

Memory_Db_Service :: struct {
	db:      sqlite3,
	db_path: string,
}

memory_db: Memory_Db_Service

MEMORY_DB_USER_VERSION :: 4 // teams-v2: +target_agent_id (memory db is recreated on bump)

memory_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/memory", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/memory.db", db_dir)
	memory_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &memory_db.db)
	if rc != SQLITE_OK {
		fmt.println("memory_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !memory_db_run_migrations() {
		fmt.println("memory_db_init: failed to run migrations")
		sqlite3_close(memory_db.db)
		return false
	}

	fmt.println("memory_db_init: database initialized at", db_path)
	return true
}

memory_db_close :: proc() {
	if memory_db.db != nil {
		sqlite3_close(memory_db.db)
		memory_db.db = nil
	}
}

memory_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS memories (
		memory_id TEXT PRIMARY KEY,
		proposal_id TEXT NOT NULL,
		target_team_kind TEXT NOT NULL DEFAULT '',
		target_role TEXT NOT NULL DEFAULT '',
		target_project_id TEXT NOT NULL DEFAULT '',
		type TEXT NOT NULL,
		title TEXT NOT NULL,
		body TEXT NOT NULL,
		status TEXT NOT NULL,
		reason TEXT,
		evidence TEXT,
		metadata_json TEXT,
		source_task_id TEXT,
		version INTEGER NOT NULL,
		created_unix_ms INTEGER NOT NULL,
		updated_unix_ms INTEGER NOT NULL,
		target_agent_id TEXT NOT NULL DEFAULT ''
	);
	CREATE INDEX IF NOT EXISTS idx_memories_status ON memories(status);
	CREATE INDEX IF NOT EXISTS idx_memories_targets ON memories(status, target_team_kind, target_role, target_project_id);
	CREATE INDEX IF NOT EXISTS idx_memories_agent ON memories(status, target_agent_id);
	CREATE INDEX IF NOT EXISTS idx_memories_proposal ON memories(proposal_id);

	CREATE TABLE IF NOT EXISTS memory_events (
		event_id TEXT PRIMARY KEY,
		memory_id TEXT NOT NULL,
		proposal_id TEXT NOT NULL,
		kind TEXT NOT NULL,
		reason TEXT,
		evidence TEXT,
		author TEXT NOT NULL,
		created_unix_ms INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_memory_events_memory ON memory_events(memory_id);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(memory_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("memory_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

memory_db_run_migrations :: proc() -> bool {
	current_version := db_get_user_version(memory_db.db)
	if current_version != MEMORY_DB_USER_VERSION {
		if !db_execute(memory_db.db, "BEGIN TRANSACTION;") do return false
		if !db_execute(memory_db.db, "DROP TABLE IF EXISTS memory_events;") {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_execute(memory_db.db, "DROP TABLE IF EXISTS memories;") {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !memory_db_create_schema() {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_set_user_version(memory_db.db, MEMORY_DB_USER_VERSION) {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_execute(memory_db.db, "COMMIT;") do return false
		return true
	}
	return memory_db_create_schema()
}

memory_db_save_record :: proc(rec: contracts.Memory_Record) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO memories (
		memory_id, proposal_id, target_team_kind, target_role, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_save_record: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	type_str := memory_type_string_service(rec.type)
	status_str := memory_status_string_service(rec.status)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(rec.memory_id)), i32(len(rec.memory_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(rec.proposal_id)), i32(len(rec.proposal_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(rec.target_team_kind)), i32(len(rec.target_team_kind)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(rec.target_role)), i32(len(rec.target_role)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(rec.target_project_id)), i32(len(rec.target_project_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 6, cstring(raw_data(type_str)), i32(len(type_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(rec.title)), i32(len(rec.title)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 8, cstring(raw_data(rec.body)), i32(len(rec.body)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 9, cstring(raw_data(status_str)), i32(len(status_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 10, cstring(raw_data(rec.reason)), i32(len(rec.reason)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 11, cstring(raw_data(rec.evidence)), i32(len(rec.evidence)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 12, cstring(raw_data(rec.metadata_json)), i32(len(rec.metadata_json)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 13, cstring(raw_data(rec.source_task_id)), i32(len(rec.source_task_id)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 14, i64(rec.version))
	sqlite3_bind_int64(stmt, 15, rec.created_unix_ms)
	sqlite3_bind_int64(stmt, 16, rec.updated_unix_ms)
	sqlite3_bind_text(stmt, 17, cstring(raw_data(rec.target_agent_id)), i32(len(rec.target_agent_id)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("memory_db_save_record: step failed:", rc)
		return false
	}
	return true
}

memory_db_save_event :: proc(ev: contracts.Memory_Event) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO memory_events (
		event_id, memory_id, proposal_id, kind, reason, evidence, author, created_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_save_event: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	kind_str := memory_event_kind_string_db(ev.kind)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(ev.event_id)), i32(len(ev.event_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(ev.memory_id)), i32(len(ev.memory_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(ev.proposal_id)), i32(len(ev.proposal_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(kind_str)), i32(len(kind_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(ev.reason)), i32(len(ev.reason)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 6, cstring(raw_data(ev.evidence)), i32(len(ev.evidence)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(ev.author)), i32(len(ev.author)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 8, ev.created_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("memory_db_save_event: step failed:", rc)
		return false
	}
	return true
}

memory_db_get_record :: proc(memory_id: string) -> (rec: contracts.Memory_Record, found: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		memory_id, proposal_id, target_team_kind, target_role, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories WHERE memory_id = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_get_record: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(memory_id)), i32(len(memory_id)), SQLITE_TRANSIENT)
	if sqlite3_step(stmt) == SQLITE_ROW {
		return memory_db_parse_record(stmt), true
	}
	return {}, false
}

memory_db_get_proposal :: proc(proposal_id: string) -> (rec: contracts.Memory_Record, found: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		memory_id, proposal_id, target_team_kind, target_role, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories WHERE proposal_id = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_get_proposal: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(proposal_id)), i32(len(proposal_id)), SQLITE_TRANSIENT)
	if sqlite3_step(stmt) == SQLITE_ROW {
		return memory_db_parse_record(stmt), true
	}
	return {}, false
}

memory_db_list_records :: proc(status: contracts.Memory_Status, include_all: bool) -> []contracts.Memory_Record {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		memory_id, proposal_id, target_team_kind, target_role, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories`
	if !include_all do query = `SELECT
		memory_id, proposal_id, target_team_kind, target_role, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories WHERE status = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_list_records: prepare failed:", rc)
		return nil
	}
	defer sqlite3_finalize(stmt)

	if !include_all {
		status_str := memory_status_string_service(status)
		sqlite3_bind_text(stmt, 1, cstring(raw_data(status_str)), i32(len(status_str)), SQLITE_TRANSIENT)
	}

	result := make([dynamic]contracts.Memory_Record, context.allocator)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&result, memory_db_parse_record(stmt))
	}
	return result[:]
}

memory_db_history :: proc(memory_id: string) -> []contracts.Memory_Event {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		event_id, memory_id, proposal_id, kind, reason, evidence, author, created_unix_ms
		FROM memory_events WHERE memory_id = ? ORDER BY created_unix_ms ASC`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_history: prepare failed:", rc)
		return nil
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(memory_id)), i32(len(memory_id)), SQLITE_TRANSIENT)

	result := make([dynamic]contracts.Memory_Event, context.allocator)
	for sqlite3_step(stmt) == SQLITE_ROW {
		ev := contracts.Memory_Event{
			event_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			memory_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			proposal_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			kind = memory_event_kind_from_string_db(strings.clone_from_cstring(sqlite3_column_text(stmt, 3))),
			reason = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			evidence = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
			author = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
			created_unix_ms = sqlite3_column_int64(stmt, 7),
		}
		if rec, found := memory_db_get_record(ev.memory_id); found {
			ev.target_agent_id = strings.clone(rec.target_agent_id)
			ev.target_team_kind = strings.clone(rec.target_team_kind)
			ev.target_role = strings.clone(rec.target_role)
			ev.target_project_id = strings.clone(rec.target_project_id)
			ev.type = rec.type
			ev.title = strings.clone(rec.title)
			ev.body = strings.clone(rec.body)
			ev.status = rec.status
			ev.metadata_json = strings.clone(rec.metadata_json)
			ev.source_task_id = strings.clone(rec.source_task_id)
			ev.version = rec.version
			memory_record_free(rec)
		}
		append(&result, ev)
	}
	return result[:]
}

memory_db_archive_active_expertise :: proc(rec: contracts.Memory_Record, keep_memory_id: string, at_unix_ms: i64) -> bool {
	records := memory_db_list_records(.Active, false)
	defer {
		for other in records do memory_record_free(other)
		delete(records)
	}
	bucket := memory_expertise_bucket_key(rec)
	defer delete(bucket)
	for other in records {
		if other.memory_id == keep_memory_id do continue
		if other.type != .Expertise do continue
		other_bucket := memory_expertise_bucket_key(other)
		matches := other_bucket == bucket
		delete(other_bucket)
		if !matches do continue
		if found, ok := memory_db_get_record(other.memory_id); ok {
			found.status = .Archived
			found.version += 1
			found.updated_unix_ms = at_unix_ms
			if !memory_db_save_record(found) {
				memory_record_free(found)
				return false
			}
			memory_record_free(found)
		}
	}
	return true
}

memory_db_parse_record :: proc(stmt: sqlite3_stmt) -> contracts.Memory_Record {
	type_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
	status_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 8))
	type_val, _ := memory_type_parse(type_str)
	status_val, _ := memory_status_parse(status_str)
	delete(type_str)
	delete(status_str)

	return contracts.Memory_Record{
		memory_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		proposal_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		target_team_kind = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		target_role = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		target_project_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		type = type_val,
		title = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		status = status_val,
		reason = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		evidence = strings.clone_from_cstring(sqlite3_column_text(stmt, 10)),
		metadata_json = strings.clone_from_cstring(sqlite3_column_text(stmt, 11)),
		source_task_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 12)),
		version = int(sqlite3_column_int64(stmt, 13)),
		created_unix_ms = sqlite3_column_int64(stmt, 14),
		updated_unix_ms = sqlite3_column_int64(stmt, 15),
		target_agent_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 16)),
	}
}

memory_record_free :: proc(rec: contracts.Memory_Record) {
	delete(rec.memory_id)
	delete(rec.proposal_id)
	delete(rec.target_agent_id)
	delete(rec.target_team_kind)
	delete(rec.target_role)
	delete(rec.target_project_id)
	delete(rec.title)
	delete(rec.body)
	delete(rec.reason)
	delete(rec.evidence)
	delete(rec.metadata_json)
	delete(rec.source_task_id)
}

memory_event_free :: proc(ev: contracts.Memory_Event) {
	delete(ev.event_id)
	delete(ev.memory_id)
	delete(ev.proposal_id)
	delete(ev.target_agent_id)
	delete(ev.target_team_kind)
	delete(ev.target_role)
	delete(ev.target_project_id)
	delete(ev.title)
	delete(ev.body)
	delete(ev.reason)
	delete(ev.evidence)
	delete(ev.metadata_json)
	delete(ev.author)
	delete(ev.source_task_id)
}

memory_event_kind_string_db :: proc(kind: contracts.Memory_Event_Kind) -> string {
	switch kind {
	case .Memory_Proposed: return "Memory_Proposed"
	case .Memory_Approved: return "Memory_Approved"
	case .Memory_Rejected: return "Memory_Rejected"
	case .Memory_Archived: return "Memory_Archived"
	}
	return "Memory_Proposed"
}

memory_event_kind_from_string_db :: proc(value: string) -> contracts.Memory_Event_Kind {
	switch value {
	case "Memory_Approved": return .Memory_Approved
	case "Memory_Rejected": return .Memory_Rejected
	case "Memory_Archived": return .Memory_Archived
	case: return .Memory_Proposed
	}
}
