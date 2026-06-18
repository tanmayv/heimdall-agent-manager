package main

import "core:net"

handle_register :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "unknown")
	agent_class := extract_json_string(body, "agent_class", "")
	if agent_class == "" do agent_class = derive_agent_class(agent_instance_id)
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id; use class@suffix with only letters, numbers, and dash in each part"}`)
		return
	}
	if !valid_agent_id_part(agent_class) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_class; use only letters, numbers, and dash"}`)
		return
	}
	if agent_class != derive_agent_class(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_class must match agent_instance_id prefix"}`)
		return
	}
	if registry_agent_exists(agent_instance_id) && registry_agent_active_for_duplicate(agent_instance_id) {
		write_response(client, 409, "Conflict", `{"ok":false,"error":"active_duplicate","message":"agent_instance_id already registered and active"}`)
		return
	}

	requested_agent_token := extract_json_string(body, "agent_token", "")
	if requested_agent_token != "" && !registry_consume_pending_agent_token(agent_instance_id, requested_agent_token) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"untrusted pre-generated agent token"}`)
		return
	}

	record := registry_register(
		agent_class,
		agent_instance_id,
		extract_json_string(body, "display_name", ""),
		requested_agent_token,
	)
	router_adapter_announce_local_agent(agent_instance_id, agent_class)
	write_response(client, 200, "OK", register_response_json(record))
}

handle_heartbeat :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`)
		return
	}
	if registry_heartbeat(agent_instance_id) {
		write_response(client, 200, "OK", `{"ok":true}`)
	} else {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown agent instance"}`)
	}
}
