package sqlite

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"

// `lease next` lookups (spec SCHED 10.1, REQ-SCHED-38/40). Each is one index
// range read bounded by `limit`; none scans the chain's tasks.

@(private = "file")
LOOKUP_TASK_COLS :: "t.task_id, t.chain_id, t.owner_user_id, t.title, t.description, t.publish_state, t.state, t.kind, t.priority, t.attempt_no, t.brief_json, t.blocked_on_json, t.requires_user_approval, t.ready_since, t.bridge_id, t.stage_key, t.stage_index, t.generated_by_json, t.created_at, t.updated_at, t.published_at, t.started_at, t.completed_at, t.workflow_run_id, t.workflow_execution_no"

// Same order as the matcher's sorted tasks: priority, then ready_since (empty
// last), created_at, task_id.
@(private = "file")
LOOKUP_TASK_ORDER :: "lower(t.priority), (t.ready_since = ''), t.ready_since, t.created_at, t.task_id"

@(private = "file")
lookup_prepare :: proc(impl: ^Taskchain_Repo_SQLite, query: string, what: string) -> (sqlite3_stmt, domain.Domain_Error) {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, fmt.tprintf("failed to prepare %s", what))
	}
	return stmt, domain.Domain_Error{}
}

@(private = "file")
lookup_tasks :: proc(impl: ^Taskchain_Repo_SQLite, query: string, what: string, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, agent_id: string, limit: int) -> ([]domain.Task, domain.Domain_Error) {
	stmt, err := lookup_prepare(impl, query, what)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, agent_id)
	bind_text(stmt, 3, string(owner_user_id))
	sqlite3_bind_int64(stmt, 4, i64(max(limit, 1)))
	out := make([dynamic]domain.Task)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, fmt.tprintf("%s failed", what))
		append(&out, task_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

// A review is owed when the agent is listed (task_reviewers), has posted no
// agent verdict on the current attempt (the roles excluded here are the ones
// agent_verdict_role rejects) and is not the agent of the current attempt's
// holder (nobody reviews their own work), and no instance of the agent holds
// a live review lease on it (spec SCHED 10.1 step 2), so leased items can
// never hide an owed one behind the limit.
task_list_owed_reviews_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, agent_id: string, limit: int) -> ([]domain.Task, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	query := "SELECT " + LOOKUP_TASK_COLS + " FROM task_reviewers r JOIN tasks t ON t.task_id = r.task_id" +
		" WHERE r.chain_id = ?1 AND r.agent_id = ?2 AND t.owner_user_id = ?3 AND t.state = 'in_review' AND t.kind <> 'gate'" +
		" AND NOT EXISTS (SELECT 1 FROM task_reviews v WHERE v.task_id = t.task_id AND v.attempt_no = t.attempt_no AND v.reviewer_kind = 'agent' AND v.reviewer_agent_id = r.agent_id" +
		" AND v.role NOT IN ('coordinator', 'user') AND v.role NOT LIKE 'legacy-verify:%')" +
		" AND NOT EXISTS (SELECT 1 FROM task_attempts a JOIN agent_instances i ON i.agent_instance_id = a.holder_instance_id" +
		" WHERE a.task_id = t.task_id AND i.agent_id = r.agent_id AND a.attempt_no = (SELECT MAX(m.attempt_no) FROM task_attempts m WHERE m.task_id = t.task_id))" +
		" AND NOT EXISTS (SELECT 1 FROM task_leases l JOIN agent_instances li ON li.agent_instance_id = l.holder_instance_id" +
		" WHERE l.task_id = t.task_id AND l.kind = 'review' AND l.phase <> 'waiting' AND li.agent_id = r.agent_id)" +
		" ORDER BY " + LOOKUP_TASK_ORDER + " LIMIT ?4;"
	return lookup_tasks(impl, query, "owed review list", chain_id, owner_user_id, agent_id, limit)
}

task_list_assigned_ready_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, agent_id: string, limit: int) -> ([]domain.Task, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	query := "SELECT " + LOOKUP_TASK_COLS + " FROM tasks t" +
		" WHERE t.chain_id = ?1 AND t.assignee_agent_id = ?2 AND t.state = 'ready' AND t.owner_user_id = ?3 AND t.kind <> 'gate'" +
		" ORDER BY (t.attempt_no > 0) DESC, " + LOOKUP_TASK_ORDER + " LIMIT ?4;"
	return lookup_tasks(impl, query, "assigned ready list", chain_id, owner_user_id, agent_id, limit)
}

taskchain_list_dependencies_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := lookup_prepare(impl, "SELECT task_id, depends_on_task_id, chain_id, owner_user_id, created_at FROM task_dependencies WHERE task_id = ? AND owner_user_id = ? ORDER BY created_at ASC;", "dependency list by task")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id))
	bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Dependency)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, dependency_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}
