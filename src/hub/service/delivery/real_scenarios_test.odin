package delivery

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

Real_Case :: enum {
	Closed,
	Expires,
	Invalid,
	Unknown,
	Send_Failure,
	Final,
	Exhausted,
	Accepted,
	Retry,
	Limit,
	Waiting,
	Stale,
	Wait_Offline,
	Restart,
	Disconnect,
	Clean,
	Lost_Cas,
	Reconnect,
	Fatal,
	Fatal_Replace,
	Older_Success,
	Idempotent,
}

fixture_frame :: proc(f: ^Fixture, index: int) -> contracts.Event_Deliver_Wire {
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	frame: contracts.Event_Deliver_Wire
	assert(json.unmarshal(transmute([]byte)f.frames[index], &frame, allocator = context.temp_allocator) == nil)
	return frame
}
fixture_answer :: proc(f: ^Fixture, index: int, body: string = `{"status":"succeeded"}`) {
	frame := fixture_frame(f, index)
	on_command_result(f.s, "brg_one", frame.command_id, body)
}
fixture_wait_empty :: proc(t: ^testing.T, f: ^Fixture) {
	tick := time.tick_now()
	for time.tick_since(tick) < 8 * time.Second {
		state, err := nats.stream_info(f.client, STREAM)
		if err.status == 0 && state.messages == 0 do return
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, false, "stream should be empty")
}
fixture_wait_state :: proc(t: ^testing.T, f: ^Fixture, id, state: string) {
	tick := time.tick_now()
	for time.tick_since(tick) < 12 * time.Second {
		d := fixture_get(f, id)
		matches := d.state == state
		domain.pipeline_delivery_destroy(&d)
		if matches do return
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, false, "delivery %s should be %s", id, state)
}

real_scenario :: proc(t: ^testing.T, which: Real_Case) {
	if which == .Clean {forward_ack_scenario(t); return}
	f := fixture_new(t, true)
	defer fixture_destroy(f)
	if which == .Limit || which == .Waiting || which == .Stale {limit_scenario(t, f, which); return}
	if which == .Reconnect {reconnect_scenario(t, f); return}
	if which == .Final || which == .Exhausted {f.s.max_deliver = 3; f.s.ack_wait_ms = 1000}
	if which == .Send_Failure || which == .Restart || which == .Disconnect || which == .Lost_Cas || which == .Older_Success do f.s.ack_wait_ms = 1000
	if which == .Accepted do f.s.ack_wait_ms = 2000
	testing.expect(t, start(f.s))
	if which != .Wait_Offline do fixture_live(f)
	if which == .Unknown {
		bodies := []string{`{"delivery_id":"dlv_missing"}`, `not json`}
		for body in bodies {
			_, err := nats.publish(f.client, "dlv.alice.brg_one.prompt", transmute([]byte)body)
			testing.expect_value(t, err.status, i32(0))
		}
		fixture_wait_empty(t, f)
		testing.expect_value(t, fixture_frames(f), 0)
		testing.expect_value(t, sync.atomic_load(&f.s.invalid_messages), i64(2))
		return
	}
	if which == .Closed {
		for state in ([]string{"done", "failed", "replaced"}) {
			id := fixture_route(t, f)
			fixture_set(f, id, state)
			delete(id)
		}
		fixture_publish(t, f)
		fixture_wait_empty(t, f)
		testing.expect_value(t, fixture_frames(f), 0)
		return
	}
	id := fixture_route(t, f)
	defer delete(id)
	if which == .Expires do fixture_set(f, id, "routed", 0, "2000-01-01T00:00:00Z")
	if which == .Invalid do sync.atomic_store(&f.invalid_sink, 1)
	if which == .Send_Failure do sync.atomic_store(&f.offline_send, 1)
	if which == .Send_Failure {
		for _ in 0 ..< 2 {extra := fixture_route(t, f); delete(extra)}
	}
	fixture_publish(t, f)
	if which == .Expires || which == .Invalid {
		fixture_wait_state(t, f, id, "failed")
		fixture_wait_empty(t, f)
		d := fixture_get(f, id)
		testing.expect_value(t, d.reason, "bridge_offline" if which == .Expires else "superseded")
		domain.pipeline_delivery_destroy(&d)
		testing.expect_value(t, fixture_frames(f), 0)
		testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
		return
	}
	if which == .Wait_Offline {
		time.sleep(1200 * time.Millisecond)
		testing.expect_value(t, fixture_frames(f), 0)
		fixture_live(f)
	}
	if !fixture_wait_frames(t, f, 1) do return
	#partial switch which {
	case .Idempotent:
		frame := fixture_frame(f, 0)
		on_command_result(f.s, "other", frame.command_id, `{"status":"succeeded"}`)
		on_command_result(f.s, "brg_one", "dlv_unknown:1", `{"status":"succeeded"}`)
		fixture_answer(f, 0)
		fixture_answer(f, 0)
		fixture_answer(f, 0, `{"status":"failed"}`)
		testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
	case .Older_Success:
		if !fixture_wait_frames(t, f, 2) do return
		fixture_answer(f, 0)
		d := fixture_get(f, id)
		testing.expect_value(t, d.state, "done")
		domain.pipeline_delivery_destroy(&d)
	case .Fatal, .Fatal_Replace:
		f.replace_enabled = which == .Fatal_Replace
		fixture_answer(
			f,
			0,
			`{"status":"failed","result":{"class":"fatal"},"error":{"code":"internal_error","cause":"launch_failed"}}`,
		)
		d := fixture_get(f, id)
		testing.expect_value(t, d.state, "replaced" if which == .Fatal_Replace else "failed")
		if which == .Fatal do testing.expect_value(t, d.reason, "launch_failed")
		domain.pipeline_delivery_destroy(&d)
		if which == .Fatal_Replace do assert_replacement(t, f, id)
	case .Accepted:
		// A fetch may take one second. Renew well before AckWait rather than
		// racing a queued answer against a two-second deadline under Valgrind.
		time.sleep(500 * time.Millisecond)
		fixture_answer(f, 0, `{"status":"accepted"}`)
		time.sleep(1000 * time.Millisecond)
		fixture_answer(f, 0, `{"status":"accepted"}`)
		time.sleep(1600 * time.Millisecond)
		testing.expect_value(t, fixture_frames(f), 1)
		d := fixture_get(f, id)
		testing.expect_value(t, d.state, "forwarded")
		domain.pipeline_delivery_destroy(&d)
		fixture_answer(f, 0)
	case .Retry:
		fixture_answer(f, 0, `{"status":"failed","result":{"class":"retry"}}`)
		time.sleep(1500 * time.Millisecond)
		testing.expect_value(t, fixture_frames(f), 1)
		if fixture_wait_frames(t, f, 2) {
			frame := fixture_frame(f, 1)
			testing.expect_value(t, frame.command_id, fmt.tprintf("%s:2", id))
			d := fixture_get(f, id)
			testing.expect_value(t, d.state, "forwarded")
			domain.pipeline_delivery_destroy(&d)
			fixture_answer(f, 1)
		}
	case .Send_Failure:
		d := fixture_get(f, id)
		testing.expect_value(t, d.state, "forwarded")
		domain.pipeline_delivery_destroy(&d)
		time.sleep(300 * time.Millisecond)
		testing.expect_value(t, fixture_frames(f), 1)
		sync.atomic_store(&f.offline_send, 0)
		if fixture_wait_frames(t, f, 4) {
			testing.expect_value(t, fixture_frame(f, 1).attempt, 2)
			for i in 1 ..< 4 do fixture_answer(f, i)
		}
	case .Final, .Exhausted:
		if !fixture_wait_frames(t, f, 3) do return
		testing.expect(t, fixture_frame(f, 2).final)
		if which == .Final do fixture_answer(f, 2, `{"status":"failed","class":"retry"}`)
		fixture_wait_state(t, f, id, "failed")
		d := fixture_get(f, id)
		testing.expect_value(t, d.reason, "no_answer")
		domain.pipeline_delivery_destroy(&d)
		testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
	case .Restart:
		stop(f.s)
		f.s = new_service(
			&f.factory,
			&f.bridges,
			&f.registry,
			&f.commands,
			&f.clock,
			&f.ids,
			{url = f.server.url, timeout_ms = 200},
		)
		f.s.ack_wait_ms = 1000
		register_sink(f.s, {ctx = f, kind = "prompt", on_final = fixture_final})
		testing.expect(t, start(f.s))
		on_bridge_online(f.s, "brg_one")
		if fixture_wait_frames(t, f, 2) {
			testing.expect_value(t, fixture_frame(f, 1).attempt, 2)
			fixture_answer(f, 1)
		}
	case .Disconnect:
		project.bridge_runtime_registry_mark_offline(
			&f.registry,
			"brg_one",
			project.bridge_runtime_registry_generation(&f.registry, "brg_one"),
		)
		on_bridge_offline(f.s, "brg_one")
		testing.expect_value(t, sync.atomic_load(&f.replace_calls), i32(0))
		time.sleep(1200 * time.Millisecond)
		fixture_live(f)
		if fixture_wait_frames(t, f, 2) {
			testing.expect_value(t, fixture_frame(f, 1).attempt, 2)
			fixture_answer(f, 1)
		}
	case .Lost_Cas:
		// Close after the first forward; the next gate sees the durable closure.
		fixture_set(f, id, "forwarded", 1, "2000-01-01T00:00:00Z")
		uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
		closed,expiry_err:=expire(f.s,&uow,id)
 testing.expect(t,closed && expiry_err.code==.None)
		_, _ = iface.unit_of_work_commit(&uow)
		time.sleep(2500 * time.Millisecond)
		testing.expect_value(t, fixture_frames(f), 1)
		fixture_answer(f, 0)
		fixture_answer(f, 0)
		testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
	case .Wait_Offline:
		testing.expect_value(t, fixture_frame(f, 0).attempt, 1)
		fixture_answer(f, 0)
	case:
		unreachable()
	}
	fixture_wait_empty(t, f)
}

limit_scenario :: proc(t: ^testing.T, f: ^Fixture, which: Real_Case) {
	count := 40 if which == .Limit else 20 if which == .Waiting else 16
	for _ in 0 ..< count {
		id := fixture_route(t, f)
		if which == .Stale {
			fixture_set(f, id, "forwarded")
			uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
			r := &uow.repos.pipeline_deliveries
			d, _, _ := r.get(r.ctx, id)
			next := d; next.updated_at = "2000-01-01T00:00:00Z"
			_, _ = r.transition(r.ctx, next, "forwarded")
			domain.pipeline_delivery_destroy(&d)
			_, _ = iface.unit_of_work_commit(&uow)
		}
		delete(id)
	}
	if which != .Stale do fixture_publish(t, f)
	testing.expect(t, start(f.s))
	fixture_live(f)
	if which == .Stale {
		id := fixture_route(t, f); delete(id)
		// Old rows were not published; mark their outbox rows first so this
		// assertion isolates the SQL count rather than their redelivery.
		uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
		o := &uow.repos.event_outbox
		for _ in 0 ..< 16 {
			row, found, _ := o.next(o.ctx); assert(found)
			_ = o.mark_published(o.ctx, row.outbox_seq, "2000-01-01T00:00:00Z")
			domain.event_outbox_row_destroy(&row)
		}
		_, _ = iface.unit_of_work_commit(&uow)
		fixture_publish(t, f)
		testing.expect(t, fixture_wait_frames(t, f, 1))
		return
	}
	if !fixture_wait_frames(t, f, 16) do return
	time.sleep(200 * time.Millisecond)
	testing.expect_value(t, fixture_frames(f), 16)
	if which == .Limit {
		for i in 0 ..< 4 do fixture_answer(f, i)
		testing.expect(t, fixture_wait_frames(t, f, 20))
		testing.expect_value(t, fixture_frames(f), 20)
	} else {
		for i in 0 ..< 16 do fixture_answer(f, i, `{"status":"failed","class":"retry"}`)
		if !fixture_wait_frames(t, f, 20) do return
		for i in 16 ..< 20 do fixture_answer(f, i, `{"status":"failed","class":"retry"}`)
		id := fixture_route(t, f); defer delete(id)
		fixture_publish(t, f)
		testing.expect(t, fixture_wait_frames(t, f, 21))
		testing.expect_value(t, fixture_frame(f, 20).delivery.delivery_id, id)
	}
}

reconnect_scenario :: proc(t: ^testing.T, f: ^Fixture) {
	f.s.ack_wait_ms = 1000
	ids := make([dynamic]string)
	defer {for id in ids do delete(id); delete(ids)}
	for _ in 0 ..< 200 {
		id := fixture_route(t, f)
		append(&ids, id)
	}
	fixture_publish(t, f)
	testing.expect(t, start(f.s))
	fixture_live(f)
	if !fixture_wait_frames(t, f, 16) do return
	caller_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	feeder := thread.create_and_start_with_data(f, answer_feeder, init_context = context)
	context.allocator = caller_allocator
	for _ in 0 ..< 2 {
		natstest.stop(&f.server)
		time.sleep(150 * time.Millisecond)
		testing.expect(t, natstest.restart(&f.server))
	}
	thread.join(feeder)
	thread.destroy(feeder)
	fixture_wait_empty(t, f)
	testing.expect_value(t, sync.atomic_load(&f.finals), i32(200))
	for id in ids {
		d := fixture_get(f, id)
		testing.expect_value(t, d.state, "done")
		domain.pipeline_delivery_destroy(&d)
	}
}

answer_feeder :: proc(data: rawptr) {
	f := (^Fixture)(data)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	index := 0
	tick := time.tick_now()
	for sync.atomic_load(&f.finals) < 200 && time.tick_since(tick) < 45 * time.Second {
		if index < fixture_frames(f) {
			fixture_answer(f, index)
			index += 1
			free_all(context.allocator)
		} else {time.sleep(5 * time.Millisecond)}
	}
}

@(test)
test_idle_forwarder_query_cost :: proc(t: ^testing.T) {
	f := fixture_new(t, true)
	testing.expect(t, start(f.s))
	fixture_live(f)
	time.sleep(3200 * time.Millisecond)
	count := sync.atomic_load(&f.s.in_flight_queries)
	fmt.printf("idle forwarder: %d count queries / 3.2s, %d server pulls\n", count, sync.atomic_load(&f.s.pull_requests))
	testing.expect_value(t, count, i64(1))
	testing.expect_value(t, sync.atomic_load(&f.s.pull_requests), i64(1))
	fixture_destroy(f)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
}

@(test)
test_reconnect_preserves_limit_and_releases_recovered_slots :: proc(t: ^testing.T) {
	f := fixture_new(t, true)
	f.s.ack_wait_ms = 30_000
	for _ in 0..<20 {id := fixture_route(t, f); delete(id)}
	fixture_publish(t, f)
	testing.expect(t, start(f.s))
	fixture_live(f)
	if fixture_wait_frames(t, f, 16) {
		connection_failed(f.s)
		tick := time.tick_now()
		for sync.atomic_load(&f.s.in_flight_queries) < 2 && time.tick_since(tick) < 5 * time.Second do time.sleep(10 * time.Millisecond)
		testing.expect(t, sync.atomic_load(&f.s.in_flight_queries) >= 2)
		time.sleep(200 * time.Millisecond)
		testing.expect_value(t, fixture_frames(f), 16)
		// These answers refer to the previous connection's attempts.
		for i in 0..<4 do fixture_answer(f, i)
		testing.expect(t, fixture_wait_frames(t, f, 20))
		testing.expect_value(t, fixture_frames(f), 20)
	}
	fixture_destroy(f)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
}
