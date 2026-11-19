package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Event_Outbox_Repo_SQLite :: struct {
	conn: ^Conn,
}
new_event_outbox_repository :: proc(impl: ^Event_Outbox_Repo_SQLite, conn: ^Conn) -> iface.Event_Outbox_Repository {
	impl.conn = conn
	return {
		ctx = impl,
		next_version = outbox_next_version,
		open_topic = outbox_open_topic,
		resolve_topic = outbox_resolve_topic,
		append = outbox_append,
		next = outbox_next,
		mark_published = outbox_mark,
		backlog = outbox_backlog,
 backlog_owner = outbox_backlog_owner,
		prune = outbox_prune,
	}
}
// The shared request connection must never expose uncommitted rows to the relay.
// Require the caller's UoW for reads as well as writes.
outbox_prepare :: proc(ctx: rawptr, query: cstring) -> (sqlite3_stmt, domain.Domain_Error) {
	impl := (^Event_Outbox_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil || !outbox_uow_owns(impl.conn) {
		return nil, domain.domain_error(.Internal_Error, "event outbox requires a unit of work")
	}
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare event outbox query")
	}
	return stmt, {}
}
outbox_append :: proc(ctx: rawptr, row: domain.Event_Outbox_Row) -> domain.Domain_Error {
	stmt, err := outbox_prepare(
		ctx,
		"INSERT INTO event_outbox(event_id,owner_user_id,subject,envelope_json,headers_json,created_at) VALUES(?,?,?,?,?,?);",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, row.event_id); bind_text(stmt, 2, row.owner_user_id); bind_text(stmt, 3, row.subject)
	bind_text(stmt, 4, row.envelope_json); bind_text(stmt, 5, row.headers_json if row.headers_json != "" else "{}")
	bind_text(stmt, 6, row.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to append event outbox")
	return {}
}
outbox_next :: proc(ctx: rawptr) -> (row: domain.Event_Outbox_Row, found: bool, err: domain.Domain_Error) {
	stmt: sqlite3_stmt
	stmt, err = outbox_prepare(
		ctx,
		"SELECT outbox_seq,event_id,owner_user_id,subject,envelope_json,headers_json,created_at FROM event_outbox WHERE published_at IS NULL ORDER BY outbox_seq LIMIT 1;",
	)
	if err.code != .None do return
	defer sqlite3_finalize(stmt)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return
	if rc != SQLITE_ROW {err = domain.domain_error(.Internal_Error, "failed to read event outbox"); return}
	row = {
		outbox_seq    = sqlite3_column_int64(stmt, 0),
		event_id      = column_text(stmt, 1),
		owner_user_id = column_text(stmt, 2),
		subject       = column_text(stmt, 3),
		envelope_json = column_text(stmt, 4),
		headers_json  = column_text(stmt, 5),
		created_at    = column_text(stmt, 6),
	}
	found = true
	return
}
outbox_mark :: proc(ctx: rawptr, seq: i64, published_at: string) -> domain.Domain_Error {
	stmt, err := outbox_prepare(
		ctx,
		"UPDATE event_outbox SET published_at=? WHERE outbox_seq=? AND published_at IS NULL;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, published_at); sqlite3_bind_int64(stmt, 2, seq)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to mark event published")
	return {}
}
outbox_backlog :: proc(ctx: rawptr) -> (i64, domain.Domain_Error) {
	stmt, err := outbox_prepare(ctx, "SELECT count(*) FROM event_outbox WHERE published_at IS NULL;")
	if err.code != .None do return 0, err
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to count event outbox")
	return sqlite3_column_int64(stmt, 0), {}
}
outbox_prune :: proc(ctx: rawptr, before: string) -> domain.Domain_Error {
	stmt, err := outbox_prepare(ctx, "DELETE FROM event_outbox WHERE published_at < ?;")
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, before)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to prune event outbox")
	return {}
}

// Versions and topics are protected by the same caller-owned UoW as the outbox.
outbox_next_version :: proc(ctx: rawptr, owner, kind, id: string) -> (i64, domain.Domain_Error) {
	stmt, err := outbox_prepare(
		ctx,
		"INSERT INTO event_entity_versions(owner_user_id,entity_kind,entity_id,version) VALUES(?,?,?,1) ON CONFLICT(owner_user_id,entity_kind,entity_id) DO UPDATE SET version=version+1 RETURNING version;",
	)
	if err.code != .None do return 0, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, kind); bind_text(stmt, 3, id)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to increment event version")
	return sqlite3_column_int64(stmt, 0), {}
}
outbox_open_topic :: proc(
	ctx: rawptr,
	owner, topic, event_id: string,
	replace_open: bool,
) -> (
	i64,
	bool,
	domain.Domain_Error,
) {
	// Gate evaluation and recovery may revisit an unchanged pending request.
	// Only a new triggering change may replace an already-open generation.
	stmt, err := outbox_prepare(
		ctx,
		"INSERT INTO event_topics(owner_user_id,topic_key,generation,opened_event_id) VALUES(?,?,1,?) ON CONFLICT(owner_user_id,topic_key) DO UPDATE SET generation=generation+1,opened_event_id=excluded.opened_event_id WHERE ? OR generation<=resolved_generation RETURNING generation;",
	)
	if err.code != .None do return 0, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, topic); bind_text(stmt, 3, event_id)
	sqlite3_bind_int(stmt, 4, 1 if replace_open else 0)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return 0, false, {}
	if rc != SQLITE_ROW do return 0, false, domain.domain_error(.Internal_Error, "failed to open event topic")
	return sqlite3_column_int64(stmt, 0), true, {}
}
outbox_resolve_topic :: proc(ctx: rawptr, owner, topic, at, event_id: string) -> domain.Domain_Error {
	stmt, err := outbox_prepare(
		ctx,
		"UPDATE event_topics SET resolved_generation=generation,resolved_at=?,resolved_by_event_id=? WHERE owner_user_id=? AND topic_key=? AND resolved_generation<generation;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, at); bind_text(stmt, 2, event_id); bind_text(stmt, 3, owner); bind_text(stmt, 4, topic)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to resolve event topic")
	return {}
}

outbox_backlog_owner :: proc(ctx: rawptr, owner: string) -> (i64, domain.Domain_Error) {
 stmt, err := outbox_prepare(ctx, "SELECT count(*) FROM event_outbox WHERE published_at IS NULL AND owner_user_id=?;")
 if err.code != .None do return 0, err
 defer sqlite3_finalize(stmt)
 bind_text(stmt, 1, owner)
 if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to count owner outbox")
 return sqlite3_column_int64(stmt, 0), {}
}
