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
	for sync.atomic_load(&s.stopping) == 0 {
		if sync.atomic_load(&f.disabled) != 0 {
			sync.sema_wait(&f.wake)
			continue
		}
		wait := forwarder_pass(f)
		free_all(context.allocator)
		if wait > 0 {_ = sync.sema_wait_with_timeout(&f.wake, wait)} else if wait < 0 {sync.sema_wait(&f.wake)}
	}
}

// A negative duration means wait until an external event, never while holding conn_lock.
forwarder_pass :: proc(f: ^Forwarder) -> time.Duration {
	s := f.service
	if s.registry == nil || !project.bridge_runtime_registry_has_live(s.registry, f.bridge_id) do return -1
	sync.rw_mutex_shared_lock(&s.conn_lock)
	defer sync.rw_mutex_shared_unlock(&s.conn_lock)
	if !s.connected || sync.atomic_load(&s.reconnect) != 0 do return -1
	answers := take_answers(f)
	failed := false
	for a in answers {
		err: nats.Error
		switch a.op {
		case .Ack:
			err = nats.ack_reply_async(s.conn, a.reply)
		case .Term:
			err = nats.term_reply(s.conn, a.reply)
		case .In_Progress:
			err = nats.in_progress_reply(s.conn, a.reply)
		case .Nak_Delay:
			err = nats.nak_reply_delay(s.conn, a.reply, a.delay_ms)
		}
		failed = failed || err.status != 0
	}
	free_answers(answers)
	if failed {connection_failed(s); return -1}
	uow, ok, _ := iface.unit_of_work_begin(s.factory)
	if !ok do return time.Second
	ms, valid := platform.rfc3339_to_unix_ms(platform.clock_now(s.clock))
	if !valid {iface.unit_of_work_rollback(&uow); return time.Second}
	since := platform.format_rfc3339_utc(time.Time{_nsec = (ms - s.ack_wait_ms) * 1_000_000})
	repo := &uow.repos.pipeline_deliveries
	count, db_err := repo.in_flight(repo.ctx, f.bridge_id, since)
	iface.unit_of_work_rollback(&uow)
	if db_err.code != .None do return time.Second
	n := contracts.DELIVERY_MAX_IN_FLIGHT - count
	if n <= 0 do return time.Second
	if f.pull == nil {
		name := fmt.tprintf("brg_%s", f.bridge_id)
		err := nats.consumer_add(
			s.conn,
			{
				stream = STREAM,
				durable = name,
				filter_subjects = []string{fmt.tprintf("dlv.*.%s.>", f.bridge_id)},
				ack_wait_ns = s.ack_wait_ms * 1_000_000,
				max_deliver = i64(s.max_deliver),
				max_ack_pending = contracts.DELIVERY_MAX_ACK_PENDING,
			},
		)
		if err.status != 0 {connection_failed(s); return -1}
		f.pull, err = nats.pull_bind(s.conn, STREAM, name)
		if err.status != 0 {connection_failed(s); return -1}
	}
	batch, err := nats.fetch(f.pull, n, 1000)
	defer nats.batch_destroy(batch)
	if err.status != 0 {
		if err.status != 26 {nats.pull_destroy(f.pull); f.pull = nil; connection_failed(s); return -1}
		return 0
	}
	for i in 0 ..< nats.batch_count(batch) {
		if sync.atomic_load(&f.disabled) != 0 do break
		if !forward_gate(f, nats.batch_message(batch, i)) do return 5 * time.Second
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
		_ = nats.term(msg)
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
		sync.atomic_add(&s.invalid_messages, 1); _ = nats.term(msg)
		return true
	}
	if !domain.pipeline_delivery_open(d.state) {
		iface.unit_of_work_rollback(&uow); _ = nats.ack(msg)
		return true
	}
	reason := ""
	if d.expires_at <= platform.clock_now(s.clock) {reason = "bridge_offline"} else {
		sink := find_sink(s, d.kind)
		if sink.still_valid != nil && !sink.still_valid(sink.ctx, &uow, d) do reason = "superseded"
	}
	if reason != "" {
		changed := close_delivery(s, &uow, d, domain.DELIVERY_FAILED, reason, "")
		committed, _ := iface.unit_of_work_commit(&uow)
		if committed && changed {_ = nats.ack(msg); prune_after_final(s)}
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
	if !changed {_ = nats.ack(msg); return true}
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
