package sqlite

import "core:c"
import "core:strconv"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Shell_Session_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_shell_session_repository :: proc(impl: ^Shell_Session_Repo_SQLite, conn: ^Conn) -> iface.Shell_Session_Repository {
	impl.conn = conn
	return iface.Shell_Session_Repository{
		ctx             = rawptr(impl),
		upsert          = shell_session_upsert_sqlite,
		get             = shell_session_get_sqlite,
		get_by_id       = shell_session_get_by_id_sqlite,
		list_by_bridge  = shell_session_list_by_bridge_sqlite,
		list_by_project = shell_session_list_by_project_sqlite,
		list_by_chain   = shell_session_list_by_chain_sqlite,
		delete          = shell_session_delete_sqlite,
	}
}

// Column order for SELECT queries:
// 0:session_id 1:owner_user_id 2:bridge_id 3:project_id 4:chain_id
// 5:agent_instance_id 6:kind 7:label 8:cmd 9:cwd 10:status
// 11:exit_code 12:pid 13:server_port 14:started_at 15:finished_at
// 16:created_at 17:last_activity_at
shell_session_select_cols :: "session_id, owner_user_id, bridge_id, project_id, chain_id, agent_instance_id, kind, label, cmd, cwd, status, exit_code, pid, server_port, started_at, finished_at, created_at, last_activity_at"

shell_session_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Shell_Session {
	s: domain.Shell_Session
	s.session_id         = column_text(stmt, 0)
	s.owner_user_id      = column_text(stmt, 1)
	s.bridge_id          = column_text(stmt, 2)
	s.project_id         = column_text(stmt, 3)
	s.chain_id           = column_text(stmt, 4)
	s.agent_instance_id  = column_text(stmt, 5)
	s.kind               = column_text(stmt, 6)
	s.label              = column_text(stmt, 7)
	s.cmd                = column_text(stmt, 8)
	s.cwd                = column_text(stmt, 9)
	s.status             = column_text(stmt, 10)
	// exit_code is nullable INTEGER: column_text_unowned returns "" for NULL
	ec := column_text_unowned(stmt, 11)
	if ec != "" {
		if v, ok := strconv.parse_int(ec); ok {
			s.exit_code     = int(v)
			s.exit_code_set = true
		}
	}
	// pid and server_port: NOT NULL INTEGER, use column_text_unowned for transient parse
	if v, ok := strconv.parse_int(column_text_unowned(stmt, 12)); ok { s.pid = int(v) }
	if v, ok := strconv.parse_int(column_text_unowned(stmt, 13)); ok { s.server_port = int(v) }
	s.started_at       = column_text(stmt, 14)
	s.finished_at      = column_text(stmt, 15)
	s.created_at       = column_text(stmt, 16)
	s.last_activity_at = column_text(stmt, 17)
	return s
}

shell_session_upsert_sqlite :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO shell_sessions (
		session_id, owner_user_id, bridge_id, project_id, chain_id, agent_instance_id,
		kind, label, cmd, cwd, status, exit_code, pid, server_port,
		started_at, finished_at, created_at, last_activity_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(session_id) DO UPDATE SET
		status           = excluded.status,
		exit_code        = excluded.exit_code,
		pid              = CASE WHEN excluded.pid != 0 THEN excluded.pid ELSE shell_sessions.pid END,
		server_port      = CASE WHEN excluded.server_port != 0 THEN excluded.server_port ELSE shell_sessions.server_port END,
		finished_at      = CASE WHEN excluded.finished_at != '' THEN excluded.finished_at ELSE shell_sessions.finished_at END,
		last_activity_at = CASE WHEN excluded.last_activity_at != '' THEN excluded.last_activity_at ELSE shell_sessions.last_activity_at END,
		label            = CASE WHEN excluded.label != '' THEN excluded.label ELSE shell_sessions.label END,
		cwd              = CASE WHEN excluded.cwd != '' THEN excluded.cwd ELSE shell_sessions.cwd END;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session upsert")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1,  session.session_id)
	bind_text(stmt, 2,  session.owner_user_id)
	bind_text(stmt, 3,  session.bridge_id)
	bind_text(stmt, 4,  session.project_id)
	bind_text(stmt, 5,  session.chain_id)
	bind_text(stmt, 6,  session.agent_instance_id)
	bind_text(stmt, 7,  session.kind)
	bind_text(stmt, 8,  session.label)
	bind_text(stmt, 9,  session.cmd)
	bind_text(stmt, 10, session.cwd)
	bind_text(stmt, 11, session.status)
	// exit_code: NULL when not set, integer value when set
	if session.exit_code_set {
		sqlite3_bind_int(stmt, 12, c.int(session.exit_code))
	} else {
		sqlite3_bind_null(stmt, 12)
	}
	sqlite3_bind_int(stmt, 13, c.int(session.pid))
	sqlite3_bind_int(stmt, 14, c.int(session.server_port))
	bind_text(stmt, 15, session.started_at)
	bind_text(stmt, 16, session.finished_at)
	bind_text(stmt, 17, session.created_at)
	bind_text(stmt, 18, session.last_activity_at)

	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to upsert shell session")
	}
	return true, domain.Domain_Error{}
}

shell_session_get_sqlite :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := strings.concatenate({"SELECT ", shell_session_select_cols, " FROM shell_sessions WHERE owner_user_id = ? AND session_id = ? LIMIT 1;"}, context.temp_allocator)
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "failed to prepare shell session get")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, session_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return shell_session_from_stmt(stmt), true, domain.Domain_Error{}
}

// shell_session_get_by_id_sqlite mirrors shell_session_get_sqlite but selects on
// session_id alone. session_id is the table's primary key, so this returns at
// most one row. Unscoped by design — see Shell_Session_Get_By_Id_Proc; it backs
// the shell_exited event path only and must not be reached from an HTTP handler.
shell_session_get_by_id_sqlite :: proc(ctx: rawptr, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := strings.concatenate({"SELECT ", shell_session_select_cols, " FROM shell_sessions WHERE session_id = ? LIMIT 1;"}, context.temp_allocator)
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "failed to prepare shell session get by id")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, session_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return shell_session_from_stmt(stmt), true, domain.Domain_Error{}
}

shell_session_list_by_bridge_sqlite :: proc(ctx: rawptr, owner_user_id, bridge_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	return shell_session_list_generic(ctx, "bridge_id", owner_user_id, bridge_id, status_filter, cursor, limit)
}

shell_session_list_by_project_sqlite :: proc(ctx: rawptr, owner_user_id, project_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	return shell_session_list_generic(ctx, "project_id", owner_user_id, project_id, status_filter, cursor, limit)
}

shell_session_list_by_chain_sqlite :: proc(ctx: rawptr, owner_user_id, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	return shell_session_list_generic(ctx, "chain_id", owner_user_id, chain_id, status_filter, cursor, limit)
}

shell_session_list_generic :: proc(ctx: rawptr, scope_col, owner_user_id, scope_val, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, "", domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	lim := limit
	if lim <= 0 do lim = 50

	has_status := status_filter != ""
	has_cursor := cursor != ""

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ")
	strings.write_string(&b, shell_session_select_cols)
	strings.write_string(&b, " FROM shell_sessions WHERE owner_user_id = ? AND ")
	strings.write_string(&b, scope_col)
	strings.write_string(&b, " = ?")
	if has_status do strings.write_string(&b, " AND status = ?")
	if has_cursor do strings.write_string(&b, " AND session_id < ?")
	strings.write_string(&b, " ORDER BY started_at DESC, session_id DESC LIMIT ?;")
	query := strings.to_string(b)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, "", domain.domain_error(.Internal_Error, "failed to prepare shell session list")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, scope_val)
	p := 3
	if has_status { bind_text(stmt, p, status_filter); p += 1 }
	if has_cursor  { bind_text(stmt, p, cursor);        p += 1 }
	bind_text(stmt, p, int_s(lim))

	items := make([dynamic]domain.Shell_Session)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, shell_session_from_stmt(stmt))
	}
	next_cursor := ""
	if len(items) >= lim && len(items) > 0 {
		next_cursor = items[len(items)-1].session_id
	}
	return items, next_cursor, domain.Domain_Error{}
}

shell_session_delete_sqlite :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM shell_sessions WHERE owner_user_id = ? AND session_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, session_id)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete shell session")
	}
	return true, domain.Domain_Error{}
}
