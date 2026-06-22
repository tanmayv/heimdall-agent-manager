package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

Task_Db_Service :: struct {
	db: sqlite3,
	db_path: string,
}

task_db: Task_Db_Service

task_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/tasks", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/task.db", db_dir)
	task_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &task_db.db)
	if rc != SQLITE_OK {
		fmt.println("task_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !task_db_create_schema() {
		fmt.println("task_db_init: failed to create schema")
		sqlite3_close(task_db.db)
		return false
	}

	fmt.println("task_db_init: database initialized at", db_path)
	return true
}

task_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS task_events (
		event_id TEXT PRIMARY KEY,
		kind TEXT NOT NULL,
		task_id TEXT,
		chain_id TEXT,
		title TEXT,
		description TEXT,
		acceptance_criteria TEXT,
		priority TEXT,
		status TEXT,
		body TEXT,
		comment_id TEXT,
		vote_approved TEXT,
		project_id TEXT,
		agent_instance_id TEXT,
		assignee_agent_instance_id TEXT,
		coordinator_agent_instance_id TEXT,
		depends_on TEXT,
		role TEXT,
		created_by TEXT,
		author_agent_instance_id TEXT,
		created_unix_ms INTEGER NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_task_id ON task_events(task_id);
	CREATE INDEX IF NOT EXISTS idx_chain_id ON task_events(chain_id);
	CREATE INDEX IF NOT EXISTS idx_created_unix_ms ON task_events(created_unix_ms);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(task_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("task_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}

	return true
}

task_db_bind_text :: proc(stmt: sqlite3_stmt, index: int, val: string) {
	sqlite3_bind_text(stmt, c.int(index), cstring(raw_data(val)), i32(len(val)), SQLITE_TRANSIENT)
}

task_db_insert_event :: proc(event: Task_Event) -> bool {
	stmt: sqlite3_stmt = nil

	query := `INSERT INTO task_events (
		event_id, kind, task_id, chain_id, title, description, acceptance_criteria,
		priority, status, body, comment_id, vote_approved, project_id,
		agent_instance_id, assignee_agent_instance_id, coordinator_agent_instance_id,
		depends_on, role, created_by, author_agent_instance_id, created_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("task_db_insert_event: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	kind_str := fmt.tprintf("%v", event.kind)

	task_db_bind_text(stmt, 1, event.event_id)
	task_db_bind_text(stmt, 2, kind_str)
	task_db_bind_text(stmt, 3, event.task_id)
	task_db_bind_text(stmt, 4, event.chain_id)
	task_db_bind_text(stmt, 5, event.title)
	task_db_bind_text(stmt, 6, event.description)
	task_db_bind_text(stmt, 7, event.acceptance_criteria)
	task_db_bind_text(stmt, 8, event.priority)
	task_db_bind_text(stmt, 9, event.status)
	task_db_bind_text(stmt, 10, event.body)
	task_db_bind_text(stmt, 11, event.comment_id)
	task_db_bind_text(stmt, 12, event.vote_approved)
	task_db_bind_text(stmt, 13, event.project_id)
	task_db_bind_text(stmt, 14, event.agent_instance_id)
	task_db_bind_text(stmt, 15, event.assignee_agent_instance_id)
	task_db_bind_text(stmt, 16, event.coordinator_agent_instance_id)
	task_db_bind_text(stmt, 17, event.depends_on)
	task_db_bind_text(stmt, 18, event.role)
	task_db_bind_text(stmt, 19, event.created_by)
	task_db_bind_text(stmt, 20, event.author_agent_instance_id)
	sqlite3_bind_int64(stmt, 21, event.created_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("task_db_insert_event: step failed:", rc)
		return false
	}

	return true
}

task_db_replay_all :: proc() -> bool {
	stmt: sqlite3_stmt = nil
	query := `SELECT 
		event_id, kind, task_id, chain_id, title, description, acceptance_criteria,
		priority, status, body, comment_id, vote_approved, project_id,
		agent_instance_id, assignee_agent_instance_id, coordinator_agent_instance_id,
		depends_on, role, created_by, author_agent_instance_id, created_unix_ms
		FROM task_events ORDER BY created_unix_ms ASC`

	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("task_db_replay_all: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	for sqlite3_step(stmt) == SQLITE_ROW {
		event: Task_Event
		event.event_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		kind_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
		event.kind = task_event_kind_from_string(kind_str)
		event.task_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
		event.chain_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
		event.title = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
		event.description = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
		event.acceptance_criteria = strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
		event.priority = strings.clone_from_cstring(sqlite3_column_text(stmt, 7))
		event.status = strings.clone_from_cstring(sqlite3_column_text(stmt, 8))
		event.body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9))
		event.comment_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 10))
		event.vote_approved = strings.clone_from_cstring(sqlite3_column_text(stmt, 11))
		event.project_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 12))
		event.agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 13))
		event.assignee_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 14))
		event.coordinator_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 15))
		event.depends_on = strings.clone_from_cstring(sqlite3_column_text(stmt, 16))
		event.role = strings.clone_from_cstring(sqlite3_column_text(stmt, 17))
		event.created_by = strings.clone_from_cstring(sqlite3_column_text(stmt, 18))
		event.author_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 19))
		event.created_unix_ms = sqlite3_column_int64(stmt, 20)

		if !task_store_apply_event(event) {
			fmt.println("WARNING: task_db_replay_all failed to apply event", event.event_id)
		}
	}

	return true
}

task_db_execute :: proc(query: string) -> bool {
	errmsg: cstring = nil
	rc := sqlite3_exec(task_db.db, cstring(raw_data(query)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("task_db_execute failed:", rc)
		if errmsg != nil {
			fmt.println("task_db_execute error:", errmsg)
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}
