package main

import "core:net"

handle_user_client_register :: proc(client: net.TCP_Socket, body: string) {
	record, ok, message := user_client_register(
		extract_json_string(body, "user_id", ""),
		extract_json_string(body, "client_instance_id", ""),
		extract_json_string(body, "client_token", ""),
	)
	if !ok {
		write_response(client, 400, "Bad Request", user_client_error_json(message))
		return
	}
	write_response(client, 200, "OK", user_client_register_response_json(record))
}

handle_user_client_heartbeat :: proc(client: net.TCP_Socket, body: string) {
	if user_client_heartbeat(extract_json_string(body, "client_instance_id", ""), extract_json_string(body, "client_token", "")) {
		write_response(client, 200, "OK", `{"ok":true}`)
		return
	}
	write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid client token"}`)
}

handle_user_presence :: proc(client: net.TCP_Socket, body: string) {
	if registry_agent_instance_for_token(extract_json_string(body, "agent_token", "")) == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`)
		return
	}
	write_response(client, 200, "OK", user_presence_json())
}
