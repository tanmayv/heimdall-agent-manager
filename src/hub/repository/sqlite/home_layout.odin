package sqlite

import domain "odin_test:hub/domain"

home_layout_get_sqlite :: proc(ctx: rawptr, owner: domain.User_ID) -> (domain.Home_Layout_Record, bool, domain.Domain_Error) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return {}, false, domain.domain_error(.Internal_Error, "Home layout storage is not open")
	query := "SELECT revision, payload_json FROM user_home_layouts WHERE owner_user_id=?;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed to prepare Home layout lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner))
	switch sqlite3_step(stmt) {
	case SQLITE_DONE: return {}, false, {}
	case SQLITE_ROW: return {revision = sqlite3_column_int64(stmt, 0), payload_json = column_text(stmt, 1)}, true, {}
	case: return {}, false, domain.domain_error(.Internal_Error, "failed to read Home layout")
	}
}

home_layout_cas_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, expected_version: i64, payload: string) -> (bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return false, domain.domain_error(.Internal_Error, "Home layout storage is not open")
	if string(owner) == "" || expected_version < 0 || expected_version >= domain.HOME_LAYOUT_MAX_VERSION || len(payload) > domain.HOME_LAYOUT_MAX_BYTES do return false, domain.domain_error(.Validation_Failed, "invalid Home layout write")
	// Each path is one database-atomic statement. No read-before-write window,
	// including on the first create from independent devices/connections.
	query := "UPDATE user_home_layouts SET revision=revision+1, payload_json=?3 WHERE owner_user_id=?1 AND revision=?2;"
	if expected_version == 0 do query = "INSERT INTO user_home_layouts(owner_user_id,revision,payload_json) VALUES (?1,?2+1,?3) ON CONFLICT(owner_user_id) DO NOTHING;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare Home layout save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner))
	sqlite3_bind_int64(stmt, 2, expected_version)
	bind_text(stmt, 3, payload)
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to save Home layout")
	if changed != 1 do return false, domain.domain_error(.Conflict, "The Home layout changed elsewhere.", `{"reason":"home_layout_version_conflict"}`)
	return true, {}
}
