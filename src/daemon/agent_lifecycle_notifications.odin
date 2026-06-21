package main

import "core:fmt"
import "core:strings"

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
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"agent_lifecycle_changed","agent_instance_id":"`); json_write_string(&builder, agent.agent_instance_id)
	strings.write_string(&builder, `","agent_class":"`); json_write_string(&builder, agent.agent_class)
	strings.write_string(&builder, `","display_name":"`); json_write_string(&builder, agent.display_name)
	strings.write_string(&builder, `","connected":`); strings.write_string(&builder, "true" if agent.connected else "false")
	strings.write_string(&builder, `,"connection_state":"`); json_write_string(&builder, connection_state)
	strings.write_string(&builder, `","reason":"`); json_write_string(&builder, reason)
	strings.write_string(&builder, `","last_seen_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", agent.last_seen_unix_ms))
	strings.write_string(&builder, `,"startup_status":"`); json_write_string(&builder, agent.startup_status)
	strings.write_string(&builder, `","reason_code":"`); json_write_string(&builder, agent.startup_reason_code)
	strings.write_string(&builder, `","safe_diagnostic":"`); json_write_string(&builder, agent.startup_safe_diagnostic)
	strings.write_string(&builder, `","provider_profile":"`); json_write_string(&builder, agent.provider_profile)
	strings.write_string(&builder, `","run_dir":"`); json_write_string(&builder, agent.run_dir)
	strings.write_string(&builder, `","tmux_pane":"`); json_write_string(&builder, agent.tmux_pane)
	// Include project_id / project_name / model_tier so the UI doesn't lose them
	// when the event arrives (lifecycle events were dropping these by overwriting
	// the cached agent record with empty strings).
	project_name := ""
	model_tier := ""
	project_id := agent.project_id
	if pidx := agent_record_index_by_instance(agent.agent_instance_id); pidx >= 0 {
		rec := agent_instance_records[pidx]
		if project_id == "" do project_id = rec.project_id
		model_tier = rec.model_tier
		if rec.project_id != "" {
			if pj := project_index(rec.project_id); pj >= 0 do project_name = project_records[pj].name
		}
	}
	strings.write_string(&builder, `","project_id":"`); json_write_string(&builder, project_id)
	strings.write_string(&builder, `","project_name":"`); json_write_string(&builder, project_name)
	strings.write_string(&builder, `","model_tier":"`); json_write_string(&builder, model_tier)
	strings.write_string(&builder, `"}`)
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
	strings.write_string(&b, `","reason":"`); json_write_string(&b, reason)
	strings.write_string(&b, `","tmux_pane":"`); json_write_string(&b, agent.tmux_pane)
	strings.write_string(&b, `","pid":`); strings.write_string(&b, fmt.tprintf("%d", agent.pid))
	strings.write_string(&b, `,"exec_state":"`); json_write_string(&b, agent.exec_state)
	strings.write_string(&b, `","exec_state_since_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", agent.exec_state_since_unix_ms))
	strings.write_string(&b, `,"blocked_reason":"`); json_write_string(&b, agent.blocked_reason)
	strings.write_string(&b, `","run_dir":"`); json_write_string(&b, agent.run_dir)
	strings.write_string(&b, `","last_seen_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", agent.last_seen_unix_ms))
	strings.write_string(&b, `}`)
	user_client_fanout_all_ws_text(strings.to_string(b))
}
