package sqlite

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_event_delivery_retention_targeted_ack_and_redelivery :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	event_retention_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}
event_retention_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	impl: Event_Subscription_Repo_SQLite
	repo := new_event_subscription_repository(&impl, &conn)
	repos := iface.Repositories {
		event_subscriptions = repo,
	}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	defer iface.unit_of_work_rollback(&uow)
	testing.expect_value(
		t,
		repo.put(repo.ctx, {subscription_id = "sub", owner_user_id = "alice", subscriber_instance_id = "agt", chain_id = "chain", source = "explicit", filter_subjects = "[]", consumer_name = "sub", created_at = "now"}).code,
		domain.Error_Code.None,
	)
	// 1,000 delivered occurrences: acknowledgement retains only a small recent
	// receipt window; repeated calls never need to load the rest of this history.
	for i in 0 ..< 1000 {
		id := fmt.tprintf("event_%d", i)
		testing.expect_value(
			t,
			repo.delivered(repo.ctx, "alice", "agt", {subscription_id = "sub", event_id = id, ack_reply = "reply", stream_sequence = i64(i)}).code,
			domain.Error_Code.None,
		)
		testing.expect_value(
			t,
			repo.mark_delivery(repo.ctx, "alice", "agt", "sub", id, false).code,
			domain.Error_Code.None,
		)
	}
	testing.expect_value(t, event_delivery_count(&conn), domain.EVENT_ACK_RECEIPT_LIMIT)
	// An unauthorized mark must not run cleanup on another owner's subscription,
	// including historical receipts left from a previous version.
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO event_deliveries(subscription_id,event_id,ack_reply,stream_sequence,acknowledged,recorded_at) VALUES('sub','legacy_receipt','reply',10000,1,'2026-01-01T00:00:00Z');",
		),
	)
	testing.expect_value(
		t,
		repo.mark_delivery(repo.ctx, "bob", "agt", "sub", "event_999", false).code,
		domain.Error_Code.None,
	)
	testing.expect_value(t, event_delivery_count(&conn), domain.EVENT_ACK_RECEIPT_LIMIT + 1)
	testing.expect_value(
		t,
		repo.mark_delivery(repo.ctx, "alice", "agt", "sub", "event_999", false).code,
		domain.Error_Code.None,
	)
	testing.expect_value(t, event_delivery_count(&conn), domain.EVENT_ACK_RECEIPT_LIMIT)
	requested := []string{"event_999"}
	rows, err := repo.deliveries(repo.ctx, "alice", "agt", requested)
	testing.expect(t, err.code == .None && len(rows) == 1 && rows[0].acknowledged)
	for &row in rows do domain.event_delivery_destroy(&row)
	delete(rows)
	rows, err = repo.deliveries(repo.ctx, "bob", "agt", requested)
	testing.expect(t, err.code == .None && len(rows) == 0)
	delete(rows)
	// Exercise the exact indexed join shape used by ack, rather than relying on
	// a small runtime benchmark to hide a full history scan.
	plan, plan_err := subscription_prepare(
		repo.ctx,
		"EXPLAIN QUERY PLAN SELECT d.event_id FROM json_each('[\"event_999\"]') requested CROSS JOIN event_deliveries d INDEXED BY event_deliveries_event ON d.event_id=requested.value CROSS JOIN event_subscriptions s ON s.subscription_id=d.subscription_id WHERE s.owner_user_id='alice' AND s.subscriber_instance_id='agt';",
	)
	if testing.expect_value(t, plan_err.code, domain.Error_Code.None) {
		indexed := false
		for sqlite3_step(plan) == SQLITE_ROW {
			detail := column_text_unowned(plan, 3)
			if strings.contains(detail, "event_deliveries_event") && strings.contains(detail, "SEARCH") do indexed = true
		}
		sqlite3_finalize(plan)
		testing.expect(t, indexed, "ack uses the event-id index")
	}
	// A fresh reply on server redelivery invalidates the previous local ack.
	testing.expect_value(
		t,
		repo.delivered(repo.ctx, "alice", "agt", {subscription_id = "sub", event_id = "event_999", ack_reply = "new_reply", stream_sequence = 999}).code,
		domain.Error_Code.None,
	)
	rows, err = repo.deliveries(repo.ctx, "alice", "agt", requested)
	testing.expect(t, err.code == .None && len(rows) == 1 && !rows[0].acknowledged && rows[0].ack_reply == "new_reply")
	for &row in rows do domain.event_delivery_destroy(&row)
	delete(rows)
	// Acknowledged but unresolved topics survive receipt trimming. Once their
	// resolution notice is sent, they become eligible for the bounded window.
	testing.expect_value(
		t,
		repo.delivered(repo.ctx, "alice", "agt", {subscription_id = "sub", event_id = "review", ack_reply = "review_reply", stream_sequence = 1001, topic_key = "task.review_request", topic_generation = 1}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		repo.mark_delivery(repo.ctx, "alice", "agt", "sub", "review", false).code,
		domain.Error_Code.None,
	)
	testing.expect_value(t, event_delivery_count(&conn), domain.EVENT_ACK_RECEIPT_LIMIT + 1)
	testing.expect_value(
		t,
		repo.mark_delivery(repo.ctx, "alice", "agt", "sub", "review", true).code,
		domain.Error_Code.None,
	)
	testing.expect_value(t, event_delivery_count(&conn), domain.EVENT_ACK_RECEIPT_LIMIT + 1) // one redelivery remains unacked
	testing.expect_value(
		t,
		repo.mark_delivery(repo.ctx, "alice", "agt", "sub", "event_999", false).code,
		domain.Error_Code.None,
	)
	testing.expect_value(t, event_delivery_count(&conn), domain.EVENT_ACK_RECEIPT_LIMIT)
	// Fill the remaining active capacity without acknowledging. Admission leaves
	// further events in JetStream; the metadata table cannot grow indefinitely.
	for i in domain.EVENT_ACK_RECEIPT_LIMIT ..< domain.EVENT_DELIVERY_LIMIT {
		testing.expect_value(
			t,
			repo.delivered(repo.ctx, "alice", "agt", {subscription_id = "sub", event_id = fmt.tprintf("pending_%d", i), ack_reply = "pending_reply", stream_sequence = i64(i + 10000)}).code,
			domain.Error_Code.None,
		)
	}
	slots, slots_err := repo.available(repo.ctx, "alice", "agt", "sub")
	testing.expect(t, slots_err.code == .None && slots == 0)
	testing.expect_value(
		t,
		repo.delivered(repo.ctx, "alice", "agt", {subscription_id = "sub", event_id = "over_limit", ack_reply = "reply", stream_sequence = 90000}).code,
		domain.Error_Code.Conflict,
	)
	testing.expect_value(t, event_delivery_count(&conn), domain.EVENT_DELIVERY_LIMIT)
	// Runtime's TTL query expires abandoned/unacked metadata as well as receipts.
	testing.expect(t, exec(&conn, "UPDATE event_deliveries SET recorded_at='2000-01-01T00:00:00Z';"))
	testing.expect_value(t, repo.prune(repo.ctx, "2026-01-01T00:00:00Z").code, domain.Error_Code.None)
	testing.expect_value(t, event_delivery_count(&conn), 0)
}
event_delivery_count :: proc(conn: ^Conn) -> int {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, "SELECT COUNT(*) FROM event_deliveries;", -1, &stmt, nil) != SQLITE_OK do return -1
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return -1
	return int(sqlite3_column_int64(stmt, 0))
}
