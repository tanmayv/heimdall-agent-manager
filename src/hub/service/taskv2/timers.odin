package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Timer_Service (plan §2.3): a min-heap of (due, kind, key, armed_deadline) that
// is purely a CACHE over columns. The columns are the truth —
// task_leases.expires_at / hard_deadline_at / confirmed_at, tasks.ready_since,
// tasks.blocked_on_json.since, agent_instances.last_seen_at — so:
//   * a timer is never cancelled: on fire it re-reads the row and is a no-op when
//     the deadline moved (heartbeat), the row is gone (released) or the state
//     changed (answered);
//   * the heap is rebuilt from the columns on boot (rebuild_timers);
//   * tests drive fire_due(now) with a fake clock; the thread is a thin wrapper.
//
// MEM-4: keys are heap-cloned under the mutex. Request threads arm timers from a
// per-request arena (context.allocator is freed at disconnect), so a key that
// aliased the request body would dangle at the next probe.

Timer_Kind :: enum {
	Requirements_Notice, // pending revision/read acknowledgements, rebuilt from durable events
	Lease_TTL,         // key = lease_id,    armed = expires_at
	Lease_Hard_Cap,    // key = lease_id,    armed = hard_deadline_at
	Grant_Unconfirmed, // key = lease_id,    armed = granted_at (+ resend count via events)
	Idle_Grace,        // key = instance_id, armed = lease.last_beat_at
	Idle_TTL,          // key = instance_id, armed = "" (release time)
	Ready_Unclaimed,   // key = task_id,     armed = ready_since
	Blocked_Realert,   // key = task_id,     armed = blocked_on_json
	// Rematch is a safety net: a Ready / In-review task that still has no lease
	// of the right kind re-runs the matcher for its chain, so a missed trigger
	// (e.g. a hub restart or re-fold racing the bridge reconnect) self-heals.
	Rematch,           // key = task_id,     armed = task state when armed
	// Dependency_Stalled: a Done prerequisite whose merge never settled keeps
	// its backlog dependents waiting; alert after a bounded delay (REQ-TV2-3b).
	Dependency_Stalled, // key = prerequisite task_id, armed = "done"
	// Hold_Stale: a held task with no live lease reminds whoever placed the
	// hold (the coordinator, or the user via a user event) with exponential
	// back-off, at most HOLD_STALE_MAX_REMINDERS times per hold.
	Hold_Stale,         // key = task_id,     armed = the hold's since_ms
	// Coordinator idle stops (coordinator_idle.odin): measured from the
	// instance's user-activity stamp; X only while its chains are completed.
	Coordinator_Idle_Completed, // key = instance_id, armed = user_activity_at
	Coordinator_Idle,           // key = instance_id, armed = user_activity_at
	// Lease_Stalled (lease_stall.odin): a confirmed, active work lease whose
	// holder shows no activity for a window is nudged once, then reported to
	// the coordinator. Never expires the lease. One pending timer per lease.
	Lease_Stalled,              // key = lease_id,    armed = "" (activity is re-read on fire)
}

Timer :: struct {
	due_ms: i64,
	kind:   Timer_Kind,
	// key and armed are heap-owned copies (runtime.heap_allocator()).
	key:    string,
	armed:  string,
	seq:    u64,
}

Timer_Service :: struct {
	mutex:  sync.Mutex,
	heap:   [dynamic]Timer,
	seq:    u64,
	// stop asks the thin thread to exit (tests never start it).
	stop:   bool,
}

LEASE_TTL_SECONDS           :: 15 * 60
LEASE_HARD_CAP_SECONDS      :: 60 * 60
GRANT_UNCONFIRMED_SECONDS   :: 180
IDLE_GRACE_SECONDS          :: 5 * 60
IDLE_TTL_DEFAULT_SECONDS    :: 600
READY_UNCLAIMED_SECONDS     :: 10 * 60
BLOCKED_REALERT_SECONDS     :: 24 * 60 * 60
// Rematch one-shots after a task becomes Ready / In review (bounded, no self re-arm).
REMATCH_DELAYS_SECONDS      :: [3]i64{60, 180, 600}
CLOCK_JUMP_SEEN_WITHIN_SECONDS :: 120
// review_stalled re-alerts while the stall holds (re-armed from fire_rematch).
REVIEW_STALLED_REALERT_SECONDS :: 60 * 60
// dependency_stalled: first alert this long after the prerequisite reached
// Done, then re-alerted at this interval while the merge stays unresolved.
DEPENDENCY_STALLED_SECONDS     :: 10 * 60
// hold_stale: default FIRST reminder delay for a held, unleased task
// (Service.hold_stale_seconds overrides it). Each later reminder waits
// HOLD_STALE_BACKOFF times longer (30 min → 2 h → 8 h); after
// HOLD_STALE_MAX_REMINDERS the hold is left to the attention UI.
HOLD_STALE_SECONDS             :: 30 * 60
HOLD_STALE_BACKOFF             :: 4
HOLD_STALE_MAX_REMINDERS       :: 3

// timers_arm schedules a fire at due_ms. Thread-safe; O(log n).
timers_arm :: proc(svc: ^Service, kind: Timer_Kind, key: string, due_ms: i64, armed: string) {
	if svc == nil || key == "" do return
	ts := &svc.timers
	timers_held := dbt.profiled_mutex_lock(&ts.mutex, .Taskv2_Timers)
	defer dbt.profiled_mutex_unlock(&ts.mutex, .Taskv2_Timers, timers_held)
	// Pending requirement notices are a recurring retry, unlike the existing
	// one-shot timers. Keep one per task, including under frequent heartbeats.
	if kind == .Requirements_Notice {
		for timer in ts.heap do if timer.kind == kind && timer.key == key do return
	}
	// Coordinator idle timers are re-armed on every reset, start and chain
	// completion; one pending timer per (kind, instance, stamp) is enough.
	if kind == .Coordinator_Idle_Completed || kind == .Coordinator_Idle {
		for timer in ts.heap do if timer.kind == kind && timer.key == key && timer.armed == armed && timer.due_ms <= due_ms do return
	}
	// Lease_Stalled is armed at grant, confirm, rebuild and by its own fire:
	// keep exactly one per lease, at the earliest requested due time (a fire
	// that finds recent activity re-arms itself for the later window).
	if kind == .Lease_Stalled {
		for &timer, i in ts.heap do if timer.kind == kind && timer.key == key {
			if due_ms < timer.due_ms {
				timer.due_ms = due_ms
				heap_up(ts.heap[:], i)
			}
			return
		}
	}
	if ts.heap == nil do ts.heap = make([dynamic]Timer, runtime.heap_allocator())
	ts.seq += 1
	t := Timer{
		due_ms = due_ms,
		kind = kind,
		key = strings.clone(key, runtime.heap_allocator()),
		armed = strings.clone(armed, runtime.heap_allocator()),
		seq = ts.seq,
	}
	append(&ts.heap, t)
	heap_up(ts.heap[:], len(ts.heap) - 1)
	timrics_set_armed(len(ts.heap))
}

timers_armed_count :: proc(svc: ^Service) -> int {
	timers_held := dbt.profiled_mutex_lock(&svc.timers.mutex, .Taskv2_Timers)
	defer dbt.profiled_mutex_unlock(&svc.timers.mutex, .Taskv2_Timers, timers_held)
	return len(svc.timers.heap)
}

// timers_pop_due removes and returns every timer with due_ms <= now_ms. The
// caller owns the returned slice and its strings (timer_destroy).
timers_pop_due :: proc(svc: ^Service, now_ms: i64) -> []Timer {
	ts := &svc.timers
	out := make([dynamic]Timer)
	timers_held := dbt.profiled_mutex_lock(&ts.mutex, .Taskv2_Timers)
	defer dbt.profiled_mutex_unlock(&ts.mutex, .Taskv2_Timers, timers_held)
	for len(ts.heap) > 0 && ts.heap[0].due_ms <= now_ms {
		top := ts.heap[0]
		last := len(ts.heap) - 1
		ts.heap[0] = ts.heap[last]
		pop(&ts.heap)
		if len(ts.heap) > 0 do heap_down(ts.heap[:], 0)
		append(&out, top)
	}
	timrics_set_armed(len(ts.heap))
	return out[:]
}

timer_destroy :: proc(t: ^Timer) {
	delete(t.key, runtime.heap_allocator())
	delete(t.armed, runtime.heap_allocator())
}

@(private = "file")
timer_less :: proc(a, b: Timer) -> bool {
	if a.due_ms != b.due_ms do return a.due_ms < b.due_ms
	return a.seq < b.seq
}

@(private = "file")
heap_up :: proc(h: []Timer, i_in: int) {
	i := i_in
	for i > 0 {
		p := (i - 1) / 2
		if !timer_less(h[i], h[p]) do break
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

@(private = "file")
heap_down :: proc(h: []Timer, i_in: int) {
	i := i_in
	n := len(h)
	for {
		l := 2*i + 1
		r := 2*i + 2
		m := i
		if l < n && timer_less(h[l], h[m]) do m = l
		if r < n && timer_less(h[r], h[m]) do m = r
		if m == i do break
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

// ---- deadline helpers --------------------------------------------------------------

add_seconds :: proc(rfc3339: string, seconds: int) -> string {
	out, ok := platform.expires_at_after_seconds_from(rfc3339, seconds)
	if !ok do return rfc3339
	return out
}

to_ms :: proc(rfc3339: string) -> i64 {
	ms, ok := platform.rfc3339_to_unix_ms(rfc3339)
	if !ok do return 0
	return ms
}

// min_rfc3339 returns the earlier of two hub timestamps ("" counts as +inf).
min_rfc3339 :: proc(a, b: string) -> string {
	if a == "" do return b
	if b == "" do return a
	return a if a <= b else b
}

// ---- arming from engine events -------------------------------------------------------

arm_lease_timers :: proc(svc: ^Service, lease: domain.Task_Lease) {
	if task, found, _ := iface.taskchain_get_task(svc.repo, lease.task_id); found {
		if state, err := requirements_read(svc.repo, task); err.code == .None && state.revision > 1 {
			timers_arm(svc, .Requirements_Notice, string(lease.task_id), now_ms(svc.clock) + 1000, "")
		}
	}
	if lease.phase != domain.LEASE_PHASE_WAITING && lease.confirmed_at == "" {
		timers_arm(svc, .Grant_Unconfirmed, lease.lease_id, to_ms(lease.granted_at) + GRANT_UNCONFIRMED_SECONDS * 1000, lease.granted_at)
	}
	arm_lease_stall(svc, lease)
}

// arm_idle_ttl: `idle_since` (= the release time written to the instance row)
// is the armed stamp; a later release moves it and the older timer is a no-op.
arm_idle_ttl :: proc(svc: ^Service, instance_id: string, idle_ttl_seconds: int, idle_since: string) {
	ttl := idle_ttl_seconds
	if ttl <= 0 do ttl = IDLE_TTL_DEFAULT_SECONDS
	timers_arm(svc, .Idle_TTL, instance_id, to_ms(idle_since) + i64(ttl) * 1000, idle_since)
}

arm_task_timers :: proc(svc: ^Service, task: domain.Task) {
	if task.state == .Ready || task.state == .In_Review {
		state := domain.task_state_string(task.state)
		now := now_ms(svc.clock)
		delays := REMATCH_DELAYS_SECONDS
		for d in delays do timers_arm(svc, .Rematch, string(task.task_id), now + d * 1000, state)
	}
	if task.state == .Ready && task.ready_since != "" {
		timers_arm(svc, .Ready_Unclaimed, string(task.task_id), to_ms(task.ready_since) + READY_UNCLAIMED_SECONDS * 1000, task.ready_since)
	}
	if task.blocked_on_json != "" && strings.contains(task.blocked_on_json, `"human"`) {
		timers_arm(svc, .Blocked_Realert, string(task.task_id), now_ms(svc.clock) + BLOCKED_REALERT_SECONDS * 1000, task.blocked_on_json)
	}
	if task.state == .Done && task.kind == .Task && task.stage_key == "" {
		timers_arm(svc, .Dependency_Stalled, string(task.task_id), now_ms(svc.clock) + DEPENDENCY_STALLED_SECONDS * 1000, "done")
	}
	if hold, held := task_hold_object(task.blocked_on_json); held {
		since := i64(jsonx.extract_int(hold, "since_ms", 0, true))
		timers_arm(svc, .Hold_Stale, string(task.task_id), max(since + hold_stale_ms(svc), now_ms(svc.clock)), fmt.tprintf("%d", since))
	}
}

hold_stale_ms :: proc(svc: ^Service) -> i64 {
	secs := svc.hold_stale_seconds
	if secs <= 0 do secs = HOLD_STALE_SECONDS
	return i64(secs) * 1000
}

// hold_stale_delay_ms: the wait before reminder number `sent`+1, given `sent`
// reminders already went out for this hold (exponential back-off).
hold_stale_delay_ms :: proc(svc: ^Service, sent: int) -> i64 {
	d := hold_stale_ms(svc)
	for _ in 0..<sent do d *= HOLD_STALE_BACKOFF
	return d
}

// rebuild_timers (boot): arm from the columns — every lease, every ready task,
// every blocked-on-human task. Nothing else is persisted; nothing else is needed.
rebuild_timers :: proc(svc: ^Service) {
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code == .None {
		for l in leases do arm_lease_timers(svc, l)
	}
	ready, rerr := iface.taskchain_list_tasks_by_state(svc.repo, .Ready)
	if rerr.code == .None {
		for t in ready do arm_task_timers(svc, t)
	}
	backlog, berr := iface.taskchain_list_tasks_by_state(svc.repo, .Backlog)
	if berr.code == .None {
		for t in backlog do arm_task_timers(svc, t)
	}
	in_review, irerr := iface.taskchain_list_tasks_by_state(svc.repo, .In_Review)
	if irerr.code == .None {
		for t in in_review do arm_task_timers(svc, t)
	}
	// Done tasks whose merge never settled (dependency_stalled); the same
	// lookup bridge hello does for requeue_pending_merges. The merge_pending
	// projection keeps boot independent of Done history: only those tasks'
	// event logs are read, and merge_pending(evs) still decides.
	if done, derr := iface.taskchain_list_merge_pending_done_tasks(svc.repo); derr.code == .None {
		for t in done {
			evs, eerr := iface.taskchain_list_events_by_task(svc.repo, t.task_id, t.owner_user_id)
			if eerr.code != .None || !merge_pending(evs) do continue
			if berr := backfill_merge_snapshot(svc, t, evs); berr.code != .None {
				fmt.eprintfln("[taskv2] merge snapshot backfill for %s failed (%s); retried next boot", t.task_id, berr.message)
			}
			arm_task_timers(svc, t)
		}
	}
	// Idle_TTL from agent_instances.idle_since (live, lease-free instances).
	if insts, ierr := iface.agent_list_active_runtime_instances(svc.agents); ierr.code == .None {
		for inst in insts {
			if inst.idle_since == "" || inst.chain_id == "" do continue
			if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held do continue
			arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, domain.Task_Chain_ID(inst.chain_id), inst.owner_user_id, inst.agent_id), inst.idle_since)
		}
	}
	// Coordinator idle stops from agent_instances.user_activity_at (REQ-CIS-4).
	rebuild_coordinator_idle_timers(svc)
}

// ---- firing -----------------------------------------------------------------------

// Fire_Result: Noop (deadline moved / row gone / state changed), Acted, or
// Failed — a partial write that must be rolled back, never committed (S2).
Fire_Result :: enum { Noop, Acted, Failed }

// fire_due pops every timer due at now_ms and fires it: ONE unit of work per
// timer, each re-reading its column before acting. Returns the number fired.
// `jump_detected` is the timer thread's "now − last tick > TTL" signal (plan
// §2.4 clock-jump rule); tests pass it explicitly.
fire_due :: proc(svc: ^Service, now_ms: i64, jump_detected := false) -> int {
	due := timers_pop_due(svc, now_ms)
	defer delete(due)
	fired := 0
	for &t in due {
		fire_timer(svc, t, now_ms, jump_detected)
		timer_destroy(&t)
		fired += 1
	}
	return fired
}

@(private = "file")
fire_timer :: proc(svc: ^Service, t: Timer, now_ms: i64, jump_detected: bool) {
	u, ok, _ := begin_uow(svc)
	if !ok do return
	r := Fire_Result.Noop
	idle_stop: Coordinator_Idle_Stop
	has_idle_stop := false
	switch t.kind {
	case .Requirements_Notice:
		if task, found, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key)); found {
			if ok, _ := requirements_reconcile_in_uow(svc, &u, task); ok {
				r = .Acted
				if ok, _ := after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Updated); !ok do r = .Failed
			} else { r = .Failed }
		}
	case .Lease_TTL:        r = .Noop
	case .Lease_Hard_Cap:   r = .Noop
	case .Grant_Unconfirmed: r = fire_grant_unconfirmed(svc, &u, t)
	case .Idle_Grace:       r = .Noop
	case .Idle_TTL:         r = fire_idle_ttl(svc, &u, t)
	case .Ready_Unclaimed:  r = fire_ready_unclaimed(svc, &u, t)
	case .Blocked_Realert:  r = fire_blocked_realert(svc, &u, t)
	case .Rematch:          r = fire_rematch(svc, &u, t)
	case .Dependency_Stalled: r = fire_dependency_stalled(svc, &u, t)
	case .Hold_Stale:       r = fire_hold_stale(svc, &u, t, now_ms)
	case .Coordinator_Idle_Completed, .Coordinator_Idle:
		idle_stop, has_idle_stop = fire_coordinator_idle(svc, t, now_ms)
		if has_idle_stop do r = .Acted
	case .Lease_Stalled:    r = fire_lease_stalled(svc, &u, t, now_ms)
	}
	if r == .Failed {
		fmt.eprintfln("[taskv2] timer %v for %s failed; rolled back", t.kind, t.key)
		// Re-arm so the condition is re-evaluated next tick instead of being lost.
		timers_arm(svc, t.kind, t.key, now_ms + 1000, t.armed)
	}
	committed, _ := end_uow(svc, &u, r != .Failed)
	// The stop is network I/O and takes the agent service's own locks: strictly
	// after the unit of work released the engine lock.
	if has_idle_stop && committed do coordinator_idle_stop_after_commit(svc, idle_stop, now_ms)
}

@(private = "file")
expire_result_to_fire :: proc(r: Expire_Result) -> Fire_Result {
	switch r {
	case .Expired: return .Acted
	case .Gone: return .Noop
	case .Failed: return .Failed
	}
	return .Noop
}

@(private = "file")
fire_lease_ttl :: proc(svc: ^Service, u: ^Uow, t: Timer, now_ms: i64, jump_detected: bool) -> Fire_Result {
	// Compatibility for already queued timers: ownership never expires with time.
	return .Noop
}

// expire_then_match: a timer-driven expiry followed by exactly one matcher run
// for the lease's chain (review B3: the matcher never runs inside expire).
@(private = "file")
expire_then_match :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, reason: string) -> Fire_Result {
	r := expire_result_to_fire(expire_lease_in_uow(svc, u, lease, reason, hub_actor()))
	if r != .Acted do return r
	if ok, _ := after_chain_change(svc, u, lease.chain_id, lease.owner_user_id, .Lease_Expired); !ok do return .Failed
	return .Acted
}

@(private = "file")
fire_lease_hard_cap :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	// Compatibility for already queued timers: ownership never expires with time.
	return .Noop
}

@(private = "file")
fire_grant_unconfirmed :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	lease, ok, _ := iface.taskchain_get_lease(svc.repo, t.key)
	if !ok do return .Noop
	if lease.phase == domain.LEASE_PHASE_WAITING || lease.confirmed_at != "" do return .Noop
	if lease.granted_at != t.armed do return .Noop
	task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok do return .Noop
	if !lease_resent(svc, lease) {
		// Re-send the wake ONCE (the bridge may have dropped the frame), then
		// give it another window.
		p := json_begin()
		json_str(&p, "lease_id", lease.lease_id)
		if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_LEASE_RESENT, json_end(&p)); !aok do return .Failed
		effect_wake_lease(svc, u, lease, task)
		timers_arm(svc, .Grant_Unconfirmed, lease.lease_id, now_ms(svc.clock) + GRANT_UNCONFIRMED_SECONDS * 1000, lease.granted_at)
		return .Acted
	}
	// After one delivery retry, missing startup confirmation is a dispatch
	// failure. Park it with diagnostics instead of burning work attempts.
	switch dispatch_failed_in_uow(svc, u, lease, "startup was not confirmed after retrying delivery") {
	case .Gone: return .Noop
	case .Failed: return .Failed
	case .Expired:
		if ok, _ := after_chain_change(svc, u, lease.chain_id, lease.owner_user_id, .Instance_Terminal); !ok do return .Failed
		return .Acted
	}
	return .Noop
}

@(private = "file")
lease_resent :: proc(svc: ^Service, lease: domain.Task_Lease) -> bool {
	evs, err := iface.taskchain_list_events_by_task(svc.repo, lease.task_id, lease.owner_user_id)
	if err.code != .None do return false
	for e in evs {
		if e.kind == EV_LEASE_RESENT && strings.contains(e.payload_json, lease.lease_id) do return true
	}
	return false
}

@(private = "file")
fire_idle_grace :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	// Compatibility for already queued timers: ownership never expires with time.
	return .Noop
}

@(private = "file")
fire_idle_ttl :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, t.key); held do return .Noop
	inst, iok, _ := iface.agent_get_instance(svc.agents, t.key)
	if !iok do return .Noop
	if inst.idle_since == "" || inst.idle_since != t.armed do return .Noop // re-leased and released again: the newer timer owns it (S4)
	// Not running (or `unreachable` behind an offline bridge): nothing to stop
	// now. idle_since is unchanged, so the reconnect sweep finds the window
	// over and delivers the stop (spec SCHED 12, bridge offline).
	if !instance_is_live(inst) && !instance_is_pending(inst) do return .Noop
	// The grace window ended with no lease (REQ-SCHED-23/26): point reads only.
	// A worker waiting for review or blocked holds a waiting claim, so it is
	// never stopped here; an instance outside any chain fleet is not managed.
	if inst.chain_id == "" do return .Noop
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id))
	if !cok do return .Noop
	if _, managed := instance_stop_managed(svc, chain, inst); !managed do return .Noop
	if stopped, _ := stop_instance_in_uow(svc, u, inst, inst.chain_id, STOP_REASON_IDLE_TTL); !stopped do return .Failed
	return .Acted
}

@(private = "file")
fire_ready_unclaimed :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	task, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key))
	if !ok do return .Noop
	if task.state != .Ready || task.ready_since != t.armed do return .Noop
	// A task assigned to the coordinator's own agent: nudge_coordinator_item
	// (coordinator_item_ready) replaces this alert and the coordinator pulls;
	// nothing is waiting on a free worker (rule f).
	if chain, cok, _ := iface.taskchain_get_chain(svc.repo, task.chain_id); cok {
		if coord_agent := chain_coordinator_agent_id(svc, chain); coord_agent != "" && brief_assignee(task.brief_json) == coord_agent do return .Noop
	}
	p := json_begin()
	json_str(&p, "since", task.ready_since)
	reason := ""
	if assignee_fleet_paused(svc, task) {
		reason = fmt.tprintf("assignee fleet row paused: %s", brief_assignee(task.brief_json))
		json_str(&p, "reason", reason)
	}
	if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_READY_UNCLAIMED, json_end(&p)); !aok do return .Failed
	effect_publish_task(u, task, "ready_unclaimed")
	line := fmt.tprintf("[taskv2] ready_unclaimed: task %s (%s) ready since %s", task.task_id, task.title, task.ready_since)
	if reason != "" do line = fmt.tprintf("%s (%s; resume with task-chain fleet resume)", line, reason)
	effect_notify_task(svc, u, task, "ready_unclaimed", line)
	return .Acted
}

// assignee_fleet_paused: the fleet row of the task's assignee is paused.
@(private = "file")
assignee_fleet_paused :: proc(svc: ^Service, task: domain.Task) -> bool {
	assignee := brief_assignee(task.brief_json)
	if assignee == "" do return false
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, task.chain_id, task.owner_user_id)
	if ferr.code != .None do return false
	defer delete(fleets)
	f, ok := fleet_row_for_agent(fleets, assignee)
	return ok && f.paused
}

// fire_rematch: the task is still Ready / In review (same state as when armed)
// and holds no lease of the kind that state needs → run the matcher for its
// chain. Harmless when nothing can be granted (no free worker, etc.).
@(private = "file")
fire_rematch :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	task, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key))
	if !ok || domain.task_state_string(task.state) != t.armed do return .Noop
	want := domain.LEASE_KIND_WORK if task.state == .Ready else domain.LEASE_KIND_REVIEW
	if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); lerr.code == .None {
		for l in leases do if l.phase != domain.LEASE_PHASE_WAITING && l.kind == want do return .Noop
	}
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok || chain.status != .Active || chain.publish_state != .Published do return .Noop
	if mok, _ := match_chain_in_uow(svc, u, chain, .Timer); !mok do return .Failed
	if task.state == .In_Review do check_review_stalled(svc, u, task)
	return .Acted
}

// check_review_stalled: the review invariant (REQ-TV2-3a). An in_review task
// whose gate waits while no lease is live and no agent pair is owed (every
// required reviewer has posted, yet the gate did not advance) can never move on
// its own: tell the coordinator what is missing and how to recover, and re-arm
// while the condition holds. A gate waiting only on the user's approval is not
// a stall; the coordinator was told review_requested_from_user.
@(private = "file")
check_review_stalled :: proc(svc: ^Service, u: ^Uow, task_in: domain.Task) {
	task, ok, _ := iface.taskchain_get_task(svc.repo, task_in.task_id)
	if !ok || task.state != .In_Review || task.kind == .Gate do return
	if task_is_held(task) do return // waiting on its release, not stalled
	if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); lerr.code != .None || active_claim_count(leases) > 0 do return
	unmet, uerr := gate_unmet_components(svc, task)
	if uerr.code != .None || len(unmet) == 0 do return
	reviews, rerr := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	if rerr.code != .None do return
	for m in unmet {
		// an owed review (no verdict yet) is the matcher's job, not a stall
		if m.kind == "review" && agent_review_owed(reviews, task, m.agent_id) do return
	}
	if awaits_user_review(svc, task) do return
	p := json_begin()
	json_raw(&p, "unmet", gate_unmet_json(unmet))
	if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_REVIEW_STALLED, json_end(&p)); !aok do return
	effect_publish_task(u, task, "review_stalled")
	effect_notify_task(svc, u, task, "review_stalled", fmt.tprintf("[taskv2] review_stalled: task %s (%s) gate is waiting with no live lease and no review owed; unmet=%s. Recover with: ham-ctl review post %s --verdict approve|request_changes --on-behalf-of user, re-run the reviewer (task show %s), or adjust the brief reviewers", task.task_id, task.title, gate_unmet_json(unmet), task.task_id, task.task_id))
	timers_arm(svc, .Rematch, string(task.task_id), now_ms(svc.clock) + REVIEW_STALLED_REALERT_SECONDS * 1000, domain.task_state_string(task.state))
}

// fire_dependency_stalled: the prerequisite is Done but its merge is pending,
// conflicted or failed. Every backlog dependent whose readiness is false ONLY
// because of that merge (all its other edges are satisfied) gets a
// dependency_stalled event and the coordinator is told the offending
// prerequisite, its merge state and the recovery. Re-armed while it holds.
@(private = "file")
fire_dependency_stalled :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	prereq, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key))
	if !ok || prereq.state != .Done do return .Noop
	merge := task_merge_status(svc, prereq)
	if merge.state == "none" || merge.state == "merged" do return .Noop
	edges, eerr := iface.taskchain_list_work_dependencies(svc.repo, prereq.chain_id, prereq.owner_user_id)
	if eerr.code != .None do return .Noop
	prereq_ref := domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(prereq.task_id)}
	stalled := 0
	for edge in edges {
		if edge.removed_at != "" || edge.prerequisite != prereq_ref || edge.dependent.kind != domain.WORK_ITEM_TASK do continue
		dep, dok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(edge.dependent.id))
		if !dok || dep.state != .Backlog || dep.blocked_on_json != "" do continue
		if !only_merge_blocks(svc, dep, prereq_ref, edges) do continue
		p := json_begin()
		json_str(&p, "prerequisite", string(prereq.task_id))
		json_str(&p, "merge", merge.state)
		if merge.detail != "" do json_str(&p, "detail", merge.detail)
		if _, aok, _ := append_event(svc.repo, svc.clock, dep, hub_actor(), EV_DEPENDENCY_STALLED, json_end(&p)); !aok do return .Failed
		effect_publish_task(u, dep, "dependency_stalled")
		effect_notify_task(svc, u, dep, "dependency_stalled", fmt.tprintf("[taskv2] dependency_stalled: task %s (%s) waits only on the merge of %s (merge %s). Inspect with: ham-ctl task readiness %s. Recover: resolve the merge conflict / bring the bridge online so the merge is retried, or remove the dependency.", dep.task_id, dep.title, prereq.task_id, merge.state, dep.task_id))
		stalled += 1
	}
	if stalled == 0 do return .Noop
	timers_arm(svc, .Dependency_Stalled, string(prereq.task_id), now_ms(svc.clock) + DEPENDENCY_STALLED_SECONDS * 1000, "done")
	return .Acted
}

// only_merge_blocks: every other dependency of `dep` is satisfied, so the
// merge state of `prereq` is the only thing keeping it in backlog.
@(private = "file")
only_merge_blocks :: proc(svc: ^Service, dep: domain.Task, prereq: domain.Work_Item_Ref, edges: []domain.Work_Dependency) -> bool {
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, dep.chain_id, dep.owner_user_id)
	if terr.code != .None do return false
	deps, derr := iface.taskchain_list_dependencies_by_chain(svc.repo, dep.chain_id, dep.owner_user_id)
	if derr.code != .None do return false
	if !deps_done_for(dep.task_id, tasks, deps) do return false
	self := domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(dep.task_id)}
	for edge in edges {
		if edge.removed_at != "" || edge.dependent != self || edge.prerequisite == prereq do continue
		snap, sok, _ := work_item_snapshot(svc, dep.chain_id, dep.owner_user_id, edge.prerequisite)
		if !sok || !snap.succeeded do return false
	}
	return true
}

@(private = "file")
fire_blocked_realert :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	task, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key))
	if !ok do return .Noop
	if task.blocked_on_json == "" || task.blocked_on_json != t.armed do return .Noop
	p := json_begin()
	json_raw(&p, "blocked_on", task.blocked_on_json)
	if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_BLOCKED_REALERT, json_end(&p)); !aok do return .Failed
	effect_publish_task(u, task, "blocked_realert")
	effect_notify_task(svc, u, task, "blocked_on human", fmt.tprintf("[taskv2] blocked_on human: task %s (%s) still waiting on human input", task.task_id, task.title))
	timers_arm(svc, .Blocked_Realert, string(task.task_id), now_ms(svc.clock) + BLOCKED_REALERT_SECONDS * 1000, task.blocked_on_json)
	return .Acted
}

// fire_hold_stale: the task is still held by the same hold, no lease is live
// (a live holder was asked to checkpoint; its handoff re-arms this), and the
// back-off interval since the last reminder for this hold has passed. Several
// timers may be armed for one hold (every blocked_on change re-arms); the event
// log dedupes them, and a timer that fires too early re-arms for the next due
// time so a rebuild between reminders never drops the hold. Reminders back off
// exponentially (hold_stale_delay_ms) and stop after HOLD_STALE_MAX_REMINDERS.
// A hold the user placed is the user's to release: the reminder goes to the
// user (task/hold_stale user event + attention re-projection), never to an
// agent. Released, cancelled and done tasks carry no hold: no-op.
@(private = "file")
fire_hold_stale :: proc(svc: ^Service, u: ^Uow, t: Timer, now: i64) -> Fire_Result {
	task, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key))
	if !ok || domain.task_state_is_terminal(task.state) do return .Noop
	hold, held := task_hold_object(task.blocked_on_json)
	if !held do return .Noop
	since := i64(jsonx.extract_int(hold, "since_ms", 0, true))
	if fmt.tprintf("%d", since) != t.armed do return .Noop // a newer hold owns it
	if strings.contains(hold, `"checkpoint_requested":true`) do return .Noop
	// A live (non-waiting) lease is still working toward its checkpoint; its
	// handoff changes blocked_on and re-arms this timer.
	leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if lerr.code != .None do return .Failed
	for l in leases do if l.phase != domain.LEASE_PHASE_WAITING do return .Noop
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None do return .Failed
	last := since
	sent := 0
	for e in evs {
		if e.kind == EV_HOLD_STALE && e.ts_ms >= since {
			last = max(last, e.ts_ms)
			sent += 1
		}
	}
	if sent >= HOLD_STALE_MAX_REMINDERS do return .Noop
	due := last + hold_stale_delay_ms(svc, sent)
	if now < due {
		// Too soon after the last reminder (e.g. a boot rebuild armed this one
		// for now): keep the hold covered by re-arming for the next due time.
		timers_arm(svc, .Hold_Stale, string(task.task_id), due, t.armed)
		return .Noop
	}
	by_user := jsonx.extract_string(hold, "by", "", true, context.temp_allocator) == ACTOR_USER
	age_min := (now - since) / 60000
	p := json_begin()
	json_int(&p, "since_ms", since)
	json_int(&p, "age_minutes", age_min)
	json_int(&p, "reminder", i64(sent + 1))
	json_str(&p, "routed_to", "user" if by_user else "coordinator")
	if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_HOLD_STALE, json_end(&p)); !aok do return .Failed
	if by_user {
		effect_publish_task(u, task, "hold_stale")
		effect_attention(u, task)
	} else {
		reason := jsonx.extract_string(hold, "reason", "", true, context.temp_allocator)
		line := fmt.tprintf("[taskv2] hold_stale: task %s (%s) held for %d min (reason: %s); release it with `task release %s` once the reason is resolved", task.task_id, task.title, age_min, reason, task.task_id)
		effect_notify_task(svc, u, task, "hold_stale", line)
	}
	if sent + 1 < HOLD_STALE_MAX_REMINDERS {
		timers_arm(svc, .Hold_Stale, string(task.task_id), now + hold_stale_delay_ms(svc, sent + 1), t.armed)
	}
	return .Acted
}

// ---- the thin thread -----------------------------------------------------------------

// start_timer_thread runs fire_due once a second against the service clock. It
// is a 1 s check of an in-memory heap, not a table sweep.
start_timer_thread :: proc(svc: ^Service) -> ^thread.Thread {
	// thread-spawn: startup (caller's allocator is the process heap)
	t := thread.create(timer_thread_proc)
	t.data = rawptr(svc)
	sync.atomic_store(&svc.touch_async, true)
	thread.start(t)
	return t
}

@(private = "file")
timer_thread_proc :: proc(t: ^thread.Thread) {
	svc := (^Service)(t.data)
	// Everything a tick allocates (repository rows, payloads, effects) is
	// scratch: route the thread's allocator to its temp arena and free it per
	// tick. Heap-lived state (timer keys, recent_expiries) names
	// runtime.heap_allocator explicitly.
	context.allocator = context.temp_allocator
	last_tick := now_ms(svc.clock)
	for !sync.atomic_load(&svc.timers.stop) {
		time.sleep(time.Second)
		now := now_ms(svc.clock)
		// Clock jump (plan §2.4): the hub slept/was suspended for longer than
		// a TTL; TTL fires in this tick may grant the one-shot extension.
		jump := now - last_tick > LEASE_TTL_SECONDS * 1000
		last_tick = now
		dbt.scope_begin(.Timer)
		_ = fire_due(svc, now, jump)
		drain_pending_touches(svc)
		drain_coordinator_wakes(svc)
		dbt.scope_end_background()
		// Per-tick scratch (wake keys, JSON) lives on the temp allocator.
		free_all(context.temp_allocator)
	}
}
