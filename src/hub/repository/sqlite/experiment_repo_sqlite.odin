package sqlite

import "core:c"
import "core:strconv"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Experiment_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_experiment_repository :: proc(impl: ^Experiment_Repo_SQLite, conn: ^Conn) -> iface.Experiment_Repository {
	impl.conn = conn
	return iface.Experiment_Repository{
		ctx           = rawptr(impl),
		set           = experiment_set_sqlite,
		list_by_owner = experiment_list_by_owner_sqlite,
	}
}

// experiment_set_sqlite upserts a flag for (owner_user_id, key). A row already
// present for that pair is updated in place; a new pair is inserted.
experiment_set_sqlite :: proc(ctx: rawptr, exp: domain.Experiment) -> (bool, domain.Domain_Error) {
	impl := (^Experiment_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO experiments (owner_user_id, key, enabled, updated_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(owner_user_id, key) DO UPDATE SET
    enabled    = excluded.enabled,
    updated_at = excluded.updated_at;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare experiment set")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, exp.owner_user_id)
	bind_text(stmt, 2, exp.key)
	sqlite3_bind_int(stmt, 3, 1 if exp.enabled else 0)
	bind_text(stmt, 4, exp.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to set experiment flag")
	}
	return true, domain.Domain_Error{}
}

// experiment_list_by_owner_sqlite returns all flags for the given owner.
// An owner with no rows returns an empty slice, not an error.
experiment_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	impl := (^Experiment_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT owner_user_id, key, enabled, updated_at FROM experiments WHERE owner_user_id = ? ORDER BY key ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare experiment list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	items := make([dynamic]domain.Experiment)
	for sqlite3_step(stmt) == SQLITE_ROW {
		exp: domain.Experiment
		exp.owner_user_id = column_text(stmt, 0)
		exp.key           = column_text(stmt, 1)
		if v, ok := strconv.parse_int(column_text_unowned(stmt, 2)); ok {
			exp.enabled = v != 0
		}
		exp.updated_at = column_text(stmt, 3)
		append(&items, exp)
	}
	return items, domain.Domain_Error{}
}
