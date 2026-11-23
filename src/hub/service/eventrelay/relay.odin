// Transactional outbox relay. Owns exactly one synchronous NATS connection;
// no network operation runs inside a repository unit of work.
package eventrelay

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

RELAY_BATCH :: 64
DELIVERY_STREAM :: "HEIM_DELIVER"
Schedule_Support :: enum i32 { Unknown, Supported, Unsupported }
Service :: struct {
	wake_sema: sync.Sema,
	// Zero selects the production 1 s fallback; tests may lengthen it.
	idle_wait: time.Duration,
	support: i32,
	schedule_rejects: i64,
	unsupported_logged: bool,
	// Optional fault-injection seam; nil uses the real server version lookup.
	support_lookup: proc(conn: ^nats.Connection, stream: string) -> (bool, nats.Error),

	// Optional post-publish signal; never called while holding a SQL UoW.
	published_ctx: rawptr,
	published: proc(ctx: rawptr, subject: string),
	factory: ^iface.Unit_Of_Work_Factory,
	options: nats.Connect_Options,
	worker: ^thread.Thread,
	stopping, healthy: i32,
	// Owned exclusively by the relay thread (or by step's caller before start).
	connection: ^nats.Connection,
	last_prune: time.Tick,
}
stream_config :: proc() -> nats.Stream_Config {
	subjects := make([]string, 2, context.temp_allocator)
	subjects[0] = "ev.>"
	subjects[1] = "sched.def.>"
	return {name = "HEIM_EVENTS", subjects = subjects, max_age_ns = i64(14 * 24 * time.Hour),
	duplicate_window_ns = i64(2 * time.Minute), replicas = 1, allow_rollup = true, allow_direct = true, allow_msg_schedules = true, allow_msg_ttl = true}
}
delivery_stream_config :: proc() -> nats.Stream_Config {
	subjects := make([]string, 1, context.temp_allocator)
	subjects[0] = "dlv.>"
	return {name = DELIVERY_STREAM, subjects = subjects, retention = .Work_Queue,
		max_age_ns = i64(24 * time.Hour), duplicate_window_ns = i64(2 * time.Minute),
		replicas = 1, allow_direct = true}
}
wake :: proc(s: ^Service) {
	if s != nil do sync.sema_post(&s.wake_sema)
}
schedule_support :: proc(s: ^Service) -> Schedule_Support {
	return Schedule_Support(sync.atomic_load(&s.support))
}
start :: proc(s: ^Service, factory: ^iface.Unit_Of_Work_Factory, options: nats.Connect_Options) {
	if s.worker != nil do return
	context.allocator = runtime.heap_allocator()
	s.factory = factory
	s.options = options
	s.options.url = strings.clone(options.url)
	s.options.creds_file = strings.clone(options.creds_file)
	s.options.ca_file = strings.clone(options.ca_file)
	s.stopping = 0
	s.healthy = 0
	s.worker = thread.create_and_start_with_data(s, entry, init_context = context)
}
stop :: proc(s: ^Service) {
	if s.worker == nil do return
	sync.atomic_store(&s.stopping, 1)
	wake(s)
	thread.join(s.worker)
	thread.destroy(s.worker)
	s.worker = nil
	context.allocator = runtime.heap_allocator()
	delete(s.options.url); delete(s.options.creds_file); delete(s.options.ca_file)
	s.options = {}
	sync.atomic_store(&s.healthy, 0)
}
entry :: proc(data: rawptr) {
	s := (^Service)(data)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	defer { nats.destroy(s.connection); s.connection = nil }
	delay := 100 * time.Millisecond
	for sync.atomic_load(&s.stopping) == 0 {
		ok, progress := step(s)
		wait := time.Duration(0)
		if !ok {
			wait = delay
			delay = min(delay * 2, 5 * time.Second)
		} else {
			delay = 100 * time.Millisecond
			if !progress {
				idle_wait := s.idle_wait if s.idle_wait > 0 else time.Second
				_ = sync.sema_wait_with_timeout(&s.wake_sema, idle_wait)
			}
		}
		free_all(context.allocator)
		for wait > 0 && sync.atomic_load(&s.stopping) == 0 {
			chunk := min(wait, 50 * time.Millisecond)
			time.sleep(chunk)
			wait -= chunk
		}
	}
}
// step is also usable synchronously by deterministic integration tests.
// Its caller owns the returned connection lifetime and per-pass scratch storage.
step :: proc(s: ^Service) -> (ok, progress: bool) {
	ok, progress = step_inner(s)
	sync.atomic_store(&s.healthy, 1 if ok else 0)
	if !ok {
		nats.destroy(s.connection)
		s.connection = nil
	}
	return
}
step_inner :: proc(s: ^Service) -> (bool, bool) {
	if s.connection == nil {
		conn, err := nats.connect(s.options)
		if err.status != 0 do return false, false
		s.connection = conn
		cfg := stream_config()
		// Add is idempotent for an identical config. Existing differing configs
		// require update; neither operation deletes messages or consumers.
		_, err = nats.stream_add(conn, cfg)
		if err.status != 0 {
			_, err = nats.stream_update(conn, cfg)
			if err.status != 0 do return false, false
		}

		delivery_cfg := delivery_stream_config()
		_, err = nats.stream_add(conn, delivery_cfg)
		if err.status != 0 {
			_, err = nats.stream_update(conn, delivery_cfg)
			if err.status != 0 do return false, false
		}
		lookup := s.support_lookup
		if lookup == nil do lookup = nats.server_supports_schedules
		supported, support_err := lookup(conn, cfg.name)
		// A failed lookup is a failed setup, not evidence of an old server.
		// step closes the connection and retries without consuming outbox rows.
		if support_err.status != 0 do return false, false
		sync.atomic_store(&s.support, i32(Schedule_Support.Supported) if supported else i32(Schedule_Support.Unsupported))
	}
	progress := false
	for _ in 0 ..< RELAY_BATCH {
		ok, handled := relay_one(s)
		progress = progress || handled
		if !ok do return false, progress
		if !handled do break
	}
	if s.last_prune._nsec == 0 || time.tick_since(s.last_prune) >= time.Minute {
		prune, began, _ := iface.unit_of_work_begin(s.factory)
		if !began do return false, progress
		defer if prune.ctx != nil do iface.unit_of_work_rollback(&prune)
		before := platform.format_rfc3339_utc(time.time_add(time.now(), -24 * time.Hour))
		err := prune.repos.event_outbox.prune(prune.repos.event_outbox.ctx, before)
		if err.code != .None do return false, progress
		committed, _ := iface.unit_of_work_commit(&prune)
		prune.ctx = nil // commit consumes the context even when it fails
		if !committed do return false, progress
		s.last_prune = time.tick_now()
	}
	return true, progress
}
relay_one :: proc(s: ^Service) -> (bool, bool) {
	uow, began, _ := iface.unit_of_work_begin(s.factory)
	if !began do return false, false
	row, found, err := uow.repos.event_outbox.next(uow.repos.event_outbox.ctx)
	if err.code != .None { iface.unit_of_work_rollback(&uow); return false, false }
	committed, _ := iface.unit_of_work_commit(&uow)
	if !committed { domain.event_outbox_row_destroy(&row); return false, false }
	defer domain.event_outbox_row_destroy(&row)
	if found {
		// JSON header values must be strings. Reject malformed persisted metadata
		// without skipping the head row (and therefore without reordering events).
		value, parse_err := json.parse(row.headers_json)
		if parse_err != nil do return false, false
		defer json.destroy_value(value)
		object, is_object := value.(json.Object)
		if !is_object do return false, false
		purge := false
		headers := make([dynamic]nats.Header)
		defer delete(headers)
		for k, v in object {
			str, is_string := v.(json.String)
			if !is_string do return false, false
			if k == "Heim-Op" { purge = string(str) == "purge"; continue }
			// event_id is authoritative even if a producer supplied this header.
			if strings.to_lower(k, context.temp_allocator) == "nats-msg-id" do continue
			append(&headers, nats.Header{k, string(str)})
		}
		pub_err: nats.Error
		if purge {
			_, pub_err = nats.stream_purge_subject(s.connection, "HEIM_EVENTS", row.subject)
		} else if strings.has_prefix(row.subject, "sched.def.") && schedule_support(s) == .Unsupported {
			if !s.unsupported_logged {
				fmt.eprintf("eventrelay: dropping schedule definitions: server does not support schedules\n")
				s.unsupported_logged = true
			}
		} else {
			_, pub_err = nats.publish(s.connection, row.subject, transmute([]byte)row.envelope_json, row.event_id, headers[:])
			if strings.has_prefix(row.subject, "sched.def.") &&
			   (pub_err.jetstream == 10189 || pub_err.jetstream == 10190 || pub_err.jetstream == 10223) {
				fmt.eprintf("eventrelay: rejected schedule %s: %d\n", row.subject, pub_err.jetstream)
				sync.atomic_add(&s.schedule_rejects, 1)
				pub_err = {}
			}
		}
		if pub_err.status != 0 do return false, false
		if s.published != nil do s.published(s.published_ctx, row.subject)
		mark, mark_began, _ := iface.unit_of_work_begin(s.factory)
		if !mark_began do return false, false
		err = mark.repos.event_outbox.mark_published(mark.repos.event_outbox.ctx, row.outbox_seq, platform.format_rfc3339_utc(time.now()))
		if err.code != .None { iface.unit_of_work_rollback(&mark); return false, false }
		if marked, _ := iface.unit_of_work_commit(&mark); !marked do return false, false
	} else {
		// Check connectivity even with no pending events so health detects outages.
		_, info_err := nats.stream_info(s.connection, "HEIM_EVENTS")
		if info_err.status != 0 do return false, false
	}
	return true, found
}
health :: proc(s: ^Service) -> (status: string, backlog: i64) {
	status = "degraded"
	uow, began, _ := iface.unit_of_work_begin(s.factory)
	if !began do return
	count, err := uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
	if err.code != .None { iface.unit_of_work_rollback(&uow); return }
	committed, _ := iface.unit_of_work_commit(&uow)
	if !committed do return
	backlog = count
	if sync.atomic_load(&s.healthy) != 0 do status = "ok"
	return
}
