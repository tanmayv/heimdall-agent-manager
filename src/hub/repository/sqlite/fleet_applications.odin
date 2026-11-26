package sqlite

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"

fleet_application_decode :: proc(stmt: sqlite3_stmt) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	raw := column_text(stmt, 2); defer delete(raw)
	r := domain.Fleet_Application_Record{owner_user_id=domain.User_ID(column_text(stmt, 0)),request_json=column_text(stmt, 1)}
	r.authority_json=column_text(stmt,3)
	if json.unmarshal_string(raw, &r.application) != nil {
		domain.fleet_application_record_destroy(&r)
		return {}, false, fleet_db_error()
	}
	return r, true, {}
}

fleet_application_operation_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, instance_id, key: string) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	q := "SELECT owner_user_id,request_json,application_json,authority_json FROM bridge_fleet_applications a WHERE owner_user_id=?1 AND EXISTS (SELECT 1 FROM json_each(a.application_json,'$.targets') t WHERE json_extract(t.value,'$.agent_instance_id')=?2 AND json_extract(t.value,'$.operation_key')=?3) LIMIT 1;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, fleet_db_error()
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,string(owner)); bind_text(stmt,2,instance_id); bind_text(stmt,3,key)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {},false,domain.domain_error(.Not_Found,"Fleet application not found")
	if rc != SQLITE_ROW do return {},false,fleet_db_error()
	return fleet_application_decode(stmt)
}

fleet_application_get_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, bridge_id, id: string, by_request: bool) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	q := "SELECT owner_user_id,request_json,application_json,authority_json FROM bridge_fleet_applications WHERE owner_user_id=?1 AND bridge_id=?2 AND application_id=?3;"
	if by_request do q = "SELECT owner_user_id,request_json,application_json,authority_json FROM bridge_fleet_applications WHERE owner_user_id=?1 AND bridge_id=?2 AND request_id=?3;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, fleet_db_error()
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner)); bind_text(stmt, 2, bridge_id); bind_text(stmt, 3, id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, domain.domain_error(.Not_Found, "Fleet application not found")
	if rc != SQLITE_ROW do return {}, false, fleet_db_error()
	return fleet_application_decode(stmt)
}

fleet_application_put_sqlite :: proc(ctx: rawptr, r: domain.Fleet_Application_Record, expected_revision: int) -> (bool, domain.Domain_Error) {
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	a := r.application
	if a.revision != expected_revision + 1 do return false, domain.domain_error(.Conflict, "stale Fleet application revision")
	data, je := json.marshal(a); defer delete(data)
	if je != nil do return false, fleet_db_error()
	q := "INSERT INTO bridge_fleet_applications(application_id,bridge_id,owner_user_id,request_id,request_json,revision,state,application_json,authority_json) SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?10 FROM bridges b WHERE b.bridge_id=?2 AND b.owner_user_id=?3;"
	if expected_revision > 0 do q = "UPDATE bridge_fleet_applications SET revision=?6,state=?7,application_json=?8 WHERE application_id=?1 AND bridge_id=?2 AND owner_user_id=?3 AND request_id=?4 AND request_json=?5 AND revision=?9 AND authority_json=?10;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return false, fleet_db_error()
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, a.application_id); bind_text(stmt, 2, a.bridge_id); bind_text(stmt, 3, string(r.owner_user_id))
	bind_text(stmt, 4, a.request_id); bind_text(stmt, 5, r.request_json); sqlite3_bind_int64(stmt, 6, i64(a.revision))
	bind_text(stmt, 7, a.state); bind_text(stmt, 8, string(data))
	if expected_revision > 0 do sqlite3_bind_int64(stmt, 9, i64(expected_revision))
	bind_text(stmt,10,r.authority_json)
	rc,changed:=step_changes(impl.conn.db,stmt)
	if rc != SQLITE_DONE do return false, fleet_db_error()
	if changed != 1 do return false, domain.domain_error(.Conflict, "Fleet application changed")
	return true, {}
}

fleet_application_list_sqlite :: proc(ctx: rawptr) -> ([]domain.Fleet_Application_Record, domain.Domain_Error) {
	guard := tx_repository_enter(); defer tx_repository_leave(guard)
	impl := (^Bridge_Repo_SQLite)(ctx)
	// Settled partial failures change only through an explicit retry. Keep the
	// partial index predicate verbatim so SQLite can still use it, then narrow.
	q := "SELECT owner_user_id,request_json,application_json,authority_json FROM bridge_fleet_applications WHERE state IN ('pending','restarting','partial_failure') AND state<>'partial_failure' ORDER BY application_id;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return nil, fleet_db_error()
	defer sqlite3_finalize(stmt)
	items := make([dynamic]domain.Fleet_Application_Record)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		r: domain.Fleet_Application_Record
		ok := false
		err: domain.Domain_Error
		if rc == SQLITE_ROW do r, ok, err = fleet_application_decode(stmt)
		if !ok {
			for &item in items do domain.fleet_application_record_destroy(&item)
			delete(items)
			return nil, err if err.code != .None else fleet_db_error()
		}
		append(&items, r)
	}
	out := make([]domain.Fleet_Application_Record, len(items)); copy(out, items[:]); delete(items)
	return out, {}
}
