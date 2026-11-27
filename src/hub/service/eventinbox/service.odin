package eventinbox

import "core:encoding/json"
import "core:fmt"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

Notice_Process :: enum {Unknown, Ready, Exited}

Service :: struct {
	factory:     ^iface.Unit_Of_Work_Factory,
	notice_dirty: Notice_Dirty,
 wake_mutex: sync.Mutex,
 wake_cond: sync.Cond,
 wake_pending: bool,
 watched_scopes: map[string]bool,
 interest_ready: bool,
 reconcile_interval: time.Duration, // Zero uses five minutes.

	counters: Counter_Registry,
	notice_ctx: rawptr,
	notice_process: proc(ctx: rawptr, owner: string, target: domain.Event_Notice_Target) -> Notice_Process,
	// Called outside a UoW. True means the existing notice/start path accepted it.
	notice: proc(ctx: rawptr, owner, instance: string, target: domain.Event_Notice_Target, count: int, wake: bool) -> bool,
	options:     nats.Connect_Options,
	ids:         ^platform.ID_Generator,
	ack_wait:    time.Duration,
	max_deliver: i64,
	// provisioned is the process-wide record of JetStream consumers already
	// created with their current config; the runtime and HTTP pulls share it so
	// a pull never re-provisions a known consumer (REQ-EVQ-4).
	provisioned: Provisioned_Cache,
	// pull_cursor rotates where next starts scanning subscriptions, so a pull
	// that stops at its budget or limit does not starve the later ones.
	pull_cursor: u64,
	// provision_calls counts consumer provisioning requests (consumer_add plus
	// fence) made through this service; tests use it to prove pulls reuse the cache.
	provision_calls: u64,
}
Provisioned_Cache :: struct {
	mutex: sync.Mutex,
	names: map[string]string, // consumer_name -> config fingerprint
}
// NEXT_OVERHEAD_BUDGET bounds the work next may do beyond the caller's wait:
// no NATS step starts once wait + this budget has elapsed (the deadline is
// checked before every request). The longest step that can start just before
// the deadline is provisioning (consumer_add plus the fence's consumer_delete),
// so the call returns within wait + 2 s + 2 x Connect_Options.timeout_ms, i.e.
// wait + 4 s in production (timeout_ms = 1 s) (REQ-EVQ-1). The bridge's stall
// guard for this call (BRIDGE_EVENTS_LONG_POLL_STALL_MS, 45 s) covers 30 + 4 s.
NEXT_OVERHEAD_BUDGET :: 2 * time.Second
// NEXT_POLL_TICK is how often a long poll checks, with one direct get limited
// to the caller's own subjects (ev.<owner>.>), whether an idle consumer may
// have gained work.
NEXT_POLL_TICK :: 250 * time.Millisecond
// NEXT_RESCAN_INTERVAL caps how often a long poll re-checks its idle
// consumers (one consumer-info request each), however busy the owner's
// subjects are.
NEXT_RESCAN_INTERVAL :: time.Second
// NATS_NOT_FOUND is natsStatus NATS_NOT_FOUND: a direct get found no message.
NATS_NOT_FOUND :: i32(13)
// NATS_TIMEOUT is natsStatus NATS_TIMEOUT: a fetch found nothing in time.
NATS_TIMEOUT :: i32(26)
// JS_CONSUMER_NOT_FOUND is the JetStream error code for a missing consumer.
JS_CONSUMER_NOT_FOUND :: i32(10014)

consumer_fingerprint :: proc(s: ^Service, row: domain.Event_Subscription) -> string {
	return fmt.tprintf("%s/%d/%d", row.filter_subjects, s.ack_wait, s.max_deliver)
}
consumer_known :: proc(s: ^Service, name, fingerprint: string) -> bool {
	sync.mutex_lock(&s.provisioned.mutex); defer sync.mutex_unlock(&s.provisioned.mutex)
	known, found := s.provisioned.names[name]
	return found && known == fingerprint
}
remember_consumer :: proc(s: ^Service, name, fingerprint: string) {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&s.provisioned.mutex); defer sync.mutex_unlock(&s.provisioned.mutex)
	if s.provisioned.names == nil do s.provisioned.names = make(map[string]string)
	if name in s.provisioned.names {key, value := delete_key(&s.provisioned.names, name); delete(key); delete(value)}
	s.provisioned.names[strings.clone(name)] = strings.clone(fingerprint)
}
forget_consumer :: proc(s: ^Service, name: string) {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&s.provisioned.mutex); defer sync.mutex_unlock(&s.provisioned.mutex)
	if name in s.provisioned.names {key, value := delete_key(&s.provisioned.names, name); delete(key); delete(value)}
}
provisioned_destroy :: proc(s: ^Service) {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&s.provisioned.mutex); defer sync.mutex_unlock(&s.provisioned.mutex)
	for key, value in s.provisioned.names {delete(key); delete(value)}
	delete(s.provisioned.names); s.provisioned.names = nil
}
subscription_rows_destroy :: proc(rows: []domain.Event_Subscription) {
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
}
delivery_rows_destroy :: proc(rows: []domain.Event_Delivery) {
	for &row in rows do domain.event_delivery_destroy(&row)
	delete(rows)
}
values_destroy :: proc(rows: []json.Value) {
	for row in rows do json.destroy_value(row)
	delete(rows)
}
unavailable :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "event queue unavailable")
}
subscriptions :: proc(
	s: ^Service,
	owner, instance: string,
) -> (
	rows: []domain.Event_Subscription,
	err: domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, begin_err
	rows, err = uow.repos.event_subscriptions.list(uow.repos.event_subscriptions.ctx, owner, instance)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {subscription_rows_destroy(rows); return nil, commit_err}
	return
}
watch :: proc(s: ^Service, owner, instance, chain: string, remove: bool) -> domain.Domain_Error {
	if owner == "" || instance == "" do return domain.domain_error(.Forbidden, "agent instance required")
	subjects, valid := filters(owner, chain, "", "explicit")
	if !valid do return domain.domain_error(.Validation_Failed, "invalid chain")
	defer filters_destroy(subjects)
	encoded, enc_err := json.marshal(subjects)
	if enc_err != nil do return unavailable()
	defer delete(encoded)
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return begin_err
	// Validate ownership even on unwatch; never accept tenant ids from the body.
	repo := uow.repos.event_subscriptions
	owned, get_err := repo.owns_chain(repo.ctx, owner, chain)
	if get_err.code != .None {
		iface.unit_of_work_rollback(&uow)
		return get_err
	}
	if !owned {
		iface.unit_of_work_rollback(&uow)
		return domain.domain_error(.Not_Found, "chain not found")
	}
	err: domain.Domain_Error
	if remove {
		rows, list_err := repo.list(repo.ctx, owner, instance)
		err = list_err
		if err.code == .None {
			for row in rows {
				if row.chain_id == chain && row.source == "explicit" {
					err = repo.remove(repo.ctx, owner, instance, row.subscription_id)
					if err.code != .None do break
				}
			}
		}
		subscription_rows_destroy(rows)
	} else {
		id := platform.generate_id(s.ids, "sub_")
		if id == "" {iface.unit_of_work_rollback(&uow); return unavailable()}
		err = repo.put(
			repo.ctx,
			domain.Event_Subscription {
				subscription_id = id,
				owner_user_id = owner,
				subscriber_instance_id = instance,
				chain_id = chain,
				source = "explicit",
				filter_subjects = string(encoded),
				wake_policy = "catalog",
				consumer_name = id,
				created_at = subscription_created_at(time.now()),
			},
		)
	}
	if err.code != .None {iface.unit_of_work_rollback(&uow); return err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return commit_err
	return {}
}
// Millisecond precision, so the consumer's start excludes events from the same
// second that were stored before the subscription existed.
subscription_created_at :: proc(t: time.Time) -> string {
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	ms := (time.to_unix_nanoseconds(t) / 1_000_000) % 1000
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", year, int(month), day, hour, minute, second, ms)
}
// subscription_start_ns is where a subscription's consumer starts reading: the
// moment the subscription was created. A new subscription (a new role holder,
// a restart after a user stop, a reassignment, a transfer or a new watch)
// therefore never replays events from before it existed, although the stream
// keeps 14 days (E3: a new instance starts fresh). Every hub-written created_at
// parses; an unparseable value (only hand-built test rows) reads the whole
// retained stream, as consumers did before EV2.
subscription_start_ns :: proc(row: domain.Event_Subscription) -> i64 {
	created, ok := platform.parse_rfc3339_utc(row.created_at)
	if !ok do return 0
	return max(i64(0), time.to_unix_nanoseconds(created))
}
ensure_consumer :: proc(s: ^Service, conn: ^nats.Connection, row: domain.Event_Subscription) -> bool {
	subjects: []string
	defer filters_destroy(subjects)
	if json.unmarshal(transmute([]byte)row.filter_subjects, &subjects) != nil do return false
	ack_wait := s.ack_wait
	if ack_wait <= 0 do ack_wait = 5 * time.Minute
	max_deliver := s.max_deliver
	if max_deliver <= 0 do max_deliver = 10
	err := nats.consumer_add(
		conn,
		{
			stream = "HEIM_EVENTS",
			durable = row.consumer_name,
			filter_subjects = subjects,
			ack_wait_ns = i64(ack_wait),
			max_deliver = max_deliver,
			start_time_ns = subscription_start_ns(row),
		},
	)
	return err.status == 0
}

ack_snapshot :: proc(
	s: ^Service,
	owner, instance: string,
	ids: []string,
) -> (
	rows: []domain.Event_Delivery,
	err: domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, begin_err
	repo := uow.repos.event_subscriptions
	rows, err = repo.deliveries(repo.ctx, owner, instance, ids)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {delivery_rows_destroy(rows); return nil, commit_err}
	return
}
resolved_snapshot :: proc(
	s: ^Service,
	owner, instance: string,
	limit: int,
) -> (
	rows: []domain.Event_Delivery,
	err: domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, begin_err
	repo := uow.repos.event_subscriptions
	rows, err = repo.resolutions(repo.ctx, owner, instance, limit)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {delivery_rows_destroy(rows); return nil, commit_err}
	return
}

mark :: proc(s: ^Service, owner, instance: string, row: domain.Event_Delivery, resolved: bool) -> domain.Domain_Error {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return begin_err
	repo := uow.repos.event_subscriptions
	err := repo.mark_delivery(repo.ctx, owner, instance, row.subscription_id, row.event_id, resolved)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return commit_err
	return {}
}
acknowledge :: proc(s: ^Service, owner, instance: string, ids: []string) -> domain.Domain_Error {
	if owner == "" || instance == "" do return domain.domain_error(.Forbidden, "agent instance required")
	if len(ids) == 0 || len(ids) > 100 do return domain.domain_error(.Validation_Failed, "ack requires 1..100 event ids")
	// Resolution notices have no delivery row and are already satisfied.
	real_ids := make([dynamic]string)
	defer delete(real_ids)
	for id in ids do if !strings.has_prefix(id, "resolved:") do append(&real_ids, id)
	if len(real_ids) == 0 do return {}
	rows, err := ack_snapshot(s, owner, instance, real_ids[:])
	if err.code != .None do return err
	defer delivery_rows_destroy(rows)
	// Validate the whole request before making any acknowledgement.
	for id in real_ids {
		found := false
		for row in rows do if row.event_id == id do found = true
		if !found do return domain.domain_error(.Not_Found, "event delivery not found")
	}
	conn, nerr := nats.connect(s.options)
	if nerr.status != 0 do return unavailable()
	defer nats.destroy(conn)
	for row in rows {
		wanted := false
		for id in real_ids do if id == row.event_id do wanted = true
		if !wanted || row.acknowledged do continue
		if nats.ack_reply(conn, row.ack_reply, 1000).status != 0 do return unavailable()
		if err = mark(s, owner, instance, row, false); err.code != .None do return err
	}
	return {}
}
is_stale :: proc(s: ^Service, owner, topic: string, generation: i64) -> (bool, domain.Domain_Error) {
	if topic == "" do return false, {}
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return false, begin_err
	repo := uow.repos.event_subscriptions
	stale, err := repo.stale(repo.ctx, owner, topic, generation)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false, err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	return stale, {}
}
// Freshness and recording share a transaction: a concurrent topic resolution
// cannot slip between a successful freshness read and the delivery decision.
record :: proc(s: ^Service, owner, instance: string, row: domain.Event_Delivery) -> (bool, domain.Domain_Error) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return false, begin_err
	repo := uow.repos.event_subscriptions
	stale := false
	err: domain.Domain_Error
	if row.topic_key != "" do stale, err = repo.stale(repo.ctx, owner, row.topic_key, row.topic_generation)
	if err.code == .None && !stale do err = repo.delivered(repo.ctx, owner, instance, row)
	if err.code == .Not_Found {iface.unit_of_work_rollback(&uow); return false, {}}
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false, err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	return !stale, {}
}

// Provisioning never trusts a pre-commit snapshot alone. If removal won the
// race, leave a durable deletion intent before trying immediate cleanup.
fence_consumer :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	row: domain.Event_Subscription,
) -> (
	bool,
	domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return false, begin_err
	repo := uow.repos.event_subscriptions
	live, err := repo.exists(repo.ctx, row.owner_user_id, row.subscriber_instance_id, row.subscription_id)
	if err.code == .None && !live do err = repo.queue_delete(repo.ctx, row.consumer_name)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false, err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	if live do return true, {}
	forget_consumer(s, row.consumer_name)
	nerr := nats.consumer_delete(conn, "HEIM_EVENTS", row.consumer_name)
	if nerr.status != 0 && nerr.jetstream != JS_CONSUMER_NOT_FOUND do return false, unavailable()
	return false, {}
}
provision_consumer :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	row: domain.Event_Subscription,
) -> (
	bool,
	domain.Domain_Error,
) {
	sync.atomic_add(&s.provision_calls, 1)
	if !ensure_consumer(s, conn, row) do return false, unavailable()
	return fence_consumer(s, conn, row)
}
Bound_Pull :: struct {
	row:   domain.Event_Subscription, // borrowed from request-owned subscriptions
	pull:  ^nats.Pull, // nil until the consumer has work (idle consumers are never bound)
	slots: int,
	gone:  bool, // removed after the snapshot; skipped for the rest of the request
}
pull_slots :: proc(s: ^Service, pulls: []Bound_Pull) -> domain.Domain_Error {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return begin_err
	repo := uow.repos.event_subscriptions
	for &bound in pulls {
		if bound.pull == nil do continue
		slots, err := repo.available(
			repo.ctx,
			bound.row.owner_user_id,
			bound.row.subscriber_instance_id,
			bound.row.subscription_id,
		)
		if err.code != .None {iface.unit_of_work_rollback(&uow); return err}
		bound.slots = slots
	}
	committed, err := iface.unit_of_work_commit(&uow)
	if !committed do return err
	return {}
}
// ready_consumer makes sure the row's durable exists with its current config.
// A consumer this process already provisioned (by the runtime or an earlier
// pull) costs no JetStream request; only a cache miss provisions and fences.
ready_consumer :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	row: domain.Event_Subscription,
) -> (
	live: bool,
	err: domain.Domain_Error,
) {
	fingerprint := consumer_fingerprint(s, row)
	if consumer_known(s, row.consumer_name, fingerprint) do return true, {}
	live, err = provision_consumer(s, conn, row)
	if err.code == .None && live do remember_consumer(s, row.consumer_name, fingerprint)
	return
}
// redelivery_possible reports whether a consumer whose only messages await
// acknowledgement may have one ready for redelivery: an unacked delivery
// recorded at least ack_wait ago, or none recorded at all (a delivery this hub
// never stored). recorded_at has second precision, so the cut-off is widened by
// one second: it may fetch early, never late.
redelivery_possible :: proc(s: ^Service, row: domain.Event_Subscription) -> (bool, domain.Domain_Error) {
	wait := s.ack_wait
	if wait <= 0 do wait = 5 * time.Minute
	before := platform.format_rfc3339_utc(time.time_add(time.now(), time.Second - wait))
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return false, begin_err
	repo := uow.repos.event_subscriptions
	due, err := repo.due_deliveries(repo.ctx, row.owner_user_id, row.subscriber_instance_id, row.subscription_id, before)
	possible := len(due) > 0
	delivery_rows_destroy(due)
	if err.code == .None && !possible {
		unacked: []domain.Event_Delivery
		unacked, err = repo.due_deliveries(repo.ctx, row.owner_user_id, row.subscriber_instance_id, row.subscription_id, "9999")
		possible = len(unacked) == 0
		delivery_rows_destroy(unacked)
	}
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false, err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	return possible, {}
}
// activate binds the consumers that have work. An idle consumer (nothing
// pending, nothing awaiting ack) costs one consumer-info request and is neither
// bound nor fetched. Scanning stops at the request's deadline; later rows wait
// for the next pull (the start offset rotates per call).
activate :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	pulls: []Bound_Pull,
	started: time.Tick,
	deadline: time.Duration,
) -> domain.Domain_Error {
	// The deadline is checked before every NATS step, not once per row, so a
	// cache miss cannot chain several requests past the budget.
	expired :: proc(started: time.Tick, deadline: time.Duration) -> bool {return time.tick_since(started) >= deadline}
	for &bound in pulls {
		if bound.pull != nil || bound.gone do continue
		if expired(started, deadline) do break
		live, err := ready_consumer(s, conn, bound.row)
		if err.code != .None do return err
		if !live {bound.gone = true; continue}
		if expired(started, deadline) do break
		state, serr := nats.consumer_state(conn, "HEIM_EVENTS", bound.row.consumer_name)
		if serr.status != 0 {
			if serr.jetstream != JS_CONSUMER_NOT_FOUND do return unavailable()
			// The consumer vanished behind the cache (for example JetStream state
			// was lost): provision it once more, under the usual fence.
			forget_consumer(s, bound.row.consumer_name)
			if expired(started, deadline) do break
			live, err = ready_consumer(s, conn, bound.row)
			if err.code != .None do return err
			if !live {bound.gone = true; continue}
			if expired(started, deadline) do break
			state, serr = nats.consumer_state(conn, "HEIM_EVENTS", bound.row.consumer_name)
			if serr.status != 0 do return unavailable()
		}
		if state.pending == 0 {
			if state.ack_pending == 0 do continue
			// Only unacked deliveries remain. JetStream holds a NoWait fetch on
			// such a consumer for its full expiry (1 s), so fetch only when a
			// redelivery can already be due.
			due, due_err := redelivery_possible(s, bound.row)
			if due_err.code != .None do return due_err
			if !due do continue
		}
		if expired(started, deadline) do break
		pull, bind_err := nats.pull_bind(conn, "HEIM_EVENTS", bound.row.consumer_name)
		if bind_err.status != 0 do return unavailable()
		bound.pull = pull
	}
	return {}
}
append_unique :: proc(events: ^[dynamic]json.Value, value: json.Value) {
	obj, _ := value.(json.Object)
	id, _ := obj["event_id"].(json.String)
	for prior in events^ {
		prior_obj, _ := prior.(json.Object)
		prior_id, _ := prior_obj["event_id"].(json.String)
		if id == prior_id {json.destroy_value(value); return}
	}
	append(events, value)
}
collect_resolutions :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	owner, instance: string,
	events: ^[dynamic]json.Value,
	limit: int,
	started: time.Tick,
	deadline: time.Duration,
) -> domain.Domain_Error {
	rows, err := resolved_snapshot(s, owner, instance, limit - len(events^))
	if err.code != .None do return err
	defer delivery_rows_destroy(rows)
	for row in rows {
		// The rest stay unsent and are returned by a later pull.
		if time.tick_since(started) >= deadline do break
		if !row.acknowledged {
			if nats.ack_reply(conn, row.ack_reply, 1000).status != 0 do return unavailable()
			if err = mark(s, owner, instance, row, false); err.code != .None do return err
		}
		data, encode_err := json.marshal(struct {
			type, event_id, resolved_event_id: string,
		}{"resolved", fmt.tprintf("resolved:%s", row.event_id), row.event_id})
		if encode_err != nil do return unavailable()
		notice, parse_err := json.parse(data)
		delete(data)
		if parse_err != nil do return unavailable()
		if err = mark(s, owner, instance, row, true); err.code != .None {json.destroy_value(notice); return err}
		append_unique(events, notice)
		if len(events^) >= limit do break
	}
	return {}
}
// The C batch owns msg. Every success transfers one parsed JSON value; stale
// events are acknowledged and freed while no SQLite transaction is open.
read_message :: proc(
	s: ^Service,
	owner, instance, subscription: string,
	msg: ^nats.Message,
) -> (
	value: json.Value,
	accepted: bool,
	err: domain.Domain_Error,
) {
	parsed, parse_err := json.parse(nats.message_data(msg), parse_integers = true)
	obj, object_ok := parsed.(json.Object)
	id, id_ok := obj["event_id"].(json.String)
	topic, _ := obj["topic_key"].(json.String)
	generation, _ := obj["topic_generation"].(json.Integer)
	if parse_err != nil || !object_ok || !id_ok {
		json.destroy_value(parsed)
		return nil, false, unavailable()
	}
	if catalog_chain(obj) == "" {
  json.destroy_value(parsed)
  if nats.ack(msg).status != 0 do return nil, false, unavailable()
  return nil, false, {}
 }
	meta, merr := nats.message_metadata(msg)
	if merr.status != 0 {json.destroy_value(parsed); return nil, false, unavailable()}
	accepted, err = record(
		s,
		owner,
		instance,
		domain.Event_Delivery {
			subscription_id = subscription,
			event_id = string(id),
			ack_reply = nats.message_reply(msg),
			topic_key = string(topic),
			topic_generation = i64(generation),
			stream_sequence = i64(meta.stream_sequence),
		},
	)
	if err.code != .None {json.destroy_value(parsed); return nil, false, err}
	if !accepted {
		json.destroy_value(parsed)
		if nats.ack(msg).status != 0 do return nil, false, unavailable()
		return nil, false, {}
	}
	return parsed, true, {}
}
next :: proc(
	s: ^Service,
	owner, instance: string,
	wait: time.Duration,
	limit: int,
) -> (
	result: []json.Value,
	err: domain.Domain_Error,
) {
	if owner == "" || instance == "" do return nil, domain.domain_error(.Forbidden, "agent instance required")
	if wait < 0 || wait > 30 * time.Second || limit < 1 || limit > 100 do return nil, domain.domain_error(.Validation_Failed, "wait must be 0..30s and limit 1..100")
	// Every stage below shares one budget: wait for events, plus a fixed
	// overhead for setup and fetches (REQ-EVQ-1).
	started := time.tick_now()
	deadline := wait + NEXT_OVERHEAD_BUDGET
	events := make([dynamic]json.Value)
	defer if err.code != .None {values_destroy(events[:]); result = nil}
	conn, nerr := nats.connect(s.options)
	if nerr.status != 0 {delete(events); return nil, unavailable()}
	defer nats.destroy(conn)
	if !prepare_advisories(conn) {err = unavailable(); return}
	if err = collect_resolutions(s, conn, owner, instance, &events, limit, started, deadline); err.code != .None do return
	if len(events) >= limit do return events[:], {}
	rows, rerr := subscriptions(s, owner, instance)
	if rerr.code != .None {err = rerr; return}
	defer subscription_rows_destroy(rows)
	pulls := make([dynamic]Bound_Pull, 0, len(rows))
	defer {for bound in pulls do nats.pull_destroy(bound.pull); delete(pulls)}
	if len(rows) > 0 {
		offset := int(sync.atomic_add(&s.pull_cursor, 1) % u64(len(rows)))
		for i in 0 ..< len(rows) do append(&pulls, Bound_Pull{row = rows[(offset + i) % len(rows)]})
	}
	// The stream's last sequence before the first scan: a later message on the
	// caller's own subjects means an idle consumer may have gained work.
	stream, serr := nats.stream_info(conn, "HEIM_EVENTS")
	if serr.status != 0 {err = unavailable(); return}
	last_sequence := stream.last
	owner_filter := fmt.tprintf("ev.%s.>", owner)
	if err = activate(s, conn, pulls[:], started, deadline); err.code != .None do return
	last_scan := time.tick_now()
	pass := 0
	for {
		if err = pull_slots(s, pulls[:]); err.code != .None do return
		ready := 0
		for bound in pulls do if bound.pull != nil && bound.slots > 0 do ready += 1
		// First visit every bound consumer promptly. Later passes block on each
		// for a share of the remaining wait, at most one poll tick, so new work
		// on idle consumers is noticed between passes.
		visited := 0
		for &bound in pulls {
			if bound.pull == nil || bound.slots <= 0 do continue // idle, or backpressure: leave backlog in JetStream
			if time.tick_since(started) >= deadline do return events[:], {}
			blocking := pass > 0 && len(events) == 0
			timeout_ms := i64(1)
			if blocking {
				remaining := wait - time.tick_since(started)
				if remaining <= 0 do break
				share := min(remaining / time.Duration(ready - visited), NEXT_POLL_TICK)
				timeout_ms = max(1, i64(share / time.Millisecond))
			}
			visited += 1
			batch: ^nats.Batch
			berr: nats.Error
			if !blocking || timeout_ms < 5 {
				batch, berr = nats.fetch_available(bound.pull, min(limit - len(events), bound.slots))
			} else {
				batch, berr = nats.fetch(bound.pull, min(limit - len(events), bound.slots), timeout_ms)
			}
			if berr.status != 0 {
				nats.batch_destroy(batch)
				if berr.status != NATS_TIMEOUT {err = unavailable(); return}
				continue
			}
			for i in 0 ..< nats.batch_count(batch) {
				value, accepted, read_err := read_message(
					s,
					owner,
					instance,
					bound.row.subscription_id,
					nats.batch_message(batch, i),
				)
				if read_err.code != .None {nats.batch_destroy(batch); err = read_err; return}
				if accepted do append_unique(&events, value)
			}
			nats.batch_destroy(batch)
			if len(events) >= limit do return events[:], {}
		}
		if err = collect_resolutions(s, conn, owner, instance, &events, limit, started, deadline); err.code != .None do return
		if len(events) > 0 || time.tick_since(started) >= wait do return events[:], {}
		bound_count, idle := 0, 0
		for bound in pulls {
			if bound.gone do continue
			if bound.pull == nil {idle += 1} else {bound_count += 1}
		}
		if bound_count > 0 && ready == 0 && idle == 0 {
			// No capacity: do not consume delivery attempts while the agent needs to
			// acknowledge/resolve existing records.
			return events[:], {}
		}
		if ready == 0 {
			time.sleep(max(0, min(NEXT_POLL_TICK, wait - time.tick_since(started))))
		}
		if idle > 0 && subject_token(owner) && time.tick_since(last_scan) >= NEXT_RESCAN_INTERVAL {
			// One direct get on ev.<owner>.> after the last seen sequence: other
			// owners' traffic never triggers a rescan, and a rescan runs at most
			// once per NEXT_RESCAN_INTERVAL.
			msg, _, next_err := nats.stream_next(conn, "HEIM_EVENTS", owner_filter, last_sequence + 1)
			nats.message_destroy(msg)
			if next_err.status != 0 && next_err.status != NATS_NOT_FOUND {err = unavailable(); return}
			if next_err.status == 0 {
				stream, serr = nats.stream_info(conn, "HEIM_EVENTS")
				if serr.status != 0 {err = unavailable(); return}
				last_sequence = stream.last
				last_scan = time.tick_now()
				if err = activate(s, conn, pulls[:], started, deadline); err.code != .None do return
			}
		}
		pass += 1
	}
}
