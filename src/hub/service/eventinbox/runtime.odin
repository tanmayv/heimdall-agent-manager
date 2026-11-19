package eventinbox

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

Runtime :: struct {
	service:    ^Service,
	worker:     ^thread.Thread,
	stopping:   i32,
	connection: ^nats.Connection,
	advisory:   ^nats.Pull,
}
ADVISORY_STREAM :: "HEIM_EVENT_ADVISORIES"
ADVISORY_CONSUMER :: "hub_event_dlq"
start :: proc(r: ^Runtime, s: ^Service) {
	if r.worker != nil do return
	context.allocator = runtime.heap_allocator()
	r.service = s
	// Runtime and HTTP use independent connections. Service config is immutable.
	s.options.url = strings.clone(s.options.url)
	s.options.creds_file = strings.clone(s.options.creds_file)
	s.options.ca_file = strings.clone(s.options.ca_file)
	r.stopping = 0
	r.worker = thread.create_and_start_with_data(r, runtime_entry, init_context = context)
}
stop :: proc(r: ^Runtime) {
	if r.worker == nil do return
	sync.atomic_store(&r.stopping, 1)
	thread.join(r.worker); thread.destroy(r.worker); r.worker = nil
	context.allocator = runtime.heap_allocator()
	delete(r.service.options.url); delete(r.service.options.creds_file); delete(r.service.options.ca_file)
	r.service.options = {}
}
runtime_disconnect :: proc(r: ^Runtime) {
	nats.pull_destroy(r.advisory); r.advisory = nil
	nats.destroy(r.connection); r.connection = nil
}
runtime_entry :: proc(data: rawptr) {
	r := (^Runtime)(data)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	defer runtime_disconnect(r)
	for sync.atomic_load(&r.stopping) == 0 {
		ok := reconcile(r)
		if !ok do runtime_disconnect(r)
		free_all(context.allocator)
		delay := 100 * time.Millisecond if ok else time.Second
		for delay > 0 && sync.atomic_load(&r.stopping) == 0 {
			chunk := min(delay, 50 * time.Millisecond)
			time.sleep(chunk); delay -= chunk
		}
	}
}
// Persist advisories in their own stream before any pull consumer is created.
// A core subscription alone could lose max-delivery notices across hub restarts.
runtime_connect :: proc(r: ^Runtime) -> bool {
	if r.connection != nil do return true
	conn, err := nats.connect(r.service.options)
	if err.status != 0 do return false
	r.connection = conn
	if !prepare_advisories(conn) do return false
	err = nats.consumer_add(
		conn,
		{
			stream = ADVISORY_STREAM,
			durable = ADVISORY_CONSUMER,
			ack_wait_ns = i64(time.Second),
			max_deliver = 0x7fffffffffffffff,
		},
	)
	if err.status != 0 do return false
	pull, perr := nats.pull_bind(conn, ADVISORY_STREAM, ADVISORY_CONSUMER)
	if perr.status != 0 do return false
	r.advisory = pull
	return true
}
reconcile :: proc(r: ^Runtime) -> bool {
	if !runtime_connect(r) do return false
	s := r.service
	uow, began, _ := iface.unit_of_work_begin(s.factory)
	if !began do return false
	repo := uow.repos.event_subscriptions
	rows, err := repo.all(repo.ctx)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false}
	deleted, derr := repo.deletions(repo.ctx)
	if derr.code != .None {subscription_rows_destroy(rows); iface.unit_of_work_rollback(&uow); return false}
	committed, _ := iface.unit_of_work_commit(&uow)
	defer subscription_rows_destroy(rows)
	defer {for name in deleted do delete(name); delete(deleted)}
	if !committed do return false
	// JetStream calls happen strictly after commit, including deletion retries.
	for row in rows do if !ensure_consumer(s, r.connection, row) do return false
	for name in deleted {
		nerr := nats.consumer_delete(r.connection, "HEIM_EVENTS", name)
		// ConsumerNotFound means an earlier deletion completed before a crash.
		if nerr.status != 0 && nerr.jetstream != 10014 do return false
		mark, began_mark, _ := iface.unit_of_work_begin(s.factory)
		if !began_mark do return false
		mark_repo := mark.repos.event_subscriptions
		if mark_repo.deleted(mark_repo.ctx, name).code != .None {iface.unit_of_work_rollback(&mark); return false}
		marked, _ := iface.unit_of_work_commit(&mark)
		if !marked do return false
	}
	return drain_advisories(r)
}
drain_advisories :: proc(r: ^Runtime) -> bool {
	batch, err := nats.fetch(r.advisory, 20, 10)
	if err.status == 26 do return true
	if err.status != 0 do return false
	defer nats.batch_destroy(batch)
	for i in 0 ..< nats.batch_count(batch) {
		advisory := nats.batch_message(batch, i)
		input: struct {
			stream, consumer: string,
			stream_seq:       u64,
		}
		decode_err := json.unmarshal(nats.message_data(advisory), &input)
		defer {delete(input.stream); delete(input.consumer)}
		if decode_err != nil || input.stream != "HEIM_EVENTS" || input.stream_seq == 0 do return false
		msg, get_err := nats.stream_get(r.connection, input.stream, input.stream_seq)
		if get_err.status != 0 {
			// A rolled-up state or expired original no longer needs a dead letter.
			if get_err.jetstream == 10037 {
				if nats.ack(advisory).status != 0 do return false
				continue
			}
			return false
		}
		subject := nats.message_subject(msg)
		if !strings.has_prefix(subject, "ev.") {nats.message_destroy(msg); return false}
		destination := fmt.tprintf("ev.dlq.%s", strings.trim_prefix(subject, "ev."))
		id := fmt.tprintf("dlq:%s:%d", input.consumer, input.stream_seq)
		_, pub_err := nats.publish(
			r.connection,
			destination,
			nats.message_data(msg),
			id,
			[]nats.Header{{"Heimdall-Consumer", input.consumer}, {"Heimdall-Original-Subject", subject}},
		)
		nats.message_destroy(msg)
		if pub_err.status != 0 do return false
		if nats.ack(advisory).status != 0 do return false
	}
	return true
}

// Capturing advisory publication durably must precede every consumer's first
// fetch, including an HTTP request arriving before the background pass.
prepare_advisories :: proc(conn: ^nats.Connection) -> bool {
	cfg := nats.Stream_Config {
		name                = ADVISORY_STREAM,
		subjects            = []string{"$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.HEIM_EVENTS.>"},
		max_age_ns          = i64(14 * 24 * time.Hour),
		duplicate_window_ns = i64(2 * time.Minute),
		replicas            = 1,
	}
	_, err := nats.stream_add(conn, cfg)
	if err.status != 0 {
		_, err = nats.stream_update(conn, cfg)
		if err.status != 0 do return false
	}
	return true
}
