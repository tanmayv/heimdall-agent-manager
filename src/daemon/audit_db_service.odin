package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c"

foreign import sqlite3_lib "system:sqlite3"

@(default_calling_convention="c")
foreign sqlite3_lib {
	sqlite3_changes :: proc(db: sqlite3) -> c.int ---
}

Audit_Run :: struct {
	audit_id:             string,
	time_range:           string,
	status:               string, // "started", "completed", "failed"
	target_chains_json:   string, // JSON array of chain IDs
	started_at_unix_ms:   i64,
	completed_at_unix_ms: i64,
	failure_reason:       string,
}

Audit_Memory_Action :: struct {
	action_id:          string,
	audit_id:           string,
	memory_id:          string,
	proposal_id:        string,
	status:             string, // "proposed", "approved", "rejected"
	created_at_unix_ms: i64,
}

Audit_Db_Service :: struct {
	db:      sqlite3,
	db_path: string,
}

audit_db: Audit_Db_Service

audit_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/audits", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/audits.db", db_dir)
	audit_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &audit_db.db)
	if rc != SQLITE_OK {
		fmt.println("audit_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !audit_db_create_schema() {
		fmt.println("audit_db_init: failed to create schema")
		sqlite3_close(audit_db.db)
		return false
	}

	// Crash Recovery: transition any stuck 'started' audits to 'failed'
	audit_db_recover_crashes()

	fmt.println("audit_db_init: database initialized at", db_path)
	return true
}

audit_db_close :: proc() {
	if audit_db.db != nil {
		sqlite3_close(audit_db.db)
		audit_db.db = nil
	}
}

audit_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS audit_runs (
		audit_id TEXT PRIMARY KEY,
		time_range TEXT NOT NULL,
		status TEXT NOT NULL,
		target_chains_json TEXT NOT NULL,
		started_at_unix_ms INTEGER NOT NULL,
		completed_at_unix_ms INTEGER NOT NULL,
		failure_reason TEXT
	);
	CREATE INDEX IF NOT EXISTS idx_audit_runs_status ON audit_runs(status);

	CREATE TABLE IF NOT EXISTS audit_memory_actions (
		action_id TEXT PRIMARY KEY,
		audit_id TEXT NOT NULL,
		memory_id TEXT NOT NULL,
		proposal_id TEXT NOT NULL,
		status TEXT NOT NULL,
		created_at_unix_ms INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_audit_actions_run ON audit_memory_actions(audit_id);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(audit_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("audit_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

audit_db_create_run :: proc(run: Audit_Run) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO audit_runs (
		audit_id, time_range, status, target_chains_json, started_at_unix_ms, completed_at_unix_ms, failure_reason
	) VALUES (?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(audit_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("audit_db_create_run: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(run.audit_id)), i32(len(run.audit_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(run.time_range)), i32(len(run.time_range)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(run.status)), i32(len(run.status)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(run.target_chains_json)), i32(len(run.target_chains_json)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 5, run.started_at_unix_ms)
	sqlite3_bind_int64(stmt, 6, run.completed_at_unix_ms)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(run.failure_reason)), i32(len(run.failure_reason)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("audit_db_create_run: step failed:", rc)
		return false
	}
	return true
}

audit_db_update_run :: proc(run: Audit_Run) -> bool {
	stmt: sqlite3_stmt = nil
	query := `UPDATE audit_runs SET 
		status = ?, completed_at_unix_ms = ?, failure_reason = ?
		WHERE audit_id = ?`

	rc := sqlite3_prepare_v2(audit_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("audit_db_update_run: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(run.status)), i32(len(run.status)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 2, run.completed_at_unix_ms)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(run.failure_reason)), i32(len(run.failure_reason)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(run.audit_id)), i32(len(run.audit_id)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("audit_db_update_run: step failed:", rc)
		return false
	}
	return true
}

// Checks if an audit is already running (status = "started")
audit_db_get_active_run :: proc() -> (run: Audit_Run, found: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT 
		audit_id, time_range, status, target_chains_json, started_at_unix_ms, completed_at_unix_ms, failure_reason
		FROM audit_runs WHERE status = 'started' LIMIT 1`

	rc := sqlite3_prepare_v2(audit_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("audit_db_get_active_run: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	if sqlite3_step(stmt) == SQLITE_ROW {
		run = audit_db_parse_run(stmt)
		return run, true
	}
	return {}, false
}

audit_db_log_action :: proc(action: Audit_Memory_Action) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO audit_memory_actions (
		action_id, audit_id, memory_id, proposal_id, status, created_at_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(audit_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("audit_db_log_action: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(action.action_id)), i32(len(action.action_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(action.audit_id)), i32(len(action.audit_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(action.memory_id)), i32(len(action.memory_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(action.proposal_id)), i32(len(action.proposal_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(action.status)), i32(len(action.status)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 6, action.created_at_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("audit_db_log_action: step failed:", rc)
		return false
	}
	return true
}

// Crash Recovery: transition stuck 'started' audits to 'failed' on startup
audit_db_recover_crashes :: proc() {
	stmt: sqlite3_stmt = nil
	query := `UPDATE audit_runs 
		SET status = 'failed', completed_at_unix_ms = ?, failure_reason = 'daemon_restarted_during_audit' 
		WHERE status = 'started'`

	rc := sqlite3_prepare_v2(audit_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("audit_db_recover_crashes: prepare failed:", rc)
		return
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, now_unix_ms())

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("audit_db_recover_crashes: step failed:", rc)
	} else {
		// Get number of modified rows to print diagnostics
		changes := sqlite3_changes(audit_db.db)
		if changes > 0 {
			fmt.printfln("audit_db_recover_crashes: successfully recovered %d stuck audit runs and marked them as failed.", changes)
		}
	}
}

// --- Helper Parsers ---

audit_db_parse_run :: proc(stmt: sqlite3_stmt) -> Audit_Run {
	return Audit_Run{
		audit_id             = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		time_range           = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		status               = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		target_chains_json   = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		started_at_unix_ms   = sqlite3_column_int64(stmt, 4),
		completed_at_unix_ms = sqlite3_column_int64(stmt, 5),
		failure_reason       = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
	}
}

audit_run_free :: proc(run: Audit_Run) {
	delete(run.audit_id)
	delete(run.time_range)
	delete(run.status)
	delete(run.target_chains_json)
	delete(run.failure_reason)
}

audit_action_free :: proc(action: Audit_Memory_Action) {
	delete(action.action_id)
	delete(action.audit_id)
	delete(action.memory_id)
	delete(action.proposal_id)
	delete(action.status)
}
