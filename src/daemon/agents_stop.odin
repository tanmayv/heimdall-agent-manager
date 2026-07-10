package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

handle_agents_stop :: proc(client: net.TCP_Socket, body: string, request: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	time_in_sec := extract_json_int(body, "time_in_sec", 0)
	if time_in_sec == 0 {
		time_str := query_param(request, "time_in_sec")
		if time_str != "" {
			if parsed, ok := strconv.parse_int(time_str); ok do time_in_sec = parsed
		}
	}
	if time_in_sec <= 0 do time_in_sec = 30

	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_instance_id required"}`)
		return
	}
	if ok, status, msg := agents_stop_request(agent_instance_id, time_in_sec); !ok {
		write_response(client, status, "Error", msg)
		return
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"message":"stop event sent","agent_instance_id":"`)
	json_write_string(&b, agent_instance_id)
	strings.write_string(&b, `","time_in_sec":`)
	strings.write_string(&b, fmt.tprintf("%d", time_in_sec))
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

agents_stop_request :: proc(agent_instance_id: string, time_in_sec: int) -> (bool, int, string) {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 {
		fmt.printf("WARNING: stop_agent failed: agent '%s' not found in registry\n", agent_instance_id)
		return false, 404, `{"ok":false,"message":"agent not found"}`
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
	return true, 200, `{"ok":true}`
}

handle_agents_stop_done :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_instance_id required"}`)
		return
	}
	registry_update_startup(agent_instance_id, "stopped", "stop_done", "Agent stopped gracefully", "", "", "")
	registry_clear_ws(agent_instance_id)
	agent_lifecycle_emit(agent_instance_id, "offline", "stop_done")
	write_response(client, 200, "OK", `{"ok":true,"message":"stop acknowledged"}`)
}

stop_event_json :: proc(agent_instance_id: string, time_in_sec: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"stop_event","agent_instance_id":"`)
	json_write_string(&b, agent_instance_id)
	strings.write_string(&b, `","time_in_sec":`)
	strings.write_string(&b, fmt.tprintf("%d", time_in_sec))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}
