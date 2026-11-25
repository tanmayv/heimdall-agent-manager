package sqlite

import "core:strings"
import domain "odin_test:hub/domain"

fleet_db_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "Fleet settings storage failed")
}

fleet_settings_get_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, bridge_id: string) -> (domain.Fleet_Settings, domain.Domain_Error) {
	// Do not read another request's uncommitted Apply on the shared connection.
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	// Protect both reads from seeing different revisions of a complete snapshot.
	mu := sqlite3_db_mutex(impl.conn.db); sqlite3_mutex_enter(mu); defer sqlite3_mutex_leave(mu)
	query := "SELECT f.revision,f.provider,f.provider_profile,f.model FROM bridges b LEFT JOIN bridge_fleet_settings f ON f.bridge_id=b.bridge_id AND f.owner_user_id=b.owner_user_id WHERE b.bridge_id=? AND b.owner_user_id=?;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, fleet_db_error()
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id); bind_text(stmt, 2, string(owner))
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, domain.domain_error(.Not_Found, "bridge not found")
	if rc != SQLITE_ROW do return {}, fleet_db_error()
	out := domain.Fleet_Settings{bridge_id = strings.clone(bridge_id), revision = sqlite3_column_int64(stmt, 0), default_runtime = {column_text(stmt, 1), column_text(stmt, 2), column_text(stmt, 3)}}
	if out.revision == 0 do return out, {}
	q := "SELECT agent_id,provider,provider_profile,model FROM bridge_fleet_agent_overrides WHERE bridge_id=? ORDER BY agent_id;"
	rows: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &rows, nil) != SQLITE_OK {domain.fleet_settings_destroy(out); return {}, fleet_db_error()}
	defer sqlite3_finalize(rows)
	bind_text(rows, 1, bridge_id)
	items := make([dynamic]domain.Fleet_Agent_Override)
	for {
		step := sqlite3_step(rows)
		if step == SQLITE_DONE do break
		if step != SQLITE_ROW {
			for o in items {delete(o.agent_id); domain.fleet_runtime_destroy(o.runtime)}
			delete(items); domain.fleet_settings_destroy(out); return {}, fleet_db_error()
		}
		append(&items, domain.Fleet_Agent_Override{column_text(rows, 0), {column_text(rows, 1), column_text(rows, 2), column_text(rows, 3)}})
	}
	// Exact-sized slice: destroy does not need dynamic capacity.
	out.overrides = make([]domain.Fleet_Agent_Override, len(items)); copy(out.overrides, items[:]); delete(items)
	return out, {}
}

fleet_settings_save_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, bridge_id: string, draft: domain.Fleet_Settings_Draft) -> (domain.Fleet_Settings, bool, domain.Domain_Error) {
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	mu := sqlite3_db_mutex(impl.conn.db); sqlite3_mutex_enter(mu); defer sqlite3_mutex_leave(mu)
	if !exec(impl.conn, "SAVEPOINT fleet_settings_save;") do return {}, false, fleet_db_error()
	committed := false
	defer if !committed do _ = exec(impl.conn, "ROLLBACK TO fleet_settings_save; RELEASE fleet_settings_save;")
	prior, err := fleet_settings_get_sqlite(ctx, owner, bridge_id)
	if err.code != .None do return {}, false, err
	defer domain.fleet_settings_destroy(prior)
	if prior.revision != draft.expected_revision do return {}, false, domain.domain_error(.Conflict, "Fleet settings changed; refresh the bridge draft", `{"code":"fleet_revision_conflict"}`)
	if draft.default_runtime.provider == "" || draft.default_runtime.model == "" do return {}, false, domain.domain_error(.Unprocessable_Entity, "default provider and model are required")
	seen := make(map[string]bool, context.temp_allocator)
	for o in draft.overrides {
		if seen[o.agent_id] || o.agent_id == "" || o.runtime.provider == "" || o.runtime.model == "" do return {}, false, domain.domain_error(.Unprocessable_Entity, "invalid or duplicate Fleet override")
		seen[o.agent_id] = true
		q := "SELECT 1 FROM agents WHERE agent_id=? AND owner_user_id=?;"
		stmt: sqlite3_stmt
		if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, fleet_db_error()
		bind_text(stmt, 1, o.agent_id); bind_text(stmt, 2, string(owner))
		rc := sqlite3_step(stmt); sqlite3_finalize(stmt)
		if rc == SQLITE_DONE do return {}, false, domain.domain_error(.Not_Found, "agent not found")
		if rc != SQLITE_ROW do return {}, false, fleet_db_error()
	}
	changed := prior.revision == 0 || !domain.fleet_runtime_equal(prior.default_runtime, draft.default_runtime) || len(prior.overrides) != len(draft.overrides)
	for o in draft.overrides {
		found := false
		for p in prior.overrides do if p.agent_id == o.agent_id && domain.fleet_runtime_equal(p.runtime, o.runtime) do found = true
		if !found do changed = true
	}
	if changed {
		q := "INSERT INTO bridge_fleet_settings(bridge_id,owner_user_id,revision,provider,provider_profile,model) VALUES(?,?,?,?,?,?) ON CONFLICT(bridge_id) DO UPDATE SET revision=excluded.revision,provider=excluded.provider,provider_profile=excluded.provider_profile,model=excluded.model;"
		stmt: sqlite3_stmt
		if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, fleet_db_error()
		bind_text(stmt, 1, bridge_id); bind_text(stmt, 2, string(owner)); sqlite3_bind_int64(stmt, 3, prior.revision + 1)
		bind_text(stmt, 4, draft.default_runtime.provider); bind_text(stmt, 5, domain.profile_effective_id(draft.default_runtime.provider, draft.default_runtime.provider_profile)); bind_text(stmt, 6, draft.default_runtime.model)
		rc := sqlite3_step(stmt); sqlite3_finalize(stmt)
		if rc != SQLITE_DONE do return {}, false, fleet_db_error()
		q = "DELETE FROM bridge_fleet_agent_overrides WHERE bridge_id=?;"
		if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, fleet_db_error()
		bind_text(stmt, 1, bridge_id); rc = sqlite3_step(stmt); sqlite3_finalize(stmt)
		if rc != SQLITE_DONE do return {}, false, fleet_db_error()
		for o in draft.overrides {
			q = "INSERT INTO bridge_fleet_agent_overrides(bridge_id,agent_id,provider,provider_profile,model) VALUES(?,?,?,?,?);"
			if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, fleet_db_error()
			bind_text(stmt, 1, bridge_id); bind_text(stmt, 2, o.agent_id); bind_text(stmt, 3, o.runtime.provider); bind_text(stmt, 4, domain.profile_effective_id(o.runtime.provider, o.runtime.provider_profile)); bind_text(stmt, 5, o.runtime.model)
			rc = sqlite3_step(stmt); sqlite3_finalize(stmt)
			if rc != SQLITE_DONE do return {}, false, fleet_db_error()
		}
	}
	out, read_err := fleet_settings_get_sqlite(ctx, owner, bridge_id)
	if read_err.code != .None do return {}, false, read_err
	if !exec(impl.conn, "RELEASE fleet_settings_save;") {domain.fleet_settings_destroy(out); return {}, false, fleet_db_error()}
	committed = true
	return out, changed, {}
}
