
package eventinbox

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

Notice_Recorder :: struct {
	nudges, wakes, count: int,
	attempts:             int,
	accept:               bool,
	service:              ^Service,
	t:                    ^testing.T,
}
notification_record_dispatch :: proc(
	ctx: rawptr,
	owner, instance: string,
	target: domain.Event_Notice_Target,
	count: int,
	wake: bool,
) -> bool {
	r := (^Notice_Recorder)(ctx)
	testing.expect_value(r.t, owner, "alice")
	testing.expect_value(r.t, instance, "inst_coord")
	testing.expect_value(r.t, target.instance_id, "inst_coord")
	// Opens a real UoW here: notice delivery must be outside every transaction.
	rows, err := subscriptions(r.service, owner, instance)
	testing.expect_value(r.t, err.code, domain.Error_Code.None)
	subscription_rows_destroy(rows)
	r.attempts += 1
	if !r.accept do return false
	if wake {r.wakes += 1} else {r.nudges += 1}
	r.count = count
	return true
}
@(test)
test_event_notifications_burst_idle_freshness_wake_and_redelivery :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	notification_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
notification_scenario :: proc(t: ^testing.T) {
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
	recorder := Notice_Recorder {
		accept  = true,
		service = &service,
		t       = t,
	}
	service.notice_ctx = &recorder
	service.notice_process = notice_test_process
	service.notice = notification_record_dispatch
	runtime := Runtime {
		service = &service,
	}
	defer runtime_disconnect(&runtime)
	defer counters_destroy(&service)
	defer clear_notifications(&runtime)
	testing.expect(
		t,
		sqlite.exec(
			&db,
			"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,created_at,updated_at) VALUES('inst_coord','alice','agt_coord','bridge','running','busy','now','now');",
		),
	)
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	for id in ([]string{"sub_coord", "sub_overlap"}) {
		testing.expect_value(
			t,
			repos.event_subscriptions.put(repos.event_subscriptions.ctx, {
				subscription_id     = id,
				owner_user_id       = "alice",
				subscriber_instance_id = "inst_coord",
				chain_id            = "chain_1",
				// Different sources avoid the scope uniqueness constraint.
				source              = "role_default" if id == "sub_coord" else "explicit",
				filter_subjects     = `["ev.alice.chain.chain_1.>"]`,
				wake_policy         = "catalog",
				consumer_name       = id,
				created_at          = "now",
			}).code,
			domain.Error_Code.None,
		)
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	if !testing.expect(t, committed) do return
	if !testing.expect(t, reconcile(&runtime)) do return
	rows, err := subscriptions(&service, "alice", "inst_coord")
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
	defer subscription_rows_destroy(rows)
	for i in 0 ..< 20 do inbox_test_publish(t, conn, "ev.alice.chain.chain_1.task.task_1.review_verdict", fmt.tprintf("burst_%d", i), "task.review_verdict", "", 0, "", false)
	now := time.tick_now()
	testing.expect(t, notify_pending_full(&runtime, rows, now))
	testing.expect(t, recorder.nudges == 0, "busy agents are left alone")
	testing.expect(
		t,
		sqlite.exec(&db, "UPDATE agent_instances SET activity_status='idle' WHERE agent_instance_id='inst_coord';"),
	)
	testing.expect(t, notify_pending_full(&runtime, rows, now))
	testing.expect_value(t, recorder.nudges, 1)
	first_metrics,first_metrics_err:=metrics(&service,"alice")
	testing.expect_value(t,first_metrics_err.code,domain.Error_Code.None)
	testing.expect(t,first_metrics.nudges_sent==1,"successful notification dispatch increments the owner metric")
	testing.expect_value(t,first_metrics.wakes_sent,u64(0))
	metrics_destroy(&first_metrics)
	testing.expect(t, recorder.count == 20, "overlapping watches count each event once")
	for _ in 0 ..< 20 do testing.expect(t, notify_pending_full(&runtime, rows, now))
	testing.expect(t, recorder.nudges == 1, "burst produces at most one line in 30 seconds")
	observed, observed_err := nats.consumer_state(conn, "HEIM_EVENTS", "sub_coord")
	testing.expect_value(t, observed_err.status, i32(0))
	testing.expect(t, observed.delivered == u64(0), "notification observation never advances consumer")
	testing.expect_value(t, observed.pending, u64(20))
	testing.expect_value(t, observed.ack_pending, u64(0))
	events, next_err := next(&service, "alice", "inst_coord", 0, 100)
	testing.expect_value(t, next_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(events), 20)
	values_destroy(events)
	// A stale observation taken before next must be rejected by the final SQL
	// receipt check even if its consumer snapshot raced the pull.
	stale_value, _ := json.parse_string(
		`{"event_id":"burst_0","owner_user_id":"alice","entity":{"kind":"task","id":"task_1"},"data":{"chain_id":"chain_1"},"type":"task.review_verdict"}`,
	)
	stale_live, stale_err := notice_live(&service, Notice_Candidate{row = rows[0], value = stale_value})
	testing.expect_value(t, stale_err.code, domain.Error_Code.None)
	testing.expect(t, !stale_live, "a concurrent pull suppresses an unseen candidate")
	json.destroy_value(stale_value)
	// next exits as soon as the first subscription supplies the limit only at
	// 100; both overlapping consumers have therefore been scanned.
	later := now
	later._nsec += i64(31 * time.Second)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.nudges == 1, "pulled, unacked events do not remind before ack_wait")
	testing.expect(t, sqlite.exec(&db, "UPDATE event_deliveries SET recorded_at='2000-01-01T00:00:00Z';"))
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.nudges == 2, "redelivery due after ack_wait becomes eligible")
	ids := make([dynamic]string)
	defer {for id in ids do delete(id); delete(ids)}
	for i in 0 ..< 20 do append(&ids, fmt.aprintf("burst_%d", i))
	testing.expect_value(t, acknowledge(&service, "alice", "inst_coord", ids[:]).code, domain.Error_Code.None)
	later._nsec += i64(31 * time.Second)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.nudges == 2, "acknowledged events never remind")

	testing.expect(
		t,
		sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst_coord';"),
	)
	inbox_test_publish(
		t,
		conn,
		"ev.alice.chain.chain_1.task.task_1.state",
		"pull_only",
		"task.state",
		"",
		0,
		"ready",
		true,
	)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.wakes == 0, "task.state never wakes")
	topic := "task.task_1.review_request"
	generation := inbox_test_open(t, &factory, topic, "resolved")
	inbox_test_publish(
		t,
		conn,
		"ev.alice.chain.chain_1.task.task_1.review_requested_from_user",
		"resolved",
		"task.review_requested_from_user",
		topic,
		generation,
		"",
		false,
	)
	inbox_test_resolve(t, &factory, topic)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.wakes == 0, "resolved requests never wake")
	testing.expect(
		t,
		sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='running' WHERE agent_instance_id='inst_coord';"),
	)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.nudges == 2, "resolved requests and task.state never nudge")
	testing.expect(
		t,
		sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst_coord';"),
	)
	generation = inbox_test_open(t, &factory, topic, "live")
	inbox_test_publish(
		t,
		conn,
		"ev.alice.chain.chain_1.task.task_1.review_requested_from_user",
		"live",
		"task.review_requested_from_user",
		topic,
		generation,
		"",
		false,
	)
	testing.expect(
		t,
		// A typed failure (held for recovery, not Dead). inst_coord holds no role
		// in this fixture, so an untyped failure would count as superseded and
		// end its subscriptions (EV2).
		sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='failed',last_error_json='{\"class\":\"fatal\"}' WHERE agent_instance_id='inst_coord';"),
	)
	attempts := recorder.attempts
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect_value(t, recorder.attempts, attempts)
	testing.expect(t, recorder.wakes == 0, "failed instances require explicit recovery")
	testing.expect(
		t,
		sqlite.exec(&db, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst_coord';"),
	)
	recorder.accept = false
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.wakes == 0, "rejected sends do not increment success counters")
	recorder.accept = true
	attempts = recorder.attempts
	before_backoff, _, _ := nats.api_stats(conn)
	for _ in 0 ..< 5 do testing.expect(t, notify_pending_full(&runtime, rows, later))
	after_backoff, _, _ := nats.api_stats(conn)
	testing.expect(t, after_backoff - before_backoff <= 1, "backoff skips consumer and stream reads")
	testing.expect_value(t, recorder.attempts, attempts)
	almost := later
	almost._nsec += i64(5 * time.Second - time.Nanosecond)
	testing.expect(t, notify_pending_full(&runtime, rows, almost))
	testing.expect_value(t, recorder.attempts, attempts)
	later._nsec += i64(5 * time.Second)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.wakes == 1, "stopped coordinator wakes for live review")
	result,metrics_err:=metrics(&service,"alice")
	testing.expect_value(t,metrics_err.code,domain.Error_Code.None)
	testing.expect_value(t,result.wakes_sent,u64(1))
	testing.expect_value(t,result.nudges_sent,u64(2))
	metrics_destroy(&result)
	other_owner,other_err:=metrics(&service,"bob")
	testing.expect_value(t,other_err.code,domain.Error_Code.None)
	testing.expect_value(t,other_owner.nudges_sent,u64(0))
	testing.expect_value(t,other_owner.wakes_sent,u64(0))
	metrics_destroy(&other_owner)
	for _ in 0 ..< 20 do testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.wakes == 1, "wake burst is coalesced too")
	later._nsec += i64(31 * time.Second)
	testing.expect(
		t,
		sqlite.exec(&db, "UPDATE agent_instances SET stopped_by='user' WHERE agent_instance_id='inst_coord';"),
	)
	testing.expect(t, notify_pending_full(&runtime, rows, later))
	testing.expect(t, recorder.wakes == 1, "preserve explicit user stops")

	obj := make(json.Object)
	data := make(json.Object)
	data["state"] = json.String("completed")
	obj["type"] = json.String("chain.state")
	obj["data"] = data
	defer delete(obj["data"].(json.Object))
	defer delete(obj)
	testing.expect(t, notice_wake_worthy(obj, true))
	testing.expect(t, !notice_wake_worthy(obj, false), "chain completion wakes only bots")
}

// Fence scenarios explicitly request a reconciliation after direct external
// writes; production uses the publish hook or the low-frequency fallback.
notify_pending_full :: proc(r: ^Runtime, rows: []domain.Event_Subscription, now: time.Tick) -> bool {
    r.notice_reconcile = {}
    return notify_pending(r, rows, now)
}

notice_test_process :: proc(_: rawptr, _: string, target: domain.Event_Notice_Target) -> Notice_Process {
    if target.runtime_status == "stopped" do return .Exited
    if target.runtime_status == "running" || target.runtime_status == "idle" do return .Ready
    return .Unknown
}
