package sqlite

import "core:encoding/json"
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
		bot_agent = subscription_bot_agent,
		owns_chain = subscription_owns_chain,
		all = subscription_all,
		by_owner = subscription_by_owner,
		deliveries = subscription_deliveries,
		resolutions = subscription_resolutions,
		exists = subscription_exists,
		available = subscription_available,
		queue_delete = subscription_queue_delete,
		prune = subscription_prune,
		delivered = subscription_delivered,
		notice_target = subscription_notice_target,
		due_deliveries = subscription_due_deliveries,
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
	if row.subscriber_instance_id == "" do return domain.domain_error(.Forbidden, "subscriber instance required")
	// The agent column is informational: the caller's value, else the
	// instance's durable agent, else the instance id itself.
	stmt, err := subscription_prepare(
		ctx,
		"INSERT INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id) VALUES(?1,?2,COALESCE(NULLIF(?3,''),(SELECT NULLIF(agent_id,'') FROM agent_instances WHERE agent_instance_id=?11 AND owner_user_id=?2),?11),?4,NULLIF(?5,''),?6,?7,?8,?9,?10,?11) ON CONFLICT DO NOTHING;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, row.subscription_id); bind_text(stmt, 2, row.owner_user_id)
	bind_text(stmt, 3, row.subscriber_agent_id); bind_text(stmt, 4, row.chain_id)
	bind_text(stmt, 5, row.task_id); bind_text(stmt, 6, row.source)
	bind_text(stmt, 7, row.filter_subjects); bind_text(stmt, 8, row.wake_policy)
	bind_text(stmt, 9, row.consumer_name); bind_text(stmt, 10, row.created_at)
	bind_text(stmt, 11, row.subscriber_instance_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to store event subscription")
	return {}
}

subscription_list :: proc(ctx: rawptr, owner, instance: string) -> ([]domain.Event_Subscription, domain.Domain_Error) {
	if owner == "" || instance == "" do return nil, domain.domain_error(.Forbidden, "subscriber instance required")
	return subscription_query(ctx, owner, instance)
}
subscription_all :: proc(ctx: rawptr) -> ([]domain.Event_Subscription, domain.Domain_Error) {
	return subscription_query(ctx, "", "")
}
subscription_query :: proc(ctx: rawptr, owner, instance: string) -> ([]domain.Event_Subscription, domain.Domain_Error) {
	stmt, err := subscription_prepare(
		ctx,
		"SELECT subscription_id,owner_user_id,subscriber_agent_id,chain_id,COALESCE(task_id,''),source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id FROM event_subscriptions WHERE (?='' OR owner_user_id=?) AND (?='' OR subscriber_instance_id=?) ORDER BY subscription_id;",
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, owner); bind_text(stmt, 3, instance); bind_text(stmt, 4, instance)
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
				subscriber_instance_id = column_text(stmt, 10),
			},
		)
	}
}

subscription_remove :: proc(ctx: rawptr, owner, instance, subscription_id: string) -> domain.Domain_Error {
	stmt, err := subscription_prepare(
		ctx,
		"DELETE FROM event_subscriptions WHERE owner_user_id=? AND subscriber_instance_id=? AND subscription_id=?;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, instance); bind_text(stmt, 3, subscription_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to remove event subscription")
	return {}
}


subscription_delivered :: proc(ctx: rawptr, owner, instance: string, row: domain.Event_Delivery) -> domain.Domain_Error {
	stmt, err := subscription_prepare(
		ctx,
		"INSERT INTO event_deliveries(subscription_id,event_id,ack_reply,topic_key,topic_generation,stream_sequence,recorded_at) SELECT ?,?,?,?,?,?,strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE EXISTS(SELECT 1 FROM event_subscriptions WHERE subscription_id=? AND owner_user_id=? AND subscriber_instance_id=?) AND (EXISTS(SELECT 1 FROM event_deliveries WHERE subscription_id=? AND event_id=?) OR (SELECT COUNT(*) FROM event_deliveries WHERE subscription_id=?)<4096) ON CONFLICT(subscription_id,event_id) DO UPDATE SET acknowledged=CASE WHEN event_deliveries.ack_reply!=excluded.ack_reply THEN 0 ELSE event_deliveries.acknowledged END,ack_reply=excluded.ack_reply,recorded_at=excluded.recorded_at RETURNING event_id;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, row.subscription_id); bind_text(stmt, 2, row.event_id)
	bind_text(stmt, 3, row.ack_reply); bind_text(stmt, 4, row.topic_key)
	sqlite3_bind_int64(stmt, 5, row.topic_generation); sqlite3_bind_int64(stmt, 6, row.stream_sequence)
	bind_text(stmt, 7, row.subscription_id); bind_text(stmt, 8, owner); bind_text(stmt, 9, instance)
	bind_text(
		stmt,
		10,
		row.subscription_id,
	); bind_text(stmt, 11, row.event_id); bind_text(stmt, 12, row.subscription_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW do return {}
	if rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to record delivery")
	exists, exists_err := subscription_exists(ctx, owner, instance, row.subscription_id)
	if exists_err.code != .None do return exists_err
	if !exists do return domain.domain_error(.Not_Found, "subscription ended")
	return domain.domain_error(.Conflict, "event inbox delivery capacity reached; acknowledge outstanding events")
}
DELIVERY_SELECT :: "SELECT d.subscription_id,d.event_id,d.ack_reply,d.topic_key,d.topic_generation,d.stream_sequence,d.acknowledged,d.resolved_sent "
subscription_deliveries :: proc(
	ctx: rawptr,
	owner, instance: string,
	ids: []string,
) -> (
	[]domain.Event_Delivery,
	domain.Domain_Error,
) {
	if len(ids) < 1 || len(ids) > 100 do return nil, domain.domain_error(.Validation_Failed, "ack requires 1..100 event ids")
	encoded, encode_err := json.marshal(ids)
	if encode_err != nil do return nil, domain.domain_error(.Internal_Error, "failed to encode event ids")
	defer delete(encoded)
	stmt, err := subscription_prepare(
		ctx,
		DELIVERY_SELECT +
		"FROM json_each(?) requested CROSS JOIN event_deliveries d INDEXED BY event_deliveries_event ON d.event_id=requested.value CROSS JOIN event_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.owner_user_id=? AND s.subscriber_instance_id=? ORDER BY d.stream_sequence,d.subscription_id;",
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(encoded)); bind_text(stmt, 2, owner); bind_text(stmt, 3, instance)
	return subscription_read_deliveries(stmt)
}
subscription_resolutions :: proc(
	ctx: rawptr,
	owner, instance: string,
	limit: int,
) -> (
	[]domain.Event_Delivery,
	domain.Domain_Error,
) {
	stmt, err := subscription_prepare(
		ctx,
		DELIVERY_SELECT +
		"FROM event_subscriptions s JOIN event_deliveries d ON d.subscription_id=s.subscription_id JOIN event_topics t ON t.owner_user_id=s.owner_user_id AND t.topic_key=d.topic_key WHERE s.owner_user_id=? AND s.subscriber_instance_id=? AND d.resolved_sent=0 AND (d.topic_generation<=t.resolved_generation OR d.topic_generation<t.generation) ORDER BY d.stream_sequence,d.subscription_id LIMIT ?;",
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, instance)
	sqlite3_bind_int64(stmt, 3, i64(clamp(limit, 1, 100)))
	return subscription_read_deliveries(stmt)
}
subscription_read_deliveries :: proc(stmt: sqlite3_stmt) -> ([]domain.Event_Delivery, domain.Domain_Error) {
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
subscription_exists :: proc(ctx: rawptr, owner, instance, subscription: string) -> (bool, domain.Domain_Error) {
	stmt, err := subscription_prepare(
		ctx,
		"SELECT 1 FROM event_subscriptions WHERE owner_user_id=? AND subscriber_instance_id=? AND subscription_id=?;",
	)
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, instance); bind_text(stmt, 3, subscription)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW do return true, {}
	if rc == SQLITE_DONE do return false, {}
	return false, domain.domain_error(.Internal_Error, "failed to check subscription")
}
subscription_available :: proc(ctx: rawptr, owner, instance, subscription: string) -> (int, domain.Domain_Error) {
	stmt, err := subscription_prepare(
		ctx,
		"SELECT 4096-(SELECT COUNT(*) FROM event_deliveries WHERE subscription_id=?) FROM event_subscriptions WHERE owner_user_id=? AND subscriber_instance_id=? AND subscription_id=?;",
	)
	if err.code != .None do return 0, err
	defer sqlite3_finalize(stmt)
	bind_text(
		stmt,
		1,
		subscription,
	); bind_text(stmt, 2, owner); bind_text(stmt, 3, instance); bind_text(stmt, 4, subscription)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return 0, {}
	if rc != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to check delivery capacity")
	return max(0, int(sqlite3_column_int64(stmt, 0))), {}
}
subscription_queue_delete :: proc(ctx: rawptr, consumer: string) -> domain.Domain_Error {
	stmt, err := subscription_prepare(
		ctx,
		"INSERT INTO event_consumer_deletions(consumer_name) VALUES(?) ON CONFLICT DO NOTHING;",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, consumer)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to queue consumer deletion")
	return {}
}
subscription_prune :: proc(ctx: rawptr, before: string) -> domain.Domain_Error {
	// A row without an owning instance can only come from a hub build older
	// than EV2 writing against the migrated schema (a rolling restart or a
	// rollback). No instance can read it, so it is deleted on every sweep; the
	// delete trigger releases its deliveries and queues its consumer.
	orphans, orphan_err := subscription_prepare(ctx, "DELETE FROM event_subscriptions WHERE subscriber_instance_id='';")
	if orphan_err.code != .None do return orphan_err
	orphan_rc := sqlite3_step(orphans)
	sqlite3_finalize(orphans)
	if orphan_rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to delete event subscriptions without an instance")
	stmt, err := subscription_prepare(
		ctx,
		"DELETE FROM event_deliveries WHERE recorded_at<? OR rowid IN(SELECT delivery_row FROM(SELECT rowid AS delivery_row,ROW_NUMBER() OVER(PARTITION BY subscription_id ORDER BY stream_sequence DESC) AS receipt_rank FROM event_deliveries WHERE acknowledged=1 AND (topic_key='' OR resolved_sent=1)) WHERE receipt_rank>256);",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, before)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to prune event deliveries")
	return {}
}
subscription_trim_receipts :: proc(ctx: rawptr, subscription: string) -> domain.Domain_Error {
	stmt, err := subscription_prepare(
		ctx,
		"DELETE FROM event_deliveries WHERE subscription_id=? AND acknowledged=1 AND (topic_key='' OR resolved_sent=1) AND event_id NOT IN(SELECT event_id FROM event_deliveries WHERE subscription_id=? AND acknowledged=1 AND (topic_key='' OR resolved_sent=1) ORDER BY stream_sequence DESC LIMIT 256);",
	)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, subscription); bind_text(stmt, 2, subscription)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to trim acknowledgement receipts")
	return {}
}
subscription_mark_delivery :: proc(
	ctx: rawptr,
	owner, instance, subscription, event: string,
	resolved: bool,
) -> domain.Domain_Error {
	query: cstring = "UPDATE event_deliveries SET acknowledged=1 WHERE subscription_id=? AND event_id=? AND EXISTS(SELECT 1 FROM event_subscriptions s WHERE s.subscription_id=event_deliveries.subscription_id AND s.owner_user_id=? AND s.subscriber_instance_id=?);"
	if resolved do query = "UPDATE event_deliveries SET resolved_sent=1 WHERE subscription_id=? AND event_id=? AND EXISTS(SELECT 1 FROM event_subscriptions s WHERE s.subscription_id=event_deliveries.subscription_id AND s.owner_user_id=? AND s.subscriber_instance_id=?);"
	stmt, err := subscription_prepare(ctx, query)
	if err.code != .None do return err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, subscription); bind_text(stmt, 2, event); bind_text(stmt, 3, owner); bind_text(stmt, 4, instance)
	impl := (^Event_Subscription_Repo_SQLite)(ctx)
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to mark delivery")
	// A foreign/missing row must not trigger cleanup of that subscription.
	if changed == 0 do return {}
	return subscription_trim_receipts(ctx, subscription)
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

// The notice target is the instance that owns the subscription and nothing
// else (REQ-EVP-4a): no fallback to another instance of the same agent, or to
// another chain. Tenant-scoped; requires the subscription to still exist.
subscription_notice_target :: proc(
	ctx: rawptr,
	row: domain.Event_Subscription,
) -> (
	target: domain.Event_Notice_Target,
	result_err: domain.Domain_Error,
) {
	stmt, err := subscription_prepare(
		ctx,
		`SELECT ai.agent_instance_id,ai.bridge_id,ai.runtime_status,ai.activity_status,ai.stopped_by,
 EXISTS(SELECT 1 FROM bots b WHERE b.owner_user_id=ai.owner_user_id AND b.agent_instance_id=ai.agent_instance_id)
 FROM event_subscriptions s JOIN agent_instances ai
  ON ai.agent_instance_id=s.subscriber_instance_id AND ai.owner_user_id=s.owner_user_id
 WHERE s.subscription_id=? AND s.owner_user_id=? AND s.subscriber_instance_id=? AND ai.kind='agent';`,
	)
	if err.code != .None do return {}, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, row.subscription_id); bind_text(stmt, 2, row.owner_user_id)
	bind_text(stmt, 3, row.subscriber_instance_id)
	step := sqlite3_step(stmt)
	if step == SQLITE_DONE do return {}, {}
	if step != SQLITE_ROW do return {}, domain.domain_error(.Internal_Error, "failed to read notice target")
	target = {
		instance_id     = column_text(stmt, 0),
		bridge_id       = column_text(stmt, 1),
		runtime_status  = column_text(stmt, 2),
		activity_status = column_text(stmt, 3),
		stopped_by      = column_text(stmt, 4),
		is_bot          = sqlite3_column_int64(stmt, 5) != 0,
	}
	return
}
subscription_due_deliveries :: proc(
	ctx: rawptr,
	owner, instance, subscription, before: string,
) -> (
	[]domain.Event_Delivery,
	domain.Domain_Error,
) {
	stmt, err := subscription_prepare(
		ctx,
		DELIVERY_SELECT +
		"FROM event_subscriptions s JOIN event_deliveries d ON d.subscription_id=s.subscription_id WHERE s.owner_user_id=? AND s.subscriber_instance_id=? AND s.subscription_id=? AND d.acknowledged=0 AND d.recorded_at<? ORDER BY d.stream_sequence LIMIT 4096;",
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, instance); bind_text(stmt, 3, subscription); bind_text(stmt, 4, before)
	return subscription_read_deliveries(stmt)
}


// Identity comes from the canonical bot binding, never a caller-supplied
// template id. A retired bot instance must not add watches.
subscription_bot_agent :: proc(ctx: rawptr, owner, instance: string) -> (string, domain.Domain_Error) {
	stmt, err := subscription_prepare(ctx, "SELECT agent_id FROM bots WHERE owner_user_id=? AND agent_instance_id=?;")
	if err.code != .None do return "", err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner)
	bind_text(stmt, 2, instance)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW do return column_text(stmt, 0), {}
	if rc == SQLITE_DONE do return "", {}
	return "", domain.domain_error(.Internal_Error, "failed to find bot identity")
}

subscription_by_owner :: proc(ctx: rawptr, owner: string) -> ([]domain.Event_Subscription, domain.Domain_Error) {
	if owner == "" do return nil, domain.domain_error(.Forbidden, "owner identity required")
	return subscription_query(ctx, owner, "")
}
