package eventrelay

import "core:fmt"
import "core:encoding/json"
import "core:mem"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

@(test)
test_real_outbox_relay :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	relay_scenario(t, false)
	relay_scenario(t, true)
	err := nats.shutdown(5000)
	testing.expect_value(t, err.status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
append_test_event :: proc(t: ^testing.T, factory: ^iface.Unit_Of_Work_Factory, id: int) {
	uow, began, _ := iface.unit_of_work_begin(factory)
	if !testing.expect(t, began) do return
	row := domain.Event_Outbox_Row{
	event_id = fmt.tprintf("evt_%d", id), owner_user_id = "alice", subject = "ev.alice.task.one.occurrence",
	envelope_json = order_json(id), headers_json = "{\"X-Test\":\"preserved\"}", created_at = "2026-11-19T00:00:00Z"}
	err := uow.repos.event_outbox.append(uow.repos.event_outbox.ctx, row)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
}
wait_health :: proc(t: ^testing.T, svc: ^Service, expected: string, backlog: i64) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 15 * time.Second {
		status, count := health(svc)
		if status == expected && count == backlog do return true
		time.sleep(20 * time.Millisecond)
	}
	status, count := health(svc)
	return testing.expectf(t, false, "wanted %s/%d, got %s/%d", expected, backlog, status, count)
}
relay_scenario :: proc(t: ^testing.T, threaded: bool) {
	server, started := natstest.start()
	defer natstest.destroy(&server)
	if !testing.expect(t, started) do return
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	impl: sqlite.Event_Outbox_Repo_SQLite
	repos := iface.Repositories{event_outbox = sqlite.new_event_outbox_repository(&impl, &conn)}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &conn, &repos)
	opts := nats.Connect_Options{url = server.url, timeout_ms = 250}
	svc := Service{factory = &factory, options = opts}
	defer if !threaded do nats.destroy(svc.connection)
	// Configured but down at boot: relay must retain backlog and provision later.
	natstest.stop(&server)
	append_test_event(t, &factory, 1)
	append_test_event(t, &factory, 2)
	if threaded {
		start(&svc, &factory, opts)
		defer stop(&svc)
		testing.expect(t, wait_health(t, &svc, "degraded", 2))
		if !testing.expect(t, natstest.restart(&server)) do return
		if !wait_health(t, &svc, "ok", 0) do return
		natstest.stop(&server)
		append_test_event(t, &factory, 3)
		append_test_event(t, &factory, 4)
		if !wait_health(t, &svc, "degraded", 2) do return
		if !testing.expect(t, natstest.restart(&server)) do return
		if !wait_health(t, &svc, "ok", 0) do return
		// Stop joins before the SQLite connection or service options are freed.
		stop(&svc)
	} else {
		ok, _ := step(&svc)
		testing.expect(t, !ok)
		status, count := health(&svc)
		testing.expect(t, status == "degraded" && count == 2)
		if !testing.expect(t, natstest.restart(&server)) do return
		for _ in 0 ..< 3 { ok, _ = step(&svc); testing.expect(t, ok) }
		// Simulate PubAck followed by failure to persist published_at: on retry,
		// msg-id must dedupe the already-stored event.
		append_test_event(t, &factory, 3)
		ack, pub_err := nats.publish(svc.connection, "ev.alice.task.one.occurrence", transmute([]byte)string("{\"order\":3}"), "evt_3", []nats.Header{{"X-Test", "preserved"}})
		testing.expect(t, ack.sequence == 3 && pub_err.status == 0)
		ok, _ = step(&svc)
		testing.expect(t, ok)
		append_test_event(t, &factory, 4)
		ok, _ = step(&svc)
		testing.expect(t, ok)
		_, err := nats.stream_update(svc.connection, stream_config())
		testing.expect(t, err.status == 0, "idempotent stream update preserves events")
	}
	observer, connect_err := nats.connect(opts)
	if !testing.expect(t, connect_err.status == 0) do return
	defer nats.destroy(observer)
	state, state_err := nats.stream_info(observer, "HEIM_EVENTS")
	testing.expect(t, state_err.status == 0 && state.messages == 4 && state.last == 4, "four unique stored events")
	err := nats.consumer_add(observer, {stream = "HEIM_EVENTS", durable = "verify", filter_subjects = []string{"ev.>"}, ack_wait_ns = i64(time.Minute), max_deliver = 10})
	if !testing.expect(t, err.status == 0) do return
	pull, bind_err := nats.pull_bind(observer, "HEIM_EVENTS", "verify")
	if !testing.expect(t, bind_err.status == 0) do return
	defer nats.pull_destroy(pull)
	batch, fetch_err := nats.fetch(pull, 4, 2000)
	if !testing.expect(t, fetch_err.status == 0) do return
	defer nats.batch_destroy(batch)
	testing.expect_value(t, nats.batch_count(batch), 4)
	for i in 0 ..< nats.batch_count(batch) {
		msg := nats.batch_message(batch, i)
		testing.expect_value(t, string(nats.message_data(msg)), order_json(i + 1))
		id, _ := nats.message_header(msg, "Nats-Msg-Id")
		testing.expect_value(t, id, fmt.tprintf("evt_%d", i + 1))
		header, _ := nats.message_header(msg, "X-Test")
		testing.expect_value(t, header, "preserved")
	}
}

order_json :: proc(order: int) -> string {
	payload, _ := json.marshal(struct {order: int}{order}, allocator = context.temp_allocator)
	return string(payload)
}
