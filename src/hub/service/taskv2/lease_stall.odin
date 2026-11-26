package taskv2

import "core:fmt"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Lease stall detection (Timer_Kind.Lease_Stalled).
//
// A confirmed, active WORK lease whose holder shows no activity for one window
// W is nudged once (a terminal line to the holder). If the holder is still
// silent W after that nudge, the chain coordinator gets a typed stall notice:
// a `lease_stalled` task event, the catalog event `task.lease_stalled` and a
// `[taskv2] lease_stalled` notice naming the task, the holder and the last
// activity time. The hub NEVER expires, blocks or stops the lease for this;
// recovery is the coordinator's call. Coordinators holding their own tasks are
// treated exactly like any other holder.
//
// Activity signals (no new columns; all durable, so a hub restart rebuilds the
// same answer):
//   * task_leases.granted_at    — the grant opens the first window;
//   * task_leases.confirmed_at  — the holder's start-success / inline pull;
//   * task_leases.last_beat_at  — every `lease heartbeat` (with or without a
//                                 note) and every confirm;
//   * task_events by the holder — any event on the task whose actor is the
//                                 holder instance since the grant: heartbeat
//                                 notes, task comments (`comment`), requirement
//                                 acknowledgements, and so on.
// Submit, handoff, block and release move the lease to waiting or delete it,
// which ends stall detection (the timer no-ops). Commits are only seen by the
// hub at submit/handoff, so they count through those.
//
// Window: LEASE_STALL_SECONDS (20 min) by default; hub-wide
// Service.lease_stall_seconds (Hub_Config / --lease-stall-seconds /
// HEIMDALL_LEASE_STALL_SECONDS; < 0 here disables); a chain may override it
// with a positive `lease_stall_seconds` in its defaults_json. The hub-wide
// disable wins over a chain override.
//
// Reset: the timer is a cache. Each fire re-reads the lease and the task
// events; when activity is newer than the window it simply re-arms for
// last_activity + W. Nudge and notice are keyed by the last-activity stamp they
// were sent for, so a new silence period gets a fresh nudge and notice, and a
// re-fire (or boot rebuild) never repeats them.

LEASE_STALL_SECONDS :: 20 * 60

// lease_stall_window_ms: the silence window for leases of `chain_id`; 0 when
// stall detection is disabled.
lease_stall_window_ms :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID) -> i64 {
	secs := svc.lease_stall_seconds
	if secs < 0 do return 0
	if secs == 0 do secs = LEASE_STALL_SECONDS
	if chain, ok, _ := iface.taskchain_get_chain(svc.repo, chain_id); ok && strings.has_prefix(strings.trim_space(chain.defaults_json), "{") {
		if override := jsonx.extract_int(chain.defaults_json, "lease_stall_seconds", 0, true); override > 0 do secs = override
	}
	return i64(secs) * 1000
}

// lease_watched: stall detection applies to this lease row at all.
@(private = "file")
lease_watched :: proc(lease: domain.Task_Lease) -> bool {
	return lease.kind == domain.LEASE_KIND_WORK && lease.phase != domain.LEASE_PHASE_WAITING && lease.confirmed_at != ""
}

// arm_lease_stall arms the lease's one pending stall timer from its columns
// (grant, confirm, boot rebuild). The fire re-reads events for the full answer.
arm_lease_stall :: proc(svc: ^Service, lease: domain.Task_Lease) {
	if svc == nil || !lease_watched(lease) do return
	window := lease_stall_window_ms(svc, lease.chain_id)
	if window <= 0 do return
	last := max(to_ms(lease.granted_at), to_ms(lease.confirmed_at), to_ms(lease.last_beat_at))
	timers_arm(svc, .Lease_Stalled, lease.lease_id, last + window, "")
}

// lease_last_activity_ms: the newest activity signal (see the header).
lease_last_activity_ms :: proc(lease: domain.Task_Lease, evs: []domain.Task_Event) -> i64 {
	granted := to_ms(lease.granted_at)
	last := max(granted, to_ms(lease.confirmed_at), to_ms(lease.last_beat_at))
	for e in evs {
		if e.ts_ms < granted || e.actor_kind != ACTOR_AGENT || e.actor_id != lease.holder_instance_id do continue
		last = max(last, e.ts_ms)
	}
	return last
}

// lease_stall_marks: when the nudge / stall notice for this silence period
// (lease + last-activity stamp) went out; 0 when it did not.
@(private = "file")
lease_stall_marks :: proc(evs: []domain.Task_Event, lease_id: string, last_activity: i64) -> (nudged_ms, stalled_ms: i64) {
	for e in evs {
		if e.kind != EV_LEASE_STALL_NUDGED && e.kind != EV_LEASE_STALLED do continue
		if jsonx.extract_string(e.payload_json, "lease_id", "", true, context.temp_allocator) != lease_id do continue
		if i64(jsonx.extract_int(e.payload_json, "last_activity_ms", 0, true)) != last_activity do continue
		if e.kind == EV_LEASE_STALL_NUDGED do nudged_ms = e.ts_ms
		else do stalled_ms = e.ts_ms
	}
	return
}

ms_to_rfc3339 :: proc(ms: i64) -> string {
	return platform.format_rfc3339_utc(time.unix(0, ms * 1_000_000))
}

// fire_lease_stalled: see the header. Returns Noop whenever it only re-armed.
fire_lease_stalled :: proc(svc: ^Service, u: ^Uow, t: Timer, now: i64) -> Fire_Result {
	lease, ok, _ := iface.taskchain_get_lease(svc.repo, t.key)
	if !ok || !lease_watched(lease) do return .Noop // released / waiting: the next grant re-arms
	window := lease_stall_window_ms(svc, lease.chain_id)
	if window <= 0 do return .Noop
	task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok || domain.task_state_is_terminal(task.state) do return .Noop
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None do return .Failed
	last := lease_last_activity_ms(lease, evs)
	nudged, stalled := lease_stall_marks(evs, lease.lease_id, last)
	switch {
	case stalled != 0:
		// Already reported for this silence period: keep watching so that a
		// later burst of activity followed by silence starts a new cycle.
		timers_arm(svc, .Lease_Stalled, lease.lease_id, now + window, "")
		return .Noop
	case nudged == 0 && now < last + window:
		timers_arm(svc, .Lease_Stalled, lease.lease_id, last + window, "")
		return .Noop
	case nudged != 0 && now < nudged + window:
		timers_arm(svc, .Lease_Stalled, lease.lease_id, nudged + window, "")
		return .Noop
	}
	last_at := ms_to_rfc3339(last)
	silent_min := (now - last) / 60000
	p := json_begin()
	json_str(&p, "lease_id", lease.lease_id)
	json_str(&p, "holder_instance_id", lease.holder_instance_id)
	json_int(&p, "last_activity_ms", last)
	json_str(&p, "last_activity_at", last_at)
	if nudged == 0 {
		if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_LEASE_STALL_NUDGED, json_end(&p)); !aok do return .Failed
		effect_publish_task(u, task, "lease_stall_nudged")
		bridge_id := lease.bridge_id
		if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok && inst.bridge_id != "" do bridge_id = inst.bridge_id
		effect_nudge_instance(u, lease.holder_instance_id, bridge_id, fmt.tprintf("[taskv2] lease_stall: no activity on your task %s (%s) since %s (%d min). Continue the work and report progress with `ham-ctl lease heartbeat --note \"<progress>\"`, or submit / handoff / block. The coordinator is told if you stay silent.", task.task_id, task.title, last_at, silent_min))
		timers_arm(svc, .Lease_Stalled, lease.lease_id, now + window, "")
		return .Acted
	}
	json_str(&p, "nudged_at", ms_to_rfc3339(nudged))
	// append_event also emits the catalog event task.lease_stalled.
	if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_LEASE_STALLED, json_end(&p)); !aok do return .Failed
	effect_publish_task(u, task, "lease_stalled")
	effect_notify_task(svc, u, task, "lease_stalled", fmt.tprintf("[taskv2] lease_stalled: task %s (%s) holder %s has shown no activity since %s (%d min; nudged at %s). The lease is kept. Check the holder, message it, or move the work with `lease transfer %s --instance <id>` / `task hold %s`.", task.task_id, task.title, lease.holder_instance_id, last_at, silent_min, ms_to_rfc3339(nudged), task.task_id, task.task_id))
	timers_arm(svc, .Lease_Stalled, lease.lease_id, now + window, "")
	return .Acted
}

// lease_stall_notice_relevant (notice_still_relevant): the stalled lease's task
// still has a live work lease at send time.
lease_stall_notice_relevant :: proc(svc: ^Service, task: domain.Task) -> bool {
	leases, err := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if err.code != .None do return true
	for l in leases do if lease_watched(l) do return true
	return false
}
