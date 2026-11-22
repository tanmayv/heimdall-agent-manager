package delivery

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import project "odin_test:hub/service/project"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

Fixture :: struct {
	s:                                                                                       ^Service,
	conn:                                                                                    sqlite.Conn,
	impl:                                                                                    sqlite.Pipeline_Delivery_Repo_SQLite,
	outbox:                                                                                  sqlite.Event_Outbox_Repo_SQLite,
	repos:                                                                                   iface.Repositories,
	factory_impl:                                                                            sqlite.SQLite_Unit_Of_Work_Factory,
	factory:                                                                                 iface.Unit_Of_Work_Factory,
	bridges:                                                                                 iface.Bridge_Repository,
	registry:                                                                                project.Bridge_Runtime_Registry,
	commands:                                                                                project.Bridge_Command_Sink,
	clock:                                                                                   platform.Clock,
	ids:                                                                                     platform.ID_Generator,
	server:                                                                                  natstest.Server,
	client:                                                                                  ^nats.Connection,
	mutex:                                                                                   sync.Mutex,
	frames:                                                                                  [dynamic]string,
	finals, ids_next, offline_send, invalid_at_send, incapable, invalid_sink, replace_calls: i32,
	replace_enabled:                                                                         bool,
	now_ms:                                                                                  i64,
}

fixture_bridge :: proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	f := (^Fixture)(ctx)
	if id != "brg_one" && id != "brg_two" do return {}, false, {}
	features := `{"features":["event_pipeline_v1"]}`
	if sync.atomic_load(&f.incapable) != 0 do features = `{"features":[]}`
	return {
		bridge_id = strings.clone(id),
		owner_user_id = domain.User_ID(strings.clone("alice")),
		capabilities_json = strings.clone(features),
	}, true, {}
}
fixture_id :: proc(ctx: rawptr, prefix: string) -> string {
	f := (^Fixture)(ctx)
	n := sync.atomic_add(&f.ids_next, 1)
	return fmt.tprintf("%s%d", prefix, n)
}
fixture_clock :: proc(ctx: rawptr) -> string {
	f := (^Fixture)(ctx)
	ms := sync.atomic_load(&f.now_ms)
	if ms == 0 do return platform.format_rfc3339_utc(time.now())
	return platform.format_rfc3339_utc(time.Time{_nsec = ms * 1_000_000})
}
fixture_final :: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery) {
	f := (^Fixture)(ctx)
	sync.atomic_add(&f.finals, 1)
}
fixture_valid :: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery) -> bool {
	return sync.atomic_load(&((^Fixture)(ctx)).invalid_sink) == 0
}
fixture_replace :: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery, why: Replace_Why) -> bool {
	f := (^Fixture)(ctx)
	sync.atomic_add(&f.replace_calls, 1)
	if !f.replace_enabled do return false
	_, err := route(
		f.s,
		uow,
		{
			kind = d.kind,
			owner_user_id = d.owner_user_id,
			bridge_id = "brg_two",
			agent_instance_id = d.agent_instance_id,
			ref = d.ref,
			lifetime = LIFETIME_PROMPT,
			round = d.round + 1,
			excluded_bridges = []string{d.bridge_id},
		},
	)
	return err.code == .None
}
fixture_send :: proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	f := (^Fixture)(ctx)
	colon := strings.last_index(cmd.command_id, ":")
	uow, ok, _ := iface.unit_of_work_begin(&f.factory)
	if !ok {sync.atomic_add(&f.invalid_at_send, 1); return false, {}}
	repo := &uow.repos.pipeline_deliveries
	d, found, err := repo.get(repo.ctx, cmd.command_id[:colon])
	if !found || err.code != .None || d.state != "forwarded" || d.ack_reply == "" do sync.atomic_add(&f.invalid_at_send, 1)
	domain.pipeline_delivery_destroy(&d)
	iface.unit_of_work_rollback(&uow)
	sync.mutex_lock(&f.mutex)
	append(&f.frames, strings.clone(cmd.body_json, runtime.heap_allocator()))
	sync.mutex_unlock(&f.mutex)
	return sync.atomic_load(&f.offline_send) == 0, {}
}

fixture_new :: proc(t: ^testing.T, real_nats: bool) -> ^Fixture {
	f := new(Fixture)
	f.frames = make([dynamic]string, runtime.heap_allocator())
	opened: bool
	f.conn, opened, _ = sqlite.open(":memory:")
	assert(opened)
	ok, _ := sqlite.run_migrations(&f.conn)
	assert(ok)
	f.repos.pipeline_deliveries = sqlite.new_pipeline_delivery_repository(&f.impl, &f.conn)
	f.repos.event_outbox = sqlite.new_event_outbox_repository(&f.outbox, &f.conn)
	f.factory = sqlite.new_unit_of_work_factory(&f.factory_impl, &f.conn, &f.repos)
	f.bridges = {
		ctx        = f,
		get_bridge = fixture_bridge,
	}
	f.commands = {
		ctx                  = f,
		send_runtime_command = fixture_send,
	}
	f.clock = {
		ctx = f,
		now = fixture_clock,
	}
	f.ids = {
		ctx      = f,
		generate = fixture_id,
	}
	options := nats.Connect_Options {
		url        = "nats://127.0.0.1:1",
		timeout_ms = 200,
	}
	if real_nats {
		f.server, ok = natstest.start()
		assert(ok)
		options.url = f.server.url
		f.client, _ = nats.connect(options)
		assert(f.client != nil)
		_, err := nats.stream_add(f.client, eventrelay.delivery_stream_config())
		assert(err.status == 0)
	}
	f.s = new_service(&f.factory, &f.bridges, &f.registry, &f.commands, &f.clock, &f.ids, options)
	register_sink(
		f.s,
		{ctx = f, kind = "prompt", on_final = fixture_final, still_valid = fixture_valid, replace = fixture_replace},
	)
	return f
}
fixture_destroy :: proc(f: ^Fixture) {
	stop(f.s)
	project.bridge_runtime_registry_destroy(&f.registry)
	nats.destroy(f.client)
	natstest.destroy(&f.server)
	for frame in f.frames do delete(frame, runtime.heap_allocator())
	delete(f.frames)
	sqlite.close(&f.conn)
	free(f)
}
fixture_route :: proc(t: ^testing.T, f: ^Fixture, round: int = 0) -> string {
	uow, ok, _ := iface.unit_of_work_begin(&f.factory)
	assert(ok)
	id, err := route(
		f.s,
		&uow,
		{
			kind = "prompt",
			owner_user_id = "alice",
			bridge_id = "brg_one",
			agent_instance_id = "inst_one",
			ref = "run:one",
			lifetime = LIFETIME_PROMPT,
			round = round,
		},
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	return strings.clone(id)
}
fixture_publish :: proc(t: ^testing.T, f: ^Fixture) {
	uow, ok, _ := iface.unit_of_work_begin(&f.factory)
	assert(ok)
	repo := &uow.repos.event_outbox
	for {
		row, found, err := repo.next(repo.ctx)
		assert(err.code == .None)
		if !found do break
		// Copy the row before ending its UoW; publishing is never transactional.
		iface.unit_of_work_rollback(&uow)
		_, ne := nats.publish(f.client, row.subject, transmute([]byte)row.envelope_json, row.event_id)
		testing.expect_value(t, ne.status, i32(0))
		uow, ok, _ = iface.unit_of_work_begin(&f.factory)
		assert(ok)
		testing.expect_value(
			t,
			repo.mark_published(repo.ctx, row.outbox_seq, platform.clock_now(&f.clock)).code,
			domain.Error_Code.None,
		)
		domain.event_outbox_row_destroy(&row)
		_, _ = iface.unit_of_work_commit(&uow)
		uow, ok, _ = iface.unit_of_work_begin(&f.factory)
		assert(ok)
	}
	_, _ = iface.unit_of_work_commit(&uow)
}
fixture_get :: proc(f: ^Fixture, id: string) -> domain.Pipeline_Delivery {
	uow, ok, _ := iface.unit_of_work_begin(&f.factory)
	assert(ok)
	r := &uow.repos.pipeline_deliveries
	d, found, err := r.get(r.ctx, id)
	assert(found && err.code == .None)
	iface.unit_of_work_rollback(&uow)
	return d
}
fixture_frames :: proc(f: ^Fixture) -> int {
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	return len(f.frames)
}
fixture_wait_frames :: proc(t: ^testing.T, f: ^Fixture, n: int) -> bool {
	tick := time.tick_now()
	for time.tick_since(tick) < 12 * time.Second {
		if fixture_frames(f) >= n do return true
		time.sleep(10 * time.Millisecond)
	}
	return testing.expectf(t, false, "expected %d frames, got %d", n, fixture_frames(f))
}
fixture_live :: proc(f: ^Fixture) {
	assert(project.bridge_runtime_registry_mark_live(&f.registry, "brg_one", false, ""))
	on_bridge_online(f.s, "brg_one")
}

@(test)
test_retry_delay_table :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	expected := [7]i64{10000, 20000, 40000, 80000, 160000, 300000, 300000}
	for v, i in expected do testing.expect_value(t, retry_delay_ms(i + 1, 0), v)
	testing.expect_value(t, retry_delay_ms(1, 120000), i64(120000))
	testing.expect_value(t, retry_delay_ms(1, 3600000), i64(300000))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_route_writes_row_and_outbox :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	route_transaction_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}
route_transaction_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, false)
	defer fixture_destroy(f)
	rollbacks := [2]bool{true, false}
	for rollback in rollbacks {
		uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
		id, err := route(
			f.s,
			&uow,
			{
				kind = "prompt",
				owner_user_id = "alice",
				bridge_id = "brg_one",
				agent_instance_id = "inst_one",
				lifetime = LIFETIME_PROMPT,
			},
		)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		id = strings.clone(id)
		if rollback {iface.unit_of_work_rollback(&uow)} else {_, _ = iface.unit_of_work_commit(&uow)}
		uow, ok, _ = iface.unit_of_work_begin(&f.factory); assert(ok)
		r := &uow.repos.pipeline_deliveries
		d, found, _ := r.get(r.ctx, id)
		testing.expect_value(t, found, !rollback)
		if found do testing.expect_value(t, d.state, "routed")
		domain.pipeline_delivery_destroy(&d)
		o := &uow.repos.event_outbox
		row, ofound, _ := o.next(o.ctx)
		testing.expect_value(t, ofound, !rollback)
		if ofound {
			testing.expect_value(t, row.subject, "dlv.alice.brg_one.prompt")
			testing.expect_value(t, row.event_id, id)
			wire: contracts.Delivery_Wire
			testing.expect(
				t,
				json.unmarshal(transmute([]byte)row.envelope_json, &wire, allocator = context.temp_allocator) == nil,
			)
			testing.expect_value(t, wire.delivery_id, id)
		}
		domain.event_outbox_row_destroy(&row)
		iface.unit_of_work_rollback(&uow)
		delete(id)
	}
}

@(test)
test_forward_and_ack :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	forward_ack_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
forward_ack_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, true)
	defer fixture_destroy(f)
	id := fixture_route(t, f)
	defer delete(id)
	fixture_publish(t, f)
	testing.expect(t, start(f.s))
	fixture_live(f)
	if !fixture_wait_frames(t, f, 1) do return
	testing.expect_value(t, sync.atomic_load(&f.invalid_at_send), i32(0))
	sync.mutex_lock(&f.mutex)
	frame: contracts.Event_Deliver_Wire
	je := json.unmarshal(transmute([]byte)f.frames[0], &frame, allocator = context.temp_allocator)
	sync.mutex_unlock(&f.mutex)
	testing.expect(t, je == nil)
	testing.expect_value(t, frame.command_id, fmt.tprintf("%s:1", id))
	testing.expect_value(t, frame.attempt, 1)
	testing.expect(t, !frame.final)
	on_command_result(
		f.s,
		"brg_one",
		frame.command_id,
		`{"payload":{"status":"succeeded","result":{"outcome":"started"}}}`,
	)
	d := fixture_get(f, id)
	testing.expect_value(t, d.state, "done")
	testing.expect_value(t, d.outcome, "started")
	domain.pipeline_delivery_destroy(&d)
	testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
	tick := time.tick_now()
	for time.tick_since(tick) < 5 * time.Second {
		state, err := nats.stream_info(f.client, STREAM)
		if err.status == 0 && state.messages == 0 do return
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, false, "ack removes the stream message")
}
