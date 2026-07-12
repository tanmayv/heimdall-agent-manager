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

MEMORY_DB_USER_VERSION :: 2

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

	if !memory_db_create_schema() {
		fmt.println("memory_db_init: failed to create schema")
		sqlite3_close(memory_db.db)
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
		subject_agent TEXT NOT NULL,
		scope TEXT NOT NULL DEFAULT 'personal',
		subject_key TEXT NOT NULL DEFAULT '',
		project_ids TEXT NOT NULL DEFAULT '',
		role_keys TEXT NOT NULL DEFAULT '',
		task_chain_types TEXT NOT NULL DEFAULT '',
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
		updated_unix_ms INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_memories_subject ON memories(subject_agent, status);
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
	if current_version < MEMORY_DB_USER_VERSION {
		if !db_execute(memory_db.db, "BEGIN TRANSACTION;") do return false
		if !db_has_column(memory_db.db, "memories", "scope") {
			if !db_execute(memory_db.db, "ALTER TABLE memories ADD COLUMN scope TEXT NOT NULL DEFAULT 'personal';") {
				_ = db_execute(memory_db.db, "ROLLBACK;")
				return false
			}
		}
		if !db_has_column(memory_db.db, "memories", "subject_key") {
			if !db_execute(memory_db.db, "ALTER TABLE memories ADD COLUMN subject_key TEXT NOT NULL DEFAULT '';") {
				_ = db_execute(memory_db.db, "ROLLBACK;")
				return false
			}
		}
		if !db_has_column(memory_db.db, "memories", "project_ids") {
			if !db_execute(memory_db.db, "ALTER TABLE memories ADD COLUMN project_ids TEXT NOT NULL DEFAULT '';") {
				_ = db_execute(memory_db.db, "ROLLBACK;")
				return false
			}
		}
		if !db_has_column(memory_db.db, "memories", "role_keys") {
			if !db_execute(memory_db.db, "ALTER TABLE memories ADD COLUMN role_keys TEXT NOT NULL DEFAULT '';") {
				_ = db_execute(memory_db.db, "ROLLBACK;")
				return false
			}
		}
		if !db_has_column(memory_db.db, "memories", "task_chain_types") {
			if !db_execute(memory_db.db, "ALTER TABLE memories ADD COLUMN task_chain_types TEXT NOT NULL DEFAULT '';") {
				_ = db_execute(memory_db.db, "ROLLBACK;")
				return false
			}
		}
		if !db_execute(memory_db.db, "CREATE INDEX IF NOT EXISTS idx_memories_scope_subject ON memories(scope, subject_key, status);") {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_execute(memory_db.db, "CREATE INDEX IF NOT EXISTS idx_memories_targets ON memories(status, project_ids, role_keys, task_chain_types);") {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_set_user_version(memory_db.db, MEMORY_DB_USER_VERSION) {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_execute(memory_db.db, "COMMIT;") do return false
	}
	if !db_execute(memory_db.db, "CREATE INDEX IF NOT EXISTS idx_memories_scope_subject ON memories(scope, subject_key, status);") do return false
	return db_execute(memory_db.db, "CREATE INDEX IF NOT EXISTS idx_memories_targets ON memories(status, project_ids, role_keys, task_chain_types);")
}

memory_db_save_record :: proc(rec: contracts.Memory_Record) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO memories (
		memory_id, proposal_id, subject_agent, scope, subject_key, project_ids, role_keys, task_chain_types, type,
		title, body, status, reason, evidence,
		metadata_json, source_task_id, version, created_unix_ms, updated_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

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
	sqlite3_bind_text(stmt, 3, cstring(raw_data(rec.legacy_subject_agent)), i32(len(rec.legacy_subject_agent)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(rec.scope)), i32(len(rec.scope)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(rec.legacy_subject_key)), i32(len(rec.legacy_subject_key)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 6, cstring(raw_data(rec.project_ids)), i32(len(rec.project_ids)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(rec.role_keys)), i32(len(rec.role_keys)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 8, cstring(raw_data(rec.task_chain_types)), i32(len(rec.task_chain_types)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 9, cstring(raw_data(type_str)), i32(len(type_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 10, cstring(raw_data(rec.title)), i32(len(rec.title)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 11, cstring(raw_data(rec.body)), i32(len(rec.body)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 12, cstring(raw_data(status_str)), i32(len(status_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 13, cstring(raw_data(rec.reason)), i32(len(rec.reason)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 14, cstring(raw_data(rec.evidence)), i32(len(rec.evidence)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 15, cstring(raw_data(rec.metadata_json)), i32(len(rec.metadata_json)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 16, cstring(raw_data(rec.source_task_id)), i32(len(rec.source_task_id)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 17, i64(rec.version))
	sqlite3_bind_int64(stmt, 18, rec.created_unix_ms)
	sqlite3_bind_int64(stmt, 19, rec.updated_unix_ms)

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
		memory_id, proposal_id, subject_agent, scope, subject_key, project_ids, role_keys, task_chain_types, type,
		title, body, status, reason, evidence,
		metadata_json, source_task_id, version, created_unix_ms, updated_unix_ms
		FROM memories WHERE memory_id = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_get_record: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(memory_id)), i32(len(memory_id)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		rec = memory_db_parse_record(stmt)
		return rec, true
	}
	return {}, false
}

memory_db_get_proposal :: proc(proposal_id: string) -> (rec: contracts.Memory_Record, found: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT 
		memory_id, proposal_id, subject_agent, scope, subject_key, project_ids, role_keys, task_chain_types, type,
		title, body, status, reason, evidence,
		metadata_json, source_task_id, version, created_unix_ms, updated_unix_ms
		FROM memories WHERE proposal_id = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_get_proposal: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(proposal_id)), i32(len(proposal_id)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		rec = memory_db_parse_record(stmt)
		return rec, true
	}
	return {}, false
}

memory_db_list_records :: proc(scope: string, status: contracts.Memory_Status, include_all: bool) -> []contracts.Memory_Record {
	stmt: sqlite3_stmt = nil

	query_builder := strings.builder_make()
	strings.write_string(&query_builder, `SELECT 
		memory_id, proposal_id, subject_agent, scope, subject_key, project_ids, role_keys, task_chain_types, type,
		title, body, status, reason, evidence,
		metadata_json, source_task_id, version, created_unix_ms, updated_unix_ms
		FROM memories WHERE 1=1`)
	if scope != "" do strings.write_string(&query_builder, " AND scope = ?")
	if !include_all do strings.write_string(&query_builder, " AND status = ?")

	query := strings.to_string(query_builder)
	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_list_records: prepare failed:", rc)
		return nil
	}
	defer sqlite3_finalize(stmt)

	bind_idx := i32(1)
	if scope != "" {
		sqlite3_bind_text(stmt, bind_idx, cstring(raw_data(scope)), i32(len(scope)), SQLITE_TRANSIENT)
		bind_idx += 1
	}
	if !include_all {
		status_str := memory_status_string_service(status)
		sqlite3_bind_text(stmt, bind_idx, cstring(raw_data(status_str)), i32(len(status_str)), SQLITE_TRANSIENT)
		bind_idx += 1
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
		// Fetch other details from the memory record if it is a proposal to match the contract
		if rec, found := memory_db_get_record(ev.memory_id); found {
			ev.legacy_subject_agent = rec.legacy_subject_agent
			ev.scope = rec.scope
			ev.legacy_subject_key = rec.legacy_subject_key
			ev.agent_instance_id = rec.agent_instance_id
			ev.team_id = rec.team_id
			ev.template_key = rec.template_key
			ev.project_ids = rec.project_ids
			ev.role_keys = rec.role_keys
			ev.task_chain_types = rec.task_chain_types
			ev.type = rec.type
			ev.title = rec.title
			ev.body = rec.body
			ev.status = rec.status
			ev.metadata_json = rec.metadata_json
			ev.source_task_id = rec.source_task_id
			ev.version = rec.version
		}
		append(&result, ev)
	}
	return result[:]
}

// Archive all other active expertise for the same canonical target bucket when a new one is approved
memory_db_archive_active_expertise :: proc(rec: contracts.Memory_Record, keep_memory_id: string, at_unix_ms: i64) -> bool {
	records := memory_db_list_records(rec.scope, .Active, false)
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

// --- Helper Parsers ---

memory_db_parse_record :: proc(stmt: sqlite3_stmt) -> contracts.Memory_Record {
	type_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 8))
	status_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 11))

	type_val, _ := memory_type_parse(type_str)
	status_val, _ := memory_status_parse(status_str)
	memory_id := strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
	proposal_id := strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
	subject_agent := strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
	scope := strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
	subject_key := strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
	project_ids := strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
	role_keys := strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
	task_chain_types := strings.clone_from_cstring(sqlite3_column_text(stmt, 7))
	title := strings.clone_from_cstring(sqlite3_column_text(stmt, 9))
	body := strings.clone_from_cstring(sqlite3_column_text(stmt, 10))
	reason := strings.clone_from_cstring(sqlite3_column_text(stmt, 12))
	evidence := strings.clone_from_cstring(sqlite3_column_text(stmt, 13))
	metadata_json := strings.clone_from_cstring(sqlite3_column_text(stmt, 14))
	source_task_id := strings.clone_from_cstring(sqlite3_column_text(stmt, 15))

	delete(type_str)
	delete(status_str)

	rec := contracts.Memory_Record{
		memory_id = memory_id,
		proposal_id = proposal_id,
		legacy_subject_agent = subject_agent,
		scope = scope,
		legacy_subject_key = subject_key,
		project_ids = project_ids,
		role_keys = role_keys,
		task_chain_types = task_chain_types,
		type = type_val,
		title = title,
		body = body,
		status = status_val,
		reason = reason,
		evidence = evidence,
		metadata_json = metadata_json,
		source_task_id = source_task_id,
		version = int(sqlite3_column_int64(stmt, 16)),
		created_unix_ms = sqlite3_column_int64(stmt, 17),
		updated_unix_ms = sqlite3_column_int64(stmt, 18),
	}
	memory_record_normalize_legacy(&rec)
	return rec
}

memory_record_free :: proc(rec: contracts.Memory_Record) {
	delete(rec.memory_id)
	delete(rec.proposal_id)
	delete(rec.legacy_subject_agent)
	delete(rec.scope)
	delete(rec.legacy_subject_key)
	delete(rec.agent_instance_id)
	delete(rec.team_id)
	delete(rec.template_key)
	delete(rec.project_ids)
	delete(rec.role_keys)
	delete(rec.task_chain_types)
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
	delete(ev.legacy_subject_agent)
	delete(ev.scope)
	delete(ev.legacy_subject_key)
	delete(ev.agent_instance_id)
	delete(ev.team_id)
	delete(ev.template_key)
	delete(ev.project_ids)
	delete(ev.role_keys)
	delete(ev.task_chain_types)
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
