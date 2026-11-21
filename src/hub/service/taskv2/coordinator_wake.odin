package taskv2

import "base:runtime"
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
// The callback owns every eligibility rule: status, user stop, bot, chain
// status, and the cross-flush rate limit (transport/http/coordinator_wake.odin).
// The wake is not a user event, so it never resets the coordinator idle stamp.

// queue_coordinator_wake records one pending wake; owner is the chain owner.
queue_coordinator_wake :: proc(svc: ^Service, instance_id, owner: string) {
	if svc == nil || svc.wake_coordinator == nil || instance_id == "" || owner == "" do return
	sync.mutex_lock(&svc.state_mutex)
	defer sync.mutex_unlock(&svc.state_mutex)
	// Heap-lived state: never owned by a request or scratch arena.
	context.allocator = runtime.heap_allocator()
	if svc.pending_coordinator_wakes == nil do svc.pending_coordinator_wakes = make(map[string]string)
	if instance_id in svc.pending_coordinator_wakes do return
	svc.pending_coordinator_wakes[strings.clone(instance_id)] = strings.clone(owner)
}

// drain_coordinator_wakes runs every pending wake. Swap the set under
// state_mutex, call the wakes unlocked, then free the heap-owned entries.
drain_coordinator_wakes :: proc(svc: ^Service) {
	if svc == nil do return
	sync.mutex_lock(&svc.state_mutex)
	pending := svc.pending_coordinator_wakes
	svc.pending_coordinator_wakes = nil
	sync.mutex_unlock(&svc.state_mutex)
	if pending == nil do return
	for instance_id, owner in pending {
		if svc.wake_coordinator != nil do svc.wake_coordinator(svc.wake_coordinator_ctx, owner, instance_id)
		delete(instance_id, runtime.heap_allocator())
		delete(owner, runtime.heap_allocator())
	}
	delete(pending)
}
