package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Card_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_card_repository :: proc(impl: ^Card_Repo_SQLite, conn: ^Conn) -> iface.Card_Repository {
	impl.conn = conn
	return iface.Card_Repository{
		ctx = rawptr(impl),
		create = card_create_sqlite,
		get = card_get_sqlite,
		list = card_list_sqlite,
		list_by_project = card_list_by_project_sqlite,
		update_status = card_update_status_sqlite,
		update = card_update_sqlite,
		delete_card = card_delete_sqlite,
	}
}

card_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Card {
	card: domain.Card
	card.card_id = domain.Card_ID(column_text(stmt, 0))
	card.owner_user_id = domain.User_ID(column_text(stmt, 1))
	card.project_id = domain.Project_ID(column_text(stmt, 2))
	card.title = column_text(stmt, 3)
	card.rationale = column_text(stmt, 4)
	card.scope = column_text(stmt, 5)
	if card.scope == "" do card.scope = "project"
	card.provider = column_text(stmt, 6)
	card.confidence = f32(sqlite3_column_double(stmt, 7))
	card.source_refs_json = column_text(stmt, 8)
	if card.source_refs_json == "" do card.source_refs_json = "[]"
	card.status = column_text(stmt, 9)
	if card.status == "" do card.status = "pending"
	card.operations_json = column_text(stmt, 10)
	if card.operations_json == "" do card.operations_json = "[]"
	card.guard_json = column_text(stmt, 11)
	if card.guard_json == "" do card.guard_json = "{}"
	card.snooze_until = column_text(stmt, 12)
	card.ttl_at = column_text(stmt, 13)
	card.created_at = column_text(stmt, 14)
	card.updated_at = column_text(stmt, 15)
	return card
}

bind_card_insert :: proc(stmt: sqlite3_stmt, card: domain.Card) {
	scope := card.scope
	if scope == "" do scope = "project"
	source_refs := card.source_refs_json
	if source_refs == "" do source_refs = "[]"
	status := card.status
	if status == "" do status = "pending"
	ops := card.operations_json
	if ops == "" do ops = "[]"
	guard := card.guard_json
	if guard == "" do guard = "{}"

	bind_text(stmt, 1, string(card.card_id))
	bind_text(stmt, 2, string(card.owner_user_id))
	bind_text(stmt, 3, string(card.project_id))
	bind_text(stmt, 4, card.title)
	bind_text(stmt, 5, card.rationale)
	bind_text(stmt, 6, scope)
	bind_text(stmt, 7, card.provider)
	sqlite3_bind_double(stmt, 8, c.double(card.confidence))
	bind_text(stmt, 9, source_refs)
	bind_text(stmt, 10, status)
	bind_text(stmt, 11, ops)
	bind_text(stmt, 12, guard)
	bind_text(stmt, 13, card.snooze_until)
	bind_text(stmt, 14, card.ttl_at)
	bind_text(stmt, 15, card.created_at)
	bind_text(stmt, 16, card.updated_at)
}

card_create_sqlite :: proc(ctx: rawptr, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO cards (
		card_id, owner_user_id, project_id, title, rationale, scope,
		provider, confidence, source_refs_json, status, operations_json,
		guard_json, snooze_until, ttl_at, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to prepare card insert")
	}
	defer sqlite3_finalize(stmt)

	bind_card_insert(stmt, card)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Card{}, false, domain.domain_error(.Conflict, "card could not be saved")
	}
	saved := card
	if saved.scope == "" do saved.scope = "project"
	if saved.status == "" do saved.status = "pending"
	if saved.source_refs_json == "" do saved.source_refs_json = "[]"
	if saved.operations_json == "" do saved.operations_json = "[]"
	if saved.guard_json == "" do saved.guard_json = "{}"
	return saved, true, domain.Domain_Error{}
}

card_get_sqlite :: proc(ctx: rawptr, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at FROM cards WHERE card_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to prepare card lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	if sqlite3_step(stmt) != SQLITE_ROW {
		return domain.Card{}, false, domain.domain_error(.Not_Found, "card not found")
	}
	return card_from_stmt(stmt), true, domain.Domain_Error{}
}

card_list_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Card, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at FROM cards WHERE owner_user_id = ? ORDER BY created_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare card list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))

	items := make([dynamic]domain.Card)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, card_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

card_list_by_project_sqlite :: proc(ctx: rawptr, project_id: domain.Project_ID) -> ([]domain.Card, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at FROM cards WHERE project_id = ? ORDER BY created_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare card list by project")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(project_id))

	items := make([dynamic]domain.Card)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, card_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

card_update_status_sqlite :: proc(ctx: rawptr, id: domain.Card_ID, status: string, updated_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE cards SET status = ?, updated_at = ? WHERE card_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare card update status")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, status)
	bind_text(stmt, 2, updated_at)
	bind_text(stmt, 3, string(id))

	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to update card status")
	}
	return sqlite3_changes(impl.conn.db) > 0, domain.Domain_Error{}
}

card_update_sqlite :: proc(ctx: rawptr, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `UPDATE cards SET
		title = ?, rationale = ?, scope = ?, provider = ?, confidence = ?,
		source_refs_json = ?, status = ?, operations_json = ?, guard_json = ?,
		snooze_until = ?, ttl_at = ?, updated_at = ?
		WHERE card_id = ?;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to prepare card update")
	}
	defer sqlite3_finalize(stmt)

	scope := card.scope
	if scope == "" do scope = "project"
	source_refs := card.source_refs_json
	if source_refs == "" do source_refs = "[]"
	status := card.status
	if status == "" do status = "pending"
	ops := card.operations_json
	if ops == "" do ops = "[]"
	guard := card.guard_json
	if guard == "" do guard = "{}"

	bind_text(stmt, 1, card.title)
	bind_text(stmt, 2, card.rationale)
	bind_text(stmt, 3, scope)
	bind_text(stmt, 4, card.provider)
	sqlite3_bind_double(stmt, 5, c.double(card.confidence))
	bind_text(stmt, 6, source_refs)
	bind_text(stmt, 7, status)
	bind_text(stmt, 8, ops)
	bind_text(stmt, 9, guard)
	bind_text(stmt, 10, card.snooze_until)
	bind_text(stmt, 11, card.ttl_at)
	bind_text(stmt, 12, card.updated_at)
	bind_text(stmt, 13, string(card.card_id))

	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to update card")
	}
	if sqlite3_changes(impl.conn.db) == 0 {
		return domain.Card{}, false, domain.domain_error(.Not_Found, "card not found")
	}
	updated := card
	updated.scope = scope
	updated.source_refs_json = source_refs
	updated.status = status
	updated.operations_json = ops
	updated.guard_json = guard
	return updated, true, domain.Domain_Error{}
}

card_delete_sqlite :: proc(ctx: rawptr, id: domain.Card_ID) -> (bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM cards WHERE card_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare card delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete card")
	}
	return sqlite3_changes(impl.conn.db) > 0, domain.Domain_Error{}
}
