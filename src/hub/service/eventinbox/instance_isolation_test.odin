package eventinbox

import "core:encoding/json"
import "core:mem"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

// EV2 (REQ-EVP-1, REQ-EVP-4a..c): two instances of ONE durable agent, each
// coordinating its own chain, see only their own chain's events and notices.

Isolation_Notice :: struct {
	instance: string,
	count:    int,
}
Isolation_Recorder :: struct {
	t:       ^testing.T,
	notices: [dynamic]Isolation_Notice,
	reject: bool,
}
isolation_record :: proc(
	ctx: rawptr,
	owner, instance: string,
	target: domain.Event_Notice_Target,
	count: int,
	wake: bool,
) -> bool {
	r := (^Isolation_Recorder)(ctx)
	testing.expect_value(r.t, owner, "alice")
	testing.expect_value(r.t, target.instance_id, instance)
	testing.expect(r.t, !wake)
	if r.reject do return false
	append(&r.notices, Isolation_Notice{instance, count})
	return true
}
isolation_publish :: proc(t: ^testing.T, conn: ^nats.Connection, chain, id: string) {
	envelope := inbox_v2(id, "task.review_verdict", "alice", chain, "task_1")
	data, err := json.marshal(envelope)
	if !testing.expect(t, err == nil) do return
	defer delete(data)
	subject := "ev.alice.chain.chain_a.task.task_1.review_verdict"
	if chain == "chain_b" do subject = "ev.alice.chain.chain_b.task.task_1.review_verdict"
	_, nerr := nats.publish(conn, subject, data, id, nil)
	testing.expect_value(t, nerr.status, i32(0))
}
isolation_event_ids :: proc(events: []json.Value) -> (ids: [4]string, n: int) {
	for value in events {
		obj, _ := value.(json.Object)
		id, _ := obj["event_id"].(json.String)
		if n < len(ids) do ids[n] = string(id)
		n += 1
	}
	return
}

@(test)
test_event_inbox_two_instances_of_one_agent_are_isolated :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	isolation_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
isolation_scenario :: proc(t: ^testing.T) {
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
	service := Service {
		factory = &factory,
		options = {url = server.url, timeout_ms = 1000},
	}
	recorder := Isolation_Recorder {
		t = t,
	}
	defer delete(recorder.notices)
	service.notice_ctx = &recorder
	service.notice_process = notice_test_process
	service.notice = isolation_record
	runtime := Runtime {
		service = &service,
	}
	defer runtime_disconnect(&runtime)
	defer counters_destroy(&service)
	defer clear_notifications(&runtime)
	defer provisioned_destroy(&service)
	// inst_a is busy at first: its chain's event must not be sent to inst_b.
	testing.expect(
		t,
		sqlite.exec(
			&db,
			"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,chain_id,created_at,updated_at) VALUES('inst_a','alice','agt_coord','bridge','running','busy','chain_a','2026-01-01','now'),('inst_b','alice','agt_coord','bridge','running','idle','chain_b','2026-01-02','now');",
		),
	)
	testing.expect(
		t,
		sqlite.exec(
			&db,
			"INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain_a','inst_a','agt_coord','alice','coordinator','now'),('chain_b','inst_b','agt_coord','alice','coordinator','now');",
		),
	)
	if !testing.expect(t, reconcile(&runtime)) do return
	for instance, i in ([]string{"inst_a", "inst_b"}) {
		rows, err := subscriptions(&service, "alice", instance)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, len(rows), 1)
		if len(rows) == 1 do testing.expect_value(t, rows[0].chain_id, "chain_a" if i == 0 else "chain_b")
		subscription_rows_destroy(rows)
	}
	isolation_publish(t, conn, "chain_a", "a_1")
	isolation_publish(t, conn, "chain_b", "b_1")
	isolation_publish(t, conn, "chain_b", "b_2")

	all: []domain.Event_Subscription
	{
		uow, began, _ := iface.unit_of_work_begin(&factory)
		if !testing.expect(t, began) do return
		err: domain.Domain_Error
		all, err = uow.repos.event_subscriptions.all(uow.repos.event_subscriptions.ctx)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		iface.unit_of_work_commit(&uow)
	}
	defer subscription_rows_destroy(all)
	now := time.tick_now()
	// REQ-EVP-4a/b: only inst_b is notified, counting only chain_b's events.
	testing.expect(t, notify_pending_full(&runtime, all, now))
	testing.expect_value(t, len(recorder.notices), 1)
	if len(recorder.notices) == 1 {
		testing.expect_value(t, recorder.notices[0].instance, "inst_b")
		testing.expect_value(t, recorder.notices[0].count, 2)
	}
	// The 30 s rate limit is per instance: inst_b's notice does not hold back
	// inst_a once it is idle, and inst_b is not notified again.
	testing.expect(t, sqlite.exec(&db, "UPDATE agent_instances SET activity_status='idle' WHERE agent_instance_id='inst_a';"))
	testing.expect(t, notify_pending_full(&runtime, all, now))
	testing.expect_value(t, len(recorder.notices), 2)
	if len(recorder.notices) == 2 {
		testing.expect_value(t, recorder.notices[1].instance, "inst_a")
		testing.expect_value(t, recorder.notices[1].count, 1)
	}
	// REQ-EVP-4c: next reads only the caller's subscriptions.
	events, err := next(&service, "alice", "inst_a", 0, 20)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	ids, n := isolation_event_ids(events)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, ids[0], "a_1")
	values_destroy(events)
	// inst_a cannot acknowledge inst_b's deliveries before inst_b pulls them,
	// nor after.
	testing.expect_value(t, acknowledge(&service, "alice", "inst_a", []string{"b_1"}).code, domain.Error_Code.Not_Found)
	events, err = next(&service, "alice", "inst_b", 0, 20)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	ids, n = isolation_event_ids(events)
	testing.expect_value(t, n, 2)
	testing.expect(t, ids[0] != "a_1" && ids[1] != "a_1", "inst_b never sees chain_a")
	values_destroy(events)
	testing.expect_value(t, acknowledge(&service, "alice", "inst_a", []string{"b_1"}).code, domain.Error_Code.Not_Found)
	testing.expect_value(t, acknowledge(&service, "alice", "inst_b", []string{"b_1", "b_2"}).code, domain.Error_Code.None)
	testing.expect_value(t, acknowledge(&service, "alice", "inst_a", []string{"a_1"}).code, domain.Error_Code.None)

	// E3: a user stop of inst_b deletes its subscription and, on the next
	// reconcile, its consumer; inst_a is untouched.
	testing.expect(t, sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='stopped',stopped_by='user' WHERE agent_instance_id='inst_b';"))
	rows, rerr := subscriptions(&service, "alice", "inst_b")
	testing.expect(t, rerr.code == .None && len(rows) == 0, "stopped instance has no subscriptions")
	subscription_rows_destroy(rows)
	consumer_b := ""
	for row in all do if row.subscriber_instance_id == "inst_b" do consumer_b = row.consumer_name
	if !testing.expect(t, reconcile(&runtime)) do return
	_, gone := nats.consumer_state(conn, "HEIM_EVENTS", consumer_b)
	testing.expect_value(t, gone.jetstream, i32(10014))
	rows, rerr = subscriptions(&service, "alice", "inst_a")
	testing.expect(t, rerr.code == .None && len(rows) == 1, "sibling instance keeps its subscription")
	subscription_rows_destroy(rows)
}

isolation_all_rows :: proc(t: ^testing.T, factory: ^iface.Unit_Of_Work_Factory) -> []domain.Event_Subscription {
	uow, began, _ := iface.unit_of_work_begin(factory)
	if !testing.expect(t, began) do return nil
	rows, err := uow.repos.event_subscriptions.all(uow.repos.event_subscriptions.ctx)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	iface.unit_of_work_commit(&uow)
	return rows
}
isolation_publish_subject :: proc(t: ^testing.T, conn: ^nats.Connection, subject, typ, id: string) {
	envelope := inbox_v2(id, typ, "alice", "chain_a", "task_1")
	data, err := json.marshal(envelope)
	if !testing.expect(t, err == nil) do return
	defer delete(data)
	_, nerr := nats.publish(conn, subject, data, id, nil)
	testing.expect_value(t, nerr.status, i32(0))
}
isolation_next_count :: proc(t: ^testing.T, s: ^Service, instance: string) -> int {
	events, err := next(s, "alice", instance, 0, 20)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	n := len(events)
	values_destroy(events)
	return n
}

// Review finding (E3 "starts fresh"): a subscription's consumer starts when the
// subscription is created. A new role holder, a restart after a user stop and
// a claim transfer never replay the stream's retained (14-day) history, and
// notify_pending sends no notice or wake for it.
@(test)
test_event_inbox_new_subscription_never_replays_history :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	no_replay_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
no_replay_scenario :: proc(t: ^testing.T) {
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
	service := Service {
		factory = &factory,
		options = {url = server.url, timeout_ms = 1000},
	}
	recorder := Isolation_Recorder {
		t = t,
	}
	defer delete(recorder.notices)
	service.notice_ctx = &recorder
	service.notice_process = notice_test_process
	service.notice = isolation_record
	runtime := Runtime {
		service = &service,
	}
	defer runtime_disconnect(&runtime)
	defer counters_destroy(&service)
	defer clear_notifications(&runtime)
	defer provisioned_destroy(&service)
	review := "ev.alice.chain.chain_a.task.task_1.review_verdict"
	requirements := "ev.alice.chain.chain_a.task.task_1.requirements_changed"
	testing.expect(
		t,
		sqlite.exec(
			&db,
			"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,created_at,updated_at) VALUES('inst_a','alice','agt_coord','bridge','running','idle','now','now'),('inst_w1','alice','agt_worker','bridge','running','idle','now','now'),('inst_w2','alice','agt_worker','bridge','running','idle','now','now');",
		),
	)
	// History retained by the stream before any subscription exists.
	isolation_publish_subject(t, conn, review, "task.review_verdict", "old_review")
	isolation_publish_subject(t, conn, requirements, "task.requirements_changed", "old_requirements")
	time.sleep(20 * time.Millisecond)

	// 1. A new role holder starts fresh.
	testing.expect(
		t,
		sqlite.exec(
			&db,
			"INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain_a','inst_a','agt_coord','alice','coordinator','now');",
		),
	)
	testing.expect(
		t,
		sqlite.exec(
			&db,
			"INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES('lease','task_1','chain_a','alice',1,'inst_w1','work','now','','','wake');",
		),
	)
	if !testing.expect(t, reconcile(&runtime)) do return
	rows := isolation_all_rows(t, &factory)
	testing.expect_value(t, len(rows), 2)
	now := time.tick_now()
	testing.expect(t, notify_pending_full(&runtime, rows, now))
	subscription_rows_destroy(rows)
	testing.expect_value(t, len(recorder.notices), 0)
	testing.expect_value(t, isolation_next_count(t, &service, "inst_a"), 0)
	testing.expect_value(t, isolation_next_count(t, &service, "inst_w1"), 0)

	// Events after creation are delivered as usual.
	time.sleep(20 * time.Millisecond)
	isolation_publish_subject(t, conn, review, "task.review_verdict", "new_review")
	isolation_publish_subject(t, conn, requirements, "task.requirements_changed", "new_requirements")
	rows = isolation_all_rows(t, &factory)
	testing.expect(t, notify_pending_full(&runtime, rows, now))
	subscription_rows_destroy(rows)
	testing.expect_value(t, len(recorder.notices), 2)
	for notice in recorder.notices do testing.expect_value(t, notice.count, 1)
	testing.expect_value(t, isolation_next_count(t, &service, "inst_a"), 1)
	// inst_w1 pulls but does not acknowledge new_requirements.
	testing.expect_value(t, isolation_next_count(t, &service, "inst_w1"), 1)

	// 2. A restart after a user stop starts fresh: neither the old history nor
	// an event published while stopped comes back.
	testing.expect(t, sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='stopped',stopped_by='user' WHERE agent_instance_id='inst_a';"))
	isolation_publish_subject(t, conn, review, "task.review_verdict", "while_stopped")
	time.sleep(20 * time.Millisecond)
	testing.expect(t, sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='running',stopped_by='' WHERE agent_instance_id='inst_a';"))
	if !testing.expect(t, reconcile(&runtime)) do return
	later := now
	later._nsec += i64(31 * time.Second)
	clear(&recorder.notices)
	rows = isolation_all_rows(t, &factory)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	subscription_rows_destroy(rows)
	for notice in recorder.notices do testing.expect(t, notice.instance != "inst_a", "restarted instance gets no notice for old events")
	testing.expect_value(t, isolation_next_count(t, &service, "inst_a"), 0)

	// 3. A claim transfer starts the new holder fresh; the old holder's
	// unacknowledged delivery does not move with it.
	time.sleep(20 * time.Millisecond)
	testing.expect(t, sqlite.exec(&db, "UPDATE task_leases SET holder_instance_id='inst_w2' WHERE lease_id='lease';"))
	if !testing.expect(t, reconcile(&runtime)) do return
	clear(&recorder.notices)
	later._nsec += i64(31 * time.Second)
	rows = isolation_all_rows(t, &factory)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	subscription_rows_destroy(rows)
	testing.expect_value(t, len(recorder.notices), 0)
	testing.expect_value(t, isolation_next_count(t, &service, "inst_w2"), 0)
	testing.expect_value(t, isolation_next_count(t, &service, "inst_w1"), 0)
}
