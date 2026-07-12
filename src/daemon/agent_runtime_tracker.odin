package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"

AGENT_TRACKER_MAX :: 1024
AGENT_TRACKER_LAUNCH_TIMEOUT_MS :: i64(60_000)
AGENT_TRACKER_HEARTBEAT_FRESH_MS :: i64(30_000)

Agent_Runtime_State :: enum {
	Not_Running,
	Launching,
	Running,
}

Agent_Runtime_Record :: struct {
	agent_instance_id: string,
	state: Agent_Runtime_State,
	launch_token: string,
	launch_source: string,
	launch_task_id: string,
	launch_started_unix_ms: i64,
	last_observed_unix_ms: i64,
}

agent_runtime_tracker_records: [AGENT_TRACKER_MAX]Agent_Runtime_Record
agent_runtime_tracker_count: int
agent_runtime_tracker_mutex: sync.Mutex

agent_runtime_tracker_init :: proc() {
	agent_runtime_tracker_records = [AGENT_TRACKER_MAX]Agent_Runtime_Record{}
	agent_runtime_tracker_count = 0
	agent_runtime_tracker_mutex = sync.Mutex{}
}

agent_runtime_tracker_index_locked :: proc(agent_instance_id: string) -> int {
	for i in 0..<agent_runtime_tracker_count {
		if agent_runtime_tracker_records[i].agent_instance_id == agent_instance_id do return i
	}
	return -1
}

agent_runtime_tracker_index_or_add_locked :: proc(agent_instance_id: string) -> int {
	if idx := agent_runtime_tracker_index_locked(agent_instance_id); idx >= 0 do return idx
	if agent_runtime_tracker_count >= AGENT_TRACKER_MAX do return -1
	idx := agent_runtime_tracker_count
	agent_runtime_tracker_count += 1
	agent_runtime_tracker_records[idx] = Agent_Runtime_Record{
		agent_instance_id = strings.clone(agent_instance_id),
		state = .Not_Running,
	}
	return idx
}

agent_runtime_tracker_observed_state_unlocked :: proc(agent_instance_id: string, now: i64) -> Agent_Runtime_State {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return .Not_Running
	ag := agents[idx]
	fresh := ag.last_seen_unix_ms > 0 && now - ag.last_seen_unix_ms <= AGENT_TRACKER_HEARTBEAT_FRESH_MS
	if ag.connected && ag.has_ws && fresh && ag.startup_status == "ready" do return .Running
	if ag.startup_status == "starting" && fresh do return .Launching
	return .Not_Running
}

agent_runtime_tracker_note_stale_registry_unlocked :: proc(agent_instance_id, reason: string, now: i64) {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return
	ag := &agents[idx]
	if ag.has_ws {
		net.shutdown(ag.ws_socket, .Both)
		net.close(ag.ws_socket)
	}
	was_stale := ag.connected || ag.has_ws || ag.startup_status == "ready" || ag.startup_status == "starting" || ag.exec_state != ""
	ag.connected = false
	ag.has_ws = false
	ag.last_seen_unix_ms = now
	ag.startup_status = "startup_unknown"
	ag.startup_reason_code = strings.clone(reason)
	ag.startup_safe_diagnostic = strings.clone("Agent runtime tracker cleared stale/non-deliverable runtime state")
	ag.startup_updated_unix_ms = now
	ag.exec_state = ""
	ag.exec_state_since_unix_ms = 0
	ag.blocked_reason = ""
	if was_stale {
		fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=stale_runtime_cleared agent=%s reason=%s connected=false has_ws=false", now, agent_instance_id, reason)
		agent_lifecycle_emit(agent_instance_id, "not_running", reason)
	}
}

agent_runtime_tracker_running :: proc(agent_instance_id: string) -> bool {
	now := router_now_unix_ms()
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	defer sync.mutex_unlock(&agent_runtime_tracker_mutex)
	return agent_runtime_tracker_observed_state_unlocked(agent_instance_id, now) == .Running
}

agent_runtime_tracker_is_launching :: proc(agent_instance_id: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		return agents[idx].startup_status == "starting"
	}
	return false
}

agent_runtime_tracker_has_ws :: proc(agent_instance_id: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		return agents[idx].has_ws
	}
	return false
}

agent_runtime_tracker_is_stopping :: proc(agent_instance_id: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		agent := agents[idx]
		return agent.stop_requested_unix_ms != 0 || agent.startup_status == "stopping"
	}
	return false
}

agent_runtime_tracker_startup_failure_reason :: proc(agent_instance_id: string) -> string {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		if agents[idx].startup_status == "startup_failed" do return agents[idx].startup_reason_code
	}
	return ""
}

agent_runtime_tracker_lifecycle_status :: proc(agent_instance_id: string) -> string {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		agent := agents[idx]
		if agent.connected || agent.has_ws do return "connected"
		if agent_runtime_tracker_is_stopping(agent_instance_id) do return "stopping"
		if agent.startup_status == "starting" do return "starting"
		if agent.startup_status == "startup_blocked" do return "startup_blocked"
		if agent.startup_status == "startup_failed" do return "startup_failed"
		if agent.startup_status == "ready" do return "ready"
		if agent.startup_status == "stopped" do return "stopped"
		return "idle"
	}
	return "offline"
}

agent_runtime_tracker_agent_state :: proc(agent_instance_id: string, has_current_task: bool) -> string {
	if registry_find_agent(agent_instance_id) >= 0 {
		if agent_runtime_tracker_is_stopping(agent_instance_id) do return "shutting_down"
		if idx := registry_find_agent(agent_instance_id); idx >= 0 {
			agent := agents[idx]
			if agent.blocked_reason != "" || agent.exec_state == "blocked" do return "blocked"
		}
		if has_current_task do return "live"
		if agent_runtime_tracker_is_launching(agent_instance_id) do return "warming"
		return "idle"
	}
	if has_current_task do return "live"
	return "idle"
}

agent_runtime_tracker_try_begin_launch :: proc(agent_instance_id, launch_token, reason, task_id: string, now: i64) -> bool {
	if agent_instance_id == "" do return false
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	defer sync.mutex_unlock(&agent_runtime_tracker_mutex)

	idx := agent_runtime_tracker_index_or_add_locked(agent_instance_id)
	if idx < 0 {
		fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=launch_rejected agent=%s reason=%s reject=tracker_full", now, agent_instance_id, reason)
		return false
	}
	rec := &agent_runtime_tracker_records[idx]
	observed := agent_runtime_tracker_observed_state_unlocked(agent_instance_id, now)
	if observed == .Running {
		rec.state = .Running
		rec.last_observed_unix_ms = now
		fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=launch_coalesced agent=%s reason=%s state=running", now, agent_instance_id, reason)
		return false
	}
	if rec.state == .Launching && now - rec.launch_started_unix_ms <= AGENT_TRACKER_LAUNCH_TIMEOUT_MS {
		fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=launch_coalesced agent=%s reason=%s state=launching source=%s task=%s age_ms=%d", now, agent_instance_id, reason, rec.launch_source, rec.launch_task_id, now - rec.launch_started_unix_ms)
		return false
	}

	// Ready/running metadata without a deliverable WS is not live. Clear it so
	// the rest of the daemon cannot keep suppressing recovery launches.
	agent_runtime_tracker_note_stale_registry_unlocked(agent_instance_id, reason, now)

	rec.state = .Launching
	rec.launch_token = strings.clone(launch_token)
	rec.launch_source = strings.clone(reason)
	rec.launch_task_id = strings.clone(task_id)
	rec.launch_started_unix_ms = now
	rec.last_observed_unix_ms = now
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=launch_begin agent=%s reason=%s task=%s", now, agent_instance_id, reason, task_id)
	return true
}

agent_runtime_tracker_launch_failed :: proc(agent_instance_id, launch_token, reason: string) {
	now := router_now_unix_ms()
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	defer sync.mutex_unlock(&agent_runtime_tracker_mutex)
	idx := agent_runtime_tracker_index_locked(agent_instance_id)
	if idx < 0 do return
	rec := &agent_runtime_tracker_records[idx]
	if rec.launch_token != "" && launch_token != "" && rec.launch_token != launch_token do return
	rec.state = .Not_Running
	rec.launch_token = ""
	rec.last_observed_unix_ms = now
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=launch_failed agent=%s reason=%s", now, agent_instance_id, reason)
}

agent_runtime_tracker_register_allowed :: proc(agent_instance_id, agent_token: string) -> bool {
	now := router_now_unix_ms()
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	defer sync.mutex_unlock(&agent_runtime_tracker_mutex)
	idx := agent_runtime_tracker_index_locked(agent_instance_id)
	if idx < 0 do return true
	rec := &agent_runtime_tracker_records[idx]
	if rec.state == .Launching && rec.launch_token != "" && agent_token != rec.launch_token && now - rec.launch_started_unix_ms <= AGENT_TRACKER_LAUNCH_TIMEOUT_MS {
		fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=register_rejected_superseded agent=%s incoming_token_prefix=%s current_token_prefix=%s", now, agent_instance_id, agent_runtime_tracker_token_prefix(agent_token), agent_runtime_tracker_token_prefix(rec.launch_token))
		return false
	}
	return true
}

agent_runtime_tracker_clear_stop_request :: proc(agent_instance_id, source: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		changed := agents[idx].stop_requested_unix_ms != 0 || agents[idx].stop_timeout_seconds != 0
		agents[idx].stop_requested_unix_ms = 0
		agents[idx].stop_timeout_seconds = 0
		if changed do fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=stop_request_cleared agent=%s source=%s", router_now_unix_ms(), agent_instance_id, source)
		return changed
	}
	return false
}

agent_runtime_tracker_request_stop :: proc(agent_instance_id: string, time_in_sec: int, reason: string) -> (bool, int, string) {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 {
		fmt.printf("WARNING: stop_agent failed: agent '%s' not found in registry\n", agent_instance_id)
		return false, 404, `{"ok":false,"message":"agent not found"}`
	}
	if agents[idx].stop_requested_unix_ms != 0 {
		fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=stop_requested_duplicate agent=%s reason=%s", router_now_unix_ms(), agent_instance_id, reason)
		return true, 200, `{"ok":true,"already":true}`
	}
	if !agents[idx].has_ws {
		fmt.printf("WARNING: stop_agent failed: agent '%s' has no active WebSocket connection (connected=%t)\n", agent_instance_id, agents[idx].connected)
		return false, 400, `{"ok":false,"message":"agent not connected via WebSocket"}`
	}
	payload := stop_event_json(agent_instance_id, time_in_sec)
	if !registry_send_ws_text(agent_instance_id, payload) {
		fmt.printf("ERROR: stop_agent failed: failed to deliver stop event to agent '%s' over WebSocket\n", agent_instance_id)
		return false, 500, `{"ok":false,"message":"failed to deliver stop event to agent"}`
	}
	agents[idx].stop_timeout_seconds = time_in_sec
	agents[idx].stop_requested_unix_ms = router_now_unix_ms()
	registry_update_startup(agent_instance_id, "stopping", "stop_requested", "Stop event sent to agent", "", "", "")
	agent_lifecycle_emit(agent_instance_id, "stopping", "stop_requested")

	sync.mutex_lock(&agent_runtime_tracker_mutex)
	if rec_idx := agent_runtime_tracker_index_or_add_locked(agent_instance_id); rec_idx >= 0 {
		rec := &agent_runtime_tracker_records[rec_idx]
		rec.state = .Not_Running
		rec.last_observed_unix_ms = router_now_unix_ms()
	}
	sync.mutex_unlock(&agent_runtime_tracker_mutex)
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=stop_requested agent=%s reason=%s timeout_sec=%d", router_now_unix_ms(), agent_instance_id, reason, time_in_sec)
	return true, 200, `{"ok":true}`
}

agent_runtime_tracker_observe_stop_done :: proc(agent_instance_id, reason: string) {
	_ = agent_runtime_tracker_clear_stop_request(agent_instance_id, reason)
	registry_update_startup(agent_instance_id, "stopped", "stop_done", "Agent stopped gracefully", "", "", "")
	registry_clear_ws(agent_instance_id)
	agent_runtime_tracker_observe_disconnected(agent_instance_id, "stop_done")
	agent_lifecycle_emit(agent_instance_id, "offline", "stop_done")
}

agent_runtime_tracker_observe_register :: proc(agent_instance_id, agent_token: string) {
	now := router_now_unix_ms()
	_ = agent_runtime_tracker_clear_stop_request(agent_instance_id, "register")
	if reg_idx := registry_find_agent(agent_instance_id); reg_idx >= 0 {
		if agents[reg_idx].startup_status == "stopping" || agents[reg_idx].startup_status == "stopped" || agents[reg_idx].startup_reason_code == "stop_requested" || agents[reg_idx].startup_reason_code == "stop_done" {
			agents[reg_idx].startup_status = "starting"
			agents[reg_idx].startup_reason_code = "register"
			agents[reg_idx].startup_safe_diagnostic = "Agent registered after previous stop"
			agents[reg_idx].startup_updated_unix_ms = now
		}
	}
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	defer sync.mutex_unlock(&agent_runtime_tracker_mutex)
	idx := agent_runtime_tracker_index_or_add_locked(agent_instance_id)
	if idx < 0 do return
	rec := &agent_runtime_tracker_records[idx]
	if rec.state != .Launching || rec.launch_token == "" {
		rec.state = .Launching
		rec.launch_token = strings.clone(agent_token)
		rec.launch_source = "register"
		rec.launch_started_unix_ms = now
	}
	rec.last_observed_unix_ms = now
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=register_observed agent=%s state=%v", now, agent_instance_id, rec.state)
}

agent_runtime_tracker_observe_ws_connected :: proc(agent_instance_id: string, socket: net.TCP_Socket) -> bool {
	if !registry_set_ws(agent_instance_id, socket) do return false
	now := router_now_unix_ms()
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	idx := agent_runtime_tracker_index_or_add_locked(agent_instance_id)
	if idx >= 0 {
		rec := &agent_runtime_tracker_records[idx]
		if rec.state == .Not_Running do rec.state = .Launching
		rec.last_observed_unix_ms = now
		fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=ws_connected agent=%s state=%v", now, agent_instance_id, rec.state)
	}
	sync.mutex_unlock(&agent_runtime_tracker_mutex)
	agent_lifecycle_emit(agent_instance_id, "connected", "websocket_connected")
	return true
}

agent_runtime_tracker_observe_ready_or_heartbeat :: proc(agent_instance_id, source: string) {
	now := router_now_unix_ms()
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	defer sync.mutex_unlock(&agent_runtime_tracker_mutex)
	idx := agent_runtime_tracker_index_or_add_locked(agent_instance_id)
	if idx < 0 do return
	rec := &agent_runtime_tracker_records[idx]
	observed := agent_runtime_tracker_observed_state_unlocked(agent_instance_id, now)
	if observed == .Running {
		_ = agent_runtime_tracker_clear_stop_request(agent_instance_id, source)
		rec.state = .Running
	} else if observed == .Launching {
		_ = agent_runtime_tracker_clear_stop_request(agent_instance_id, source)
		rec.state = .Launching
	} else {
		rec.state = .Not_Running
	}
	rec.last_observed_unix_ms = now
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=%s agent=%s observed=%v state=%v", now, source, agent_instance_id, observed, rec.state)
}

agent_runtime_tracker_apply_startup_report :: proc(agent_instance_id, status, reason_code, safe_diagnostic, provider_profile, run_dir, tmux_pane: string) -> bool {
	if !registry_update_startup(agent_instance_id, status, reason_code, safe_diagnostic, provider_profile, run_dir, tmux_pane) do return false
	if status == "starting" || status == "ready" do _ = agent_runtime_tracker_clear_stop_request(agent_instance_id, "startup_report")
	agent_runtime_tracker_observe_ready_or_heartbeat(agent_instance_id, "startup_report")
	agent_lifecycle_emit(agent_instance_id, status, "startup_report")
	return true
}

agent_runtime_tracker_apply_heartbeat_snapshot :: proc(snap: Heartbeat_Snapshot) -> (runtime_changed: bool, lifecycle_changed: bool) {
	was_live := registry_agent_live(snap.agent_instance_id)
	runtime_changed, lifecycle_changed = registry_apply_heartbeat_snapshot(snap)
	agent_runtime_tracker_observe_ready_or_heartbeat(snap.agent_instance_id, "heartbeat")
	if !was_live || lifecycle_changed {
		agent_lifecycle_emit(snap.agent_instance_id, "connected", "heartbeat")
	}
	if runtime_changed do agent_runtime_emit(snap.agent_instance_id, "heartbeat")
	return
}

agent_runtime_tracker_observe_start_success :: proc(agent_instance_id: string) -> bool {
	now := router_now_unix_ms()
	if !registry_update_startup(agent_instance_id, "ready", "start_success", "Agent reported ready via start-success RPC", "", "", "") do return false
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		agents[idx].connected = true
		agents[idx].startup_updated_unix_ms = now
	}
	_ = agent_runtime_tracker_clear_stop_request(agent_instance_id, "start_success")
	observed: Agent_Runtime_State = .Launching
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	if idx := agent_runtime_tracker_index_or_add_locked(agent_instance_id); idx >= 0 {
		rec := &agent_runtime_tracker_records[idx]
		observed = agent_runtime_tracker_observed_state_unlocked(agent_instance_id, now)
		if observed == .Running {
			rec.state = .Running
		} else {
			rec.state = .Launching
		}
		rec.last_observed_unix_ms = now
	}
	sync.mutex_unlock(&agent_runtime_tracker_mutex)
	agent_lifecycle_emit(agent_instance_id, "connected", "start_success")
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=start_success agent=%s observed=%v", now, agent_instance_id, observed)
	return true
}

agent_runtime_tracker_observe_ws_disconnected :: proc(agent_instance_id: string, socket: net.TCP_Socket, reason: string) -> bool {
	if !registry_clear_ws_if_socket(agent_instance_id, socket) do return false
	agent_runtime_tracker_observe_disconnected(agent_instance_id, reason)
	agent_lifecycle_emit(agent_instance_id, "disconnected", reason)
	return true
}

agent_runtime_tracker_observe_disconnected :: proc(agent_instance_id, reason: string) {
	now := router_now_unix_ms()
	sync.mutex_lock(&agent_runtime_tracker_mutex)
	defer sync.mutex_unlock(&agent_runtime_tracker_mutex)
	idx := agent_runtime_tracker_index_or_add_locked(agent_instance_id)
	if idx < 0 do return
	rec := &agent_runtime_tracker_records[idx]
	rec.state = .Not_Running
	rec.last_observed_unix_ms = now
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=disconnected agent=%s reason=%s", now, agent_instance_id, reason)
}

agent_runtime_tracker_apply_startup_timeout :: proc(agent_instance_id: string, timed_out_unix_ms: i64) -> bool {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return false
	agent := &agents[idx]
	if agent.startup_status != "starting" do return false

	agent.startup_status = "startup_failed"
	agent.startup_reason_code = "startup_stale"
	agent.startup_safe_diagnostic = "Agent did not report startup status within the configured timeout"
	agent.startup_updated_unix_ms = timed_out_unix_ms
	if !agent.has_ws do agent.connected = false
	agent_lifecycle_emit(agent_instance_id, "startup_failed", "startup_stale")
	fmt.printfln("AGENT_TRACKER ts_unix_ms=%d event=startup_timeout agent=%s", timed_out_unix_ms, agent_instance_id)
	return true
}

agent_runtime_tracker_apply_heartbeat_timeout :: proc(agent_instance_id: string) -> bool {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return false
	agent := &agents[idx]
	if !agent.connected do return false

	fmt.println("LIVENESS TIMEOUT: Agent", agent_instance_id, "has not sent heartbeats for 30s. Marking offline.")
	if agent.has_ws {
		net.close(agent.ws_socket)
		agent.has_ws = false
	}
	agent.connected = false
	agent.exec_state = "offline"
	agent_runtime_tracker_observe_disconnected(agent_instance_id, "heartbeat_timeout")
	agent_lifecycle_emit(agent_instance_id, "disconnected", "heartbeat_timeout")
	return true
}

agent_runtime_tracker_token_prefix :: proc(token: string) -> string {
	if len(token) <= 12 do return token
	return token[:12]
}
