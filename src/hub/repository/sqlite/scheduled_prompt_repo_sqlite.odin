package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Scheduled_Prompt_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_scheduled_prompt_repository :: proc(impl: ^Scheduled_Prompt_Repo_SQLite, conn: ^Conn) -> iface.Scheduled_Prompt_Repository {
	impl.conn = conn
	return iface.Scheduled_Prompt_Repository{
		ctx = rawptr(impl),
		save = scheduled_prompt_save_sqlite,
		get = scheduled_prompt_get_sqlite,
		delete_prompt = scheduled_prompt_delete_sqlite,
		list = scheduled_prompt_list_sqlite,
		list_by_instance = scheduled_prompt_list_by_instance_sqlite,
		cas_lease = scheduled_prompt_cas_lease_sqlite,
		max_updated_at_for_bridge = scheduled_prompt_max_updated_at_for_bridge_sqlite,
	}
}

scheduled_prompt_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Scheduled_Prompt {
	prompt: domain.Scheduled_Prompt
	prompt.id = domain.Scheduled_Prompt_ID(column_text(stmt, 0))
	prompt.owner_user_id = domain.User_ID(column_text(stmt, 1))
	prompt.target_instance_id = domain.Agent_Instance_ID(column_text(stmt, 2))
	prompt.prompt_text = column_text(stmt, 3)
	prompt.target_run_at = column_text(stmt, 4)
	prompt.interval = column_text(stmt, 5)
	
	state_str := column_text(stmt, 6)
	switch state_str {
	case "in_flight": prompt.state = .In_Flight
	case "completed": prompt.state = .Completed
	case: prompt.state = .Active
	}
	
	prompt.in_flight = column_text(stmt, 7) == "1"
	prompt.leased_at = column_text(stmt, 8)
	prompt.deleted_at = column_text(stmt, 9)
	prompt.created_at = column_text(stmt, 10)
	prompt.updated_at = column_text(stmt, 11)
	return prompt
}

scheduled_prompt_save_sqlite :: proc(ctx: rawptr, prompt: domain.Scheduled_Prompt) -> (domain.Scheduled_Prompt, bool, domain.Domain_Error) {
	impl := (^Scheduled_Prompt_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Scheduled_Prompt{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO scheduled_prompts (
		id, owner_user_id, target_instance_id, prompt_text, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(id) DO UPDATE SET
		owner_user_id=excluded.owner_user_id,
		target_instance_id=excluded.target_instance_id,
		prompt_text=excluded.prompt_text,
		target_run_at=excluded.target_run_at,
		interval=excluded.interval,
		state=excluded.state,
		in_flight=excluded.in_flight,
		leased_at=excluded.leased_at,
		deleted_at=excluded.deleted_at,
		updated_at=excluded.updated_at;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Scheduled_Prompt{}, false, domain.domain_error(.Internal_Error, "failed to prepare scheduled prompt save")
	}
	defer sqlite3_finalize(stmt)

	state_str := "active"
	switch prompt.state {
	case .In_Flight: state_str = "in_flight"
	case .Completed: state_str = "completed"
	case .Active: state_str = "active"
	}

	bind_text(stmt, 1, string(prompt.id))
	bind_text(stmt, 2, string(prompt.owner_user_id))
	bind_text(stmt, 3, string(prompt.target_instance_id))
	bind_text(stmt, 4, prompt.prompt_text)
	bind_text(stmt, 5, prompt.target_run_at)
	bind_text(stmt, 6, prompt.interval)
	bind_text(stmt, 7, state_str)
	bind_text(stmt, 8, "1" if prompt.in_flight else "0")
	bind_text(stmt, 9, prompt.leased_at)
	bind_text(stmt, 10, prompt.deleted_at)
	bind_text(stmt, 11, prompt.created_at)
	bind_text(stmt, 12, prompt.updated_at)

	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Scheduled_Prompt{}, false, domain.domain_error(.Conflict, "scheduled prompt could not be saved")
	}
	return prompt, true, domain.Domain_Error{}
}

scheduled_prompt_get_sqlite :: proc(ctx: rawptr, id: domain.Scheduled_Prompt_ID) -> (domain.Scheduled_Prompt, bool, domain.Domain_Error) {
	impl := (^Scheduled_Prompt_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Scheduled_Prompt{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, target_instance_id, prompt_text, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at FROM scheduled_prompts WHERE id = ? AND deleted_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Scheduled_Prompt{}, false, domain.domain_error(.Internal_Error, "failed to prepare scheduled prompt lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	if sqlite3_step(stmt) != SQLITE_ROW {
		return domain.Scheduled_Prompt{}, false, domain.domain_error(.Not_Found, "scheduled prompt not found")
	}
	return scheduled_prompt_from_stmt(stmt), true, domain.Domain_Error{}
}

scheduled_prompt_delete_sqlite :: proc(ctx: rawptr, id: domain.Scheduled_Prompt_ID) -> (bool, domain.Domain_Error) {
	impl := (^Scheduled_Prompt_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE scheduled_prompts SET deleted_at = datetime('now'), updated_at = datetime('now') WHERE id = ? AND deleted_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare scheduled prompt delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete scheduled prompt")
	}
	return sqlite3_changes(impl.conn.db) > 0, domain.Domain_Error{}
}

scheduled_prompt_list_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Scheduled_Prompt, domain.Domain_Error) {
	impl := (^Scheduled_Prompt_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, target_instance_id, prompt_text, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at FROM scheduled_prompts WHERE owner_user_id = ? AND deleted_at = '' ORDER BY target_run_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare scheduled prompt list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))

	items := make([dynamic]domain.Scheduled_Prompt)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, scheduled_prompt_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

scheduled_prompt_list_by_instance_sqlite :: proc(ctx: rawptr, instance_id: domain.Agent_Instance_ID) -> ([]domain.Scheduled_Prompt, domain.Domain_Error) {
	impl := (^Scheduled_Prompt_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, target_instance_id, prompt_text, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at FROM scheduled_prompts WHERE target_instance_id = ? AND deleted_at = '' ORDER BY target_run_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare scheduled prompt list by instance")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(instance_id))

	items := make([dynamic]domain.Scheduled_Prompt)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, scheduled_prompt_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

scheduled_prompt_cas_lease_sqlite :: proc(ctx: rawptr, id: domain.Scheduled_Prompt_ID, leased_at: string, now: string) -> (bool, domain.Domain_Error) {
	impl := (^Scheduled_Prompt_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE scheduled_prompts SET in_flight = 1, leased_at = ?, state = 'in_flight', updated_at = ? WHERE id = ? AND in_flight = 0 AND target_run_at <= ? AND deleted_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare scheduled prompt cas lease")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, leased_at)
	bind_text(stmt, 2, leased_at)
	bind_text(stmt, 3, string(id))
	bind_text(stmt, 4, now)

	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to execute cas lease")
	}
	return sqlite3_changes(impl.conn.db) > 0, domain.Domain_Error{}
}

scheduled_prompt_max_updated_at_for_bridge_sqlite :: proc(ctx: rawptr, bridge_id: domain.Bridge_ID) -> (string, domain.Domain_Error) {
	impl := (^Scheduled_Prompt_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return "", domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT COALESCE(MAX(sp.updated_at), '')
		FROM scheduled_prompts sp
		JOIN agent_instances ai ON sp.target_instance_id = ai.agent_instance_id
		WHERE ai.bridge_id = ?;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return "", domain.domain_error(.Internal_Error, "failed to prepare scheduled prompt max updated_at lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(bridge_id))

	if sqlite3_step(stmt) == SQLITE_ROW {
		return column_text(stmt, 0), domain.Domain_Error{}
	}
	return "", domain.Domain_Error{}
}
