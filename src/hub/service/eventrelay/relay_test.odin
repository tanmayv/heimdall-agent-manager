package eventrelay

import "core:fmt"
import "core:encoding/json"
import "core:mem"
import "core:testing"
import "core:time"
import "core:sync"
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
	test_relay_stream_has_schedule_subjects(t)
	test_relay_purge_row(t)
	test_relay_poison_schedule_row(t)
	test_relay_drops_definitions_when_unsupported(t)
	test_relay_reports_schedule_support(t)
	test_relay_support_lookup_failure_retains_definitions(t)
	test_relay_creates_delivery_stream(t)
	test_relay_publishes_delivery_row_once(t)
	test_relay_delivery_row_does_not_block_events(t)
	test_relay_wakes_on_commit(t)
	test_relay_rollback_does_not_wake(t)
	test_relay_publishes_batch_in_order(t)
	test_relay_idle_fallback_wait(t)
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

Relay_Fixture :: struct {
	server: natstest.Server,
	conn: sqlite.Conn,
	impl: sqlite.Event_Outbox_Repo_SQLite,
	repos: iface.Repositories,
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	factory: iface.Unit_Of_Work_Factory,
	svc: Service,
}
relay_fixture_init :: proc(t: ^testing.T, f: ^Relay_Fixture) -> bool {
	ok: bool
	f.server, ok = natstest.start()
	if !testing.expect(t, ok) do return false
	f.conn, ok, _ = sqlite.open(":memory:")
	if !testing.expect(t, ok) do return false
	migrated, _ := sqlite.run_migrations(&f.conn)
	if !testing.expect(t, migrated) do return false
	f.repos.event_outbox = sqlite.new_event_outbox_repository(&f.impl, &f.conn)
	f.factory = sqlite.new_unit_of_work_factory(&f.factory_impl, &f.conn, &f.repos)
	f.svc.factory = &f.factory
	f.svc.options = {url = f.server.url, timeout_ms = 250}
	f.conn.outbox_after_commit_ctx = &f.svc
	f.conn.outbox_after_commit = proc(ctx: rawptr) {wake((^Service)(ctx))}
	ok, _ = step(&f.svc)
	return testing.expect(t, ok)
}
relay_fixture_destroy :: proc(f: ^Relay_Fixture) {
	if f.svc.worker != nil do stop(&f.svc)
	nats.destroy(f.svc.connection)
	sqlite.close(&f.conn); natstest.destroy(&f.server)
}
relay_append :: proc(t: ^testing.T, f: ^Relay_Fixture, id, subject: string, headers := "{}", rollback := false) -> bool {
	uow, began, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, began) do return false
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	err := uow.repos.event_outbox.append(uow.repos.event_outbox.ctx, {event_id = id, owner_user_id = "alice",
		subject = subject, envelope_json = "{}", headers_json = headers, created_at = "2026-11-22T00:00:00Z"})
	if err.code != .None do return false
	if rollback {iface.unit_of_work_rollback(&uow); uow.ctx = nil; return true}
	ok, _ := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	return testing.expect(t, ok)
}
relay_expect_count :: proc(t: ^testing.T, f: ^Relay_Fixture, stream, subject: string, expected: u64) {
	n, err := nats.subject_count(f.svc.connection, stream, subject)
	testing.expectf(t, err.status == 0 && n == expected, "%s count %d expected %d: %v", subject, n, expected, err)
}
relay_expect_empty :: proc(t: ^testing.T, f: ^Relay_Fixture) {
	_, backlog := health(&f.svc); testing.expect_value(t, backlog, i64(0))
}
test_relay_stream_has_schedule_subjects :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	_, err := nats.publish(f.svc.connection, "sched.def.x", transmute([]byte)string("{}"))
	testing.expect_value(t, err.status, i32(0))
}
test_relay_purge_row :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	testing.expect(t, relay_append(t, &f, "def", "sched.def.x", "{\"Nats-Schedule\":\"@every 1h\",\"Nats-Schedule-Target\":\"ev.fire\",\"Nats-TTL\":\"never\"}"))
	testing.expect(t, relay_append(t, &f, "purge", "sched.def.x", "{\"Heim-Op\":\"purge\"}"))
	ok, progress := step(&f.svc); testing.expect(t, ok && progress)
	relay_expect_empty(t, &f); relay_expect_count(t, &f, "HEIM_EVENTS", "sched.def.x", 0)
}
test_relay_poison_schedule_row :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	relay_append(t, &f, "poison", "sched.def.poison", "{\"Nats-Schedule\":\"0 99 * * * *\",\"Nats-Schedule-Target\":\"ev.fire\"}")
	relay_append(t, &f, "good", "ev.alice.good")
	ok, _ := step(&f.svc); testing.expect(t, ok)
	testing.expect_value(t, sync.atomic_load(&f.svc.schedule_rejects), i64(1))
	relay_expect_empty(t, &f); relay_expect_count(t, &f, "HEIM_EVENTS", "ev.alice.good", 1)
}
test_relay_drops_definitions_when_unsupported :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	sync.atomic_store(&f.svc.support, i32(Schedule_Support.Unsupported))
	relay_append(t, &f, "unsupported", "sched.def.x")
	ok, _ := step(&f.svc); testing.expect(t, ok)
	relay_expect_empty(t, &f); relay_expect_count(t, &f, "HEIM_EVENTS", "sched.def.x", 0)
}
test_relay_reports_schedule_support :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	testing.expect_value(t, schedule_support(&f.svc), Schedule_Support.Unknown)
	if !relay_fixture_init(t, &f) do return
	testing.expect_value(t, schedule_support(&f.svc), Schedule_Support.Supported)
}
test_relay_creates_delivery_stream :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	_, err := nats.stream_info(f.svc.connection, DELIVERY_STREAM); testing.expect_value(t, err.status, i32(0))
	_, err = nats.publish(f.svc.connection, "dlv.u.b.prompt", transmute([]byte)string("{}"))
	testing.expect_value(t, err.status, i32(0))
}
test_relay_publishes_delivery_row_once :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	testing.expect(t, relay_append(t, &f, "dlv_1", "dlv.u.b.prompt"))
	ok, _ := step(&f.svc); testing.expect(t, ok)
	testing.expect(t, !relay_append(t, &f, "dlv_1", "dlv.u.b.prompt"))
	relay_expect_count(t, &f, DELIVERY_STREAM, "dlv.u.b.prompt", 1)
}
test_relay_delivery_row_does_not_block_events :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	relay_append(t, &f, "delivery", "dlv.u.b.prompt"); relay_append(t, &f, "event", "ev.alice.good")
	ok, _ := step(&f.svc); testing.expect(t, ok); relay_expect_empty(t, &f)
	relay_expect_count(t, &f, DELIVERY_STREAM, "dlv.u.b.prompt", 1)
	relay_expect_count(t, &f, "HEIM_EVENTS", "ev.alice.good", 1)
}
test_relay_wakes_on_commit :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	f.svc.idle_wait = 10 * time.Second
	start(&f.svc, &f.factory, f.svc.options)
	time.sleep(100 * time.Millisecond) // Let the empty worker enter the long idle wait.
	started := time.tick_now()
	testing.expect(t, relay_append(t, &f, "wake", "ev.alice.wake"))
	done := false
	for time.tick_since(started) < 200 * time.Millisecond {
		_, count := health(&f.svc)
		if count == 0 {done = true; break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, done, "commit wakes relay within 200 ms despite 10 s idle wait")
}
test_relay_rollback_does_not_wake :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	testing.expect(t, relay_append(t, &f, "rollback", "ev.alice.rollback", rollback = true))
	testing.expect(t, !sync.sema_wait_with_timeout(&f.svc.wake_sema, time.Millisecond))
	ok, progress := step(&f.svc); testing.expect(t, ok && !progress)
	relay_expect_count(t, &f, "HEIM_EVENTS", "ev.alice.rollback", 0)
	// Nested commits are held until the outer commit; nested rollback drops its mark.
	outer, began, _ := iface.unit_of_work_begin(&f.factory); if !testing.expect(t, began) do return
	relay_append(t, &f, "nested_drop", "ev.alice.nested", rollback = true)
	if committed, _ := iface.unit_of_work_commit(&outer); !testing.expect(t, committed) do return
	testing.expect(t, !sync.sema_wait_with_timeout(&f.svc.wake_sema, time.Millisecond))
	outer, began, _ = iface.unit_of_work_begin(&f.factory); if !testing.expect(t, began) do return
	relay_append(t, &f, "nested_keep", "ev.alice.nested")
	testing.expect(t, !sync.sema_wait_with_timeout(&f.svc.wake_sema, time.Millisecond))
	// A subsequent sibling rollback must not erase the committed child's mark.
	relay_append(t, &f, "sibling_drop", "ev.alice.nested", rollback = true)
	committed, _ := iface.unit_of_work_commit(&outer); testing.expect(t, committed)
	testing.expect(t, sync.sema_wait_with_timeout(&f.svc.wake_sema, time.Millisecond))
	testing.expect(t, !sync.sema_wait_with_timeout(&f.svc.wake_sema, time.Millisecond), "one signal per transaction")
}
test_relay_publishes_batch_in_order :: proc(t: ^testing.T) {
	for fails in ([]bool{false, true}) {
		f: Relay_Fixture
		if !relay_fixture_init(t, &f) {relay_fixture_destroy(&f); return}
		for i in 1 ..= 200 {
			// Use the existing helper's ordered payload, then poison row 70's subject.
			append_test_event(t, &f.factory, i)
		}
		if fails do testing.expect(t, sqlite.exec(&f.conn, "UPDATE event_outbox SET subject='missing.stream' WHERE outbox_seq=70;"))
		passes := 0
		for passes < 4 {
			ok, _ := step(&f.svc); passes += 1
			if !ok {testing.expect(t, fails); break}
			_, backlog := health(&f.svc); if backlog == 0 do break
		}
		observer, ce := nats.connect(f.svc.options); testing.expect_value(t, ce.status, i32(0))
		state, se := nats.stream_info(observer, "HEIM_EVENTS")
		testing.expect(t, se.status == 0 && state.messages == (69 if fails else 200))
		for i in 1 ..= int(state.messages) {
			msg, err := nats.stream_get(observer, "HEIM_EVENTS", u64(i))
			testing.expect(t, err.status == 0 && string(nats.message_data(msg)) == order_json(i))
			nats.message_destroy(msg)
		}
		if fails {
			testing.expect(t, sqlite.exec(&f.conn, "UPDATE event_outbox SET subject='ev.alice.task.one.occurrence' WHERE outbox_seq=70;"))
			ok, _ := step(&f.svc); testing.expect(t, ok)
			msg, err := nats.stream_get(observer, "HEIM_EVENTS", 70)
			testing.expect(t, err.status == 0 && string(nats.message_data(msg)) == order_json(70))
			nats.message_destroy(msg)
		} else {testing.expect(t, passes <= 4); relay_expect_empty(t, &f)}
		nats.destroy(observer); relay_fixture_destroy(&f)
	}
}
test_relay_idle_fallback_wait :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	f.svc.idle_wait = 100 * time.Millisecond
	start(&f.svc, &f.factory, f.svc.options)
	// A raw database insertion bypasses the repository append mark and wake hook.
	testing.expect(t, sqlite.exec(&f.conn, "INSERT INTO event_outbox(event_id,owner_user_id,subject,envelope_json,headers_json,created_at) VALUES('direct','alice','ev.alice.direct','{}','{}','2026-11-22T00:00:00Z');"))
	testing.expect(t, wait_health(t, &f.svc, "ok", 0))
}

test_relay_support_lookup_failure_retains_definitions :: proc(t: ^testing.T) {
	f: Relay_Fixture; defer relay_fixture_destroy(&f)
	if !relay_fixture_init(t, &f) do return
	testing.expect(t, relay_append(t, &f, "retry_definition", "sched.def.retry",
		"{\"Nats-Schedule\":\"@every 1h\",\"Nats-Schedule-Target\":\"ev.fire\",\"Nats-TTL\":\"never\"}"))
	// Force setup again, with a transient failure after both streams exist.
	nats.destroy(f.svc.connection); f.svc.connection = nil
	sync.atomic_store(&f.svc.support, i32(Schedule_Support.Unknown))
	f.svc.support_lookup = proc(conn: ^nats.Connection, stream: string) -> (bool, nats.Error) {
		return false, {status = 26}
	}
	ok, progress := step(&f.svc)
	testing.expect(t, !ok && !progress && f.svc.connection == nil)
	testing.expect_value(t, schedule_support(&f.svc), Schedule_Support.Unknown)
	_, backlog := health(&f.svc); testing.expect_value(t, backlog, i64(1))
	// A later successful lookup publishes the SAME pending definition.
	f.svc.support_lookup = nil
	ok, progress = step(&f.svc); testing.expect(t, ok && progress)
	testing.expect_value(t, schedule_support(&f.svc), Schedule_Support.Supported)
	relay_expect_empty(t, &f)
	relay_expect_count(t, &f, "HEIM_EVENTS", "sched.def.retry", 1)
}
