package sqlite

import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Bridge_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_bridge_repository :: proc(impl: ^Bridge_Repo_SQLite, conn: ^Conn) -> iface.Bridge_Repository {
	impl.conn = conn
	return iface.Bridge_Repository{
		ctx = rawptr(impl),
		save_enrollment = bridge_save_enrollment_sqlite,
		get_enrollment_by_token_hash = bridge_get_enrollment_by_token_hash_sqlite,
		get_enrollment = bridge_get_enrollment_sqlite,
		list_enrollments_by_owner = bridge_list_enrollments_by_owner_sqlite,
		save_bridge = bridge_save_bridge_sqlite,
		get_bridge = bridge_get_bridge_sqlite,
		get_bridge_by_token_hash = bridge_get_bridge_by_token_hash_sqlite,
		list_by_owner = bridge_list_by_owner_sqlite,
	}
}

bridge_save_enrollment_sqlite :: proc(ctx: rawptr, enrollment: domain.Bridge_Enrollment) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO bridge_enrollments (enrollment_id, owner_user_id, label, token_hash, status, expires_at, consumed_at, consumed_by_bridge_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(enrollment_id) DO UPDATE SET label=excluded.label, status=excluded.status, expires_at=excluded.expires_at, consumed_at=excluded.consumed_at, consumed_by_bridge_id=excluded.consumed_by_bridge_id, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Internal_Error, "failed to prepare enrollment save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, enrollment.enrollment_id)
	bind_text(stmt, 2, string(enrollment.owner_user_id))
	bind_text(stmt, 3, enrollment.label)
	bind_text(stmt, 4, enrollment.token_hash)
	bind_text(stmt, 5, domain.enrollment_status_string(enrollment.status))
	bind_text(stmt, 6, enrollment.expires_at)
	bind_text(stmt, 7, enrollment.consumed_at)
	bind_text(stmt, 8, enrollment.consumed_by_bridge_id)
	bind_text(stmt, 9, enrollment.created_at)
	bind_text(stmt, 10, enrollment.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Conflict, "enrollment could not be saved")
	return enrollment, true, domain.Domain_Error{}
}

bridge_get_enrollment_by_token_hash_sqlite :: proc(ctx: rawptr, token_hash: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT enrollment_id, owner_user_id, label, token_hash, status, expires_at, consumed_at, consumed_by_bridge_id, created_at, updated_at FROM bridge_enrollments WHERE token_hash = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Internal_Error, "failed to prepare enrollment lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, token_hash)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Not_Found, "enrollment not found")
	return enrollment_from_stmt(stmt), true, domain.Domain_Error{}
}

bridge_get_enrollment_sqlite :: proc(ctx: rawptr, enrollment_id: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT enrollment_id, owner_user_id, label, token_hash, status, expires_at, consumed_at, consumed_by_bridge_id, created_at, updated_at FROM bridge_enrollments WHERE enrollment_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Internal_Error, "failed to prepare enrollment lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, enrollment_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Not_Found, "enrollment not found")
	return enrollment_from_stmt(stmt), true, domain.Domain_Error{}
}

bridge_list_enrollments_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Bridge_Enrollment, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT enrollment_id, owner_user_id, label, token_hash, status, expires_at, consumed_at, consumed_by_bridge_id, created_at, updated_at FROM bridge_enrollments WHERE owner_user_id = ? ORDER BY created_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare enrollment list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Bridge_Enrollment)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, enrollment_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

bridge_save_bridge_sqlite :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO bridges (bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(bridge_id) DO UPDATE SET label=excluded.label, label_is_user_customized=excluded.label_is_user_customized, machine_hostname=excluded.machine_hostname, machine_os=excluded.machine_os, machine_arch=excluded.machine_arch, capabilities_json=excluded.capabilities_json, hub_url=excluded.hub_url, status=excluded.status, bridge_token_hash=excluded.bridge_token_hash, updated_at=excluded.updated_at, last_seen_at=excluded.last_seen_at, revoked_at=excluded.revoked_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "failed to prepare bridge save")
	defer sqlite3_finalize(stmt)
	bind_bridge(stmt, bridge)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Bridge{}, false, domain.domain_error(.Conflict, "bridge could not be saved")
	return bridge, true, domain.Domain_Error{}
}

bridge_get_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	return bridge_get_by_column(ctx, "bridge_id", bridge_id)
}

bridge_get_bridge_by_token_hash_sqlite :: proc(ctx: rawptr, token_hash: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	return bridge_get_by_column(ctx, "bridge_token_hash", token_hash)
}

bridge_get_by_column :: proc(ctx: rawptr, column, value: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("SELECT bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at FROM bridges WHERE %s = ?;", column)
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "failed to prepare bridge lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, value)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Bridge{}, false, domain.domain_error(.Not_Found, "bridge not found")
	return bridge_from_stmt(stmt), true, domain.Domain_Error{}
}

bridge_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at FROM bridges WHERE owner_user_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Bridge)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, bridge_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

bind_bridge :: proc(stmt: sqlite3_stmt, bridge: domain.Bridge) {
	bind_text(stmt, 1, bridge.bridge_id)
	bind_text(stmt, 2, string(bridge.owner_user_id))
	bind_text(stmt, 3, bridge.label)
	bind_text(stmt, 4, "1" if bridge.label_is_user_customized else "0")
	bind_text(stmt, 5, bridge.machine_hostname)
	bind_text(stmt, 6, bridge.machine_os)
	bind_text(stmt, 7, bridge.machine_arch)
	bind_text(stmt, 8, bridge.capabilities_json)
	bind_text(stmt, 9, bridge.hub_url)
	bind_text(stmt, 10, domain.bridge_status_string(bridge.status))
	bind_text(stmt, 11, bridge.bridge_token_hash)
	bind_text(stmt, 12, bridge.created_at)
	bind_text(stmt, 13, bridge.updated_at)
	bind_text(stmt, 14, bridge.last_seen_at)
	bind_text(stmt, 15, bridge.revoked_at)
}

enrollment_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Bridge_Enrollment {
	return domain.Bridge_Enrollment{enrollment_id = column_text(stmt, 0), owner_user_id = domain.User_ID(column_text(stmt, 1)), label = column_text(stmt, 2), token_hash = column_text(stmt, 3), status = enrollment_status_from_string(column_text(stmt, 4)), expires_at = column_text(stmt, 5), consumed_at = column_text(stmt, 6), consumed_by_bridge_id = column_text(stmt, 7), created_at = column_text(stmt, 8), updated_at = column_text(stmt, 9)}
}

bridge_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Bridge {
	return domain.Bridge{bridge_id = column_text(stmt, 0), owner_user_id = domain.User_ID(column_text(stmt, 1)), label = column_text(stmt, 2), label_is_user_customized = column_text(stmt, 3) == "1", machine_hostname = column_text(stmt, 4), machine_os = column_text(stmt, 5), machine_arch = column_text(stmt, 6), capabilities_json = column_text(stmt, 7), hub_url = column_text(stmt, 8), status = bridge_status_from_string(column_text(stmt, 9)), bridge_token_hash = column_text(stmt, 10), created_at = column_text(stmt, 11), updated_at = column_text(stmt, 12), last_seen_at = column_text(stmt, 13), revoked_at = column_text(stmt, 14)}
}

bridge_status_from_string :: proc(status: string) -> domain.Bridge_Status {
	if status == "online" do return .Online
	if status == "revoked" do return .Revoked
	return .Offline
}

enrollment_status_from_string :: proc(status: string) -> domain.Enrollment_Status {
	if status == "consumed" do return .Consumed
	if status == "revoked" do return .Revoked
	if status == "expired" do return .Expired
	return .Pending
}
