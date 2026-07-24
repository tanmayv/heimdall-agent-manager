package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Taskchain_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_taskchain_repository :: proc(impl: ^Taskchain_Repo_SQLite, conn: ^Conn) -> iface.Taskchain_Repository {
	impl.conn = conn
	return iface.Taskchain_Repository{
		ctx = rawptr(impl),
		get_chain = taskchain_get_chain_sqlite,
		list_chains_by_owner = taskchain_list_chains_by_owner_sqlite,
		save_chain = taskchain_save_chain_sqlite,
		save_task = task_save_sqlite,
		get_task = task_get_sqlite,
		list_tasks_by_chain = task_list_by_chain_sqlite,
		save_comment = task_comment_save_sqlite,
		list_comments_by_task = task_comment_list_by_task_sqlite,
	}
}

taskchain_get_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT chain_id, owner_user_id, title, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at FROM task_chains WHERE chain_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "failed to prepare chain lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "task chain not found")
	return chain_from_stmt(stmt), true, domain.Domain_Error{}
}

taskchain_list_chains_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT chain_id, owner_user_id, title, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at FROM task_chains WHERE owner_user_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare chain list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Task_Chain)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, chain_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_save_chain_sqlite :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_chains (chain_id, owner_user_id, title, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(chain_id) DO UPDATE SET title=excluded.title, publish_state=excluded.publish_state, status=excluded.status, kind=excluded.kind, coordinator_agent_instance_id=excluded.coordinator_agent_instance_id, default_reviewer_refs_json=excluded.default_reviewer_refs_json, updated_at=excluded.updated_at, published_at=excluded.published_at, completed_at=excluded.completed_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "failed to prepare chain save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain.chain_id)); bind_text(stmt, 2, string(chain.owner_user_id)); bind_text(stmt, 3, chain.title); bind_text(stmt, 4, publish_state_string(chain.publish_state)); bind_text(stmt, 5, chain_status_string(chain.status)); bind_text(stmt, 6, chain.kind); bind_text(stmt, 7, chain.coordinator_agent_instance_id); bind_text(stmt, 8, json_or_empty_array(chain.default_reviewer_refs_json)); bind_text(stmt, 9, chain.created_at); bind_text(stmt, 10, chain.updated_at); bind_text(stmt, 11, chain.published_at); bind_text(stmt, 12, chain.completed_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "task chain could not be saved")
	return chain, true, domain.Domain_Error{}
}

task_save_sqlite :: proc(ctx: rawptr, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO tasks (task_id, chain_id, owner_user_id, title, publish_state, status, assignee_ref_json, reviewer_refs_json, created_at, updated_at, published_at, started_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id) DO UPDATE SET title=excluded.title, publish_state=excluded.publish_state, status=excluded.status, assignee_ref_json=excluded.assignee_ref_json, reviewer_refs_json=excluded.reviewer_refs_json, updated_at=excluded.updated_at, published_at=excluded.published_at, started_at=excluded.started_at, completed_at=excluded.completed_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task{}, false, domain.domain_error(.Internal_Error, "failed to prepare task save")
	defer sqlite3_finalize(stmt)
	bind_task(stmt, task)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task{}, false, domain.domain_error(.Conflict, "task could not be saved")
	return task, true, domain.Domain_Error{}
}

task_get_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT task_id, chain_id, owner_user_id, title, publish_state, status, assignee_ref_json, reviewer_refs_json, created_at, updated_at, published_at, started_at, completed_at FROM tasks WHERE task_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task{}, false, domain.domain_error(.Internal_Error, "failed to prepare task lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task{}, false, domain.domain_error(.Not_Found, "task not found")
	return task_from_stmt(stmt), true, domain.Domain_Error{}
}

task_list_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT task_id, chain_id, owner_user_id, title, publish_state, status, assignee_ref_json, reviewer_refs_json, created_at, updated_at, published_at, started_at, completed_at FROM tasks WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare task list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, task_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

task_comment_save_sqlite :: proc(ctx: rawptr, comment: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_comments (comment_id, task_id, chain_id, owner_user_id, author_agent_instance_id, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(comment_id) DO UPDATE SET body=excluded.body, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Comment{}, false, domain.domain_error(.Internal_Error, "failed to prepare task comment save")
	defer sqlite3_finalize(stmt)
	bind_comment(stmt, comment)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Comment{}, false, domain.domain_error(.Conflict, "task comment could not be saved")
	return comment, true, domain.Domain_Error{}
}

task_comment_list_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT comment_id, task_id, chain_id, owner_user_id, author_agent_instance_id, body, created_at, updated_at FROM task_comments WHERE task_id = ? AND owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare task comment list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Comment)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, task_comment_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

bind_task :: proc(stmt: sqlite3_stmt, task: domain.Task) {
	bind_text(stmt, 1, string(task.task_id)); bind_text(stmt, 2, string(task.chain_id)); bind_text(stmt, 3, string(task.owner_user_id)); bind_text(stmt, 4, task.title); bind_text(stmt, 5, publish_state_string(task.publish_state)); bind_text(stmt, 6, task_status_string(task.status)); bind_text(stmt, 7, json_or_empty_object(task.assignee_ref_json)); bind_text(stmt, 8, json_or_empty_array(task.reviewer_refs_json)); bind_text(stmt, 9, task.created_at); bind_text(stmt, 10, task.updated_at); bind_text(stmt, 11, task.published_at); bind_text(stmt, 12, task.started_at); bind_text(stmt, 13, task.completed_at)
}

bind_comment :: proc(stmt: sqlite3_stmt, comment: domain.Task_Comment) {
	bind_text(stmt, 1, comment.comment_id); bind_text(stmt, 2, string(comment.task_id)); bind_text(stmt, 3, string(comment.chain_id)); bind_text(stmt, 4, string(comment.owner_user_id)); bind_text(stmt, 5, comment.author_agent_instance_id); bind_text(stmt, 6, comment.body); bind_text(stmt, 7, comment.created_at); bind_text(stmt, 8, comment.updated_at)
}

chain_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Chain {
	return domain.Task_Chain{chain_id = domain.Task_Chain_ID(column_text(stmt, 0)), owner_user_id = domain.User_ID(column_text(stmt, 1)), title = column_text(stmt, 2), publish_state = publish_state_from_string(column_text(stmt, 3)), status = chain_status_from_string(column_text(stmt, 4)), kind = column_text(stmt, 5), coordinator_agent_instance_id = column_text(stmt, 6), default_reviewer_refs_json = column_text(stmt, 7), created_at = column_text(stmt, 8), updated_at = column_text(stmt, 9), published_at = column_text(stmt, 10), completed_at = column_text(stmt, 11)}
}

task_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task {
	return domain.Task{task_id = domain.Task_ID(column_text(stmt, 0)), chain_id = domain.Task_Chain_ID(column_text(stmt, 1)), owner_user_id = domain.User_ID(column_text(stmt, 2)), title = column_text(stmt, 3), publish_state = publish_state_from_string(column_text(stmt, 4)), status = task_status_from_string(column_text(stmt, 5)), assignee_ref_json = column_text(stmt, 6), reviewer_refs_json = column_text(stmt, 7), created_at = column_text(stmt, 8), updated_at = column_text(stmt, 9), published_at = column_text(stmt, 10), started_at = column_text(stmt, 11), completed_at = column_text(stmt, 12)}
}

task_comment_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Comment {
	return domain.Task_Comment{comment_id = column_text(stmt, 0), task_id = domain.Task_ID(column_text(stmt, 1)), chain_id = domain.Task_Chain_ID(column_text(stmt, 2)), owner_user_id = domain.User_ID(column_text(stmt, 3)), author_agent_instance_id = column_text(stmt, 4), body = column_text(stmt, 5), created_at = column_text(stmt, 6), updated_at = column_text(stmt, 7)}
}

publish_state_string :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
publish_state_from_string :: proc(state: string) -> domain.Publish_State { if state == "published" do return .Published; return .Draft }
chain_status_string :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; return "active" }
chain_status_from_string :: proc(status: string) -> domain.Task_Chain_Status { if status == "completed" do return .Completed; if status == "cancelled" do return .Cancelled; return .Active }
task_status_string :: proc(status: domain.Task_Status) -> string { switch status { case .Assigned: return "assigned"; case .In_Progress: return "in_progress"; case .In_Validation: return "in_validation"; case .Validated_Good: return "validated_good"; case .Validated_Not_Good: return "validated_not_good"; case .Paused: return "paused"; case .Completed: return "completed"; case .Cancelled: return "cancelled" }; return "assigned" }
task_status_from_string :: proc(status: string) -> domain.Task_Status { if status == "in_progress" do return .In_Progress; if status == "in_validation" do return .In_Validation; if status == "validated_good" do return .Validated_Good; if status == "validated_not_good" do return .Validated_Not_Good; if status == "paused" do return .Paused; if status == "completed" do return .Completed; if status == "cancelled" do return .Cancelled; return .Assigned }
json_or_empty_array :: proc(value: string) -> string { if value == "" do return "[]"; return value }
json_or_empty_object :: proc(value: string) -> string { if value == "" do return "{}"; return value }
