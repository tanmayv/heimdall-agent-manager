package sqlite

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Search_Repo_SQLite :: struct { conn: ^Conn }

new_search_repository :: proc(impl: ^Search_Repo_SQLite, conn: ^Conn) -> iface.Search_Repository {
	impl.conn = conn
	return iface.Search_Repository{ctx = rawptr(impl), search = search_resources_sqlite}
}

search_resources_sqlite :: proc(ctx: rawptr, query: iface.Search_Query) -> (iface.Search_Result, domain.Domain_Error) {
	impl := (^Search_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return iface.Search_Result{}, domain.domain_error(.Internal_Error, "sqlite search repository is not open")
	_ = query.cursor // Cursor pagination is accepted by the API shape; typeahead returns bounded first-page groups in v1.
	all_hits := make([dynamic]iface.Search_Hit)
	has_more := false
	for resource_type in SEARCH_TYPE_ORDER {
		if !search_type_enabled(query.types_csv, resource_type) do continue
		rows, more, err := run_type_search(impl, resource_type, query)
		if err.code != .None do return iface.Search_Result{}, err
		if more do has_more = true
		for hit in rows do append(&all_hits, hit)
	}
	sort_hits_by_score_desc(all_hits[:])
	if len(all_hits) > query.response_limit do has_more = true
	hits := make([dynamic]iface.Search_Hit)
	for hit, i in all_hits {
		if i >= query.response_limit do break
		append(&hits, hit)
	}
	return iface.Search_Result{hits = hits[:], has_more = has_more}, domain.Domain_Error{}
}

SEARCH_TYPE_ORDER :: [?]string{"conversation", "agent", "agent_instance", "task-chain", "task", "project", "artifact", "memory"}

search_type_enabled :: proc(types_csv, resource_type: string) -> bool {
	trimmed := strings.trim_space(types_csv)
	if trimmed == "" do return true
	parts := strings.split(trimmed, ",")
	defer delete(parts)
	for raw in parts {
		candidate := strings.trim_space(raw)
		if candidate == resource_type do return true
		if candidate == "task_chain" && resource_type == "task-chain" do return true
		if candidate == "all" do return true
	}
	return false
}

run_type_search :: proc(impl: ^Search_Repo_SQLite, resource_type: string, query: iface.Search_Query) -> ([]iface.Search_Hit, bool, domain.Domain_Error) {
	sql := search_sql_for_type(resource_type)
	if sql == "" do return nil, false, domain.Domain_Error{}
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(sql)), -1, &stmt, nil) != SQLITE_OK do return nil, false, domain.domain_error(.Internal_Error, "failed to prepare search query")
	defer sqlite3_finalize(stmt)
	for i in 1..=7 do bind_text(stmt, i, query.q)
	bind_text(stmt, 8, string(query.owner_user_id))
	for i in 9..=11 do bind_text(stmt, i, query.q)
	bind_text(stmt, 12, int_s(query.hard_scan_cap))
	raw_rows := make([dynamic]iface.Search_Hit)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&raw_rows, search_hit_from_stmt(stmt))
	return raw_rows[:], len(raw_rows) >= query.hard_scan_cap, domain.Domain_Error{}
}

search_hit_from_stmt :: proc(stmt: sqlite3_stmt) -> iface.Search_Hit {
	return iface.Search_Hit{resource_type = column_text(stmt, 0), id = column_text(stmt, 1), label = column_text(stmt, 2), sublabel = column_text(stmt, 3), route = column_text(stmt, 4), score = int_v(column_text(stmt, 5))}
}

sort_hits_by_score_desc :: proc(hits: []iface.Search_Hit) {
	for i := 1; i < len(hits); i += 1 {
		current := hits[i]
		j := i - 1
		for j >= 0 && hits[j].score < current.score {
			hits[j + 1] = hits[j]
			j -= 1
		}
		hits[j + 1] = current
	}
}

search_sql_for_type :: proc(resource_type: string) -> string {
	switch resource_type {
	case "conversation":
		return SEARCH_SQL_CONVERSATIONS
	case "agent":
		return SEARCH_SQL_AGENTS
	case "agent_instance":
		return SEARCH_SQL_AGENT_INSTANCES
	case "task-chain":
		return SEARCH_SQL_TASK_CHAINS
	case "task":
		return SEARCH_SQL_TASKS
	case "project":
		return SEARCH_SQL_PROJECTS
	case "artifact":
		return SEARCH_SQL_ARTIFACTS
	case "memory":
		return SEARCH_SQL_MEMORIES
	}
	return ""
}

// Each query selects compact fields only and performs a fixed single statement per resource type.
// Ranking is deterministic: exact > prefix > word-boundary > id prefix > interior, then recency, then id.
SEARCH_SQL_AGENTS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'agent' AS resource_type, agent_id AS id, name AS label,
         'slug ' || slug || ' · ' || state AS sublabel,
         '/agents/' || agent_id AS route, updated_at, owner_user_id,
         slug || ' ' || template_id || ' ' || default_provider || ' ' || default_tier AS aux,
         CASE
           WHEN lower(name) = lower(?) THEN 100
           WHEN lower(agent_id) = lower(?) THEN 98
           WHEN lower(name) LIKE lower(?) || '%' THEN 90
           WHEN lower(name) LIKE '% ' || lower(?) || '%' OR lower(name) LIKE '%-' || lower(?) || '%' OR lower(name) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(agent_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM agents
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_AGENT_INSTANCES :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'agent_instance' AS resource_type, agent_instance_id AS id, agent_id AS label,
         runtime_status || ' · ' || provider || '/' || tier AS sublabel,
         CASE WHEN conversation_id != '' THEN '/conversations/' || conversation_id ELSE '/agents/' || agent_id END AS route,
         updated_at, owner_user_id, bridge_id || ' ' || chain_id || ' ' || project_id || ' ' || conversation_id AS aux,
         CASE
           WHEN lower(agent_id) = lower(?) THEN 100
           WHEN lower(agent_instance_id) = lower(?) THEN 98
           WHEN lower(agent_id) LIKE lower(?) || '%' THEN 90
           WHEN lower(agent_id) LIKE '% ' || lower(?) || '%' OR lower(agent_id) LIKE '%-' || lower(?) || '%' OR lower(agent_id) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(agent_instance_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM agent_instances
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_CONVERSATIONS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'conversation' AS resource_type, conversation_id AS id,
         CASE WHEN title != '' THEN title ELSE agent_id END AS label,
         agent_id || ' · chain ' || chain_id AS sublabel,
         '/conversations/' || conversation_id AS route, updated_at, owner_user_id,
         agent_id || ' ' || agent_instance_id || ' ' || chain_id || ' ' || project_id AS aux,
         CASE
           WHEN lower(CASE WHEN title != '' THEN title ELSE agent_id END) = lower(?) THEN 100
           WHEN lower(conversation_id) = lower(?) THEN 98
           WHEN lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE lower(?) || '%' THEN 90
           WHEN lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE '% ' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE '%-' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(conversation_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM chat_conversations
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_TASK_CHAINS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'task-chain' AS resource_type, chain_id AS id, title AS label,
         kind || ' · ' || status AS sublabel,
         '/chains/' || chain_id AS route, updated_at, owner_user_id,
         kind || ' ' || status || ' ' || coordinator_agent_instance_id AS aux,
         CASE
           WHEN lower(title) = lower(?) THEN 100
           WHEN lower(chain_id) = lower(?) THEN 98
           WHEN lower(title) LIKE lower(?) || '%' THEN 90
           WHEN lower(title) LIKE '% ' || lower(?) || '%' OR lower(title) LIKE '%-' || lower(?) || '%' OR lower(title) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(chain_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM task_chains
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_TASKS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'task' AS resource_type, task_id AS id, title AS label,
         'chain ' || chain_id || ' · ' || status AS sublabel,
         '/chains/' || chain_id || '/tasks/' || task_id AS route, updated_at, owner_user_id,
         chain_id || ' ' || status || ' ' || assignee_ref_json || ' ' || reviewer_refs_json AS aux,
         CASE
           WHEN lower(title) = lower(?) THEN 100
           WHEN lower(task_id) = lower(?) THEN 98
           WHEN lower(title) LIKE lower(?) || '%' THEN 90
           WHEN lower(title) LIKE '% ' || lower(?) || '%' OR lower(title) LIKE '%-' || lower(?) || '%' OR lower(title) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(task_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM tasks
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_PROJECTS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'project' AS resource_type, project_id AS id, name AS label,
         slug || ' · ' || vcs_kind AS sublabel,
         '/settings/projects/' || project_id AS route, updated_at, owner_user_id,
         slug || ' ' || repo_url || ' ' || vcs_kind AS aux,
         CASE
           WHEN lower(name) = lower(?) THEN 100
           WHEN lower(project_id) = lower(?) THEN 98
           WHEN lower(name) LIKE lower(?) || '%' THEN 90
           WHEN lower(name) LIKE '% ' || lower(?) || '%' OR lower(name) LIKE '%-' || lower(?) || '%' OR lower(name) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(project_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM projects
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_ARTIFACTS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'artifact' AS resource_type, artifact_id AS id, name AS label,
         kind || ' · ' || content_type AS sublabel,
         '/library/artifacts/' || artifact_id AS route, updated_at, owner_user_id,
         kind || ' ' || content_type || ' ' || agent_id || ' ' || agent_instance_id || ' ' || chain_id || ' ' || task_id || ' ' || project_id AS aux,
         CASE
           WHEN lower(name) = lower(?) THEN 100
           WHEN lower(artifact_id) = lower(?) THEN 98
           WHEN lower(name) LIKE lower(?) || '%' THEN 90
           WHEN lower(name) LIKE '% ' || lower(?) || '%' OR lower(name) LIKE '%-' || lower(?) || '%' OR lower(name) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(artifact_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM artifacts
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_MEMORIES :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'memory' AS resource_type, memory_id AS id,
         CASE WHEN title != '' THEN title ELSE type END AS label,
         type || ' · ' || status AS sublabel,
         '/settings/memory?memory_id=' || memory_id AS route, updated_at, owner_user_id,
         agent_id || ' ' || type || ' ' || status AS aux,
         CASE
           WHEN lower(CASE WHEN title != '' THEN title ELSE type END) = lower(?) THEN 100
           WHEN lower(memory_id) = lower(?) THEN 98
           WHEN lower(CASE WHEN title != '' THEN title ELSE type END) LIKE lower(?) || '%' THEN 90
           WHEN lower(CASE WHEN title != '' THEN title ELSE type END) LIKE '% ' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE type END) LIKE '%-' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE type END) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(memory_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM memories
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`
