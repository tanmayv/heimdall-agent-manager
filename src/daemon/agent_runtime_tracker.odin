package main

import "core:fmt"
import "core:net"
import "core:strings"

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
	agent.exec_state = strings.clone("offline")
	agent_lifecycle_emit(agent_instance_id, "disconnected", "heartbeat_timeout")
	return true
}
