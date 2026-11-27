package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"

// ---- REQ-CIS-2: a [taskv2] notice wakes a stopped coordinator ------------------
//
// flush_effects queues each coordinator that was sent a notice that is still
// relevant. The set is keyed by instance, so a burst of notices yields one
// pending wake. The timer thread drains it once a second, after commit and
// outside every taskv2 lock; the bridge already holds the notice until the
// coordinator's PTY is alive. The restart must never run inside flush_effects:
// agent.stop_instance holds reconfiguration_mutex while it calls
// on_instance_user_stopped, whose flush can emit notices, and restart_instance
// takes that mutex again. Notices flushed during boot wait for the first tick.
// Unit tests call drain_coordinator_wakes themselves.
//
// A wake is not done until it is settled. The bridge delivers only to a live
// PTY, so a wake that cannot start the coordinator yet stays pending:
//   - rate limited: retried when the limit allows (Coordinator_Wake_Reply.retry_at_ms);
//   - stopping / launching: retried until the instance settles;
//   - transient restart failure (bridge offline, reconfiguration): retried later;
//   - live coordinator: watched for COORDINATOR_WAKE_LIVE_WATCH_MS, because an
//     idle stop can land while the bridge still holds the notice (its 2 s
//     collection window) and the stopped PTY would then never receive it.
// Every entry is dropped after COORDINATOR_WAKE_DEADLINE_MS, measured from
// the latest notice.
//
// The callback owns every eligibility rule: status, user stop, bot, chain
// status, and the cross-flush rate limit (transport/http/coordinator_wake.odin).
// The wake is not a user event, so it never resets the coordinator idle stamp.

COORDINATOR_WAKE_LIVE_WATCH_MS :: i64(15_000)
// Longer than the wake guard's hourly window, so a capped wake still runs.
COORDINATOR_WAKE_DEADLINE_MS :: i64(2 * 60 * 60 * 1000)
COORDINATOR_WAKE_MIN_RETRY_MS :: i64(1_000)

// Coordinator_Wake_Reply is the callback's verdict on one attempt.
Coordinator_Wake_Reply :: struct {
	// settled: nothing more to do (started, user-stopped, not a coordinator,
	// permanent failure). The entry is dropped.
	settled:     bool,
	// live: the coordinator is running, so only the live watch keeps the entry.
	live:        bool,
	// retry_at_ms: the earliest next attempt; <= now means the next tick.
	retry_at_ms: i64,
}

Pending_Coordinator_Wake :: struct {
	owner:            string, // heap-owned
	not_before_ms:    i64,
	live_watch_until: i64,
	deadline_ms:      i64,
}

// queue_coordinator_wake records or refreshes one pending wake; owner is the
// chain owner. A fresh notice makes an entry due at once and extends its
// windows.
queue_coordinator_wake :: proc(svc: ^Service, instance_id, owner: string) {
	if svc == nil || svc.wake_coordinator == nil || instance_id == "" || owner == "" do return
	now := now_ms(svc.clock)
	state_held := state_lock(svc)
	defer state_unlock(svc, state_held)
	// Heap-lived state: never owned by a request or scratch arena.
	context.allocator = runtime.heap_allocator()
	merge_pending_coordinator_wake_locked(svc, instance_id, Pending_Coordinator_Wake{
		owner = owner, not_before_ms = now,
		live_watch_until = now + COORDINATOR_WAKE_LIVE_WATCH_MS,
		deadline_ms = now + COORDINATOR_WAKE_DEADLINE_MS,
	})
}

// merge_pending_coordinator_wake_locked: the caller holds state_mutex and uses
// the heap allocator. Clones instance_id and w.owner when it inserts.
@(private = "file")
merge_pending_coordinator_wake_locked :: proc(svc: ^Service, instance_id: string, w: Pending_Coordinator_Wake) {
	if svc.pending_coordinator_wakes == nil do svc.pending_coordinator_wakes = make(map[string]Pending_Coordinator_Wake)
	if existing, found := &svc.pending_coordinator_wakes[instance_id]; found {
		existing.not_before_ms = min(existing.not_before_ms, w.not_before_ms)
		existing.live_watch_until = max(existing.live_watch_until, w.live_watch_until)
		existing.deadline_ms = max(existing.deadline_ms, w.deadline_ms)
		return
	}
	stored := w
	stored.owner = strings.clone(w.owner)
	svc.pending_coordinator_wakes[strings.clone(instance_id)] = stored
}

// drain_coordinator_wakes attempts every due wake. Swap the set under
// state_mutex, call the wakes unlocked, then merge back the entries that are
// not settled (a notice queued meanwhile merges with them).
drain_coordinator_wakes :: proc(svc: ^Service) {
	if svc == nil do return
	state_held := state_lock(svc)
	pending := svc.pending_coordinator_wakes
	svc.pending_coordinator_wakes = nil
	state_unlock(svc, state_held)
	if pending == nil do return
	heap := runtime.heap_allocator()
	now := now_ms(svc.clock)
	keep := make([dynamic]string, heap)
	defer delete(keep)
	for instance_id, &w in pending {
		if now > w.deadline_ms {
			fmt.printf("coordinator_wake: gave up target=%s\n", instance_id)
			continue
		}
		if w.not_before_ms > now { append(&keep, instance_id); continue }
		if svc.wake_coordinator == nil do continue
		reply := svc.wake_coordinator(svc.wake_coordinator_ctx, w.owner, instance_id, now)
		if reply.settled do continue
		if reply.live && now >= w.live_watch_until do continue
		w.not_before_ms = max(reply.retry_at_ms, now + COORDINATOR_WAKE_MIN_RETRY_MS)
		append(&keep, instance_id)
	}
	state_held = state_lock(svc)
	context.allocator = heap
	for instance_id in keep do merge_pending_coordinator_wake_locked(svc, instance_id, pending[instance_id])
	state_unlock(svc, state_held)
	for instance_id, w in pending {
		delete(instance_id, heap)
		delete(w.owner, heap)
	}
	delete(pending)
}
