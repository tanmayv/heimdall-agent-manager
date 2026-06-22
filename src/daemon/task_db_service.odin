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

	if !task_db_run_migrations() {
		fmt.println("task_db_init: failed to run migrations")
		sqlite3_close(task_db.db)
		return false
	}

	fmt.println("task_db_init: relational database initialized at", db_path)
	return true
}

task_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS tasks (
		task_id TEXT PRIMARY KEY,
		chain_id TEXT NOT NULL,
		title TEXT NOT NULL,
		description TEXT NOT NULL,
		acceptance_criteria TEXT NOT NULL,
		priority TEXT NOT NULL,
		status TEXT NOT NULL,
		assignee_agent_instance_id TEXT NOT NULL,
		coordinator_agent_instance_id TEXT NOT NULL,
		depends_on TEXT NOT NULL,
		created_by TEXT NOT NULL,
		created_at_unix_ms INTEGER NOT NULL,
		updated_at_unix_ms INTEGER NOT NULL
	);

	CREATE TABLE IF NOT EXISTS task_chains (
		chain_id TEXT PRIMARY KEY,
		project_id TEXT NOT NULL,
		title TEXT NOT NULL,
		description TEXT NOT NULL,
		status TEXT NOT NULL,
		coordinator_agent_instance_id TEXT NOT NULL,
		final_summary TEXT NOT NULL,
		created_at_unix_ms INTEGER NOT NULL,
		completed_at_unix_ms INTEGER NOT NULL,
		archive_pending INTEGER NOT NULL DEFAULT 0,
		archived INTEGER NOT NULL DEFAULT 0,
		evaluation TEXT NOT NULL DEFAULT 'unreviewed',
		last_audit_at_unix_ms INTEGER NOT NULL DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS task_comments (
		comment_id TEXT PRIMARY KEY,
		task_id TEXT NOT NULL,
		chain_id TEXT NOT NULL,
		body TEXT NOT NULL,
		author_agent_instance_id TEXT NOT NULL,
		resolved INTEGER NOT NULL DEFAULT 0,
		created_unix_ms INTEGER NOT NULL
	);

	CREATE TABLE IF NOT EXISTS task_lgtm_votes (
		task_id TEXT NOT NULL,
		reviewer_agent_instance_id TEXT NOT NULL,
		chain_id TEXT NOT NULL,
		approved INTEGER NOT NULL DEFAULT 0,
		role TEXT NOT NULL,
		comment TEXT NOT NULL,
		created_unix_ms INTEGER NOT NULL,
		PRIMARY KEY (task_id, reviewer_agent_instance_id)
	);

	CREATE TABLE IF NOT EXISTS task_participants (
		task_id TEXT NOT NULL,
		agent_instance_id TEXT NOT NULL,
		chain_id TEXT NOT NULL,
		role TEXT NOT NULL,
		PRIMARY KEY (task_id, agent_instance_id, role)
	);

	CREATE INDEX IF NOT EXISTS idx_tasks_chain ON tasks(chain_id);
	CREATE INDEX IF NOT EXISTS idx_comments_task ON task_comments(task_id);
	CREATE INDEX IF NOT EXISTS idx_votes_task ON task_lgtm_votes(task_id);
	CREATE INDEX IF NOT EXISTS idx_participants_task ON task_participants(task_id);
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
	ptr := cstring(raw_data(val))
	if ptr == nil {
		sqlite3_bind_text(stmt, c.int(index), "", 0, SQLITE_TRANSIENT)
	} else {
		sqlite3_bind_text(stmt, c.int(index), ptr, i32(len(val)), SQLITE_TRANSIENT)
	}
}

task_db_save_task :: proc(state: Task_State) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO tasks (
		task_id, chain_id, title, description, acceptance_criteria, priority, status,
		assignee_agent_instance_id, coordinator_agent_instance_id, depends_on, created_by,
		created_at_unix_ms, updated_at_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("task_db_save_task: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	task_db_bind_text(stmt, 1, state.task_id)
	task_db_bind_text(stmt, 2, state.chain_id)
	task_db_bind_text(stmt, 3, state.title)
	task_db_bind_text(stmt, 4, state.description)
	task_db_bind_text(stmt, 5, state.acceptance_criteria)
	task_db_bind_text(stmt, 6, state.priority)
	task_db_bind_text(stmt, 7, state.status)
	task_db_bind_text(stmt, 8, state.assignee_agent_instance_id)
	task_db_bind_text(stmt, 9, state.coordinator_agent_instance_id)
	task_db_bind_text(stmt, 10, state.depends_on)
	task_db_bind_text(stmt, 11, state.created_by)
	sqlite3_bind_int64(stmt, 12, state.created_at_unix_ms)
	sqlite3_bind_int64(stmt, 13, state.updated_at_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("task_db_save_task: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return false
	}
	return true
}

task_db_save_chain :: proc(chain: Task_Chain_State) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO task_chains (
		chain_id, project_id, title, description, status, coordinator_agent_instance_id,
		final_summary, created_at_unix_ms, completed_at_unix_ms, archive_pending, archived, evaluation, last_audit_at_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("task_db_save_chain: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	task_db_bind_text(stmt, 1, chain.chain_id)
	task_db_bind_text(stmt, 2, chain.project_id)
	task_db_bind_text(stmt, 3, chain.title)
	task_db_bind_text(stmt, 4, chain.description)
	task_db_bind_text(stmt, 5, chain.status)
	task_db_bind_text(stmt, 6, chain.coordinator_agent_instance_id)
	task_db_bind_text(stmt, 7, chain.final_summary)
	sqlite3_bind_int64(stmt, 8, chain.created_at_unix_ms)
	sqlite3_bind_int64(stmt, 9, chain.completed_at_unix_ms)
	sqlite3_bind_int64(stmt, 10, 1 if chain.archive_pending else 0)
	sqlite3_bind_int64(stmt, 11, 1 if chain.archived else 0)
	task_db_bind_text(stmt, 12, chain.evaluation)
	sqlite3_bind_int64(stmt, 13, chain.last_audit_at_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("task_db_save_chain: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return false
	}
	return true
}

task_db_save_comment :: proc(comment: Task_Comment_State) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO task_comments (
		comment_id, task_id, chain_id, body, author_agent_instance_id, resolved, created_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("task_db_save_comment: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	task_db_bind_text(stmt, 1, comment.comment_id)
	task_db_bind_text(stmt, 2, comment.task_id)
	task_db_bind_text(stmt, 3, comment.chain_id)
	task_db_bind_text(stmt, 4, comment.body)
	task_db_bind_text(stmt, 5, comment.author_agent_instance_id)
	sqlite3_bind_int64(stmt, 6, 1 if comment.resolved else 0)
	sqlite3_bind_int64(stmt, 7, comment.created_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("task_db_save_comment: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return false
	}
	return true
}

task_db_save_vote :: proc(vote: Task_LGTM_Vote_State) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO task_lgtm_votes (
		task_id, reviewer_agent_instance_id, chain_id, approved, role, comment, created_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("task_db_save_vote: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	task_db_bind_text(stmt, 1, vote.task_id)
	task_db_bind_text(stmt, 2, vote.reviewer_agent_instance_id)
	task_db_bind_text(stmt, 3, vote.chain_id)
	sqlite3_bind_int64(stmt, 4, 1 if vote.approved else 0)
	task_db_bind_text(stmt, 5, vote.role)
	task_db_bind_text(stmt, 6, vote.comment)
	sqlite3_bind_int64(stmt, 7, vote.created_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("task_db_save_vote: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return false
	}
	return true
}

task_db_save_participant :: proc(part: Task_Participant) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO task_participants (
		task_id, agent_instance_id, chain_id, role
	) VALUES (?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("task_db_save_participant: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	task_db_bind_text(stmt, 1, part.task_id)
	task_db_bind_text(stmt, 2, part.agent_instance_id)
	task_db_bind_text(stmt, 3, part.chain_id)
	task_db_bind_text(stmt, 4, part.role)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("task_db_save_participant: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return false
	}
	return true
}

task_db_load_all :: proc() -> bool {
	task_projection_reset()

	// 1. Load task_chains
	{
		stmt: sqlite3_stmt = nil
		query := `SELECT 
			chain_id, project_id, title, description, status, coordinator_agent_instance_id,
			final_summary, created_at_unix_ms, completed_at_unix_ms, archive_pending, archived, evaluation, last_audit_at_unix_ms
			FROM task_chains`
		rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
		if rc != SQLITE_OK {
			fmt.println("task_db_load_all: prepare chains failed:", rc)
			return false
		}
		defer sqlite3_finalize(stmt)

		for sqlite3_step(stmt) == SQLITE_ROW {
			if task_chain_count >= TASK_MAX_CHAINS do break
			c := &task_chains[task_chain_count]
			c.chain_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
			c.project_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
			c.title = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
			c.description = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
			c.status = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
			c.coordinator_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
			c.final_summary = strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
			c.created_at_unix_ms = sqlite3_column_int64(stmt, 7)
			c.completed_at_unix_ms = sqlite3_column_int64(stmt, 8)
			c.archive_pending = sqlite3_column_int64(stmt, 9) != 0
			c.archived = sqlite3_column_int64(stmt, 10) != 0
			c.evaluation = strings.clone_from_cstring(sqlite3_column_text(stmt, 11))
			c.last_audit_at_unix_ms = sqlite3_column_int64(stmt, 12)
			task_chain_count += 1
		}
	}

	// 2. Load tasks (task_states)
	{
		stmt: sqlite3_stmt = nil
		query := `SELECT 
			task_id, chain_id, title, description, acceptance_criteria, priority, status,
			assignee_agent_instance_id, coordinator_agent_instance_id, depends_on, created_by,
			created_at_unix_ms, updated_at_unix_ms
			FROM tasks`
		rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
		if rc != SQLITE_OK {
			fmt.println("task_db_load_all: prepare tasks failed:", rc)
			return false
		}
		defer sqlite3_finalize(stmt)

		for sqlite3_step(stmt) == SQLITE_ROW {
			if task_state_count >= TASK_MAX_TASKS do break
			t := &task_states[task_state_count]
			t.task_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
			t.chain_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
			t.title = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
			t.description = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
			t.acceptance_criteria = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
			t.priority = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
			t.status = strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
			t.assignee_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7))
			t.coordinator_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8))
			t.depends_on = strings.clone_from_cstring(sqlite3_column_text(stmt, 9))
			t.created_by = strings.clone_from_cstring(sqlite3_column_text(stmt, 10))
			t.created_at_unix_ms = sqlite3_column_int64(stmt, 11)
			t.updated_at_unix_ms = sqlite3_column_int64(stmt, 12)
			task_state_count += 1
		}
	}

	// 3. Load task_comments
	{
		stmt: sqlite3_stmt = nil
		query := `SELECT 
			comment_id, task_id, chain_id, body, author_agent_instance_id, resolved, created_unix_ms
			FROM task_comments`
		rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
		if rc != SQLITE_OK {
			fmt.println("task_db_load_all: prepare comments failed:", rc)
			return false
		}
		defer sqlite3_finalize(stmt)

		for sqlite3_step(stmt) == SQLITE_ROW {
			if task_comment_count >= TASK_MAX_COMMENTS do break
			c := &task_comments[task_comment_count]
			c.comment_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
			c.task_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
			c.chain_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
			c.body = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
			c.author_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
			c.resolved = sqlite3_column_int64(stmt, 5) != 0
			c.created_unix_ms = sqlite3_column_int64(stmt, 6)
			task_comment_count += 1
		}
	}

	// 4. Load task_lgtm_votes
	{
		stmt: sqlite3_stmt = nil
		query := `SELECT 
			task_id, reviewer_agent_instance_id, chain_id, approved, role, comment, created_unix_ms
			FROM task_lgtm_votes`
		rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
		if rc != SQLITE_OK {
			fmt.println("task_db_load_all: prepare votes failed:", rc)
			return false
		}
		defer sqlite3_finalize(stmt)

		for sqlite3_step(stmt) == SQLITE_ROW {
			if task_lgtm_vote_count >= TASK_MAX_VOTES do break
			v := &task_lgtm_votes[task_lgtm_vote_count]
			v.task_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
			v.reviewer_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
			v.chain_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
			v.approved = sqlite3_column_int64(stmt, 3) != 0
			v.role = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
			v.comment = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
			v.created_unix_ms = sqlite3_column_int64(stmt, 6)
			task_lgtm_vote_count += 1
		}
	}

	// 5. Load task_participants
	{
		stmt: sqlite3_stmt = nil
		query := `SELECT 
			task_id, agent_instance_id, chain_id, role
			FROM task_participants`
		rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
		if rc != SQLITE_OK {
			fmt.println("task_db_load_all: prepare participants failed:", rc)
			return false
		}
		defer sqlite3_finalize(stmt)

		for sqlite3_step(stmt) == SQLITE_ROW {
			if task_participant_count >= TASK_MAX_PARTICIPANTS do break
			p := &task_participants[task_participant_count]
			p.task_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
			p.agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
			p.chain_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
			p.role = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
			task_participant_count += 1
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

TASK_DB_SCHEMA_VERSION :: 2 // Version 1: evaluation, Version 2: last_audit_at_unix_ms

task_db_run_migrations :: proc() -> bool {
	current_version := db_get_user_version(task_db.db)
	
	if current_version < 1 {
		fmt.println("DB: Migrating task.db to version 1 (adding evaluation)...")
		if !db_execute(task_db.db, "BEGIN TRANSACTION;") do return false
		
		if !db_has_column(task_db.db, "task_chains", "evaluation") {
			migrate_query := "ALTER TABLE task_chains ADD COLUMN evaluation TEXT NOT NULL DEFAULT 'unreviewed';"
			if !db_execute(task_db.db, migrate_query) {
				_ = db_execute(task_db.db, "ROLLBACK;")
				return false
			}
		} else {
			fmt.println("DB: Column 'evaluation' already exists in 'task_chains', skipping ALTER TABLE.")
		}
		
		if !db_set_user_version(task_db.db, 1) {
			_ = db_execute(task_db.db, "ROLLBACK;")
			return false
		}
		
		if !db_execute(task_db.db, "COMMIT;") do return false
		fmt.println("DB: Migrated task.db to version 1 successfully.")
	}
	
	current_version = db_get_user_version(task_db.db)
	
	if current_version < TASK_DB_SCHEMA_VERSION {
		fmt.println("DB: Migrating task.db to version 2 (adding last_audit_at_unix_ms)...")
		if !db_execute(task_db.db, "BEGIN TRANSACTION;") do return false
		
		if !db_has_column(task_db.db, "task_chains", "last_audit_at_unix_ms") {
			migrate_query := "ALTER TABLE task_chains ADD COLUMN last_audit_at_unix_ms INTEGER NOT NULL DEFAULT 0;"
			if !db_execute(task_db.db, migrate_query) {
				_ = db_execute(task_db.db, "ROLLBACK;")
				return false
			}
		} else {
			fmt.println("DB: Column 'last_audit_at_unix_ms' already exists in 'task_chains', skipping ALTER TABLE.")
		}
		
		if !db_set_user_version(task_db.db, 2) {
			_ = db_execute(task_db.db, "ROLLBACK;")
			return false
		}
		
		if !db_execute(task_db.db, "COMMIT;") do return false
		fmt.println("DB: Migrated task.db to version 2 successfully.")
	}
	
	return true
}
