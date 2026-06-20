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
	// Daemon-spawned wrappers keep their issued token across daemon restarts, but the
	// in-memory pending-token list does not. Allow a requested token for a fresh
	// instance; still reject untrusted token replacement for an existing registry entry.
	if requested_agent_token != "" && !registry_consume_pending_agent_token(agent_instance_id, requested_agent_token) && registry_agent_exists(agent_instance_id) {
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
	agent_lifecycle_emit(agent_instance_id, "registered", "register")
	write_response(client, 200, "OK", register_response_json(record))
}

handle_startup_report :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	status := extract_json_string(body, "startup_status", extract_json_string(body, "status", ""))
	if !valid_agent_instance_id(agent_instance_id) || status == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"startup report requires agent_instance_id and status"}`)
		return
	}
	if status != "starting" && status != "ready" && status != "startup_blocked" && status != "startup_failed" && status != "startup_unknown" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid startup status"}`)
		return
	}
	provider_profile := extract_json_string(body, "provider_profile", "")
	run_dir := extract_json_string(body, "run_dir", "")
	if !registry_update_startup(agent_instance_id, status, extract_json_string(body, "reason_code", ""), extract_json_string(body, "safe_diagnostic", ""), provider_profile, run_dir, extract_json_string(body, "tmux_pane", "")) {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown agent instance"}`)
		return
	}
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 && (provider_profile != "" || run_dir != "") {
		rec := agent_instance_records[idx]
		if provider_profile != "" do rec.provider_profile = provider_profile
		if run_dir != "" do rec.run_dir = run_dir
		_ = agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = rec.display_name, template_id = rec.template_id, provider_profile = rec.provider_profile, project_id = rec.project_id, run_dir = rec.run_dir, author = "startup_report"})
	}
	agent_lifecycle_emit(agent_instance_id, status, "startup_report")
	write_response(client, 200, "OK", `{"ok":true}`)
}

handle_heartbeat :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`)
		return
	}
	was_live := registry_agent_live(agent_instance_id)
	if registry_heartbeat(agent_instance_id) {
		if !was_live do agent_lifecycle_emit(agent_instance_id, "connected", "heartbeat")
		write_response(client, 200, "OK", `{"ok":true}`)
	} else {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown agent instance"}`)
	}
}
