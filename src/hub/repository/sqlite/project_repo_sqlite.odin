package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Project_Repo_SQLite :: struct { conn: ^Conn }

new_project_repository :: proc(impl: ^Project_Repo_SQLite, conn: ^Conn) -> iface.Project_Repository {
	impl.conn = conn
	return iface.Project_Repository{ctx = rawptr(impl), get = project_get_sqlite, save = project_save_sqlite, update = project_save_sqlite, list_by_owner = project_list_by_owner_sqlite, save_bridge_path = project_save_bridge_path_sqlite, get_bridge_path = project_get_bridge_path_sqlite, list_bridge_paths = project_list_bridge_paths_sqlite, delete_bridge_path = project_delete_bridge_path_sqlite}
}

project_get_sqlite :: proc(ctx: rawptr, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "SELECT project_id, owner_user_id, name, slug, description, repo_url, vcs_kind, default_path, created_at, updated_at FROM projects WHERE project_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.Project{}, false, domain.domain_error(.Internal_Error, "failed to prepare project lookup")
	defer sqlite3_finalize(stmt); bind_text(stmt, 1, string(project_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Project{}, false, domain.domain_error(.Not_Found, "project not found")
	return project_from_stmt(stmt), true, domain.Domain_Error{}
}

project_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Project, domain.Domain_Error) {
	impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "SELECT project_id, owner_user_id, name, slug, description, repo_url, vcs_kind, default_path, created_at, updated_at FROM projects WHERE owner_user_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare project list")
	defer sqlite3_finalize(stmt); bind_text(stmt, 1, string(owner_user_id)); out := make([dynamic]domain.Project)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, project_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

project_save_sqlite :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "INSERT INTO projects (project_id, owner_user_id, name, slug, description, repo_url, vcs_kind, default_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(project_id) DO UPDATE SET name=excluded.name, slug=excluded.slug, description=excluded.description, repo_url=excluded.repo_url, vcs_kind=excluded.vcs_kind, default_path=excluded.default_path, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.Project{}, false, domain.domain_error(.Internal_Error, "failed to prepare project save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(project.project_id)); bind_text(stmt, 2, string(project.owner_user_id)); bind_text(stmt, 3, project.name); bind_text(stmt, 4, project.slug); bind_text(stmt, 5, project.description); bind_text(stmt, 6, project.repo_url); bind_text(stmt, 7, project.vcs_kind); bind_text(stmt, 8, project.default_path); bind_text(stmt, 9, project.created_at); bind_text(stmt, 10, project.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Project{}, false, domain.domain_error(.Conflict, "project could not be saved")
	return project, true, domain.Domain_Error{}
}

project_save_bridge_path_sqlite :: proc(ctx: rawptr, path: domain.Project_Bridge_Path) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error) {
	impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "INSERT INTO project_bridge_paths (project_id, bridge_id, owner_user_id, path, is_validated, last_validated_at, validation_error, validation_details_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(project_id, bridge_id) DO UPDATE SET path=excluded.path, is_validated=excluded.is_validated, last_validated_at=excluded.last_validated_at, validation_error=excluded.validation_error, validation_details_json=excluded.validation_details_json, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Internal_Error, "failed to prepare project bridge path save")
	defer sqlite3_finalize(stmt); bind_path(stmt, path)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Conflict, "project bridge path could not be saved")
	return path, true, domain.Domain_Error{}
}

project_get_bridge_path_sqlite :: proc(ctx: rawptr, project_id: domain.Project_ID, bridge_id: string) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error) {
	impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "SELECT project_id, bridge_id, owner_user_id, path, is_validated, last_validated_at, validation_error, validation_details_json, created_at, updated_at FROM project_bridge_paths WHERE project_id = ? AND bridge_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Internal_Error, "failed to prepare path lookup")
	defer sqlite3_finalize(stmt); bind_text(stmt, 1, string(project_id)); bind_text(stmt, 2, bridge_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Not_Found, "project bridge path not found")
	return path_from_stmt(stmt), true, domain.Domain_Error{}
}

project_list_bridge_paths_sqlite :: proc(ctx: rawptr, project_id: domain.Project_ID, owner_user_id: domain.User_ID) -> ([]domain.Project_Bridge_Path, domain.Domain_Error) {
	impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "SELECT project_id, bridge_id, owner_user_id, path, is_validated, last_validated_at, validation_error, validation_details_json, created_at, updated_at FROM project_bridge_paths WHERE project_id = ? AND owner_user_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare path list")
	defer sqlite3_finalize(stmt); bind_text(stmt, 1, string(project_id)); bind_text(stmt, 2, string(owner_user_id)); out := make([dynamic]domain.Project_Bridge_Path)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, path_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

project_delete_bridge_path_sqlite :: proc(ctx: rawptr, project_id: domain.Project_ID, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "DELETE FROM project_bridge_paths WHERE project_id = ? AND bridge_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare path delete")
	defer sqlite3_finalize(stmt); bind_text(stmt, 1, string(project_id)); bind_text(stmt, 2, bridge_id); bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "path could not be deleted")
	return true, domain.Domain_Error{}
}

project_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Project { return domain.Project{project_id = domain.Project_ID(column_text(stmt, 0)), owner_user_id = domain.User_ID(column_text(stmt, 1)), name = column_text(stmt, 2), slug = column_text(stmt, 3), description = column_text(stmt, 4), repo_url = column_text(stmt, 5), vcs_kind = column_text(stmt, 6), default_path = column_text(stmt, 7), created_at = column_text(stmt, 8), updated_at = column_text(stmt, 9)} }
path_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Project_Bridge_Path { return domain.Project_Bridge_Path{project_id = domain.Project_ID(column_text(stmt, 0)), bridge_id = column_text(stmt, 1), owner_user_id = domain.User_ID(column_text(stmt, 2)), path = column_text(stmt, 3), is_validated = column_text(stmt, 4) == "1", last_validated_at = column_text(stmt, 5), validation_error = column_text(stmt, 6), validation_details_json = column_text(stmt, 7), created_at = column_text(stmt, 8), updated_at = column_text(stmt, 9)} }
bind_path :: proc(stmt: sqlite3_stmt, p: domain.Project_Bridge_Path) { bind_text(stmt, 1, string(p.project_id)); bind_text(stmt, 2, p.bridge_id); bind_text(stmt, 3, string(p.owner_user_id)); bind_text(stmt, 4, p.path); bind_text(stmt, 5, "1" if p.is_validated else "0"); bind_text(stmt, 6, p.last_validated_at); bind_text(stmt, 7, p.validation_error); bind_text(stmt, 8, p.validation_details_json); bind_text(stmt, 9, p.created_at); bind_text(stmt, 10, p.updated_at) }
