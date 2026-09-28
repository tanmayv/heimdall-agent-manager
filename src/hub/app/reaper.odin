package app

import "core:time"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import http "odin_test:hub/transport/http"
import shell_session_svc "odin_test:hub/service/shell_session"

// REAPER_STALE_MS mirrors the request-driven sweep threshold used on bridge
// heartbeats (http.BRIDGE_INSTANCE_STALE_MS = 90s): an instance still in an
// active runtime state whose last_seen_at is older than this is flipped to
// "unreachable". Kept generously above the ~2s heartbeat cadence so a briefly
// slow bridge is never falsely reaped.
REAPER_STALE_MS :: 90_000

// DEFAULT_REAPER_INTERVAL_SECONDS is used when the configured interval is <= 0.
DEFAULT_REAPER_INTERVAL_SECONDS :: 20

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
