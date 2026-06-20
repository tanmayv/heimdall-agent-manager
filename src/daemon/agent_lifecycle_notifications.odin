package main

import "core:fmt"
import "core:strings"

agent_lifecycle_emit :: proc(agent_instance_id, connection_state, reason: string) {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return
	agent := agents[idx]
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
	strings.write_string(&builder, `"}`)
	user_client_fanout_all_ws_text(strings.to_string(builder))
}
