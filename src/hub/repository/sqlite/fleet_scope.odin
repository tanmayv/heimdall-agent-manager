package sqlite

import "core:strings"
import domain "odin_test:hub/domain"

// Single classifier for starts and F2 target enumeration. The instance lookup,
// provenance and evidence EXISTS queries are all indexed; no Hub/Bridge RPC.
// An action can message an existing task agent; that does not change its known
// origin. Action-target history only makes unknown legacy provenance ambiguous.
FLEET_SCOPE_EXCLUDED_SQL :: "(ai.kind!='agent' OR EXISTS(SELECT 1 FROM bots b WHERE b.agent_instance_id=ai.agent_instance_id) OR (COALESCE(fs.scope,'')='' AND EXISTS(SELECT 1 FROM action_runs r WHERE r.target_instance_id=ai.agent_instance_id AND r.target_instance_id!='')) OR COALESCE(fs.scope,'')='excluded')"
// Fixed indexes are shared by the classifier and setter, whose SELECT uses ?5
// before this predicate. Anonymous placeholders there would become ?6..?9.
FLEET_SCOPE_ROW_SQL :: " FROM agent_instances ai LEFT JOIN instance_fleet_scope fs ON fs.agent_instance_id=ai.agent_instance_id WHERE ai.agent_instance_id=?1 AND ai.owner_user_id=?2 AND ai.bridge_id=?3 AND ai.agent_id=?4"

fleet_scope_get_sqlite :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Fleet_Scope, domain.Domain_Error) {
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	q := "SELECT CASE WHEN " + FLEET_SCOPE_EXCLUDED_SQL + " THEN 2 WHEN fs.scope='chain' THEN 1 WHEN fs.scope='manual' THEN 3 ELSE EXISTS(SELECT 1 FROM task_chain_members m JOIN task_chains c ON c.chain_id=m.chain_id AND c.owner_user_id=m.owner_user_id WHERE m.agent_instance_id=ai.agent_instance_id AND m.owner_user_id=ai.owner_user_id AND m.chain_id=ai.chain_id AND m.role IN ('coordinator','worker','reviewer') AND (EXISTS(SELECT 1 FROM tasks t WHERE t.chain_id=c.chain_id AND t.owner_user_id=c.owner_user_id) OR EXISTS(SELECT 1 FROM workflow_runs w WHERE w.chain_id=c.chain_id AND w.owner_user_id=c.owner_user_id) OR EXISTS(SELECT 1 FROM task_leases l WHERE l.holder_instance_id=ai.agent_instance_id AND l.chain_id=c.chain_id AND l.owner_user_id=c.owner_user_id) OR EXISTS(SELECT 1 FROM task_chain_fleets f WHERE f.task_chain_id=c.chain_id) OR EXISTS(SELECT 1 FROM task_chain_directories d WHERE d.chain_id=c.chain_id AND d.owner_user_id=c.owner_user_id))) END" + FLEET_SCOPE_ROW_SQL + ";"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return .Unknown, fleet_db_error()
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, inst.agent_instance_id); bind_text(stmt, 2, string(inst.owner_user_id)); bind_text(stmt, 3, inst.bridge_id); bind_text(stmt, 4, inst.agent_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return .Unknown, domain.domain_error(.Not_Found, "instance not found")
	if rc != SQLITE_ROW do return .Unknown, fleet_db_error()
	return domain.Fleet_Scope(sqlite3_column_int64(stmt, 0)), {}
}

fleet_scope_set_sqlite :: proc(ctx: rawptr, inst: domain.Agent_Instance, scope: string) -> domain.Domain_Error {
	if scope != "chain" && scope != "manual" && scope != "excluded" do return domain.domain_error(.Validation_Failed, "invalid Fleet scope")
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	// Trusted promotion may change manual->chain, but never bot/action/excluded.
	q := "INSERT INTO instance_fleet_scope(agent_instance_id,scope) SELECT ai.agent_instance_id,?5" + FLEET_SCOPE_ROW_SQL + " AND NOT " + FLEET_SCOPE_EXCLUDED_SQL + " ON CONFLICT(agent_instance_id) DO UPDATE SET scope=excluded.scope;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return fleet_db_error()
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, inst.agent_instance_id); bind_text(stmt, 2, string(inst.owner_user_id)); bind_text(stmt, 3, inst.bridge_id); bind_text(stmt, 4, inst.agent_id); bind_text(stmt, 5, scope)
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return fleet_db_error()
	if changed == 0 && scope == "chain" do return domain.domain_error(.Conflict, "instance origin is excluded from task Fleet")
	return {}
}
