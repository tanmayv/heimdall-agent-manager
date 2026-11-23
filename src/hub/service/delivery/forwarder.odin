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
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import nats "odin_test:lib/nats"

find_forwarder :: proc(s: ^Service, bridge_id: string) -> ^Forwarder {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	for f in s.forwarders do if f.bridge_id == bridge_id do return f
	return nil
}

forwarder_snapshot :: proc(s: ^Service) -> []^Forwarder {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	rows := make([]^Forwarder, len(s.forwarders))
	copy(rows, s.forwarders[:])
	return rows
}

enqueue_answer :: proc(s: ^Service, bridge_id: string, op: Answer_Op, reply: string, delay_ms: i64 = 0) {
	f := find_forwarder(s, bridge_id)
	if f == nil || sync.atomic_load(&f.disabled) != 0 || reply == "" do return
	answer := Answer {
		op       = op,
		reply    = strings.clone(reply, runtime.heap_allocator()),
		delay_ms = delay_ms,
	}
	sync.mutex_lock(&f.mutex)
	append(&f.answers, answer)
	sync.mutex_unlock(&f.mutex)
	sync.sema_post(&f.wake)
}

// The queue's allocator is always the heap, independent of the callback's arena.
take_answers :: proc(f: ^Forwarder) -> [dynamic]Answer {
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	answers := f.answers
	f.answers = make([dynamic]Answer, runtime.heap_allocator())
	return answers
}

free_answers :: proc(answers: [dynamic]Answer) {
	for a in answers do delete(a.reply, runtime.heap_allocator())
	delete(answers)
}

forwarder_entry :: proc(data: rawptr) {
	f := (^Forwarder)(data)
	s := f.service
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	for sync.atomic_load(&s.stopping) == 0 && sync.atomic_load(&f.disabled) == 0 {
		wait := forwarder_pass(f)
		free_all(context.allocator)
		if wait > 0 {_ = sync.sema_wait_with_timeout(&f.wake, wait)} else if wait < 0 {sync.sema_wait(&f.wake)}
	}
}

// A negative duration means wait until an external event, never while holding conn_lock.

forwarder_pass :: proc(f: ^Forwarder) -> time.Duration {
	s := f.service
	if s.registry == nil || !project.bridge_runtime_registry_has_live(s.registry, f.bridge_id) {
		retire_idle_pull(f)
		return -1
	}
	sync.rw_mutex_shared_lock(&s.conn_lock)
	defer sync.rw_mutex_shared_unlock(&s.conn_lock)
	if sync.atomic_load(&f.disabled) != 0 do return -1
	if !s.connected || sync.atomic_load(&s.reconnect) != 0 do return -1
	ms, valid := platform.rfc3339_to_unix_ms(platform.clock_now(s.clock))
	if !valid do return time.Second
	if sync.atomic_exchange(&f.invalidate_slots, 0) != 0 do reset_slots(f)
	if !f.slots_loaded {
		uow, ok, _ := iface.unit_of_work_begin(s.factory)
		if !ok do return time.Second
		since := platform.format_rfc3339_utc(time.Time{_nsec = (ms - s.ack_wait_ms) * 1_000_000})
		repo := &uow.repos.pipeline_deliveries
		sync.atomic_add(&s.in_flight_queries, 1)
		count, db_err := repo.in_flight(repo.ctx, f.bridge_id, since)
		if db_err.code != .None {iface.unit_of_work_rollback(&uow); return time.Second}
		// Only nonempty recovery needs the reply keys. This one-time read
		// lets answers release recovered slots immediately after reconnect.
		if count > 0 {
			rows, err := repo.open_for_bridge(repo.ctx, f.bridge_id, domain.DELIVERY_FORWARDED, -1)
			if err.code != .None {iface.unit_of_work_rollback(&uow); reset_slots(f); return time.Second}
			for d in rows {
				if d.retry_at == "" && d.updated_at > since && d.ack_reply != "" do reserve_slot(f, d.ack_reply, ms)
			}
			domain.pipeline_deliveries_destroy(rows)
		}
		iface.unit_of_work_rollback(&uow)
		f.recovered_slots = max(count - len(f.slots), 0)
		f.recovered_until_ms = ms + s.ack_wait_ms
		f.slots_loaded = true
	}
	answers := take_answers(f)
	failed := false
	for a in answers {
		err: nats.Error
		switch a.op {
		case .Ack: err = nats.ack_reply_async(s.conn, a.reply)
		case .Term: err = nats.term_reply(s.conn, a.reply)
		case .In_Progress: err = nats.in_progress_reply(s.conn, a.reply)
		case .Nak_Delay: err = nats.nak_reply_delay(s.conn, a.reply, a.delay_ms)
		}
		if err.status == 0 {
			if a.op == .In_Progress {
				if _, found := f.slots[a.reply]; found {
					f.slots[a.reply] = ms + s.ack_wait_ms
				} else if f.recovered_slots > 0 {
					f.recovered_until_ms = ms + s.ack_wait_ms
				} else {
					reserve_slot(f, a.reply, ms)
				}
			} else {
				release_slot(f, a.reply)
			}
		}
		failed = failed || err.status != 0
	}
	free_answers(answers)
	if failed {connection_failed(s); return -1}
	count := active_slots(f, ms)
	n := contracts.DELIVERY_MAX_IN_FLIGHT - count
	if n <= 0 do return 100 * time.Millisecond
	if f.pull == nil {
		name := fmt.tprintf("brg_%s", f.bridge_id)
		err := nats.consumer_add(s.conn, {
			stream = STREAM,
			durable = name,
			filter_subjects = []string{fmt.tprintf("dlv.*.%s.>", f.bridge_id)},
			ack_wait_ns = s.ack_wait_ms * 1_000_000,
			max_deliver = i64(s.max_deliver),
			max_ack_pending = contracts.DELIVERY_MAX_ACK_PENDING,
		})
		if err.status != 0 {connection_failed(s); return -1}
		f.pull, err = nats.long_pull_bind(s.conn, STREAM, name)
		if err.status != 0 {connection_failed(s); return -1}
	}
	// The 30s server pull survives 100ms local waits. Answers, shutdown and
	// reconnect run between waits; conn_lock is never held for 30 seconds.
	msg, requested, err := nats.long_pull_next(f.pull, n, 100)
	if requested do sync.atomic_add(&s.pull_requests, 1)
	if err.status != 0 {
		if err.status != 26 {connection_failed(s); return -1}
		return 0
	}
	if sync.atomic_load(&f.disabled) != 0 {nats.message_destroy(msg); return -1}
	forwarded := forward_gate(f, msg)
	// A message can refer to its subscription; destroy it before a failed
	// pass retires the pull binding.
	nats.message_destroy(msg)
	if !forwarded {
		// Match fetch-batch failure semantics: discard locally queued messages,
		// leaving them unacked for redelivery rather than forwarding an old
		// partial pull after the failure backoff.
		nats.long_pull_destroy(f.pull)
		f.pull = nil
		return 5 * time.Second
	}
	return 0
}

// Runs under conn_lock shared. Every network operation follows the UoW's end.
forward_gate :: proc(f: ^Forwarder, msg: ^nats.Message) -> bool {
	s := f.service
	wire: contracts.Delivery_Wire
	meta, me := nats.message_metadata(msg)
	if json.unmarshal(nats.message_data(msg), &wire) != nil || wire.delivery_id == "" || me.status != 0 {
		sync.atomic_add(&s.invalid_messages, 1)
		_ = nats.term_reply(s.conn, nats.message_reply(msg))
		return true
	}
	// Decoded strings belong to this pass's arena.
	uow, ok, _ := iface.unit_of_work_begin(s.factory)
	if !ok do return false
	repo := &uow.repos.pipeline_deliveries
	d, found, err := repo.get(repo.ctx, wire.delivery_id)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false}
	defer domain.pipeline_delivery_destroy(&d)
	if !found || d.bridge_id != f.bridge_id {
		iface.unit_of_work_rollback(&uow)
		sync.atomic_add(&s.invalid_messages, 1); _ = nats.term_reply(s.conn, nats.message_reply(msg))
		return true
	}
	if !domain.pipeline_delivery_open(d.state) {
		iface.unit_of_work_rollback(&uow); _ = nats.ack_reply_async(s.conn, nats.message_reply(msg))
		return true
	}
	reason := ""
	if d.expires_at <= platform.clock_now(s.clock) {reason = "bridge_offline"} else {
		sink := find_sink(s, d.kind)
		if sink.still_valid != nil && !sink.still_valid(sink.ctx, &uow, d) do reason = "superseded"
	}
	if reason != "" {
		changed, close_err := close_delivery(s, &uow, d, domain.DELIVERY_FAILED, reason, "")
		if close_err.code != .None {iface.unit_of_work_rollback(&uow); return false}
		committed, _ := iface.unit_of_work_commit(&uow)
		if committed && changed {_ = nats.ack_reply_async(s.conn, nats.message_reply(msg)); prune_after_final(s)}
		return committed
	}
	next := d
	next.state = domain.DELIVERY_FORWARDED; next.attempt = int(meta.num_delivered)
	next.ack_reply = nats.message_reply(msg); next.stream_sequence = i64(meta.stream_sequence); next.retry_at = ""
	next.updated_at = platform.clock_now(s.clock)
	if next.forwarded_at == "" do next.forwarded_at = next.updated_at
	changed, te := repo.transition(repo.ctx, next, d.state)
	if te.code != .None {iface.unit_of_work_rollback(&uow); return false}
	committed, _ := iface.unit_of_work_commit(&uow)
	if !committed do return false

	if !changed {_ = nats.ack_reply_async(s.conn, nats.message_reply(msg)); return true}
	ms, valid := platform.rfc3339_to_unix_ms(next.updated_at)
	if !valid do return false
	reserve_slot(f, next.ack_reply, ms)
	frame := contracts.Event_Deliver_Wire {
		type              = contracts.EVENT_DELIVER_FRAME,
		command_id        = fmt.tprintf("%s:%d", d.delivery_id, next.attempt),
		agent_instance_id = d.agent_instance_id,
		attempt           = next.attempt,
		final             = next.attempt >= s.max_deliver,
		delivery          = wire,
	}
	body, je := json.marshal(frame)
	if je != nil do return false
	defer delete(body)
	if s.commands == nil do return false
	sent, _ := project.bridge_command_send_runtime(
		s.commands^,
		{bridge_id = f.bridge_id, command_id = frame.command_id, body_json = string(body)},
	)
	return sent
}

// Recovered rows normally have reply-keyed reservations. Missing/duplicate
// reply keys retain an anonymous conservative floor for one full AckWait.
// Duplicate/late answers never release another attempt's slot.
reset_slots :: proc(f: ^Forwarder) {
	for reply in f.slots do delete(reply, runtime.heap_allocator())
	delete(f.slots)
	f.slots = nil
	f.slots_loaded = false
	f.recovered_slots = 0
}
release_slot :: proc(f: ^Forwarder, reply: string) {
	if _, found := f.slots[reply]; !found do return
	for key in f.slots {
		if key == reply {
			delete_key(&f.slots, key)
			delete(key, runtime.heap_allocator())
			return
		}
	}
}
reserve_slot :: proc(f: ^Forwarder, reply: string, ms: i64) {
	if f.slots == nil do f.slots = make(map[string]i64, runtime.heap_allocator())
	if _, found := f.slots[reply]; !found {
		f.slots[strings.clone(reply, runtime.heap_allocator())] = ms + f.service.ack_wait_ms
	} else {
		f.slots[reply] = ms + f.service.ack_wait_ms
	}
}
active_slots :: proc(f: ^Forwarder, ms: i64) -> int {
	if ms >= f.recovered_until_ms do f.recovered_slots = 0
	for reply, until in f.slots {
		if ms >= until {
			delete_key(&f.slots, reply)
			delete(reply, runtime.heap_allocator())
		}
	}
	return f.recovered_slots + len(f.slots)
}

// Stop server-side demand before an offline forwarder parks. Exclusive conn_lock
// waits out the bounded local receive and prevents concurrent destruction.
retire_idle_pull :: proc(f: ^Forwarder) {
	s := f.service
	sync.rw_mutex_lock(&s.conn_lock)
	defer sync.rw_mutex_unlock(&s.conn_lock)
	if f.pull != nil {
		nats.long_pull_destroy(f.pull)
		f.pull = nil
		// Order UNSUB before the caller can consider this pull retired.
		if nats.flush(s.conn).status != 0 do connection_failed(s)
	}
}
