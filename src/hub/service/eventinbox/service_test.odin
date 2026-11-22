package eventinbox

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

@(test)
test_event_inbox_real_delivery_freshness_and_dlq :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	inbox_delivery_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
inbox_delivery_scenario :: proc(t: ^testing.T) {
	server, started := natstest.start()
	defer natstest.destroy(&server)
	if !testing.expect(t, started) do return
	conn, nerr := nats.connect({url = server.url, timeout_ms = 1000})
	if !testing.expect_value(t, nerr.status, i32(0)) do return
	defer nats.destroy(conn)
	_, nerr = nats.stream_add(conn, eventrelay.stream_config())
	if !testing.expect_value(t, nerr.status, i32(0)) do return
	db, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&db)
	migrated, _ := sqlite.run_migrations(&db)
	if !testing.expect(t, migrated) do return
	sub_impl: sqlite.Event_Subscription_Repo_SQLite
	out_impl: sqlite.Event_Outbox_Repo_SQLite
	repos := iface.Repositories {
		event_subscriptions = sqlite.new_event_subscription_repository(&sub_impl, &db),
		event_outbox        = sqlite.new_event_outbox_repository(&out_impl, &db),
	}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &db, &repos)
	ids := platform.real_id_generator()
	service := Service {
		ids = &ids,
		factory = &factory,
		options = {url = server.url, timeout_ms = 1000},
		ack_wait = 60 * time.Millisecond,
		max_deliver = 2,
	}
	defer provisioned_destroy(&service)
	runtime := Runtime {
		service = &service,
	}
	defer runtime_disconnect(&runtime)
	subjects, _ := filters("alice", "chain_1", "", "coordinator")
	defer filters_destroy(subjects)
	encoded, _ := json.marshal(subjects)
	defer delete(encoded)
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	testing.expect_value(
		t,
		repos.event_subscriptions.put(repos.event_subscriptions.ctx, {subscription_id = "sub_coord", owner_user_id = "alice", subscriber_agent_id = "agt_coord", chain_id = "chain_1", source = "role_default", filter_subjects = string(encoded), wake_policy = "catalog", consumer_name = "coord", created_at = "now"}).code,
		domain.Error_Code.None,
	)
	committed, _ := iface.unit_of_work_commit(&uow)
	if !testing.expect(t, committed) do return
	if !testing.expect(t, reconcile(&runtime), "provision consumer and durable advisory stream") do return
	// Compare cached reconciliation with advisory draining alone: unchanged
	// subscriptions must add no management API calls, regardless of idle passes.
	api_before, _, api_err := nats.api_stats(conn)
	testing.expect_value(t, api_err.status, i32(0))
	for _ in 0 ..< 12 do testing.expect(t, drain_advisories(&runtime))
	api_after_drain, _, _ := nats.api_stats(conn)
	for _ in 0 ..< 12 do testing.expect(t, reconcile(&runtime))
	api_after_cache, _, _ := nats.api_stats(conn)
	drain_requests := api_after_drain - api_before
	cached_requests := api_after_cache - api_after_drain
	testing.expectf(
		t,
		cached_requests <= drain_requests + 2,
		"unchanged cached reconciliation adds no consumer management calls: drain %d, cached %d",
		drain_requests,
		cached_requests,
	)
	testing.expect_value(t, len(runtime.provisioned), 1)

	testing.expect(
		t,
		sqlite.exec(
			&db,
			"INSERT INTO task_chains(chain_id,owner_user_id,title,created_at,updated_at) VALUES('chain_watch','alice','Watch test','now','now');",
		),
	)
	testing.expect_value(t, watch(&service, "alice", "agt_bot", "chain_watch", false).code, domain.Error_Code.None)
	testing.expect_value(t, watch(&service, "alice", "agt_bot", "chain_watch", false).code, domain.Error_Code.None)
	watched, watch_err := subscriptions(&service, "alice", "agt_bot")
	testing.expect(t, watch_err.code == .None && len(watched) == 1, "watch is idempotent")
	subscription_rows_destroy(watched)
	testing.expect_value(t, watch(&service, "bob", "agt_bot", "chain_watch", false).code, domain.Error_Code.Not_Found)
	testing.expect_value(t, watch(&service, "alice", "agt_bot", "chain_watch", true).code, domain.Error_Code.None)
	testing.expect(t, reconcile(&runtime), "unprovision an unpulled watch")

	subject := "ev.alice.chain.chain_1.task.task_1.state"
	for state, i in ([]string{"ready", "in_progress", "in_review", "done"}) {
		inbox_test_publish(t, conn, subject, fmt.tprintf("state_%d", i), "task.state", "", 0, state, true)
	}
	events, err := next(&service, "alice", "agt_coord", 0, 20)
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
	testing.expect_value(t, len(events), 1)
	if len(events) > 0 {
		obj := events[0].(json.Object)
		data := obj["data"].(json.Object)
		testing.expect_value(t, string(data["state"].(json.String)), "done")
	}
	values_destroy(events)
	testing.expect_value(
		t,
		acknowledge(&service, "alice", "agt_coord", []string{"state_3"}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		acknowledge(&service, "alice", "agt_coord", []string{"state_3"}).code,
		domain.Error_Code.None,
	)
	// A truly empty long-poll waits for its bounded budget.
	began_wait := time.tick_now()
	empty, empty_err := next(&service, "alice", "agt_coord", 50 * time.Millisecond, 20)
	testing.expect(
		t,
		empty_err.code == .None && len(empty) == 0 && time.tick_since(began_wait) >= 50 * time.Millisecond,
	)
	values_destroy(empty)
	// Tenant and agent ids cannot select another subscriber's inbox or ack.
	for identity in ([][2]string{{"bob", "agt_coord"}, {"alice", "agt_other"}}) {
		other_rows, ferr := subscriptions(&service, identity[0], identity[1])
		testing.expect(t, ferr.code == .None && len(other_rows) == 0)
		subscription_rows_destroy(other_rows)
		testing.expect_value(
			t,
			acknowledge(&service, identity[0], identity[1], []string{"state_3"}).code,
			domain.Error_Code.Not_Found,
		)
	}
	topic := "task.task_1.review_request"
	generation := inbox_test_open(t, &factory, topic, "review_stale")
	inbox_test_publish(
		t,
		conn,
		"ev.alice.chain.chain_1.task.task_1.review_requested_from_user",
		"review_stale",
		"task.review_requested_from_user",
		topic,
		generation,
		"",
		false,
	)
	inbox_test_resolve(t, &factory, topic)
	events, err = next(&service, "alice", "agt_coord", 0, 20)
	testing.expect(t, err.code == .None && len(events) == 0, "review resolved before pull is acked and skipped")
	values_destroy(events)
	generation = inbox_test_open(t, &factory, topic, "review_live")
	inbox_test_publish(
		t,
		conn,
		"ev.alice.chain.chain_1.task.task_1.review_requested_from_user",
		"review_live",
		"task.review_requested_from_user",
		topic,
		generation,
		"",
		false,
	)
	events, err = next(&service, "alice", "agt_coord", 0, 20)
	testing.expect(t, err.code == .None && len(events) == 1, "live review delivered")
	values_destroy(events)
	testing.expect_value(
		t,
		acknowledge(&service, "alice", "agt_coord", []string{"review_live"}).code,
		domain.Error_Code.None,
	)
	inbox_test_resolve(t, &factory, topic)
	events, err = next(&service, "alice", "agt_coord", 0, 20)
	testing.expect(t, err.code == .None && len(events) == 1, "acked review later gets resolved notice")
	if len(events) > 0 {
		obj := events[0].(json.Object)
		testing.expect_value(t, string(obj["type"].(json.String)), "resolved")
		testing.expect_value(t, string(obj["resolved_event_id"].(json.String)), "review_live")
	}
	values_destroy(events)
	events, err = next(&service, "alice", "agt_coord", 0, 20)
	testing.expect(t, err.code == .None && len(events) == 0, "one resolved notice")
	values_destroy(events)
	// Occurrence remains unacked across requests. A second request binds the same
	// durable, receives ack_wait redelivery, then exhausts max_deliver.
	inbox_test_publish(
		t,
		conn,
		"ev.alice.chain.chain_1.task.task_1.review_verdict",
		"poison",
		"task.review_verdict",
		"",
		0,
		"",
		false,
	)
	for attempt in 0 ..< 2 {
		events, err = next(&service, "alice", "agt_coord", 0, 20)
		testing.expectf(
			t,
			err.code == .None && len(events) == 1,
			"delivery attempt %d: %v, count %d",
			attempt,
			err,
			len(events),
		)
		values_destroy(events)
		time.sleep(80 * time.Millisecond)
	}
	// The hub's advisory reader is offline when the last pull generates the
	// max-delivery advisory; the dedicated stream retains it until reconnect.
	runtime_disconnect(&runtime)
	// Poison advisories precede the valid exhausted delivery. They must be
	// acknowledged/discarded, so they cannot wedge the durable advisory reader.
	advisory_subject := "$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.HEIM_EVENTS.coord"
	_, bad_err := nats.publish(conn, advisory_subject, transmute([]byte)string("not-json"), "bad_advisory")
	testing.expect_value(t, bad_err.status, i32(0))
	outside_cfg := eventrelay.stream_config()
	outside_cfg.subjects = []string{"ev.>", "other.>"}
	_, bad_err = nats.stream_update(conn, outside_cfg)
	testing.expect_value(t, bad_err.status, i32(0))
	outside, outside_err := nats.publish(conn, "other.original", transmute([]byte)string("not an event"), "outside")
	testing.expect_value(t, outside_err.status, i32(0))
	bad_body, _ := json.marshal(struct {
		stream, consumer: string,
		stream_seq:       u64,
	}{"HEIM_EVENTS", "coord", outside.sequence})
	_, bad_err = nats.publish(conn, advisory_subject, bad_body, "bad_origin")
	delete(bad_body)
	testing.expect_value(t, bad_err.status, i32(0))
	events, err = next(&service, "alice", "agt_coord", 0, 20)
	testing.expect(t, err.code == .None && len(events) == 0, "exhausted delivery not returned")
	values_destroy(events)
	testing.expect(t, reconcile(&runtime), "republish max-delivery advisory")
	testing.expect_value(
		t,
		nats.consumer_add(conn, {stream = "HEIM_EVENTS", durable = "dlq_test", filter_subjects = []string{"ev.dlq.alice.>"}, ack_wait_ns = i64(time.Second), max_deliver = 10}).status,
		i32(0),
	)
	pull, perr := nats.pull_bind(conn, "HEIM_EVENTS", "dlq_test")
	if !testing.expect_value(t, perr.status, i32(0)) do return
	defer nats.pull_destroy(pull)
	batch, berr := nats.fetch(pull, 10, 500)
	if !testing.expect_value(t, berr.status, i32(0)) do return
	defer nats.batch_destroy(batch)
	testing.expect_value(t, nats.batch_count(batch), 1)
	if nats.batch_count(batch) > 0 {
		msg := nats.batch_message(batch, 0)
		testing.expect_value(t, nats.message_subject(msg), "ev.dlq.alice.chain.chain_1.task.task_1.review_verdict")
		value, jerr := json.parse(nats.message_data(msg))
		testing.expect(t, jerr == nil)
		if jerr == nil {
			obj := value.(json.Object)
			testing.expect_value(t, string(obj["event_id"].(json.String)), "poison")
		}
		json.destroy_value(value)
		testing.expect_value(t, nats.ack(msg).status, i32(0))
	}
	// Retain an HTTP request's stale snapshot, then let removal and background
	// deletion finish before that request tries to provision its consumer.
	late_snapshot, snapshot_err := subscriptions(&service, "alice", "agt_coord")
	testing.expect(t, snapshot_err.code == .None && len(late_snapshot) == 1)
	defer subscription_rows_destroy(late_snapshot)
	// Queue deletion survives the SQL commit and is drained outside the UoW.
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	testing.expect_value(
		t,
		repos.event_subscriptions.remove(repos.event_subscriptions.ctx, "alice", "agt_coord", "sub_coord").code,
		domain.Error_Code.None,
	)
	committed, _ = iface.unit_of_work_commit(&uow)
	testing.expect(t, committed && reconcile(&runtime))
	missing, merr := nats.pull_bind(conn, "HEIM_EVENTS", "coord")
	testing.expect(t, merr.status != 0 && missing == nil, "removed default retires durable consumer")
	nats.pull_destroy(missing)
	if len(late_snapshot) == 1 {
		active, fence_err := provision_consumer(&service, conn, late_snapshot[0])
		testing.expect(t, fence_err.code == .None && !active, "late request observes subscription removal")
		orphan, orphan_err := nats.pull_bind(conn, "HEIM_EVENTS", "coord")
		testing.expect(t, orphan_err.status != 0 && orphan == nil, "late provisioning cannot resurrect a consumer")
		nats.pull_destroy(orphan)
		testing.expect(t, reconcile(&runtime), "cleanup retries tolerate already-deleted consumers")
	}
	testing.expect_value(t, len(runtime.provisioned), 0)
	// Production worker lifecycle joins its thread and releases its own connection.
	runtime_disconnect(&runtime)
	start(&runtime, &service)
	time.sleep(150 * time.Millisecond)
	stop(&runtime)
	testing.expect(t, runtime.worker == nil && runtime.connection == nil && runtime.advisory == nil)
}

inbox_test_publish :: proc(
	t: ^testing.T,
	conn: ^nats.Connection,
	subject, id, typ, topic: string,
	generation: i64,
	state: string,
	rollup: bool,
) {
	envelope := struct {
		event_id, type, owner_user_id, chain_id, task_id, topic_key: string,
		topic_generation:                                            i64,
		data:                                                        struct {
			state: string,
		},
	}{id, typ, "alice", "chain_1", "task_1", topic, generation, {state}}
	data, err := json.marshal(envelope)
	if !testing.expect(t, err == nil) do return
	defer delete(data)
	headers: []nats.Header
	if rollup do headers = []nats.Header{{"Nats-Rollup", "sub"}}
	_, nerr := nats.publish(conn, subject, data, id, headers)
	testing.expect_value(t, nerr.status, i32(0))
}
inbox_test_open :: proc(t: ^testing.T, factory: ^iface.Unit_Of_Work_Factory, topic, id: string) -> i64 {
	uow, began, _ := iface.unit_of_work_begin(factory)
	if !testing.expect(t, began) do return 0
	repo := uow.repos.event_outbox
	generation, _, err := repo.open_topic(repo.ctx, "alice", topic, id, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	return generation
}
inbox_test_resolve :: proc(t: ^testing.T, factory: ^iface.Unit_Of_Work_Factory, topic: string) {
	uow, began, _ := iface.unit_of_work_begin(factory)
	if !testing.expect(t, began) do return
	repo := uow.repos.event_outbox
	testing.expect_value(
		t,
		repo.resolve_topic(repo.ctx, "alice", topic, "now", "resolution").code,
		domain.Error_Code.None,
	)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
}
