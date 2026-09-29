package app

import "core:time"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import shell_session_svc "odin_test:hub/service/shell_session"

// REAPER_STALE_MS mirrors the request-driven sweep threshold used on bridge
// heartbeats (http.BRIDGE_INSTANCE_STALE_MS = 90s): an instance still in an
// active runtime state whose last_seen_at is older than this is flipped to
// "unreachable". Kept generously above the ~2s heartbeat cadence so a briefly
// slow bridge is never falsely reaped.
REAPER_STALE_MS :: 90_000

// DEFAULT_REAPER_INTERVAL_SECONDS is used when the configured interval is <= 0.
DEFAULT_REAPER_INTERVAL_SECONDS :: 20

// REAPER_BRIDGE_GONE_MS is how long a bridge must go UNHEARD-FROM before the hub
// declares it gone for good and lands a terminal status on its live shell sessions
// (REQ-SHELL-14, core invariant (b) for the never-came-back case).
//
// IT IS DELIBERATELY FAR ABOVE THE LIVENESS THRESHOLDS, and not a reuse of them.
// REAPER_STALE_MS (90s) and http.BRIDGE_INSTANCE_STALE_MS answer "is it responding
// right now". This answers "is it never coming back", a categorically stronger claim
// about a remote machine, so it must not borrow their number: at 45s heartbeats, 90s
// is two missed beats, which is a blip.
//
// THE TRIGGER IS ABSENCE OVER TIME, NEVER "DISCONNECTED". Three call sites in this
// codebase deliberately CONVERT rather than kill on a WS drop, because a drop is
// usually transient with the child processes alive; reacting to disconnect here would
// reintroduce exactly the destroyed-in-flight-work failure those sites exist to
// prevent — a 20-minute build killed by a network hiccup.
//
// WHY ONE HOUR, in both directions, because the next reader will be tempted to tighten
// it and that is the dangerous way to be wrong:
//   TOO SHORT destroys real work. A long outage on a live bridge would mark running
//     sessions failed while their processes are fine.
//   TOO LONG only leaves a row stale for longer.
// Those costs are NOT symmetric, and the asymmetry is what picks the number: because
// REQ-SHELL-10's inventory diff REVIVES a session the hub wrongly called terminal once
// the bridge returns with the process alive, being early is bounded and self-healing,
// while being late costs only staleness. An hour is comfortably longer than any
// plausible partition or bridge restart, and short enough that a genuinely dead
// bridge's rows do not advertise themselves as live for a working day.
// That revive is a CONDITION on this constant, not a bonus: if it ever stops firing for
// hub-synthesized rows, this threshold becomes destructive rather than conservative.
// It is asserted by test for exactly that reason.
REAPER_BRIDGE_GONE_MS :: 60 * 60 * 1000

// REAPER_LIVE_BRIDGE_IDS_MAX bounds the candidate listing, a runaway backstop rather
// than pagination — mirroring SHELL_SESSION_INVENTORY_MAX_ROWS. The query already
// narrows to bridges HOLDING LIVE SESSIONS, which is small; this only stops a
// pathological table from allocating without limit on a 20-second loop.
REAPER_LIVE_BRIDGE_IDS_MAX :: 1024

// reaper_loop is the periodic background safety net for stale agent instances.
//
// Why it exists: the hub's staleness reap was REQUEST-DRIVEN only — it ran on
// inbound bridge heartbeats. If a whole bridge dies and never reconnects, no
// heartbeat arrives, so its instances stay runtime_status='running' forever
// (the clean-disconnect cascade in bridge_ws_disconnect covers an observed WS
// close, but not a hub restart with a persisted DB, a silently half-open
// connection, or a lost close). This loop re-evaluates staleness on a fixed
// cadence independent of bridge traffic and flips stranded instances to
// 'unreachable', publishing resource_changed so the UI self-heals live.
//
// Thread-safety: this runs in its own process-scoped thread (launched from
// app.run before the blocking http.serve). It uses the EXACT same access
// pattern the HTTP request threads already use concurrently — the server spawns
// one thread per client, all sharing graph.agents + graph.event_bus with no
// mutex, and request handlers already call agent_service.reap_stale_instances +
// events.publish_resource_changed. So this adds no new shared-state contract.
reaper_loop :: proc(graph: ^App_Graph) {
	if graph == nil do return
	interval := graph.config.reaper_interval_seconds
	if interval <= 0 do interval = DEFAULT_REAPER_INTERVAL_SECONDS
	for {
		time.sleep(time.Duration(interval) * time.Second)
		reaper_sweep_once(graph)
	}
}

// reaper_sweep_once performs a single stale-instance sweep + event fan-out. Split
// out from the loop so it stays trivially callable/testable and so app.run can
// launch reaper_loop as a thread entry point.
reaper_sweep_once :: proc(graph: ^App_Graph) {
	if graph == nil do return

	// REQ-SHELL-8 item 6: terminal shell_sessions rows past their retention window.
	// It rides THIS sweep rather than bringing its own timer — the loop already runs
	// on a cadence, and a second thread walking the same table would be the polling
	// the shells redesign exists to remove. Deliberately one call, for REQ-SHELL-9's
	// server reaping to extend rather than duplicate.
	//
	// A failure here is logged by neither side on purpose: retention is a best-effort
	// tidy-up, the next tick retries it unchanged, and letting it abort the sweep
	// would take the stale-instance reap down with it — the safety net this loop
	// actually exists for.
	_, _ = shell_session_svc.shell_session_sweep_terminal_rows(&graph.shell_session_service)

	// REQ-SHELL-14: sessions on a bridge that is never coming back. Rides THIS sweep
	// for the same reason the retention pass above does — the loop already runs, and a
	// second thread walking the same table would be the polling the shells redesign
	// exists to remove. Like retention, a failure is swallowed rather than allowed to
	// abort the stale-instance reap below, which is the safety net this loop is for.
	reaper_sweep_gone_bridges(graph)

	reaped := agent_service.reap_stale_instances(&graph.agents, REAPER_STALE_MS)
	defer domain.agent_instances_destroy(reaped)
	for inst in reaped {
		// REQ-SHELL-2 §9: the staleness sweep is the third and last liveness signal,
		// and it gets the same rule as the other two — a foreground run whose agent
		// is gone becomes a background run, so it stays tracked and reapable instead
		// of blocking for a caller that no longer exists.
		shell_session_svc.shell_session_background_runs_for_agent(&graph.shell_session_service, string(inst.owner_user_id), inst.agent_instance_id)
		summary := http.agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
		events.publish_resource_changed(
			&graph.event_bus,
			string(inst.owner_user_id),
			"agent_instance",
			inst.agent_instance_id,
			"status_changed",
			summary,
		)
		delete(summary)
	}
}

// reaper_sweep_gone_bridges lands a terminal status on the live shell sessions of every
// bridge the hub has not heard from for longer than REAPER_BRIDGE_GONE_MS.
//
// Split out and exported for the same reason reaper_sweep_once is: it must be callable
// from a test directly, with injected timestamps rather than by waiting an hour.
//
// SHAPE, and why it is this way round. It asks the SESSION table which bridges hold live
// rows, then asks each of those bridges how long it has been absent — not the reverse.
// The candidate set is therefore bounded by what can actually need reaping rather than
// by every bridge ever enrolled, and a bridge with nothing running costs one query row
// and no bridge read at all. On a 20-second loop that difference is the whole design.
//
// THE AGE TEST LIVES HERE, IN ODIN, NOT IN SQL. That mirrors reap_stale_instances, which
// likewise takes a candidate set from the repository and judges age itself, and it keeps
// the threshold next to the comment that justifies it instead of splitting the rule
// between a constant and a WHERE clause.
//
// MEMORY: this runs on the process-scoped reaper thread, which has NO per-request arena,
// so every HEAP allocation here is freed explicitly — the bridge id list and each id in
// it, and each cloned last_seen_at. Nothing is left for a later pass to tidy, because
// there is no later pass; a leak here would accumulate every 20 seconds forever.
// The word HEAP is load-bearing: the one value on this path that is NOT a heap block is
// the clock_now timestamp, and freeing it is a crash rather than a tidy-up. See below.
reaper_sweep_gone_bridges :: proc(graph: ^App_Graph) -> int {
	if graph == nil do return 0
	// BORROWED, NEVER DELETED. platform.clock_now bottoms out in fmt.tprintf
	// (platform/clock.odin:format_rfc3339_utc), so what it returns lives in the TEMP
	// allocator's arena and was never a heap block. Handing it to delete() frees a
	// non-heap pointer through the heap allocator — an invalid free, not a tidy-up.
	// shell_session_apply_inventory carries the same comment because it made exactly
	// this mistake once, and there bridge RECONNECT was the trigger; here it would be
	// every 20 seconds, forever.
	//
	// So this is the one clock_now on this path that must NOT be freed, and it is the
	// exception to the free-everything rule the rest of this sweep follows: the rule is
	// about HEAP allocations, and this is not one. Nothing below needs `now` to outlive
	// the call — reaper_reap_gone_bridges only parses it to an i64.
	//
	// The temp arena itself is never reset on this thread. That is a real, separate
	// concern (it predates this code: shell_session_delete_terminal_before_sqlite has
	// done the same since REQ-SHELL-8), filed as its own issue — but a 20-byte string
	// left in an arena is a leak, while delete() on it is a crash.
	now_str := platform.clock_now(&graph.clock)
	return reaper_reap_gone_bridges(&graph.bridges, &graph.shell_session_service, now_str)
}

// reaper_reap_gone_bridges is the sweep itself, taking the two services it actually
// needs instead of the whole App_Graph.
//
// IT IS SPLIT FROM THE GRAPH WRAPPER SO THE BLIP CASE IS TESTABLE. The regression this
// task must not cause — a bridge that merely blinked having its live sessions marked
// failed — can only be asserted by driving the sweep with a bridge that was seen
// recently and checking the rows are UNCHANGED. Threading a whole App_Graph into a test
// to prove that would mean standing up every repository in the hub, so the observable
// behaviour would go unasserted in practice. These two services and a timestamp are the
// entire input, and `now` being a parameter is what lets a test place a bridge an hour
// in the past without waiting an hour.
reaper_reap_gone_bridges :: proc(
	bridges:  ^bridge_service.Bridge_Service,
	sessions: ^shell_session_svc.Shell_Session_Service,
	now_str:  string,
) -> int {
	if bridges == nil || sessions == nil || sessions.repo == nil do return 0
	if now_str == "" do return 0
	now_ms, now_ok := agent_service.rfc3339_to_unix_ms(now_str)
	if !now_ok do return 0

	ids, err := iface.shell_session_list_live_bridge_ids(sessions.repo, REAPER_LIVE_BRIDGE_IDS_MAX)
	defer {
		for id in ids do delete(id)
		delete(ids)
	}
	if err.code != .None do return 0

	reaped := 0
	for id in ids {
		last_seen, eligible := bridge_service.bridge_absence_marker(bridges, id)
		defer delete(last_seen)
		if !eligible do continue
		if !reaper_bridge_absence_is_terminal(now_ms, last_seen) do continue
		reaped += shell_session_svc.shell_session_reap_gone_bridge(sessions, id, now_str)
	}
	return reaped
}

// reaper_bridge_absence_is_terminal is the age test itself: has this bridge been
// unheard-from for longer than REAPER_BRIDGE_GONE_MS?
//
// It is a separate, pure proc taking milliseconds and a timestamp rather than an inline
// comparison so the THRESHOLD DECISION is testable without a repository, a clock or a
// bridge — a test can assert directly that 59 minutes is a blip and 61 is gone, which is
// the acceptance criterion this task is judged on.
//
// AN UNPARSEABLE last_seen_at RETURNS FALSE, i.e. NOT gone. That direction is chosen
// deliberately: the failure mode of guessing "gone" from a timestamp we could not read
// is marking live sessions failed, which is the destructive direction the whole design
// avoids. Skipping mirrors reap_stale_instances, which likewise skips an instance whose
// last_seen_at will not parse rather than misclassifying it.
//
// A FUTURE-DATED last_seen_at is also NOT gone, which falls out of the signed
// comparison: clock skew between hub and bridge should never manufacture absence.
reaper_bridge_absence_is_terminal :: proc(now_ms: i64, last_seen_at: string) -> bool {
	seen_ms, ok := agent_service.rfc3339_to_unix_ms(last_seen_at)
	if !ok do return false
	return now_ms - seen_ms >= REAPER_BRIDGE_GONE_MS
}
