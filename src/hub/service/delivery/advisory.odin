package delivery

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

start :: proc(s: ^Service) -> bool {
	if s.worker != nil do return true
	expire_due(s)
	context.allocator = runtime.heap_allocator()
	s.worker = thread.create_and_start_with_data(s, supervisor_entry, init_context = context)
	if s.worker == nil do return false
	rows := forwarder_snapshot(s)
	defer delete(rows)
	for f in rows {
		sync.mutex_lock(&f.lifecycle)
		if sync.atomic_load(&f.disabled) == 0 && f.worker == nil do f.worker = thread.create_and_start_with_data(f, forwarder_entry, init_context = context)
		sync.mutex_unlock(&f.lifecycle)
	}
	return true
}

stop :: proc(s: ^Service) {
	if s == nil do return
	sync.atomic_store(&s.stopping, 1)
	sync.sema_post(&s.wake)
	// The supervisor closes its handles after active passes leave conn_lock.
	// Join every worker before freeing the shared state.
	if s.worker != nil {thread.join(s.worker); thread.destroy(s.worker)}
	context.allocator = runtime.heap_allocator()
	for f in s.forwarders do sync.sema_post(&f.wake)
	for f in s.forwarders {
		if f.worker != nil {thread.join(f.worker); thread.destroy(f.worker)}
		assert(f.pull == nil)
		free_answers(f.answers)
		delete(f.bridge_id); free(f)
	}
	delete(s.forwarders)
	for id in s.consumer_deletions do delete(id)
	delete(s.consumer_deletions)
	for id in s.refused_bridges do delete(id)
	delete(s.refused_bridges)
	for v in s.sinks do delete(v.kind)
	delete(s.sinks)
	delete(s.options.url); delete(s.options.creds_file); delete(s.options.ca_file)
	free(s)
}

connection_failed :: proc(s: ^Service) {
	sync.atomic_store(&s.reconnect, 1)
	sync.sema_post(&s.wake)
}

supervisor_disconnect :: proc(s: ^Service, advisory: ^^nats.Pull) {
	sync.rw_mutex_lock(&s.conn_lock)
	defer sync.rw_mutex_unlock(&s.conn_lock)
	if advisory^ != nil {nats.pull_destroy(advisory^); advisory^ = nil}
	rows := forwarder_snapshot(s)
	defer delete(rows)
	for f in rows {
		if f.pull != nil {nats.pull_destroy(f.pull); f.pull = nil}
		free_answers(take_answers(f))
	}
	nats.destroy(s.conn); s.conn = nil; s.connected = false
}

supervisor_entry :: proc(data: rawptr) {
	s := (^Service)(data)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	advisory: ^nats.Pull
	defer supervisor_disconnect(s, &advisory)
	delay := 100 * time.Millisecond
	for sync.atomic_load(&s.stopping) == 0 {
		if sync.atomic_load(&s.reconnect) != 0 || s.conn == nil {
			supervisor_disconnect(s, &advisory)
			if !supervisor_connect(s, &advisory) {
				supervisor_disconnect(s, &advisory)
				free_all(context.allocator)
				_ = sync.sema_wait_with_timeout(&s.wake, delay)
				delay = min(2 * delay, 5 * time.Second)
				continue
			}
			delay = 100 * time.Millisecond
			// No connection lock is held while opening a UoW.
			expire_due(s)
			rows := forwarder_snapshot(s)
			for f in rows do sync.sema_post(&f.wake)
			delete(rows)
		}
		sync.rw_mutex_shared_lock(&s.conn_lock)
		sync.mutex_lock(&s.mutex)
		deletions := s.consumer_deletions
		s.consumer_deletions = make([dynamic]string, runtime.heap_allocator())
		sync.mutex_unlock(&s.mutex)
		for id in deletions {
			err := nats.consumer_delete(s.conn, STREAM, fmt.tprintf("brg_%s", id))
			if err.status != 0 && err.jetstream != 10014 do queue_consumer_deletion(s, id)
			delete(id, runtime.heap_allocator())
		}
		delete(deletions)
		rows := forwarder_snapshot(s)
		for f in rows {
			if sync.atomic_exchange(&f.delete_consumer, 0) != 0 {
				// A deletion request fences new passes; exclusive cleanup waits out
				// an already fetched batch before touching its pull binding.
				sync.rw_mutex_shared_unlock(&s.conn_lock)
				sync.rw_mutex_lock(&s.conn_lock)
				if f.pull != nil {nats.pull_destroy(f.pull); f.pull = nil}
				err := nats.consumer_delete(s.conn, STREAM, fmt.tprintf("brg_%s", f.bridge_id))
				if err.status != 0 && err.jetstream != 10014 do sync.atomic_store(&f.delete_consumer, 1)
				sync.rw_mutex_unlock(&s.conn_lock)
				sync.rw_mutex_shared_lock(&s.conn_lock)
			}
		}
		delete(rows)
		batch, err := nats.fetch(advisory, 20, 1000)
		if err.status != 0 && err.status != 26 do connection_failed(s)
		for i in 0 ..< nats.batch_count(batch) do drain_advisory(s, nats.batch_message(batch, i))
		nats.batch_destroy(batch)
		sync.rw_mutex_shared_unlock(&s.conn_lock)
		free_all(context.allocator)
	}
}

supervisor_connect :: proc(s: ^Service, advisory: ^^nats.Pull) -> bool {
	sync.rw_mutex_lock(&s.conn_lock)
	defer sync.rw_mutex_unlock(&s.conn_lock)
	conn, err := nats.connect(s.options)
	if err.status != 0 do return false
	s.conn = conn
	cfg := nats.Stream_Config {
		name                = ADVISORY_STREAM,
		subjects            = []string{"$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.HEIM_DELIVER.>"},
		max_age_ns          = i64(14 * 24 * time.Hour),
		duplicate_window_ns = i64(2 * time.Minute),
		replicas            = 1,
	}
	_, err = nats.stream_add(conn, cfg)
	if err.status != 0 {
		_, err = nats.stream_update(conn, cfg)
		if err.status != 0 do return false
	}
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
	advisory^, err = nats.pull_bind(conn, ADVISORY_STREAM, ADVISORY_CONSUMER)
	if err.status != 0 do return false
	s.connected = true
	sync.atomic_store(&s.reconnect, 0)
	return true
}

drain_advisory :: proc(s: ^Service, msg: ^nats.Message) {
	value: struct {
		stream, consumer: string,
		stream_seq:       u64,
	}
	if json.unmarshal(nats.message_data(msg), &value) != nil || value.stream != STREAM || value.stream_seq == 0 {
		_ = nats.ack(msg); return
	}
	original, err := nats.stream_get(s.conn, STREAM, value.stream_seq)
	if err.status != 0 {
		if err.jetstream == 10037 do _ = nats.ack(msg)
		return
	}
	defer nats.message_destroy(original)
	wire: contracts.Delivery_Wire
	if json.unmarshal(nats.message_data(original), &wire) == nil && wire.delivery_id != "" {
		uow, ok, _ := iface.unit_of_work_begin(s.factory)
		if !ok do return
		repo := &uow.repos.pipeline_deliveries
		d, found, de := repo.get(repo.ctx, wire.delivery_id)
		if de.code != .None {iface.unit_of_work_rollback(&uow); return}
		changed := false
		if found do changed, de = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "no_answer", "")
		domain.pipeline_delivery_destroy(&d)
		if de.code != .None {iface.unit_of_work_rollback(&uow); return}
		committed, _ := iface.unit_of_work_commit(&uow)
		if !committed do return
		if changed do prune_after_final(s)
	}
	_, err = nats.stream_delete_message(s.conn, STREAM, value.stream_seq)
	if err.status == 0 do _ = nats.ack(msg)
}
