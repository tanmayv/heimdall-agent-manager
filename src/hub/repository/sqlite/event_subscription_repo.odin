package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Event_Subscription_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_event_subscription_repository :: proc(
	impl: ^Event_Subscription_Repo_SQLite,
	conn: ^Conn,
) -> iface.Event_Subscription_Repository {
	impl.conn = conn
	return {
		ctx = impl,
		owns_chain = subscription_owns_chain,
		all = subscription_all,
		deliveries = subscription_deliveries,
		delivered = subscription_delivered,
		mark_delivery = subscription_mark_delivery,
		stale = subscription_stale,
		deletions = subscription_deletions,
		deleted = subscription_deleted,
		put = subscription_put,
		list = subscription_list,
		remove = subscription_remove,
	}
}

subscription_prepare :: proc(ctx: rawptr, query: cstring) -> (sqlite3_stmt, domain.Domain_Error) {
	impl := (^Event_Subscription_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil || !outbox_uow_owns(impl.conn) {
		return nil, domain.domain_error(.Internal_Error, "event subscriptions require a unit of work")
	}
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare event subscription query")
	}
	return stmt, {}
}

subscription_put :: proc(ctx: rawptr, row: domain.Event_Subscription) -> domain.Domain_Error {
	stmt, err := subscription_prepare(
		ctx,
		"INSERT INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at) VALUES(?,?,?,?,NULLIF(?,''),?,?,?,?,?) ON CONFLICT DO NOTHING;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, row.subscription_id); bind_text(stmt, 2, row.owner_user_id)
	bind_text(stmt, 3, row.subscriber_agent_id); bind_text(stmt, 4, row.chain_id)
	bind_text(stmt, 5, row.task_id); bind_text(stmt, 6, row.source)
	bind_text(stmt, 7, row.filter_subjects); bind_text(stmt, 8, row.wake_policy)
	bind_text(stmt, 9, row.consumer_name); bind_text(stmt, 10, row.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to store event subscription")
	return {}
}

subscription_list :: proc(ctx: rawptr, owner, agent: string) -> ([]domain.Event_Subscription, domain.Domain_Error) {
	if owner == "" || agent == "" do return nil, domain.domain_error(.Forbidden, "subscriber identity required")
	return subscription_query(ctx, owner, agent)
}
subscription_all :: proc(ctx: rawptr) -> ([]domain.Event_Subscription, domain.Domain_Error) {
	return subscription_query(ctx, "", "")
}
subscription_query :: proc(ctx: rawptr, owner, agent: string) -> ([]domain.Event_Subscription, domain.Domain_Error) {
	stmt, err := subscription_prepare(
		ctx,
		"SELECT subscription_id,owner_user_id,subscriber_agent_id,chain_id,COALESCE(task_id,''),source,filter_subjects,wake_policy,consumer_name,created_at FROM event_subscriptions WHERE (?='' OR owner_user_id=?) AND (?='' OR subscriber_agent_id=?) ORDER BY subscription_id;",
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, owner); bind_text(stmt, 3, agent); bind_text(stmt, 4, agent)
	rows := make([dynamic]domain.Event_Subscription)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do return rows[:], {}
		if rc != SQLITE_ROW {
			for &row in rows do domain.event_subscription_destroy(&row)
			delete(rows)
			return nil, domain.domain_error(.Internal_Error, "failed to list event subscriptions")
		}
		append(
			&rows,
			domain.Event_Subscription {
				subscription_id = column_text(stmt, 0),
				owner_user_id = column_text(stmt, 1),
				subscriber_agent_id = column_text(stmt, 2),
				chain_id = column_text(stmt, 3),
				task_id = column_text(stmt, 4),
				source = column_text(stmt, 5),
				filter_subjects = column_text(stmt, 6),
				wake_policy = column_text(stmt, 7),
				consumer_name = column_text(stmt, 8),
				created_at = column_text(stmt, 9),
			},
		)
	}
}

subscription_remove :: proc(ctx: rawptr, owner, agent, subscription_id: string) -> domain.Domain_Error {
	stmt, err := subscription_prepare(
		ctx,
		"DELETE FROM event_subscriptions WHERE owner_user_id=? AND subscriber_agent_id=? AND subscription_id=?;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, agent); bind_text(stmt, 3, subscription_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to remove event subscription")
	return {}
}

subscription_delivered :: proc(ctx: rawptr, owner, agent: string, row: domain.Event_Delivery) -> domain.Domain_Error {
	stmt, err := subscription_prepare(
		ctx,
		"INSERT INTO event_deliveries(subscription_id,event_id,ack_reply,topic_key,topic_generation,stream_sequence) SELECT ?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM event_subscriptions WHERE subscription_id=? AND owner_user_id=? AND subscriber_agent_id=?) ON CONFLICT(subscription_id,event_id) DO UPDATE SET ack_reply=excluded.ack_reply RETURNING event_id;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, row.subscription_id); bind_text(stmt, 2, row.event_id)
	bind_text(stmt, 3, row.ack_reply); bind_text(stmt, 4, row.topic_key)
	sqlite3_bind_int64(stmt, 5, row.topic_generation); sqlite3_bind_int64(stmt, 6, row.stream_sequence)
	bind_text(stmt, 7, row.subscription_id); bind_text(stmt, 8, owner); bind_text(stmt, 9, agent)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return domain.domain_error(.Not_Found, "subscription ended")
	if rc != SQLITE_ROW do return domain.domain_error(.Internal_Error, "failed to record delivery")
	return {}
}
subscription_deliveries :: proc(
	ctx: rawptr,
	owner, agent: string,
	include_acknowledged: bool,
) -> (
	[]domain.Event_Delivery,
	domain.Domain_Error,
) {
	stmt, err := subscription_prepare(
		ctx,
		"SELECT d.subscription_id,d.event_id,d.ack_reply,d.topic_key,d.topic_generation,d.stream_sequence,d.acknowledged,d.resolved_sent FROM event_deliveries d JOIN event_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.owner_user_id=? AND s.subscriber_agent_id=? AND (? OR d.acknowledged=0 OR (d.topic_key!='' AND d.resolved_sent=0)) ORDER BY d.stream_sequence,d.subscription_id;",
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, agent)
	sqlite3_bind_int64(stmt, 3, 1 if include_acknowledged else 0)
	rows := make([dynamic]domain.Event_Delivery)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do return rows[:], {}
		if rc != SQLITE_ROW {
			for &row in rows do domain.event_delivery_destroy(&row)
			delete(rows)
			return nil, domain.domain_error(.Internal_Error, "failed to list deliveries")
		}
		append(
			&rows,
			domain.Event_Delivery {
				subscription_id = column_text(stmt, 0),
				event_id = column_text(stmt, 1),
				ack_reply = column_text(stmt, 2),
				topic_key = column_text(stmt, 3),
				topic_generation = sqlite3_column_int64(stmt, 4),
				stream_sequence = sqlite3_column_int64(stmt, 5),
				acknowledged = sqlite3_column_int64(stmt, 6) != 0,
				resolved_sent = sqlite3_column_int64(stmt, 7) != 0,
			},
		)
	}
}
subscription_mark_delivery :: proc(
	ctx: rawptr,
	owner, agent, subscription, event: string,
	resolved: bool,
) -> domain.Domain_Error {
	query: cstring = "UPDATE event_deliveries SET acknowledged=1 WHERE subscription_id=? AND event_id=? AND EXISTS(SELECT 1 FROM event_subscriptions s WHERE s.subscription_id=event_deliveries.subscription_id AND s.owner_user_id=? AND s.subscriber_agent_id=?);"
	if resolved do query = "UPDATE event_deliveries SET resolved_sent=1 WHERE subscription_id=? AND event_id=? AND EXISTS(SELECT 1 FROM event_subscriptions s WHERE s.subscription_id=event_deliveries.subscription_id AND s.owner_user_id=? AND s.subscriber_agent_id=?);"
	stmt, err := subscription_prepare(ctx, query)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, subscription); bind_text(stmt, 2, event); bind_text(stmt, 3, owner); bind_text(stmt, 4, agent)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to mark delivery")
	return {}
}
subscription_stale :: proc(ctx: rawptr, owner, topic: string, generation: i64) -> (bool, domain.Domain_Error) {
	stmt, err := subscription_prepare(
		ctx,
		"SELECT generation,resolved_generation FROM event_topics WHERE owner_user_id=? AND topic_key=?;",
	)
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, topic)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return false, {}
	if rc != SQLITE_ROW do return false, domain.domain_error(.Internal_Error, "failed to read topic")
	return generation <= sqlite3_column_int64(stmt, 1) || generation < sqlite3_column_int64(stmt, 0), {}
}
subscription_deletions :: proc(ctx: rawptr) -> ([]string, domain.Domain_Error) {
	stmt, err := subscription_prepare(
		ctx,
		"SELECT consumer_name FROM event_consumer_deletions ORDER BY consumer_name;",
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows := make([dynamic]string)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do return rows[:], {}
		if rc != SQLITE_ROW {
			for row in rows do delete(row)
			delete(rows)
			return nil, domain.domain_error(.Internal_Error, "failed to list consumer deletions")
		}
		append(&rows, column_text(stmt, 0))
	}
}
subscription_deleted :: proc(ctx: rawptr, consumer: string) -> domain.Domain_Error {
	stmt, err := subscription_prepare(ctx, "DELETE FROM event_consumer_deletions WHERE consumer_name=?;")
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, consumer)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to clear consumer deletion")
	return {}
}

// Watch authorization needs one owner-scoped existence check, not an entire
// decrypted/domain chain record or a caller-supplied subscriber identity.
subscription_owns_chain :: proc(ctx: rawptr, owner, chain: string) -> (bool, domain.Domain_Error) {
	stmt, err := subscription_prepare(ctx, "SELECT 1 FROM task_chains WHERE owner_user_id=? AND chain_id=?;")
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, chain)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW do return true, {}
	if rc == SQLITE_DONE do return false, {}
	return false, domain.domain_error(.Internal_Error, "failed to authorize chain watch")
}
