package eventinbox

import "base:runtime"
import retry "odin_test:hub/service/pipelineretry"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

Runtime :: struct {
	diagnostics: retry.State,
	service:         ^Service,
	worker:          ^thread.Thread,
	stopping:        i32,
	connection:      ^nats.Connection,
	advisory:        ^nats.Pull,
 advisory_signals: ^nats.Core_Subscription,
 advisory_worker: ^thread.Thread,
 advisory_stopping: i32,
 advisory_failed: i32,
	provisioned:     map[string]Provisioned_Consumer,
	cache_allocator: mem.Allocator,
	last_prune:      time.Tick,
	notifications: map[string]Notification_State,
	notice_reconcile: time.Tick,
 subscriptions_ready: bool,
 subscription_cache_changed: bool,
 subscription_revision: i64,
 subscription_reconcile: time.Tick,
 subscription_cache: map[string]Cached_Chain,
 subscription_rows: []domain.Event_Subscription, // Borrowed strings; owned outer cache array.

}
Provisioned_Consumer :: struct {
	key, fingerprint: string,
}
ADVISORY_STREAM :: "HEIM_EVENT_ADVISORIES"
ADVISORY_CONSUMER :: "hub_event_dlq"
ADVISORY_SUBJECT :: "$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.HEIM_EVENTS.>"
start :: proc(r: ^Runtime, s: ^Service) {
	if r.worker != nil do return
	context.allocator = runtime.heap_allocator()
	r.service = s
	clear_provisioned(r)
	r.cache_allocator = runtime.heap_allocator()
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
 wake(r.service)
	thread.join(r.worker); thread.destroy(r.worker); r.worker = nil
	context.allocator = runtime.heap_allocator()
	delete(r.service.options.url); delete(r.service.options.creds_file); delete(r.service.options.ca_file)
	r.service.options = {}
}
runtime_disconnect :: proc(r: ^Runtime) {
	sync.atomic_store(&r.advisory_stopping,1)
 if r.advisory_signals!=nil do _ = nats.core_unsubscribe(r.advisory_signals)
 if r.advisory_worker!=nil {
  thread.join(r.advisory_worker); thread.destroy(r.advisory_worker); r.advisory_worker=nil
 }
 nats.core_destroy(r.advisory_signals); r.advisory_signals=nil
 nats.pull_destroy(r.advisory); r.advisory = nil
	nats.destroy(r.connection); r.connection = nil
	clear_provisioned(r)
	r.notice_reconcile = {}
 clear_subscription_cache(r)
}
runtime_entry :: proc(data: rawptr) {
	r := (^Runtime)(data)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	defer runtime_disconnect(r)
	defer clear_notifications(r)
	defer clear_notice_dirty(r.service)

 backoff := time.Second
 for sync.atomic_load(&r.stopping) == 0 {
  consume_wake(r.service)
  ok := reconcile(r)
  if !ok {runtime_disconnect(r)} else {backoff=time.Second}
  free_all(context.allocator)
  delay := runtime_wait_delay(r, time.tick_now())
  if !ok {
   delay=retry.jitter(backoff,u64(time.tick_now()._nsec))
   backoff=min(backoff*2,5*time.Second)
  }
  wait_for_wake(r, delay)
 }

}
// Persist advisories in their own stream before any pull consumer is created.
// A core subscription alone could lose max-delivery notices across hub restarts.
runtime_connect :: proc(r: ^Runtime) -> bool {
	if r.connection != nil do return sync.atomic_load(&r.advisory_failed)==0
	conn, err := nats.connect(r.service.options)
	if err.status != 0 do return retry.failed(&r.diagnostics,"eventinbox",.Connect,err.status,err.jetstream)
	r.connection = conn
	if !prepare_advisories(conn) do return retry.failed(&r.diagnostics,"eventinbox",.Stream)
 hints,herr:=nats.core_subscribe(conn,ADVISORY_SUBJECT)
 if herr.status!=0 do return retry.failed(&r.diagnostics,"eventinbox",.Bind,herr.status)
 r.advisory_signals=hints
 sync.atomic_store(&r.advisory_stopping,0)
 sync.atomic_store(&r.advisory_failed,0)
	{
		// The Thread record and inherited context must outlive the runtime pass arena.
		context.allocator = runtime.heap_allocator()
		context.temp_allocator = context.allocator
		r.advisory_worker = thread.create_and_start_with_data(r, advisory_signal_entry, init_context = context)
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
	if err.status != 0 do return retry.failed(&r.diagnostics,"eventinbox",.Consumer,err.status,err.jetstream)
	pull, perr := nats.pull_bind(conn, ADVISORY_STREAM, ADVISORY_CONSUMER)
	if perr.status != 0 do return retry.failed(&r.diagnostics,"eventinbox",.Bind,perr.status,perr.jetstream)
	r.advisory = pull
	return true
}

// Cache allocations outlive the per-pass scratch arena. Entries are removed
// when subscriptions disappear and all cache memory is freed on disconnect.
clear_provisioned :: proc(r: ^Runtime) {
	if r.provisioned == nil do return
	context.allocator = r.cache_allocator
	for _, entry in r.provisioned {delete(entry.key); delete(entry.fingerprint)}
	delete(r.provisioned)
	r.provisioned = nil
}

cache_provisioned :: proc(r: ^Runtime, name, fingerprint: string) {
	if r.cache_allocator.procedure == nil do r.cache_allocator = context.allocator
	context.allocator = r.cache_allocator
	if r.provisioned == nil do r.provisioned = make(map[string]Provisioned_Consumer)
	if old, found := r.provisioned[name]; found {
		delete(old.fingerprint)
		r.provisioned[name] = Provisioned_Consumer{old.key, strings.clone(fingerprint)}
	} else {
		key := strings.clone(name)
		r.provisioned[key] = Provisioned_Consumer{key, strings.clone(fingerprint)}
	}
}
forget_provisioned :: proc(r: ^Runtime, name: string) {
	context.allocator = r.cache_allocator
	if entry, found := r.provisioned[name]; found {
		delete_key(&r.provisioned, name)
		delete(entry.key); delete(entry.fingerprint)
	}
}
reconcile :: proc(r: ^Runtime) -> bool {
	if r.cache_allocator.procedure == nil do r.cache_allocator = runtime.heap_allocator()
 if !runtime_connect(r) do return false
	s := r.service
	uow, began, _ := iface.unit_of_work_begin(s.factory)
	if !began do return retry.failed(&r.diagnostics,"eventinbox",.Read)
	repo := uow.repos.event_subscriptions
	prune_due := r.last_prune._nsec == 0 || time.tick_since(r.last_prune) >= time.Minute
	if prune_due {
		before := platform.format_rfc3339_utc(time.time_add(time.now(), -14 * 24 * time.Hour))
		if repo.prune(repo.ctx, before).code != .None {iface.unit_of_work_rollback(&uow); return retry.failed(&r.diagnostics,"eventinbox",.Read)}
	}
	if !refresh_subscription_cache(r, repo, time.tick_now()) {
 iface.unit_of_work_rollback(&uow); return retry.failed(&r.diagnostics,"eventinbox",.Read)
 }
 rows := cached_subscription_rows(r)
 err := domain.Domain_Error{}
	if err.code != .None {iface.unit_of_work_rollback(&uow); return retry.failed(&r.diagnostics,"eventinbox",.Read)}
	deleted, derr := repo.deletions(repo.ctx)
	if derr.code != .None {iface.unit_of_work_rollback(&uow); return retry.failed(&r.diagnostics,"eventinbox",.Read)}
	committed, _ := iface.unit_of_work_commit(&uow)
	defer {for name in deleted do delete(name); delete(deleted)}
	if !committed do return retry.failed(&r.diagnostics,"eventinbox",.Commit)
	if prune_due do r.last_prune = time.tick_now()
 if r.subscription_cache_changed {
	active := make(map[string]bool)
	defer delete(active)
	// No JetStream API request for an unchanged row on a healthy connection.
	for row in rows {
		active[row.consumer_name] = true
		fingerprint := consumer_fingerprint(s, row)
		if prior, found := r.provisioned[row.consumer_name]; found && prior.fingerprint == fingerprint do continue
		live, provision_err := provision_consumer(s, r.connection, row)
		if provision_err.code != .None do return retry.failed(&r.diagnostics,"eventinbox",.Consumer,i32(provision_err.code))
		if live {
			cache_provisioned(r, row.consumer_name, fingerprint)
			// Share it with HTTP pulls, which then never provision this consumer.
			remember_consumer(s, row.consumer_name, fingerprint)
		}
	}
	forgotten := make([dynamic]string)
	defer delete(forgotten)
	for name in r.provisioned do if !active[name] do append(&forgotten, name)
	for name in forgotten {
		forget_consumer(s, name)
		forget_provisioned(r, name)
	}
 }
	for name in deleted {
		nerr := nats.consumer_delete(r.connection, "HEIM_EVENTS", name)
		if nerr.status != 0 && nerr.jetstream != JS_CONSUMER_NOT_FOUND do return retry.failed(&r.diagnostics,"eventinbox",.Consumer,nerr.status,nerr.jetstream)
		forget_consumer(s, name)
		forget_provisioned(r, name)
		mark, began_mark, _ := iface.unit_of_work_begin(s.factory)
		if !began_mark do return retry.failed(&r.diagnostics,"eventinbox",.Read)
		mark_repo := mark.repos.event_subscriptions
		if mark_repo.deleted(mark_repo.ctx, name).code != .None {iface.unit_of_work_rollback(&mark); return retry.failed(&r.diagnostics,"eventinbox",.Read)}
		marked, _ := iface.unit_of_work_commit(&mark)
		if !marked do return retry.failed(&r.diagnostics,"eventinbox",.Commit)
	}
	if !notify_pending(r, rows, time.tick_now(), true) do return retry.failed(&r.diagnostics,"eventinbox",.Reconcile)
	return drain_advisories(r)
}
drain_advisories :: proc(r: ^Runtime) -> bool {
	batch, err := nats.fetch(r.advisory, 20, 10)
	if err.status == 26 do return true
	if err.status != 0 do return retry.failed(&r.diagnostics,"eventinbox",.Advisory,err.status,err.jetstream)
	defer nats.batch_destroy(batch)
 // A bounded batch must not strand the rest until the safety timer.
 if nats.batch_count(batch)==20 do wake(r.service)
 for i in 0 ..< nats.batch_count(batch) {
		advisory := nats.batch_message(batch, i)
		input: struct {
			stream, consumer: string,
			stream_seq:       u64,
		}
		decode_err := json.unmarshal(nats.message_data(advisory), &input)
		defer {delete(input.stream); delete(input.consumer)}
		if decode_err != nil || input.stream != "HEIM_EVENTS" || input.stream_seq == 0 {
			fmt.eprintln("events: discarded malformed max-delivery advisory")
			if ae:=nats.ack(advisory);ae.status!=0 do return retry.failed(&r.diagnostics,"eventinbox",.Advisory,ae.status,ae.jetstream)
			continue
		}
		msg, get_err := nats.stream_get(r.connection, input.stream, input.stream_seq)
		if get_err.status != 0 {
			// A rolled-up state or expired original no longer needs a dead letter.
			if get_err.jetstream == 10037 {
				if ae:=nats.ack(advisory);ae.status!=0 do return retry.failed(&r.diagnostics,"eventinbox",.Advisory,ae.status,ae.jetstream)
				continue
			}
			return retry.failed(&r.diagnostics,"eventinbox",.Read,get_err.status,get_err.jetstream)
		}
		subject := nats.message_subject(msg)
		if !strings.has_prefix(subject, "ev.") || strings.has_prefix(subject, "ev.dlq.") {
			nats.message_destroy(msg)
			fmt.eprintln("events: discarded max-delivery advisory with invalid original subject")
			if ae:=nats.ack(advisory);ae.status!=0 do return retry.failed(&r.diagnostics,"eventinbox",.Advisory,ae.status,ae.jetstream)
			continue
		}
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
		if pub_err.status != 0 do return retry.failed(&r.diagnostics,"eventinbox",.Publish,pub_err.status,pub_err.jetstream)
		published(r.service, destination)
		if ae:=nats.ack(advisory);ae.status!=0 do return retry.failed(&r.diagnostics,"eventinbox",.Advisory,ae.status,ae.jetstream)
	}
	return true
}

// Capturing advisory publication durably must precede every consumer's first
// fetch, including an HTTP request arriving before the background pass.
prepare_advisories :: proc(conn: ^nats.Connection) -> bool {
	cfg := nats.Stream_Config {
		name                = ADVISORY_STREAM,
		subjects            = []string{ADVISORY_SUBJECT},
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

// A coalesced condition prevents lost wakeups between reconcile and waiting.
// Callbacks perform no database/NATS work and run only after commit/publication.
wake :: proc(s: ^Service) {
 if s == nil do return
 sync.mutex_lock(&s.wake_mutex)
 s.wake_pending = true
 sync.cond_signal(&s.wake_cond)
 sync.mutex_unlock(&s.wake_mutex)
}
consume_wake :: proc(s: ^Service) {
 sync.mutex_lock(&s.wake_mutex)
 s.wake_pending = false
 sync.mutex_unlock(&s.wake_mutex)
}
wait_for_wake :: proc(r: ^Runtime, delay: time.Duration) {
 s := r.service
 started := time.tick_now()
 sync.mutex_lock(&s.wake_mutex); defer sync.mutex_unlock(&s.wake_mutex)
 for !s.wake_pending && sync.atomic_load(&r.stopping)==0 {
  left := delay-time.tick_since(started)
  if left <= 0 do return
  _ = sync.cond_wait_with_timeout(&s.wake_cond,&s.wake_mutex,left)
 }
}
reconcile_interval :: proc(s: ^Service) -> time.Duration {
 return s.reconcile_interval if s.reconcile_interval > 0 else NOTICE_RECONCILE_INTERVAL
}
runtime_wait_delay :: proc(r: ^Runtime, now: time.Tick) -> time.Duration {
 interval := reconcile_interval(r.service)
 deadline := r.subscription_reconcile._nsec+i64(interval)
 if deadline <= now._nsec do return 0
 // Ignore deadlines on ineligible targets: their committed activity change
 // wakes us. Pending eligible work waits for its cooldown/ack deadline.
 for _, chain in r.subscription_cache {
  for row in chain.rows {
   target:=chain.snapshot_by_id[row.subscription_id].target
   if target.instance_id=="" || target.stopped_by!="" do continue
   schedule, found := r.notifications[fmt.tprintf("schedule:%s",row.consumer_name)]
   if !found do continue
   due := schedule.next_check._nsec
   if schedule.dirty do due=now._nsec
   prior := r.notifications[fmt.tprintf("instance:%s/%s",row.owner_user_id,row.subscriber_instance_id)]
   due=max(due,prior.last_sent._nsec+i64(30*time.Second),prior.last_rejected._nsec+i64(5*time.Second))
   if due > 0 do deadline=min(deadline,due)
  }
 }
 return time.Duration(max(0,deadline-now._nsec))
}


advisory_signal_entry :: proc(data:rawptr) {
 r:=(^Runtime)(data)
 // No scratch arena is shared with the runtime thread. The hint's C-owned
 // message is always freed here; durable payloads are read by drain_advisories.
 for sync.atomic_load(&r.advisory_stopping)==0 {
  msg,err:=nats.core_next(r.advisory_signals,60_000)
  nats.message_destroy(msg)
  if sync.atomic_load(&r.advisory_stopping)!=0 do return
  if err.status==NATS_TIMEOUT do continue
  if err.status!=0 {
   sync.atomic_store(&r.advisory_failed,1)
   wake(r.service)
   return
  }
  wake(r.service)
 }
}
