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
	return agent_runtime_tracker_request_stop(agent_instance_id, time_in_sec, "api_stop_request")
}

handle_agents_stop_done :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_instance_id required"}`)
		return
	}
	agent_runtime_tracker_observe_stop_done(agent_instance_id, "http_stop_done")
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
