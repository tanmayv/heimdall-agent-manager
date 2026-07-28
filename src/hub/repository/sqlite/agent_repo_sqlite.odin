package sqlite

import "core:fmt"
import "core:strconv"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Agent_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_agent_repository :: proc(impl: ^Agent_Repo_SQLite, conn: ^Conn) -> iface.Agent_Repository {
	impl.conn = conn
	return iface.Agent_Repository{ctx = rawptr(impl), save = agent_save_sqlite, get = agent_get_sqlite, list_by_owner = agent_list_by_owner_sqlite, save_support = agent_save_support_sqlite, get_support = agent_get_support_sqlite, list_support = agent_list_support_sqlite, delete_support = agent_delete_support_sqlite, save_instance = agent_save_instance_sqlite, get_instance = agent_get_instance_sqlite, list_instances_by_owner = agent_list_instances_by_owner_sqlite, list_instances_by_bridge = agent_list_instances_by_bridge_sqlite}
}

agent_save_sqlite :: proc(ctx: rawptr, agent: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, default_provider, default_tier, instructions, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(agent_id) DO UPDATE SET name=excluded.name, slug=excluded.slug, template_id=excluded.template_id, default_provider=excluded.default_provider, default_tier=excluded.default_tier, instructions=excluded.instructions, state=excluded.state, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "failed to prepare agent save")
	defer sqlite3_finalize(stmt)
	bind_agent(stmt, agent)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Agent{}, false, domain.domain_error(.Conflict, "agent slug already exists or could not be saved")
	return agent, true, domain.Domain_Error{}
}

agent_get_sqlite :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_id, owner_user_id, name, slug, template_id, default_provider, default_tier, instructions, state, created_at, updated_at FROM agents WHERE agent_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "failed to prepare agent lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Agent{}, false, domain.domain_error(.Not_Found, "agent not found")
	return agent_from_stmt(stmt), true, domain.Domain_Error{}
}

agent_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Agent, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_id, owner_user_id, name, slug, template_id, default_provider, default_tier, instructions, state, created_at, updated_at FROM agents WHERE owner_user_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare agent list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Agent)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, agent_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_save_support_sqlite :: proc(ctx: rawptr, support: domain.Agent_Bridge_Support) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO agent_bridge_support (agent_id, bridge_id, owner_user_id, enabled, provider, tier, priority, max_instances, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(agent_id, bridge_id) DO UPDATE SET enabled=excluded.enabled, provider=excluded.provider, tier=excluded.tier, priority=excluded.priority, max_instances=excluded.max_instances, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "failed to prepare support save")
	defer sqlite3_finalize(stmt)
	bind_support(stmt, support)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Conflict, "support could not be saved")
	return support, true, domain.Domain_Error{}
}

agent_get_support_sqlite :: proc(ctx: rawptr, agent_id, bridge_id: string) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_id, bridge_id, owner_user_id, enabled, provider, tier, priority, max_instances, created_at, updated_at FROM agent_bridge_support WHERE agent_id = ? AND bridge_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "failed to prepare support lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id); bind_text(stmt, 2, bridge_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Not_Found, "support not found")
	return support_from_stmt(stmt), true, domain.Domain_Error{}
}

agent_list_support_sqlite :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_id, bridge_id, owner_user_id, enabled, provider, tier, priority, max_instances, created_at, updated_at FROM agent_bridge_support WHERE agent_id = ? AND owner_user_id = ? ORDER BY priority ASC, updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare support list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Agent_Bridge_Support)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, support_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_delete_support_sqlite :: proc(ctx: rawptr, agent_id, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM agent_bridge_support WHERE agent_id = ? AND bridge_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare support delete")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id); bind_text(stmt, 2, bridge_id); bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "support could not be deleted")
	return true, domain.Domain_Error{}
}

agent_save_instance_sqlite :: proc(ctx: rawptr, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO agent_instances (agent_instance_id, owner_user_id, agent_id, bridge_id, provider, tier, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, created_at, updated_at, started_at, stopped_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(agent_instance_id) DO UPDATE SET provider=excluded.provider, tier=excluded.tier, project_id=excluded.project_id, project_path=excluded.project_path, runtime_status=excluded.runtime_status, startup_status=excluded.startup_status, activity_status=excluded.activity_status, status_message=excluded.status_message, last_applied_seq=excluded.last_applied_seq, run_count=excluded.run_count, updated_at=excluded.updated_at, started_at=excluded.started_at, stopped_at=excluded.stopped_at, last_seen_at=excluded.last_seen_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "failed to prepare instance save")
	defer sqlite3_finalize(stmt)
	bind_instance(stmt, instance)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, "agent instance could not be saved")
	return instance, true, domain.Domain_Error{}
}

agent_get_instance_sqlite :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, provider, tier, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, created_at, updated_at, started_at, stopped_at, last_seen_at FROM agent_instances WHERE agent_instance_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "failed to prepare instance lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "agent instance not found")
	return instance_from_stmt(stmt), true, domain.Domain_Error{}
}

agent_list_instances_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, provider, tier, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, created_at, updated_at, started_at, stopped_at, last_seen_at FROM agent_instances WHERE owner_user_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare instance list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Agent_Instance)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, instance_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_list_instances_by_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, provider, tier, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, created_at, updated_at, started_at, stopped_at, last_seen_at FROM agent_instances WHERE bridge_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge instance list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	out := make([dynamic]domain.Agent_Instance)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, instance_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

bind_agent :: proc(stmt: sqlite3_stmt, agent: domain.Agent) {
	bind_text(stmt, 1, agent.agent_id); bind_text(stmt, 2, string(agent.owner_user_id)); bind_text(stmt, 3, agent.name); bind_text(stmt, 4, agent.slug); bind_text(stmt, 5, agent.template_id); bind_text(stmt, 6, agent.default_provider); bind_text(stmt, 7, agent.default_tier); bind_text(stmt, 8, agent.instructions); bind_text(stmt, 9, domain.agent_state_string(agent.state)); bind_text(stmt, 10, agent.created_at); bind_text(stmt, 11, agent.updated_at)
}

bind_support :: proc(stmt: sqlite3_stmt, s: domain.Agent_Bridge_Support) {
	bind_text(stmt, 1, s.agent_id); bind_text(stmt, 2, s.bridge_id); bind_text(stmt, 3, string(s.owner_user_id)); bind_text(stmt, 4, "1" if s.enabled else "0"); bind_text(stmt, 5, s.provider); bind_text(stmt, 6, s.tier); bind_text(stmt, 7, i32_to_string(s.priority)); bind_text(stmt, 8, i32_to_string(s.max_instances)); bind_text(stmt, 9, s.created_at); bind_text(stmt, 10, s.updated_at)
}

agent_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Agent {
	return domain.Agent{agent_id = column_text(stmt, 0), owner_user_id = domain.User_ID(column_text(stmt, 1)), name = column_text(stmt, 2), slug = column_text(stmt, 3), template_id = column_text(stmt, 4), default_provider = column_text(stmt, 5), default_tier = column_text(stmt, 6), instructions = column_text(stmt, 7), state = agent_state_from_string(column_text(stmt, 8)), created_at = column_text(stmt, 9), updated_at = column_text(stmt, 10)}
}

support_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Agent_Bridge_Support {
	return domain.Agent_Bridge_Support{agent_id = column_text(stmt, 0), bridge_id = column_text(stmt, 1), owner_user_id = domain.User_ID(column_text(stmt, 2)), enabled = column_text(stmt, 3) == "1", provider = column_text(stmt, 4), tier = column_text(stmt, 5), priority = string_to_i32(column_text(stmt, 6)), max_instances = string_to_i32(column_text(stmt, 7)), created_at = column_text(stmt, 8), updated_at = column_text(stmt, 9)}
}

bind_instance :: proc(stmt: sqlite3_stmt, inst: domain.Agent_Instance) {
	bind_text(stmt, 1, inst.agent_instance_id); bind_text(stmt, 2, string(inst.owner_user_id)); bind_text(stmt, 3, inst.agent_id); bind_text(stmt, 4, inst.bridge_id); bind_text(stmt, 5, inst.provider); bind_text(stmt, 6, inst.tier); bind_text(stmt, 7, string(inst.project_id)); bind_text(stmt, 8, inst.project_path); bind_text(stmt, 9, inst.chain_id); bind_text(stmt, 10, inst.conversation_id); bind_text(stmt, 11, inst.runtime_status); bind_text(stmt, 12, inst.startup_status); bind_text(stmt, 13, inst.activity_status); bind_text(stmt, 14, inst.status_message); bind_text(stmt, 15, i32_to_string(inst.last_applied_seq)); bind_text(stmt, 16, i32_to_string(inst.run_count)); bind_text(stmt, 17, inst.created_at); bind_text(stmt, 18, inst.updated_at); bind_text(stmt, 19, inst.started_at); bind_text(stmt, 20, inst.stopped_at); bind_text(stmt, 21, inst.last_seen_at)
}

instance_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Agent_Instance {
	return domain.Agent_Instance{agent_instance_id = column_text(stmt, 0), owner_user_id = domain.User_ID(column_text(stmt, 1)), agent_id = column_text(stmt, 2), bridge_id = column_text(stmt, 3), provider = column_text(stmt, 4), tier = column_text(stmt, 5), project_id = domain.Project_ID(column_text(stmt, 6)), project_path = column_text(stmt, 7), chain_id = column_text(stmt, 8), conversation_id = column_text(stmt, 9), runtime_status = column_text(stmt, 10), startup_status = column_text(stmt, 11), activity_status = column_text(stmt, 12), status_message = column_text(stmt, 13), last_applied_seq = string_to_i32(column_text(stmt, 14)), run_count = string_to_i32(column_text(stmt, 15)), created_at = column_text(stmt, 16), updated_at = column_text(stmt, 17), started_at = column_text(stmt, 18), stopped_at = column_text(stmt, 19), last_seen_at = column_text(stmt, 20)}
}

agent_state_from_string :: proc(state: string) -> domain.Agent_State { if state == "archived" do return .Archived; return .Active }
i32_to_string :: proc(v: int) -> string { return fmt.tprintf("%d", v) }
string_to_i32 :: proc(v: string) -> int { parsed, ok := strconv.parse_int(v); if !ok do return 0; return int(parsed) }
