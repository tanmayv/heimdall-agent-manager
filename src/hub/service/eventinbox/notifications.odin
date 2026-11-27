
package eventinbox

import "base:runtime"
import "core:sync"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

Notification_State :: struct {
	key:           string,
	last_sent:     time.Tick,
	last_rejected: time.Tick,
	cursor:        u64,
	fingerprint: string,
	dirty: bool,
	next_check: time.Tick,
}
clear_notifications :: proc(r: ^Runtime) {
	if r.notifications == nil do return
	context.allocator = r.cache_allocator
	for _, state in r.notifications {delete(state.key); delete(state.fingerprint)}
	delete(r.notifications); r.notifications = nil
}
save_notification_state :: proc(r: ^Runtime, key: string, state: Notification_State) {
	if r.cache_allocator.procedure == nil do r.cache_allocator = context.allocator
	context.allocator = r.cache_allocator
	if r.notifications == nil do r.notifications = make(map[string]Notification_State)
	next := state
	next.fingerprint = strings.clone(state.fingerprint)
	if prior, ok := r.notifications[key]; ok {next.key = prior.key; delete(prior.fingerprint)} else {next.key = strings.clone(key)}
	r.notifications[next.key] = next
}
// Relay callbacks may run concurrently with the inbox. Bound the dirty set;
// overflow conservatively requests a full pass instead of retaining all chains.
Notice_Dirty :: struct {
	mutex: sync.Mutex,
	chains: map[string]bool,
	all: bool,
}
NOTICE_RECONCILE_INTERVAL :: 5 * time.Minute
published :: proc(s: ^Service, subject: string) {
	if s == nil || !strings.has_prefix(subject, "ev.") do return
	parts := strings.split(subject, ".")
	defer delete(parts)
	offset := 1
	if len(parts) > 1 && parts[1] == "dlq" do offset = 2
	if len(parts) < offset+4 || parts[offset+1] != "chain" do return
	key := fmt.tprintf("%s/%s", parts[offset], parts[offset+2])
 mark_notice_dirty(s,key,true)
}
mark_notice_dirty :: proc(s:^Service,key:string,signal:bool) {
 context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&s.notice_dirty.mutex); defer sync.mutex_unlock(&s.notice_dirty.mutex)
	if s.interest_ready && !s.watched_scopes[key] do return
 if s.notice_dirty.all {if signal do wake(s); return}
	if len(s.notice_dirty.chains) >= 4096 {s.notice_dirty.all = true; if signal do wake(s); return}
	if s.notice_dirty.chains == nil do s.notice_dirty.chains = make(map[string]bool)
	if key not_in s.notice_dirty.chains do s.notice_dirty.chains[strings.clone(key)] = true
 if signal do wake(s)
}
take_notice_dirty :: proc(s: ^Service) -> (map[string]bool, bool) {
	sync.mutex_lock(&s.notice_dirty.mutex); defer sync.mutex_unlock(&s.notice_dirty.mutex)
	chains, all := s.notice_dirty.chains, s.notice_dirty.all
	s.notice_dirty.chains = nil; s.notice_dirty.all = false
	return chains, all
}
destroy_notice_dirty :: proc(chains: map[string]bool) {
	context.allocator = runtime.heap_allocator()
	for key in chains do delete(key)
	delete(chains)
}
clear_notice_dirty :: proc(s: ^Service) {
	chains, _ := take_notice_dirty(s)
	destroy_notice_dirty(chains)
 context.allocator = runtime.heap_allocator()
 sync.mutex_lock(&s.notice_dirty.mutex); defer sync.mutex_unlock(&s.notice_dirty.mutex)
 for key in s.watched_scopes do delete(key)
 delete(s.watched_scopes); s.watched_scopes=nil; s.interest_ready=false
}
notice_snapshots :: proc(s: ^Service) -> ([]domain.Event_Notice_Snapshot, domain.Domain_Error) {
	uow, began, err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, err
	rows, read_err := uow.repos.event_subscriptions.notice_snapshot(uow.repos.event_subscriptions.ctx)
	if read_err.code != .None {iface.unit_of_work_rollback(&uow); return rows, read_err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {
		for &row in rows do domain.event_notice_snapshot_destroy(&row)
		delete(rows); return nil, commit_err
	}
	return rows, {}
}
Notice_Candidate :: struct {
	row:        domain.Event_Subscription, // borrowed for this pass
	value:      json.Value,
	sequence:   u64,
	redelivery: bool,
	ack_reply:  string,
}
notice_string :: proc(obj: json.Object, key: string) -> string {
	value, _ := obj[key].(json.String)
	return string(value)
}
notice_wake_worthy :: proc(obj: json.Object, bot: bool) -> bool {
	switch notice_string(obj, "type") {
	case "task.review_requested_from_user",
	     "task.blocked_on_human",
	     "task.requirements_changed",
	     "task.merge_conflict",
	     "chain.work_finished":
		return true
	case "chain.state":
		data, _ := obj["data"].(json.Object)
		state := notice_string(data, "state")
		return bot && (state == "completed" || state == "failed")
	}
	return false
}
notice_target_snapshot :: proc(
	s: ^Service,
	row: domain.Event_Subscription,
) -> (
	domain.Event_Notice_Target,
	domain.Domain_Error,
) {
	uow, began, err := iface.unit_of_work_begin(s.factory)
	if !began do return {}, err
	repo := uow.repos.event_subscriptions
	target, read_err := repo.notice_target(repo.ctx, row)
	if read_err.code != .None {iface.unit_of_work_rollback(&uow); return target, read_err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {domain.event_notice_target_destroy(&target); return {}, commit_err}
	return target, {}
}
notice_due_snapshot :: proc(
	s: ^Service,
	row: domain.Event_Subscription,
) -> (
	[]domain.Event_Delivery,
	domain.Domain_Error,
) {
	wait := s.ack_wait
	if wait <= 0 do wait = 5 * time.Minute
	before := platform.format_rfc3339_utc(time.time_add(time.now(), -wait))
	uow, began, err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, err
	repo := uow.repos.event_subscriptions
	rows, read_err := repo.due_deliveries(
		repo.ctx,
		row.owner_user_id,
		row.subscriber_instance_id,
		row.subscription_id,
		before,
	)
	if read_err.code != .None {iface.unit_of_work_rollback(&uow); return rows, read_err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {delivery_rows_destroy(rows); return nil, commit_err}
	return rows, {}
}
notice_candidate :: proc(
	row: domain.Event_Subscription,
	msg: ^nats.Message,
	sequence: u64,
	redelivery: bool,
	candidates: ^[dynamic]Notice_Candidate,
) {
	value, err := json.parse(nats.message_data(msg), parse_integers = true)
	if err != nil {json.destroy_value(value); return}
	obj, ok := value.(json.Object)
	if !ok ||
	   notice_string(obj, "owner_user_id") != row.owner_user_id ||
	   catalog_chain(obj) != row.chain_id ||
	   notice_string(obj, "event_id") == "" ||
	   notice_string(obj, "type") == "task.state" {
		json.destroy_value(value); return
	}
	// Multiple explicit/default subscriptions may overlap.
	for prior in candidates^ {
		prior_obj, _ := prior.value.(json.Object)
		if prior.row.owner_user_id == row.owner_user_id &&
		   prior.row.subscriber_instance_id == row.subscriber_instance_id &&
		   notice_string(prior_obj, "event_id") == notice_string(obj, "event_id") {
			json.destroy_value(value); return
		}
	}
	append(candidates, Notice_Candidate{row = row, value = value, sequence = sequence, redelivery = redelivery})
}
// Revalidate freshness and subscription existence together immediately before
// deciding. Nothing below this transaction invokes a network operation.
notice_live :: proc(s: ^Service, candidate: Notice_Candidate) -> (bool, domain.Domain_Error) {
	row := candidate.row
	obj, _ := candidate.value.(json.Object)
	topic := notice_string(obj, "topic_key")
	generation, _ := obj["topic_generation"].(json.Integer)
	uow, began, err := iface.unit_of_work_begin(s.factory)
	if !began do return false, err
	repo := uow.repos.event_subscriptions
	live, read_err := repo.exists(repo.ctx, row.owner_user_id, row.subscriber_instance_id, row.subscription_id)
	if live && read_err.code == .None {
		receipts, receipt_err := repo.deliveries(
			repo.ctx,
			row.owner_user_id,
			row.subscriber_instance_id,
			[]string{notice_string(obj, "event_id")},
		)
		read_err = receipt_err
		live = !candidate.redelivery
		for receipt in receipts {
			if receipt.subscription_id == row.subscription_id {
				live = candidate.redelivery && !receipt.acknowledged && receipt.ack_reply == candidate.ack_reply
			}
		}
		delivery_rows_destroy(receipts)
	}
	if live && read_err.code == .None && topic != "" {
		stale, stale_err := repo.stale(repo.ctx, row.owner_user_id, topic, i64(generation))
		live = !stale
		read_err = stale_err
	}
	if read_err.code != .None {iface.unit_of_work_rollback(&uow); return false, read_err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	return live, {}
}
notify_pending :: proc(r: ^Runtime, rows: []domain.Event_Subscription, now: time.Tick, cached: bool = false) -> bool {
	s := r.service
	if s.notice == nil do return true
	snapshots: []domain.Event_Notice_Snapshot
 snapshot_err: domain.Domain_Error
 if !cached do snapshots, snapshot_err = notice_snapshots(s)
	if snapshot_err.code != .None do return false
	defer {if !cached {for &snapshot in snapshots do domain.event_notice_snapshot_destroy(&snapshot)}; delete(snapshots)}
	targets := make(map[string]domain.Event_Notice_Snapshot)
	defer delete(targets)
	for snapshot in snapshots do targets[snapshot.subscription_id] = snapshot
	dirty, dirty_all := take_notice_dirty(s)
	defer destroy_notice_dirty(dirty)
	// A failed pass forces full recovery on the next attempt.
	completed := false
	defer if !completed do r.notice_reconcile = {}
	full := dirty_all || r.notice_reconcile._nsec == 0 || now._nsec - r.notice_reconcile._nsec >= i64(reconcile_interval(s))
	if full do r.notice_reconcile = now
	candidates := make([dynamic]Notice_Candidate)
	defer {
		for candidate in candidates {json.destroy_value(candidate.value); delete(candidate.ack_reply)}
		delete(candidates)
	}
	active := make(map[string]bool)
	defer delete(active)
	for row in rows {
		// Counts, cooldown and rate limit are per owning instance, over that
		// instance's subscriptions only (REQ-EVP-4b).
		subscriber_key := fmt.tprintf("instance:%s/%s", row.owner_user_id, row.subscriber_instance_id)
		active[subscriber_key] = true
		schedule_key := fmt.tprintf("schedule:%s", row.consumer_name)
		active[schedule_key] = true

  schedule, known := r.notifications[schedule_key]
  signaled := full || dirty[fmt.tprintf("%s/%s",row.owner_user_id,row.chain_id)]
  // Stable cached targets need no JSON decode or fingerprint allocation
  // until a publication, activity change or schedule deadline makes them due.
  if cached && !r.subscription_cache_changed && !signaled && known &&
    !schedule.dirty && now._nsec < schedule.next_check._nsec {continue}
		// Keep bounded-scan cursors alive while their consumer waits for its
		// next deadline. Otherwise every skipped pass restarts stale history.
		subjects: []string
		if json.unmarshal(transmute([]byte)row.filter_subjects, &subjects) != nil do return false
		defer filters_destroy(subjects)
		for subject in subjects do active[fmt.tprintf("scan:%s/%s",row.consumer_name,subject)] = true
		snapshot := targets[row.subscription_id]
  if cached {
   chain:=r.subscription_cache[fmt.tprintf("%s/%s",row.owner_user_id,row.chain_id)]
   snapshot=chain.snapshot_by_id[row.subscription_id]
  }
		target := snapshot.target
		fingerprint := fmt.tprintf("%s/%s/%s/%s/%s/%s/%s/%s/%t/%s/%d/%s",
			row.owner_user_id,row.subscriber_instance_id,row.filter_subjects,row.wake_policy,
			target.instance_id,target.bridge_id,target.runtime_status,target.activity_status,
			target.is_bot,target.stopped_by,snapshot.outstanding,snapshot.oldest_delivery)
		fingerprint = fmt.tprintf("%s/%s/%s/%s",fingerprint,row.subscription_id,row.chain_id,row.created_at)
		changed := !known || schedule.fingerprint != fingerprint
		if changed || signaled {
			schedule.dirty = true
			schedule.fingerprint = fingerprint
			save_notification_state(r, schedule_key, schedule)
		}
		if !schedule.dirty && now._nsec < schedule.next_check._nsec do continue
		prior := r.notifications[subscriber_key]
		if prior.last_sent._nsec != 0 && now._nsec - prior.last_sent._nsec < i64(30 * time.Second) do continue
		if prior.last_rejected._nsec != 0 && now._nsec - prior.last_rejected._nsec < i64(5 * time.Second) do continue
		eligible :=
			target.instance_id != "" && target.stopped_by == ""
		if !eligible do continue
		state, state_err := nats.consumer_state(r.connection, "HEIM_EVENTS", row.consumer_name)
		if state_err.status != 0 do return false
		schedule.dirty = false
		delay := reconcile_interval(s)
		if state.pending > 0 do delay = 30 * time.Second
		if state.ack_pending > 0 {
			wait := s.ack_wait if s.ack_wait > 0 else 5 * time.Minute
			recorded, valid := platform.parse_rfc3339_utc(snapshot.oldest_delivery)
			if valid {
				// SQL due_deliveries uses a strict comparison of whole-second
				// timestamps; its first eligible instant is one second later.
				remaining := time.diff(time.now(), time.time_add(recorded, wait + time.Second))
				if remaining <= 0 do remaining = 30 * time.Second
				delay = min(delay, remaining)
			} else {
				// A fetch may precede its SQL receipt; recover conservatively.
				delay = min(delay, 30 * time.Second)
			}
		}
		schedule.next_check = now
		schedule.next_check._nsec += i64(delay)
		save_notification_state(r, schedule_key, schedule)
		for subject in subjects {
			key := fmt.tprintf("scan:%s/%s", row.consumer_name, subject)
			active[key] = true
			cursor := max(state.delivered + 1, r.notifications[key].cursor)
			// A bounded scan rotates past stale history; it never pulls from
			// the agent's consumer or changes its ack/delivery counters.
			if state.pending > 0 {
				for scanned in 0 ..< 256 {
					msg, sequence, err := nats.stream_next(r.connection, "HEIM_EVENTS", subject, cursor)
					if err.status == 13 {cursor = state.delivered + 1; break} 	// NATS_NOT_FOUND
					if err.status !=
					   0 {fmt.eprintln("events: pending snapshot", err, nats.error_text(err)); return false}
					if sequence <
					   cursor {fmt.eprintln("events: invalid snapshot sequence", sequence, cursor); nats.message_destroy(msg); return false}
					cursor = sequence + 1
					notice_candidate(row, msg, sequence, false, &candidates)
					nats.message_destroy(msg)
				}
			}
			save_notification_state(r, key, {cursor = cursor})
		}
		if state.ack_pending > 0 {
			due, due_err := notice_due_snapshot(s, row)
			if due_err.code != .None do return false
			for delivery in due {
				// Ack subjects end with delivered/stream/consumer/time/pending.
				// A max-delivery record has no future redelivery to announce.
				parts := strings.split(delivery.ack_reply, ".")
				max_deliver := s.max_deliver
				if max_deliver <= 0 do max_deliver = 10
				exhausted := false
				if len(parts) >= 5 {
					attempts, valid := strconv.parse_i64(parts[len(parts) - 5])
					exhausted = valid && attempts >= max_deliver
				}
				delete(parts)
				if exhausted do continue
				msg, err := nats.stream_get(r.connection, "HEIM_EVENTS", u64(delivery.stream_sequence))
				if err.jetstream == 10037 do continue
				if err.status != 0 {delivery_rows_destroy(due); return false}
				before := len(candidates)
				notice_candidate(row, msg, u64(delivery.stream_sequence), true, &candidates)
				if len(candidates) > before do candidates[len(candidates) - 1].ack_reply = strings.clone(delivery.ack_reply)
				nats.message_destroy(msg)
			}
			delivery_rows_destroy(due)
		}
	}
	// Re-snapshot once per observed consumer, rather than once per event.
	current_states := make(map[string]nats.Consumer_State)
	defer delete(current_states)
	for candidate in candidates {
		name := candidate.row.consumer_name
		if _, found := current_states[name]; found do continue
		current, err := nats.consumer_state(r.connection, "HEIM_EVENTS", name)
		if err.jetstream == 10014 do continue // removed watch; SQL fence below rejects it
		if err.status != 0 do return false
		current_states[name] = current
	}
	handled := make(map[string]bool)
	defer delete(handled)
	for candidate in candidates {
		row := candidate.row
		key := fmt.tprintf("instance:%s/%s", row.owner_user_id, row.subscriber_instance_id)
		if handled[key] do continue
		handled[key] = true
		target, err := notice_target_snapshot(s, row)
		if err.code != .None do return false
		count := 0
		worthy := false
		for other in candidates {
			if other.row.owner_user_id != row.owner_user_id || other.row.subscriber_instance_id != row.subscriber_instance_id do continue
			current, found := current_states[other.row.consumer_name]
			if !found do continue
			if !other.redelivery && other.sequence <= current.delivered do continue
			live, live_err := notice_live(s, other)
			if live_err.code != .None {domain.event_notice_target_destroy(&target); return false}
			if !live do continue
			count += 1
			obj, _ := other.value.(json.Object)
			if other.row.wake_policy == "catalog" && notice_wake_worthy(obj, target.is_bot) do worthy = true
		}
		process: Notice_Process
		if count > 0 && target.instance_id != "" && target.stopped_by == "" && s.notice_process != nil {
			process = s.notice_process(s.notice_ctx, row.owner_user_id, target)
		}
		stopped := process == .Exited
		idle := process == .Ready && target.activity_status == "idle"
		if idle || stopped && worthy {
			if s.notice(s.notice_ctx, row.owner_user_id, row.subscriber_instance_id, target, count, stopped) {
				save_notification_state(r, key, {last_sent = now})
				record_notice(s, row.owner_user_id, stopped)
			} else {
				save_notification_state(r, key, {last_rejected = now})
				// A rejected dispatch retries after the existing five-second
				// backoff, even if the pending scan's next deadline is later.
				for subscription in rows {
					if subscription.owner_user_id != row.owner_user_id || subscription.subscriber_instance_id != row.subscriber_instance_id do continue
					schedule_key := fmt.tprintf("schedule:%s",subscription.consumer_name)
					schedule := r.notifications[schedule_key]
					schedule.dirty = true
					save_notification_state(r,schedule_key,schedule)
				}
			}
		}
		domain.event_notice_target_destroy(&target)
	}
 if !cached || full || r.subscription_cache_changed {
	expired := make([dynamic]string)
	defer delete(expired)
	for key in r.notifications do if !active[key] do append(&expired, key)
	// Subscriber cooldowns survive busy periods and reconnects; removed watches
	// release their keys instead of accumulating process-lifetime allocations.
	for key in expired {
		context.allocator = r.cache_allocator
		state := r.notifications[key]
		delete_key(&r.notifications, key); delete(state.key); delete(state.fingerprint)
	}
 }
	completed = true
	return true
}
