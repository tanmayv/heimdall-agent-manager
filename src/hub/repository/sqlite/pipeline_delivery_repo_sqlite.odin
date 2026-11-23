package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Pipeline_Delivery_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_pipeline_delivery_repository :: proc(
	impl: ^Pipeline_Delivery_Repo_SQLite,
	conn: ^Conn,
) -> iface.Pipeline_Delivery_Repository {
	impl.conn = conn
	return {
		ctx = impl,
		insert = pipeline_insert,
		get = pipeline_get,
		transition = pipeline_transition,
		open_for_bridge = pipeline_open_for_bridge,
		open_by_ref = pipeline_open_by_ref,
		in_flight = pipeline_in_flight,
		expired = pipeline_expired,
		prune = pipeline_prune,
	}
}

// Export production SQL so query-plan tests exercise exactly these statements.
PIPELINE_COLUMNS :: "delivery_id,owner_user_id,kind,bridge_id,agent_instance_id,ref,message_id,state,outcome,reason,round,excluded_bridges,attempt,ack_reply,stream_sequence,retry_at,expires_at,created_at,forwarded_at,updated_at"
PIPELINE_GET_SQL :: "SELECT " + PIPELINE_COLUMNS + " FROM pipeline_deliveries WHERE delivery_id=?1;"
PIPELINE_OPEN_REF_SQL ::
	"SELECT " +
	PIPELINE_COLUMNS +
	" FROM pipeline_deliveries WHERE ref=?1 AND state IN ('routed','forwarded') LIMIT 1;"
PIPELINE_OPEN_BRIDGE_SQL ::
	"SELECT " +
	PIPELINE_COLUMNS +
	" FROM pipeline_deliveries WHERE bridge_id=?1 AND state IN ('routed','forwarded') AND (?2='' OR state=?2) ORDER BY created_at,delivery_id LIMIT ?3;"
PIPELINE_EXPIRED_SQL ::
	"SELECT " +
	PIPELINE_COLUMNS +
	" FROM pipeline_deliveries WHERE state IN ('routed','forwarded') AND expires_at<=?1 ORDER BY expires_at,delivery_id LIMIT ?2;"
PIPELINE_IN_FLIGHT_SQL :: "SELECT count(*) FROM pipeline_deliveries WHERE bridge_id=?1 AND state IN ('routed','forwarded') AND state='forwarded' AND retry_at='' AND updated_at>?2;"
PIPELINE_PRUNE_SQL :: "DELETE FROM pipeline_deliveries WHERE delivery_id IN (SELECT delivery_id FROM pipeline_deliveries WHERE state IN ('done','failed','replaced') AND updated_at<?1 ORDER BY updated_at LIMIT 128);"
PIPELINE_INSERT_SQL ::
	"INSERT INTO pipeline_deliveries(" +
	PIPELINE_COLUMNS +
	") VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20);"
PIPELINE_TRANSITION_SQL :: "UPDATE pipeline_deliveries SET kind=?1,bridge_id=?2,agent_instance_id=?3,ref=?4,message_id=?5,state=?6,outcome=?7,reason=?8,round=?9,excluded_bridges=?10,attempt=?11,ack_reply=?12,stream_sequence=?13,retry_at=?14,expires_at=?15,forwarded_at=?16,updated_at=?17 WHERE delivery_id=?18 AND state=?19;"

pipeline_prepare :: proc(ctx: rawptr, query: cstring) -> (sqlite3_stmt, domain.Domain_Error) {
	impl := (^Pipeline_Delivery_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil || !outbox_uow_owns(impl.conn) {
		return nil, domain.domain_error(.Internal_Error, "pipeline delivery requires a unit of work")
	}
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare pipeline delivery query")
	}
	return stmt, {}
}

pipeline_read :: proc(stmt: sqlite3_stmt) -> domain.Pipeline_Delivery {
	return {
		delivery_id = column_text(stmt, 0),
		owner_user_id = column_text(stmt, 1),
		kind = column_text(stmt, 2),
		bridge_id = column_text(stmt, 3),
		agent_instance_id = column_text(stmt, 4),
		ref = column_text(stmt, 5),
		message_id = column_text(stmt, 6),
		state = column_text(stmt, 7),
		outcome = column_text(stmt, 8),
		reason = column_text(stmt, 9),
		round = int(sqlite3_column_int64(stmt, 10)),
		excluded_bridges_json = column_text(stmt, 11),
		attempt = int(sqlite3_column_int64(stmt, 12)),
		ack_reply = column_text(stmt, 13),
		stream_sequence = sqlite3_column_int64(stmt, 14),
		retry_at = column_text(stmt, 15),
		expires_at = column_text(stmt, 16),
		created_at = column_text(stmt, 17),
		forwarded_at = column_text(stmt, 18),
		updated_at = column_text(stmt, 19),
	}
}

pipeline_insert :: proc(ctx: rawptr, d: domain.Pipeline_Delivery) -> domain.Domain_Error {
	stmt, err := pipeline_prepare(ctx, PIPELINE_INSERT_SQL)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, d.delivery_id); bind_text(stmt, 2, d.owner_user_id); bind_text(stmt, 3, d.kind)
	bind_text(stmt, 4, d.bridge_id); bind_text(stmt, 5, d.agent_instance_id); bind_text(stmt, 6, d.ref)
	bind_text(
		stmt,
		7,
		d.message_id,
	); bind_text(stmt, 8, d.state); bind_text(stmt, 9, d.outcome); bind_text(stmt, 10, d.reason)
	sqlite3_bind_int64(stmt, 11, i64(d.round)); bind_text(stmt, 12, d.excluded_bridges_json)
	sqlite3_bind_int64(
		stmt,
		13,
		i64(d.attempt),
	); bind_text(stmt, 14, d.ack_reply); sqlite3_bind_int64(stmt, 15, d.stream_sequence)
	bind_text(stmt, 16, d.retry_at); bind_text(stmt, 17, d.expires_at); bind_text(stmt, 18, d.created_at)
	bind_text(stmt, 19, d.forwarded_at); bind_text(stmt, 20, d.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to insert pipeline delivery")
	return {}
}

pipeline_transition :: proc(
	ctx: rawptr,
	d: domain.Pipeline_Delivery,
	from_state: string,
) -> (
	bool,
	domain.Domain_Error,
) {
	stmt, err := pipeline_prepare(ctx, PIPELINE_TRANSITION_SQL)
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, d.kind); bind_text(stmt, 2, d.bridge_id); bind_text(stmt, 3, d.agent_instance_id)
	bind_text(stmt, 4, d.ref); bind_text(stmt, 5, d.message_id); bind_text(stmt, 6, d.state)
	bind_text(stmt, 7, d.outcome); bind_text(stmt, 8, d.reason); sqlite3_bind_int64(stmt, 9, i64(d.round))
	bind_text(stmt, 10, d.excluded_bridges_json); sqlite3_bind_int64(stmt, 11, i64(d.attempt))
	bind_text(stmt, 12, d.ack_reply); sqlite3_bind_int64(stmt, 13, d.stream_sequence); bind_text(stmt, 14, d.retry_at)
	bind_text(stmt, 15, d.expires_at); bind_text(stmt, 16, d.forwarded_at); bind_text(stmt, 17, d.updated_at)
	bind_text(stmt, 18, d.delivery_id); bind_text(stmt, 19, from_state)
	impl := (^Pipeline_Delivery_Repo_SQLite)(ctx)
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to transition pipeline delivery")
	return changed > 0, {}
}

pipeline_find :: proc(
	ctx: rawptr,
	query: cstring,
	key: string,
) -> (
	domain.Pipeline_Delivery,
	bool,
	domain.Domain_Error,
) {
	stmt, err := pipeline_prepare(ctx, query)
	if err.code != .None do return {}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, key)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, {}
	if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed to read pipeline delivery")
	return pipeline_read(stmt), true, {}
}

pipeline_get :: proc(ctx: rawptr, key: string) -> (domain.Pipeline_Delivery, bool, domain.Domain_Error) {
	return pipeline_find(ctx, PIPELINE_GET_SQL, key)
}

pipeline_open_by_ref :: proc(ctx: rawptr, key: string) -> (domain.Pipeline_Delivery, bool, domain.Domain_Error) {
	return pipeline_find(ctx, PIPELINE_OPEN_REF_SQL, key)
}

pipeline_collect :: proc(stmt: sqlite3_stmt) -> ([]domain.Pipeline_Delivery, domain.Domain_Error) {
	rows := make([dynamic]domain.Pipeline_Delivery)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do return rows[:], {}
		if rc != SQLITE_ROW {
			domain.pipeline_deliveries_destroy(rows[:])
			return nil, domain.domain_error(.Internal_Error, "failed to list pipeline deliveries")
		}
		append(&rows, pipeline_read(stmt))
	}
}

pipeline_open_for_bridge :: proc(
	ctx: rawptr,
	bridge_id, state_filter: string,
	limit: int,
) -> (
	[]domain.Pipeline_Delivery,
	domain.Domain_Error,
) {
	stmt, err := pipeline_prepare(ctx, PIPELINE_OPEN_BRIDGE_SQL)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id); bind_text(stmt, 2, state_filter); sqlite3_bind_int64(stmt, 3, i64(limit))
	return pipeline_collect(stmt)
}

pipeline_expired :: proc(ctx: rawptr, now: string, limit: int) -> ([]domain.Pipeline_Delivery, domain.Domain_Error) {
	stmt, err := pipeline_prepare(ctx, PIPELINE_EXPIRED_SQL)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, now); sqlite3_bind_int64(stmt, 2, i64(limit))
	return pipeline_collect(stmt)
}

pipeline_in_flight :: proc(ctx: rawptr, bridge_id, since: string) -> (int, domain.Domain_Error) {
	stmt, err := pipeline_prepare(ctx, PIPELINE_IN_FLIGHT_SQL)
	if err.code != .None do return 0, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id); bind_text(stmt, 2, since)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to count pipeline deliveries")
	return int(sqlite3_column_int64(stmt, 0)), {}
}

pipeline_prune :: proc(ctx: rawptr, cutoff: string) -> domain.Domain_Error {
	stmt, err := pipeline_prepare(ctx, PIPELINE_PRUNE_SQL)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, cutoff)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to prune pipeline deliveries")
	return {}
}
