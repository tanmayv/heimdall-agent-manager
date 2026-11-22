package eventinbox

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

// Default keeps normal suites quick. The review measurement runs this case
// with -define:E2_IDLE_WAIT_MS=30000, for three concurrent 30-second polls.
IDLE_WAIT_MS :: #config(E2_IDLE_WAIT_MS, 1000)
Idle_Poller :: struct {
	service: ^Service,
	agent:   string,
	error:   domain.Error_Code,
	count:   int,
}
idle_poller_entry :: proc(data: rawptr) {
	job := (^Idle_Poller)(data)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {job.error = .Internal_Error; return}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	events, err := next(job.service, "alice", job.agent, time.Duration(IDLE_WAIT_MS) * time.Millisecond, 20)
	job.error = err.code
	job.count = len(events)
	values_destroy(events)
}
spawn_idle_poller :: proc(job: ^Idle_Poller) -> ^thread.Thread {
	context.allocator = runtime.heap_allocator()
	return thread.create_and_start_with_data(job, idle_poller_entry, init_context = context)
}
join_idle_poller :: proc(worker: ^thread.Thread) {
	context.allocator = runtime.heap_allocator()
	thread.join(worker); thread.destroy(worker)
}
@(test)
test_event_inbox_idle_api_rate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	idle_rate_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
idle_rate_scenario :: proc(t: ^testing.T) {
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
	impl: sqlite.Event_Subscription_Repo_SQLite
	repos := iface.Repositories {
		event_subscriptions = sqlite.new_event_subscription_repository(&impl, &db),
	}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &db, &repos)
	service := Service {
		factory = &factory,
		options = {url = server.url, timeout_ms = 1000},
	}
	jobs := [3]Idle_Poller {
		{service = &service, agent = "agt_idle_1"},
		{service = &service, agent = "agt_idle_2"},
		{service = &service, agent = "agt_idle_3"},
	}
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	for job in jobs {
		filter_json := `["ev.alice.chain.idle.state"]`
		testing.expect_value(
			t,
			repos.event_subscriptions.put(repos.event_subscriptions.ctx, {subscription_id = job.agent, owner_user_id = "alice", subscriber_instance_id = job.agent, chain_id = "idle", source = "explicit", filter_subjects = filter_json, consumer_name = job.agent, created_at = "now"}).code,
			domain.Error_Code.None,
		)
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	if !testing.expect(t, committed) do return
	before, _, stats_err := nats.api_stats(conn)
	if !testing.expect_value(t, stats_err.status, i32(0)) do return
	started_wait := time.tick_now()
	runtime := Runtime {
		service = &service,
	}
	start(&runtime, &service)
	workers: [3]^thread.Thread
	for &job, i in jobs do workers[i] = spawn_idle_poller(&job)
	for worker in workers do join_idle_poller(worker)
	stop(&runtime)
	elapsed := time.tick_since(started_wait)
	after, _, after_err := nats.api_stats(conn)
	testing.expect_value(t, after_err.status, i32(0))
	for job in jobs {
		testing.expect_value(t, job.error, domain.Error_Code.None)
		testing.expect_value(t, job.count, 0)
	}
	requests := after - before
	seconds := f64(elapsed) / f64(time.Second)
	fmt.printf(
		"idle JetStream API: agents=3 wait_ms=%d elapsed_ms=%d requests=%d requests_per_second=%.3f\n",
		IDLE_WAIT_MS,
		i64(elapsed / time.Millisecond),
		requests,
		f64(requests) / seconds,
	)
	testing.expectf(
		t,
		requests <= 96,
		"idle management API traffic must be bounded per request, not per 20ms iteration: %d requests",
		requests,
	)
	testing.expect(t, elapsed >= time.Duration(IDLE_WAIT_MS) * time.Millisecond)
}
