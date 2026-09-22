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
		list_by_owner   = shell_session_list_by_owner_sqlite,
		delete          = shell_session_delete_sqlite,
		set_server_port = shell_session_set_server_port_sqlite,
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

// shell_session_list_by_owner_sqlite lists every session the owner has, across
// all bridges, with each non-empty filter field contributing one AND-ed clause.
// No filter at all is the owner-wide default listing.
shell_session_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: string, filter: iface.Shell_Session_List_Filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	clauses := make([dynamic]Shell_Session_Where_Clause, context.temp_allocator)
	if filter.bridge_id  != "" do append(&clauses, shell_session_eq("bridge_id",  filter.bridge_id))
	if filter.project_id != "" do append(&clauses, shell_session_eq("project_id", filter.project_id))
	if filter.chain_id   != "" do append(&clauses, shell_session_eq("chain_id",   filter.chain_id))
	if filter.status     != "" do append(&clauses, shell_session_status_clause(filter.status))
	return shell_session_list_where(ctx, owner_user_id, clauses[:], cursor, limit)
}

shell_session_list_generic :: proc(ctx: rawptr, scope_col, owner_user_id, scope_val, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	// The scope clause is UNCONDITIONAL, including when scope_val is "". These
	// three lists are scoped by construction, and an empty scope value means
	// "the sessions whose column is empty" — dropping the clause instead would
	// silently widen a scoped route to the owner's whole fleet. Only the status
	// filter is optional here, exactly as before.
	clauses := make([dynamic]Shell_Session_Where_Clause, context.temp_allocator)
	append(&clauses, shell_session_eq(scope_col, scope_val))
	// Through the same translator as the owner-wide list, so `status=live` and
	// `status=finished` work identically on all four list routes.
	if status_filter != "" do append(&clauses, shell_session_status_clause(status_filter))
	return shell_session_list_where(ctx, owner_user_id, clauses[:], cursor, limit)
}

Shell_Session_Where_Op :: enum {
	Eq,     // <col> = ?
	In,     // <col> IN (?, ?, ...)
	Not_In, // <col> NOT IN (?, ?, ...)
}

// Shell_Session_Where_Clause is one AND-ed condition. `col` is always a literal
// chosen in this file, never caller text, so it is safe to inline into the SQL;
// every value in `vals` is bound as a parameter. Eq carries exactly one value;
// In/Not_In carry the set.
Shell_Session_Where_Clause :: struct {
	col:  string,
	op:   Shell_Session_Where_Op,
	vals: []string,
}

// shell_session_eq is the one-value equality clause, the shape almost every
// filter wants. The backing slice is temp-allocated, so it lives exactly as long
// as the request or loop iteration that builds the query — never past the
// sqlite3_step loop that reads it.
shell_session_eq :: proc(col, val: string) -> Shell_Session_Where_Clause {
	vals := make([]string, 1, context.temp_allocator)
	vals[0] = val
	return Shell_Session_Where_Clause{col = col, op = .Eq, vals = vals}
}

// shell_session_status_clause translates ONE status filter value into a clause.
// The two group names (domain.Shell_Session_Status_Group_Live / _Finished) become
// set membership over domain.SHELL_SESSION_TERMINAL_STATUSES — the domain's own
// definition of "over", so this cannot drift from shell_session_is_terminal.
// Anything else is an exact match, so every concrete status keeps behaving
// exactly as it did before the groups existed.
//
// `live` is NOT IN (terminal) rather than IN (starting, running): a status added
// later is live until the domain says it is terminal, which is the safer default
// — a new status shows up in the Live tab instead of vanishing from both.
shell_session_status_clause :: proc(status: string) -> Shell_Session_Where_Clause {
	switch status {
	case domain.Shell_Session_Status_Group_Finished:
		return Shell_Session_Where_Clause{col = "status", op = .In, vals = shell_session_terminal_vals()}
	case domain.Shell_Session_Status_Group_Live:
		return Shell_Session_Where_Clause{col = "status", op = .Not_In, vals = shell_session_terminal_vals()}
	}
	return shell_session_eq("status", status)
}

// shell_session_terminal_vals copies the domain's terminal set into a temp slice
// for binding. Copied rather than referenced because the domain constant is a
// fixed-size array, and the clause holds a slice.
shell_session_terminal_vals :: proc() -> []string {
	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	vals := make([]string, len(terminal), context.temp_allocator)
	for st, i in terminal do vals[i] = st
	return vals
}

// shell_session_list_where is the one keyset-paginated shell-session query. It
// always scopes to owner_user_id, ANDs every clause it is given, and keeps the
// `ORDER BY started_at DESC, session_id DESC` ordering the cursor is defined
// against.
shell_session_list_where :: proc(ctx: rawptr, owner_user_id: string, clauses: []Shell_Session_Where_Clause, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, "", domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	lim := limit
	if lim <= 0 do lim = 50

	has_cursor := cursor != ""

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ")
	strings.write_string(&b, shell_session_select_cols)
	strings.write_string(&b, " FROM shell_sessions WHERE owner_user_id = ?")
	for c in clauses {
		strings.write_string(&b, " AND ")
		strings.write_string(&b, c.col)
		switch c.op {
		case .Eq:
			strings.write_string(&b, " = ?")
		case .In, .Not_In:
			strings.write_string(&b, " NOT IN (" if c.op == .Not_In else " IN (")
			for _, i in c.vals {
				if i > 0 do strings.write_string(&b, ", ")
				strings.write_string(&b, "?")
			}
			strings.write_string(&b, ")")
		}
	}
	if has_cursor do strings.write_string(&b, " AND session_id < ?")
	strings.write_string(&b, " ORDER BY started_at DESC, session_id DESC LIMIT ?;")
	query := strings.to_string(b)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, "", domain.domain_error(.Internal_Error, "failed to prepare shell session list")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, owner_user_id)
	p := 2
	for c in clauses {
		for v in c.vals { bind_text(stmt, p, v); p += 1 }
	}
	if has_cursor { bind_text(stmt, p, cursor); p += 1 }
	bind_text(stmt, p, int_s(lim))

	items := make([dynamic]domain.Shell_Session)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, shell_session_from_stmt(stmt))
	}
	// The cursor is CLONED, not aliased. It is derived from the last row's
	// session_id, and every caller frees the page (domain.shell_sessions_destroy,
	// which deletes session_id) and the cursor (delete(next_cursor))
	// independently — aliasing made those two frees land on one allocation. An
	// owned copy is what the callers already assume they were handed.
	next_cursor := ""
	if len(items) >= lim && len(items) > 0 {
		next_cursor = strings.clone(items[len(items)-1].session_id)
	}
	return items, next_cursor, domain.Domain_Error{}
}

// shell_session_set_server_port_sqlite writes server_port alone. A direct
// UPDATE rather than a re-upsert: shell_session_upsert_sqlite keeps the existing
// port when the incoming one is 0, so clearing a port through the upsert writes
// nothing. Returns false when no row matched the owner/session pair.
shell_session_set_server_port_sqlite :: proc(ctx: rawptr, owner_user_id, session_id: string, server_port: int) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE shell_sessions SET server_port = ? WHERE owner_user_id = ? AND session_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session set server_port")
	}
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int(stmt, 1, c.int(server_port))
	bind_text(stmt, 2, owner_user_id)
	bind_text(stmt, 3, session_id)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to set shell session server_port")
	}
	return sqlite3_changes(impl.conn.db) > 0, domain.Domain_Error{}
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
