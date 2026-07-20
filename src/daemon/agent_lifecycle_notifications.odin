package main

import "core:fmt"
import "core:strings"

// Agent_Lifecycle_Event_Fields is the shared field set for an
// agent_lifecycle_changed event. Both the live-registry emit (agent_lifecycle_emit)
// and the remote-proxy emit (agent_proxy_status_emit) populate this struct and
// call agent_lifecycle_changed_write so the wire shape cannot drift between them.
Agent_Lifecycle_Event_Fields :: struct {
	agent_instance_id: string,
	agent_class: string,
	display_name: string,
	connected: bool,
	connection_state: string,
	reason: string,
	last_seen_unix_ms: i64,
	startup_status: string,
	reason_code: string,
	safe_diagnostic: string,
	provider_profile: string,
	run_dir: string,
	tmux_pane: string,
	activity_status: string,
	activity_source: string,
	activity_checked_unix_ms: i64,
	exec_state: string,
	exec_state_since_unix_ms: i64,
	blocked_reason: string,
	stop_timeout_seconds: int,
	stop_requested_unix_ms: i64,
	project_id: string,
	project_name: string,
	model_tier: string,
	current_task_id: string,
	current_task_since: i64,
	state: string,
	agent_kind: string,
}

// agent_lifecycle_changed_write serializes the common agent_lifecycle_changed
// object. `extra_json` (e.g. `"remote":{...}`) is appended before the closing
// brace so proxy-specific blocks can extend the shared shape without forking it.
agent_lifecycle_changed_write :: proc(builder: ^strings.Builder, f: Agent_Lifecycle_Event_Fields, extra_json: string = "") {
	strings.write_string(builder, `{"type":"agent_lifecycle_changed","agent_instance_id":"`); json_write_string(builder, f.agent_instance_id)
	strings.write_string(builder, `","target_agent_instance_id":"`); json_write_string(builder, f.agent_instance_id)
	strings.write_string(builder, `","fetch_required":false`)
	strings.write_string(builder, `,"agent_class":"`); json_write_string(builder, f.agent_class)
	strings.write_string(builder, `","display_name":"`); json_write_string(builder, f.display_name)
	strings.write_string(builder, `","connected":`); strings.write_string(builder, "true" if f.connected else "false")
	strings.write_string(builder, `,"connection_state":"`); json_write_string(builder, f.connection_state)
	strings.write_string(builder, `","reason":"`); json_write_string(builder, f.reason)
	strings.write_string(builder, `","last_seen_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", f.last_seen_unix_ms))
	strings.write_string(builder, `,"startup_status":"`); json_write_string(builder, f.startup_status)
	strings.write_string(builder, `","reason_code":"`); json_write_string(builder, f.reason_code)
	strings.write_string(builder, `","safe_diagnostic":"`); json_write_string(builder, f.safe_diagnostic)
	strings.write_string(builder, `","provider_profile":"`); json_write_string(builder, f.provider_profile)
	strings.write_string(builder, `","run_dir":"`); json_write_string(builder, f.run_dir)
	strings.write_string(builder, `","tmux_pane":"`); json_write_string(builder, f.tmux_pane)
	strings.write_string(builder, `","activity_status":"`); json_write_string(builder, f.activity_status)
	strings.write_string(builder, `","activity_source":"`); json_write_string(builder, f.activity_source)
	strings.write_string(builder, `","activity_checked_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", f.activity_checked_unix_ms))
	strings.write_string(builder, `,"exec_state":"`); json_write_string(builder, f.exec_state)
	strings.write_string(builder, `","exec_state_since_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", f.exec_state_since_unix_ms))
	strings.write_string(builder, `,"blocked_reason":"`); json_write_string(builder, f.blocked_reason)
	strings.write_string(builder, `","stop_timeout_seconds":`); strings.write_string(builder, fmt.tprintf("%d", f.stop_timeout_seconds))
	strings.write_string(builder, `,"stop_requested_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", f.stop_requested_unix_ms))
	strings.write_string(builder, `,"project_id":"`); json_write_string(builder, f.project_id)
	strings.write_string(builder, `","project_name":"`); json_write_string(builder, f.project_name)
	strings.write_string(builder, `","model_tier":"`); json_write_string(builder, f.model_tier)
	strings.write_string(builder, `","current_task_id":"`); json_write_string(builder, f.current_task_id)
	strings.write_string(builder, `","current_task_since":`); strings.write_string(builder, fmt.tprintf("%d", f.current_task_since))
	strings.write_string(builder, `,"state":"`); json_write_string(builder, f.state)
	strings.write_string(builder, `","agent_kind":"`); json_write_string(builder, f.agent_kind if f.agent_kind != "" else AGENT_KIND_LOCAL)
	strings.write_string(builder, `"`)
	if extra_json != "" {
		strings.write_string(builder, `,`)
		strings.write_string(builder, extra_json)
	}
	strings.write_string(builder, `}`)
}

agent_lifecycle_emit :: proc(agent_instance_id, connection_state, reason: string) {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return
	agent := agents[idx]
	// Test agents never emit production lifecycle events; their lifecycle is
	// tracked separately in test_runs and broadcast as test_start / test_done.
	if is_test_token(agent.agent_token) {
		test_run_on_lifecycle(agent.agent_token, connection_state, reason)
		return
	}
	// Include project_id / project_name / model_tier so the UI doesn't lose them
	// when the event arrives (lifecycle events were dropping these by overwriting
	// the cached agent record with empty strings).
	project_name := ""
	model_tier := ""
	project_id := agent.project_id
	current_task_id := ""
	current_task_since: i64 = 0
	state := "idle"
	agent_kind := AGENT_KIND_LOCAL
	if pidx := agent_record_index_by_instance(agent.agent_instance_id); pidx >= 0 {
		rec := agent_instance_records[pidx]
		if project_id == "" do project_id = rec.project_id
		model_tier = rec.model_tier
		current_task_id = rec.current_task_id
		current_task_since = rec.current_task_since
		state = agent_store_agent_state(rec)
		agent_kind = agent_kind_normalize(rec.agent_kind)
		if rec.project_id != "" {
			if pj := project_index(rec.project_id); pj >= 0 do project_name = project_records[pj].name
		}
	}
	builder := strings.builder_make()
	agent_lifecycle_changed_write(&builder, Agent_Lifecycle_Event_Fields{
		agent_instance_id = agent.agent_instance_id,
		agent_class = agent.agent_class,
		display_name = agent.display_name,
		connected = agent.connected,
		connection_state = connection_state,
		reason = reason,
		last_seen_unix_ms = agent.last_seen_unix_ms,
		startup_status = agent.startup_status,
		reason_code = agent.startup_reason_code,
		safe_diagnostic = agent.startup_safe_diagnostic,
		provider_profile = agent.provider_profile,
		run_dir = agent.run_dir,
		tmux_pane = agent.tmux_pane,
		activity_status = agent.activity_status,
		activity_source = agent.activity_source,
		activity_checked_unix_ms = agent.activity_checked_unix_ms,
		exec_state = agent.exec_state,
		exec_state_since_unix_ms = agent.exec_state_since_unix_ms,
		blocked_reason = agent.blocked_reason,
		stop_timeout_seconds = agent.stop_timeout_seconds,
		stop_requested_unix_ms = agent.stop_requested_unix_ms,
		project_id = project_id,
		project_name = project_name,
		model_tier = model_tier,
		current_task_id = current_task_id,
		current_task_since = current_task_since,
		state = state,
		agent_kind = agent_kind,
	})
	user_client_fanout_all_ws_text(strings.to_string(builder))
}

// agent_runtime_emit broadcasts when a wrapper heartbeat changed any runtime
// or session field (pid, tmux_pane, exec_state, blocked_reason, run_dir).
// Identity/configuration changes go through agent_lifecycle_emit instead.
agent_runtime_emit :: proc(agent_instance_id, reason: string) {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return
	agent := agents[idx]
	if is_test_token(agent.agent_token) do return
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"agent_runtime_changed","agent_instance_id":"`); json_write_string(&b, agent.agent_instance_id)
	strings.write_string(&b, `","target_agent_instance_id":"`); json_write_string(&b, agent.agent_instance_id)
	strings.write_string(&b, `","fetch_required":false`)
	strings.write_string(&b, `,"reason":"`); json_write_string(&b, reason)
	strings.write_string(&b, `","tmux_pane":"`); json_write_string(&b, agent.tmux_pane)
	strings.write_string(&b, `","pid":`); strings.write_string(&b, fmt.tprintf("%d", agent.pid))
	strings.write_string(&b, `,"exec_state":"`); json_write_string(&b, agent.exec_state)
	strings.write_string(&b, `","exec_state_since_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", agent.exec_state_since_unix_ms))
	strings.write_string(&b, `,"blocked_reason":"`); json_write_string(&b, agent.blocked_reason)
	strings.write_string(&b, `","run_dir":"`); json_write_string(&b, agent.run_dir)
	strings.write_string(&b, `","activity_status":"`); json_write_string(&b, agent.activity_status)
	strings.write_string(&b, `","activity_source":"`); json_write_string(&b, agent.activity_source)
	strings.write_string(&b, `","activity_checked_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", agent.activity_checked_unix_ms))
	strings.write_string(&b, `,"last_seen_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", agent.last_seen_unix_ms))
	strings.write_string(&b, `}`)
	user_client_fanout_all_ws_text(strings.to_string(b))
}
