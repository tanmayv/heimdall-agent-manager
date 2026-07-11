package main

import "core:fmt"
import "core:os"
import "core:strings"

Scheduled_Prompt_Record :: struct {
	scheduled_prompt_id: string,
	agent_instance_id:   string,
	prompt:              string,
	schedule_type:       string,
	schedule_expr:       string,
	status:              string,
	last_run_unix_ms:    i64,
	next_run_unix_ms:    i64,
	created_at_unix_ms:  i64,
	updated_at_unix_ms:  i64,
}

Scheduled_Prompt_Db_Service :: struct {
	db:      sqlite3,
	db_path: string,
}

scheduled_prompt_db: Scheduled_Prompt_Db_Service

scheduled_prompt_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/scheduled_prompts", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/scheduled_prompt.db", db_dir)
	scheduled_prompt_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &scheduled_prompt_db.db)
	if rc != SQLITE_OK {
		fmt.println("scheduled_prompt_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !scheduled_prompt_db_create_schema() {
		fmt.println("scheduled_prompt_db_init: failed to create schema")
		sqlite3_close(scheduled_prompt_db.db)
		return false
	}

	fmt.println("scheduled_prompt_db_init: database initialized at", db_path)
	return true
}

scheduled_prompt_db_close :: proc() {
	if scheduled_prompt_db.db != nil {
		sqlite3_close(scheduled_prompt_db.db)
		scheduled_prompt_db.db = nil
	}
}

scheduled_prompt_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS scheduled_prompts (
		scheduled_prompt_id TEXT PRIMARY KEY,
		agent_instance_id TEXT NOT NULL,
		prompt TEXT NOT NULL,
		schedule_type TEXT NOT NULL,
		schedule_expr TEXT NOT NULL,
		status TEXT NOT NULL,
		last_run_unix_ms INTEGER NOT NULL DEFAULT 0,
		next_run_unix_ms INTEGER NOT NULL DEFAULT 0,
		created_at_unix_ms INTEGER NOT NULL,
		updated_at_unix_ms INTEGER NOT NULL
	);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(scheduled_prompt_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("scheduled_prompt_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

scheduled_prompt_db_save :: proc(rec: Scheduled_Prompt_Record) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO scheduled_prompts 
		(scheduled_prompt_id, agent_instance_id, prompt, schedule_type, schedule_expr, status, last_run_unix_ms, next_run_unix_ms, created_at_unix_ms, updated_at_unix_ms) 
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(scheduled_prompt_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("scheduled_prompt_db_save: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(rec.scheduled_prompt_id)), i32(len(rec.scheduled_prompt_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(rec.agent_instance_id)), i32(len(rec.agent_instance_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(rec.prompt)), i32(len(rec.prompt)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(rec.schedule_type)), i32(len(rec.schedule_type)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(rec.schedule_expr)), i32(len(rec.schedule_expr)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 6, cstring(raw_data(rec.status)), i32(len(rec.status)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 7, rec.last_run_unix_ms)
	sqlite3_bind_int64(stmt, 8, rec.next_run_unix_ms)
	sqlite3_bind_int64(stmt, 9, rec.created_at_unix_ms)
	sqlite3_bind_int64(stmt, 10, rec.updated_at_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("scheduled_prompt_db_save: step failed:", rc)
		return false
	}
	return true
}

scheduled_prompt_db_get :: proc(id: string) -> (rec: Scheduled_Prompt_Record, ok: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT scheduled_prompt_id, agent_instance_id, prompt, schedule_type, schedule_expr, status, last_run_unix_ms, next_run_unix_ms, created_at_unix_ms, updated_at_unix_ms FROM scheduled_prompts WHERE scheduled_prompt_id = ?`

	rc := sqlite3_prepare_v2(scheduled_prompt_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("scheduled_prompt_db_get: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(id)), i32(len(id)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		rec.scheduled_prompt_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		rec.agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
		rec.prompt = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
		rec.schedule_type = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
		rec.schedule_expr = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
		rec.status = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
		rec.last_run_unix_ms = sqlite3_column_int64(stmt, 6)
		rec.next_run_unix_ms = sqlite3_column_int64(stmt, 7)
		rec.created_at_unix_ms = sqlite3_column_int64(stmt, 8)
		rec.updated_at_unix_ms = sqlite3_column_int64(stmt, 9)
		return rec, true
	}
	return {}, false
}

scheduled_prompt_db_delete :: proc(id: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := `DELETE FROM scheduled_prompts WHERE scheduled_prompt_id = ?`

	rc := sqlite3_prepare_v2(scheduled_prompt_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("scheduled_prompt_db_delete: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(id)), i32(len(id)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("scheduled_prompt_db_delete: step failed:", rc)
		return false
	}
	return true
}

scheduled_prompt_db_load_all :: proc() -> (recs: [dynamic]Scheduled_Prompt_Record, ok: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT scheduled_prompt_id, agent_instance_id, prompt, schedule_type, schedule_expr, status, last_run_unix_ms, next_run_unix_ms, created_at_unix_ms, updated_at_unix_ms FROM scheduled_prompts`

	rc := sqlite3_prepare_v2(scheduled_prompt_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("scheduled_prompt_db_load_all: prepare failed:", rc)
		return nil, false
	}
	defer sqlite3_finalize(stmt)

	recs = make([dynamic]Scheduled_Prompt_Record)
	for sqlite3_step(stmt) == SQLITE_ROW {
		rec := Scheduled_Prompt_Record{
			scheduled_prompt_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			agent_instance_id   = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			prompt              = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			schedule_type       = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
			schedule_expr       = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			status              = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
			last_run_unix_ms    = sqlite3_column_int64(stmt, 6),
			next_run_unix_ms    = sqlite3_column_int64(stmt, 7),
			created_at_unix_ms  = sqlite3_column_int64(stmt, 8),
			updated_at_unix_ms  = sqlite3_column_int64(stmt, 9),
		}
		append(&recs, rec)
	}
	return recs, true
}
