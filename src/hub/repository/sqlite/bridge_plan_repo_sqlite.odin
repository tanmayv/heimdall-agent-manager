package sqlite

import "core:slice"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// All plan mutations share the enrollment connection and SQLite write lock.
// Production never BEGINs a transaction on the shared request connection.
bridge_create_limited_sqlite :: proc(ctx: rawptr, bridge: domain.Bridge, max_bridges: int, sunset: iface.Bridge_Sunset) -> (domain.Bridge, iface.Bridge_Sunset_Receipt, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	conn := impl.conn
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_create_limited_on(&impl.commit.conn, bridge, max_bridges, sunset)
	}
	return bridge_create_limited_on(conn, bridge, max_bridges, sunset)
}

// bridge_create_limited_on is the admission transaction. With a sunset it is the
// whole "replace one of my bridges" step: retire the sunset bridge (credentials, then
// row, same order as revoke_bridge), count, insert — all under one BEGIN IMMEDIATE,
// so a failure at any point (sunset refused, plan still full, insert failed, COMMIT
// failed) leaves the sunset bridge exactly as it was.
bridge_create_limited_on :: proc(conn: ^Conn, bridge: domain.Bridge, max_bridges: int, sunset: iface.Bridge_Sunset) -> (domain.Bridge, iface.Bridge_Sunset_Receipt, bool, domain.Domain_Error) {
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, {}, false, domain.domain_error(.Internal_Error, "failed to begin bridge approval")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	local := Bridge_Repo_SQLite{conn = conn}
	receipt: iface.Bridge_Sunset_Receipt
	// Freed on every path that does not hand the receipt to the caller.
	defer if !committed do iface.bridge_sunset_receipt_destroy(&receipt)
	if sunset.bridge_id != "" {
		sunset_err := bridge_sunset_on(conn, bridge.owner_user_id, sunset, &receipt)
		if sunset_err.code != .None do return {}, {}, false, sunset_err
	}
	count, err := bridge_count_active_by_owner_sqlite(&local, bridge.owner_user_id)
	if err.code != .None do return {}, {}, false, err
	if max_bridges >= 0 && count >= max_bridges do return {}, {}, false, domain.plan_limit_error("max_bridges", max_bridges, count, "Current")
	saved, ok, save_err := bridge_save_bridge_sqlite(&local, bridge)
	if !ok do return {}, {}, false, save_err
	if bridge_create_limited_test_hook != nil && !bridge_create_limited_test_hook() {
		return {}, {}, false, domain.domain_error(.Internal_Error, "failed to commit bridge approval")
	}
	if !exec(conn, "COMMIT;") do return {}, {}, false, domain.domain_error(.Internal_Error, "failed to commit bridge approval")
	committed = true
	return saved, receipt, true, {}
}

// bridge_create_limited_test_hook runs inside the admission transaction after the
// insert and before COMMIT; returning false fails the transaction as a failed COMMIT
// would. Tests only — nil in production.
bridge_create_limited_test_hook: proc() -> bool

// bridge_sunset_on retires the sunset bridge inside the caller's transaction and fills
// `receipt` with what it changed. Refusals: absent, owned by someone else, or already
// revoked -> .Not_Found with the same text (revoke_bridge's anti-enumeration shape);
// the owner's own still-pending enrollment -> .Validation_Failed (it is not a bridge
// yet; cancel it instead, and it would otherwise be deleted by the sweep under us).
@(private = "file")
bridge_sunset_on :: proc(conn: ^Conn, owner: domain.User_ID, sunset: iface.Bridge_Sunset, receipt: ^iface.Bridge_Sunset_Receipt) -> domain.Domain_Error {
	local := Bridge_Repo_SQLite{conn = conn}
	current, found, _ := bridge_get_bridge_sqlite(&local, sunset.bridge_id)
	defer if found do domain.bridge_destroy(&current)
	not_found := domain.domain_error(.Not_Found, "resource not found")
	if !found || current.owner_user_id != owner do return not_found
	if current.status == .Revoked || current.revoked_at != "" do return not_found
	if current.enrollment_pending_until != "" {
		return domain.domain_error(.Validation_Failed, "a bridge that is still enrolling cannot be sunset; cancel its enrollment instead")
	}
	// Credentials first, recording each one so a rollback revives exactly these.
	ids := make([dynamic]string)
	ok := false
	defer if !ok {
		for id in ids do delete(id)
		delete(ids)
	}
	sel: sqlite3_stmt
	sel_sql := "SELECT token_id FROM bridge_tokens WHERE bridge_id = ? AND revoked_at = '';"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(sel_sql)), -1, &sel, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare sunset token lookup")
	bind_text(sel, 1, sunset.bridge_id)
	for {
		rc := sqlite3_step(sel)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			sqlite3_finalize(sel)
			return domain.domain_error(.Internal_Error, "failed to read sunset bridge tokens")
		}
		append(&ids, column_text(sel, 0))
	}
	sqlite3_finalize(sel)
	if _, revoke_ok, revoke_err := bridge_revoke_tokens_for_bridge_sqlite(&local, sunset.bridge_id, sunset.revoked_at); !revoke_ok do return revoke_err
	upd: sqlite3_stmt
	upd_sql := "UPDATE bridges SET status = 'revoked', revoked_at = ?2, updated_at = ?2 WHERE bridge_id = ?1 AND status != 'revoked' AND revoked_at = '' AND enrollment_pending_until = '';"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(upd_sql)), -1, &upd, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare bridge sunset")
	defer sqlite3_finalize(upd)
	bind_text(upd, 1, sunset.bridge_id)
	bind_text(upd, 2, sunset.revoked_at)
	rc, changed := step_changes(conn.db, upd)
	if rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to sunset bridge")
	// The read above was under the same write lock, so this cannot miss; checked
	// anyway so a schema or guard drift fails closed instead of reporting a sunset
	// that did not happen.
	if changed != 1 do return domain.domain_error(.Internal_Error, "bridge sunset did not apply")
	ok = true
	receipt^ = iface.Bridge_Sunset_Receipt{
		bridge_id = strings.clone(sunset.bridge_id),
		revoked_at = strings.clone(sunset.revoked_at),
		token_ids = ids[:],
	}
	return {}
}

bridge_restore_sunset_sqlite :: proc(ctx: rawptr, replacement_bridge_id: string, receipt: iface.Bridge_Sunset_Receipt, max_bridges: int, now: string) -> (restored: bool, replacement_deleted: bool, err: domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_restore_sunset_on(&impl.commit.conn, replacement_bridge_id, receipt, max_bridges, now)
	}
	return bridge_restore_sunset_on(impl.conn, replacement_bridge_id, receipt, max_bridges, now)
}

bridge_restore_sunset_on :: proc(conn: ^Conn, replacement_bridge_id: string, receipt: iface.Bridge_Sunset_Receipt, max_bridges: int, now: string) -> (restored: bool, replacement_deleted: bool, err: domain.Domain_Error) {
	if receipt.bridge_id == "" || receipt.revoked_at == "" do return false, false, domain.domain_error(.Validation_Failed, "a sunset receipt is required")
	if !exec(conn, "BEGIN IMMEDIATE;") do return false, false, domain.domain_error(.Internal_Error, "failed to begin bridge sunset restore")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	local := Bridge_Repo_SQLite{conn = conn}
	if replacement_bridge_id != "" {
		deleted, del_err := bridge_delete_pending_sqlite(&local, replacement_bridge_id)
		if del_err.code != .None do return false, false, del_err
		replacement_deleted = deleted
		// A replacement that is still here was committed (enrolled): it owns the
		// slot now, and reviving the sunset bridge too would be two live bridges
		// where the owner approved one. Keep the delete (a no-op) and stop.
		if still, found, _ := bridge_get_bridge_sqlite(&local, replacement_bridge_id); found {
			domain.bridge_destroy(&still)
			if !exec(conn, "COMMIT;") do return false, false, domain.domain_error(.Internal_Error, "failed to commit bridge sunset restore")
			committed = true
			return false, replacement_deleted, {}
		}
	}
	current, found, _ := bridge_get_bridge_sqlite(&local, receipt.bridge_id)
	if !found do return false, false, domain.domain_error(.Not_Found, "sunset bridge not found")
	owner := domain.User_ID(strings.clone(string(current.owner_user_id)))
	defer delete(string(owner))
	// Anything else since the sunset (an operator revoke has its own revoked_at)
	// means this receipt no longer describes the row; leave it alone.
	still_ours := current.status == .Revoked && current.revoked_at == receipt.revoked_at
	domain.bridge_destroy(&current)
	if still_ours && max_bridges >= 0 {
		count, count_err := bridge_count_active_by_owner_sqlite(&local, owner)
		if count_err.code != .None do return false, false, count_err
		// The freed slot was taken by another approval after the replacement went
		// away (e.g. the sweep removed it earlier): restoring would exceed the plan.
		if count >= max_bridges do still_ours = false
	}
	if still_ours {
		upd: sqlite3_stmt
		upd_sql := "UPDATE bridges SET status = 'offline', revoked_at = '', updated_at = ?3 WHERE bridge_id = ?1 AND status = 'revoked' AND revoked_at = ?2;"
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(upd_sql)), -1, &upd, nil) != SQLITE_OK do return false, false, domain.domain_error(.Internal_Error, "failed to prepare bridge sunset restore")
		bind_text(upd, 1, receipt.bridge_id)
		bind_text(upd, 2, receipt.revoked_at)
		bind_text(upd, 3, now)
		rc, changed := step_changes(conn.db, upd)
		sqlite3_finalize(upd)
		if rc != SQLITE_DONE || changed != 1 do return false, false, domain.domain_error(.Internal_Error, "failed to restore sunset bridge")
		tok: sqlite3_stmt
		tok_sql := "UPDATE bridge_tokens SET revoked_at = '' WHERE token_id = ? AND bridge_id = ? AND revoked_at = ?;"
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(tok_sql)), -1, &tok, nil) != SQLITE_OK do return false, false, domain.domain_error(.Internal_Error, "failed to prepare sunset token restore")
		defer sqlite3_finalize(tok)
		for token_id in receipt.token_ids {
			_ = sqlite3_reset(tok)
			bind_text(tok, 1, token_id)
			bind_text(tok, 2, receipt.bridge_id)
			bind_text(tok, 3, receipt.revoked_at)
			if trc, _ := step_changes(conn.db, tok); trc != SQLITE_DONE do return false, false, domain.domain_error(.Internal_Error, "failed to restore sunset bridge token")
		}
	}
	if !exec(conn, "COMMIT;") do return false, false, domain.domain_error(.Internal_Error, "failed to commit bridge sunset restore")
	committed = true
	return still_ours, replacement_deleted, {}
}

bridge_count_active_by_owner_sqlite :: proc(ctx: rawptr, owner: domain.User_ID) -> (int, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	query := "SELECT COUNT(*) FROM bridges WHERE owner_user_id = ? AND status != 'revoked' AND revoked_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, domain.domain_error(.Internal_Error, "failed to prepare bridge count")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner))
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to count bridges")
	return int(sqlite3_column_int64(stmt, 0)), {}
}

bridge_list_owners_sqlite :: proc(ctx: rawptr) -> ([]string, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	query := "SELECT DISTINCT owner_user_id FROM bridges ORDER BY owner_user_id;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge owners")
	defer sqlite3_finalize(stmt)
	out := make([dynamic]string)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for owner in out do delete(owner)
			delete(out)
			return nil, domain.domain_error(.Internal_Error, "failed to list bridge owners")
		}
		append(&out, column_text(stmt, 0))
	}
	return out[:], {}
}

bridge_reconcile_plan_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, max_bridges: int, now: string, before: iface.Bridge_Plan_Rank_Proc) -> domain.Domain_Error {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_reconcile_plan_on(&impl.commit.conn, owner, max_bridges, now, before)
	}
	return bridge_reconcile_plan_on(impl.conn, owner, max_bridges, now, before)
}

bridge_reconcile_plan_on :: proc(conn: ^Conn, owner: domain.User_ID, max_bridges: int, now: string, before: iface.Bridge_Plan_Rank_Proc) -> domain.Domain_Error {
	if !exec(conn, "BEGIN IMMEDIATE;") do return domain.domain_error(.Internal_Error, "failed to begin bridge plan reconciliation")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	// Read pending rows too; they reserve slots during approval.
	stmt: sqlite3_stmt
	query := "SELECT bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at, version, commit_sha, build_timestamp, update_status, update_message, update_progress, update_error, telemetry_enabled, vault_status, enrollment_pending_until, plan_disabled_at FROM bridges WHERE owner_user_id = ? AND status != 'revoked' AND revoked_at = '';"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare bridge reconciliation")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner))
	rows := make([dynamic]domain.Bridge)
	defer {
		for &row in rows do domain.bridge_destroy(&row)
		delete(rows)
	}
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return domain.domain_error(.Internal_Error, "failed to read bridge reconciliation rows")
		append(&rows, bridge_from_stmt(stmt))
	}
	slice.sort_by(rows[:], before)
	update: sqlite3_stmt
	update_sql := "UPDATE bridges SET plan_disabled_at = ? WHERE bridge_id = ?;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(update_sql)), -1, &update, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare bridge suspension")
	defer sqlite3_finalize(update)
	for row, i in rows {
		disabled := max_bridges >= 0 && i >= max_bridges
		if disabled == (row.plan_disabled_at != "") do continue
		_ = sqlite3_reset(update)
		bind_text(update, 1, now if disabled else "")
		bind_text(update, 2, row.bridge_id)
		if sqlite3_step(update) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to update bridge suspension")
	}
	if !exec(conn, "COMMIT;") do return domain.domain_error(.Internal_Error, "failed to commit bridge plan reconciliation")
	committed = true
	return {}
}
