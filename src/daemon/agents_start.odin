package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"

valid_model_tier :: proc(tier: string) -> bool {
	return tier == "cheap" || tier == "normal" || tier == "smart"
}

normalize_model_tier :: proc(tier: string) -> string {
	if tier == "" || tier == "cheap" do return "normal"
	return tier
}

handle_agents_providers :: proc(client: net.TCP_Socket) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"providers":[`)
	
	first := true
	for cfg in server_agent_cmd_configs {
		if !first do strings.write_string(&builder, `,`)
		first = false
		
		strings.write_string(&builder, `{"name":"`)
		json_write_string(&builder, cfg.name)
		strings.write_string(&builder, `","command":[`)
		for cmd, idx in cfg.command {
			if idx > 0 do strings.write_string(&builder, `,`)
			strings.write_string(&builder, `"`)
			json_write_string(&builder, cmd)
			strings.write_string(&builder, `"`)
		}
		strings.write_string(&builder, `],"tiers":{`)
		strings.write_string(&builder, `"cheap":"`)
		json_write_string(&builder, cfg.models.cheap)
		strings.write_string(&builder, `","normal":"`)
		json_write_string(&builder, cfg.models.normal)
		strings.write_string(&builder, `","smart":"`)
		json_write_string(&builder, cfg.models.smart)
		strings.write_string(&builder, `"}}`)
	}
	
	// Fallback if empty
	if first && len(server_agent_providers) > 0 {
		for p, idx in server_agent_providers {
			if idx > 0 do strings.write_string(&builder, `,`)
			fmt.sbprintf(&builder, `{"name":"%s","command":["%s"],"tiers":{"cheap":"","normal":"","smart":""}}`, p, p)
		}
	}
	
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_templates :: proc(client: net.TCP_Socket) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"templates":[`)
	wrote := 0
	for i in 0..<agent_template_record_count {
		rec := agent_template_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if wrote > 0 do strings.write_string(&builder, `,`)
		agent_template_record_json(&builder, rec)
		wrote += 1
	}
	if wrote == 0 {
		strings.write_string(&builder, `{"template_id":"coder","display_name":"Coder","role_hint":"assignee","default_provider_profile":"pi","memory_templates":[]},{"template_id":"reviewer","display_name":"Reviewer","role_hint":"reviewer","default_provider_profile":"pi","memory_templates":[]},{"template_id":"coordinator","display_name":"Coordinator","role_hint":"coordinator","default_provider_profile":"pi","memory_templates":[]}`)
	}
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_list :: proc(client: net.TCP_Socket, request: string) {
	project_id := query_param(request, "project_id")
	role_hint := query_param(request, "role_hint")
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"agents":[`)
	wrote := 0
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if project_id != "" && rec.project_id != project_id do continue
		if role_hint != "" {
			tidx := agent_template_index(rec.template_id)
			if tidx < 0 do continue
			if agent_template_records[tidx].role_hint != role_hint do continue
		}
		if wrote > 0 do strings.write_string(&builder, `,`)
		agent_instance_record_json(&builder, rec)
		wrote += 1
	}
	// Preserve existing live-registry visibility for callers that used /clients only.
	if project_id == "" && role_hint == "" {
		for i in 0..<agent_count {
			ag := agents[i]
			if is_test_token(ag.agent_token) do continue
			if agent_record_index_by_instance(ag.agent_instance_id) >= 0 do continue
			if wrote > 0 do strings.write_string(&builder, `,`)
			strings.write_string(&builder, `{"agent_record_id":"","agent_instance_id":"`); json_write_string(&builder, ag.agent_instance_id)
			strings.write_string(&builder, `","display_name":"`); json_write_string(&builder, ag.display_name)
			// provider_profile is set on startup report; fall back to agent_class (always set on register)
			live_pp := ag.provider_profile; if live_pp == "" do live_pp = ag.agent_class
			strings.write_string(&builder, `","template_id":"","provider_profile":"`); json_write_string(&builder, live_pp)
			strings.write_string(&builder, `","project_id":"","project_name":"","run_dir":"`); json_write_string(&builder, ag.run_dir)
			strings.write_string(&builder, `","conversation_id":"`); json_write_string(&builder, ag.conversation_id)
			strings.write_string(&builder, `","tmux_pane":"`); json_write_string(&builder, ag.tmux_pane)
			strings.write_string(&builder, `","connected":`); strings.write_string(&builder, "true" if ag.connected else "false")
			strings.write_string(&builder, `,"last_seen_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", ag.last_seen_unix_ms))
			strings.write_string(&builder, `,"startup_status":"`); json_write_string(&builder, ag.startup_status)
			strings.write_string(&builder, `","startup_reason_code":"`); json_write_string(&builder, ag.startup_reason_code)
			strings.write_string(&builder, `","safe_diagnostic":"`); json_write_string(&builder, ag.startup_safe_diagnostic)
			strings.write_string(&builder, `","startup_updated_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", ag.startup_updated_unix_ms)); strings.write_string(&builder, `}`)
			wrote += 1
		}
	}
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_associate :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	project_id := extract_json_string(body, "project_id", "")
	if project_id == "" { write_response(client, 400, "Bad Request", `{"ok":false,"message":"project_id required"}`); return }
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	rec.project_id = strings.clone(project_id)
	assoc_tier := normalize_model_tier(rec.model_tier)
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = rec.display_name, template_id = rec.template_id, provider_profile = rec.provider_profile, project_id = rec.project_id, run_dir = rec.run_dir, model_tier = assoc_tier, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent association"}`); return }
	write_agent_ok_response(client, "associated", agent_instance_records[agent_record_index(rec.agent_record_id)])
}

handle_agents_disassociate :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	rec.project_id = ""
	disassoc_tier := normalize_model_tier(rec.model_tier)
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = rec.display_name, template_id = rec.template_id, provider_profile = rec.provider_profile, project_id = "", run_dir = rec.run_dir, model_tier = disassoc_tier, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent disassociation"}`); return }
	write_agent_ok_response(client, "disassociated", agent_instance_records[agent_record_index(rec.agent_record_id)])
}

// Upsert an agent instance record. If the instance already exists the record_id and run_dir are
// preserved; caller-supplied non-empty fields override stored ones. Returns the resolved
// agent_record_id and the final model_tier, or ("", "") on failure.
agent_record_upsert :: proc(
	agent_instance_id, display_label, template_id, provider_profile, project_id, run_dir_override, model_tier: string,
) -> (agent_record_id: string, final_tier: string, ok: bool) {
	if template_id == "guide" && !guide_agent_is_singleton(agent_instance_id) {
		fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d stage=record_upsert_rejected target=%s template=%s reason=guide_template_reserved", router_now_unix_ms(), agent_instance_id, template_id)
		return "", "", false
	}
	if guide_agent_is_singleton(agent_instance_id) && template_id != "" && template_id != "guide" {
		fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d stage=record_upsert_rejected target=%s template=%s reason=guide_singleton_reserved", router_now_unix_ms(), agent_instance_id, template_id)
		return "", "", false
	}
	rec_id := agent_new_record_id()
	run_dir := run_dir_override
	tier := normalize_model_tier(model_tier)
	pp := provider_profile
	resolved_project_id := project_id
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		rec_id = agent_instance_records[idx].agent_record_id
		if run_dir == "" do run_dir = agent_instance_records[idx].run_dir
		if pp == "" do pp = agent_instance_records[idx].provider_profile
		// Empty project_id from caller (e.g. /agents/start with no body project_id)
		// must NOT clobber the stored association. Use the stored value as the
		// fallback; explicit disassociation goes through /agents/disassociate.
		if resolved_project_id == "" do resolved_project_id = agent_instance_records[idx].project_id
	}
	if pp == "" do pp = "pi"
	ev := Agent_Instance_Event{
		kind = .Agent_Instance_Upserted,
		agent_record_id = rec_id,
		agent_instance_id = agent_instance_id,
		display_name = display_label,
		template_id = template_id,
		provider_profile = pp,
		project_id = resolved_project_id,
		run_dir = run_dir,
		model_tier = tier,
		author = "api",
	}
	if !agent_store_append_event(ev) do return "", "", false
	return rec_id, tier, true
}

handle_agents_start :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", extract_json_string(body, "persona", ""))
	project_id := extract_json_string(body, "project_id", "")
	provider_profile := extract_json_string(body, "provider_profile", extract_json_string(body, "agent", ""))
	display_name := extract_json_string(body, "display_name", extract_json_string(body, "alias", ""))
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	config_path := extract_json_string(body, "config_path", server_config_path)
	if agent_instance_id == "" {
		id_base := display_name if display_name != "" else template_id
		agent_instance_id = agent_generated_instance_id(id_base, project_id)
	}
	if display_name == "" do display_name = agent_instance_id
	if template_id == "" do template_id = derive_agent_class(agent_instance_id)
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`)
		return
	}

	// Resolve model_tier: stored record's tier is the base; caller may override.
	stored_model_tier := "normal"
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		stored_model_tier = normalize_model_tier(agent_instance_records[idx].model_tier)
	}
	if request_tier := extract_json_string(body, "model_tier", ""); request_tier != "" {
		if !valid_model_tier(request_tier) {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid model_tier; expected cheap, normal, or smart"}`)
			return
		}
		stored_model_tier = normalize_model_tier(request_tier)
	}

	log_path := wrapper_log_path(agent_instance_id)
	agent_record_id, final_tier, upsert_ok := agent_record_upsert(agent_instance_id, display_name, template_id, provider_profile, project_id, "", stored_model_tier)
	if !upsert_ok {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent instance"}`)
		return
	}
	// Reload provider_profile and project_id as resolved by upsert (may have
	// fallen back to stored value if caller didn't provide a fresh one).
	resolved_project_id := project_id
	if idx := agent_record_index(agent_record_id); idx >= 0 {
		provider_profile = agent_instance_records[idx].provider_profile
		resolved_project_id = agent_instance_records[idx].project_id
	}

	agent_token := generate_agent_token()
	registry_add_pending_agent_token(agent_instance_id, agent_token)
	ok := launch_wrapper_detached(agent_instance_id, provider_profile, config_path, log_path, agent_token, display_name, final_tier, resolved_project_id, "manual_agent_start", "", "", "")
	if !ok {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to start wrapper"}`)
		return
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"mode":"remote_detached","message":"started","agent_record_id":"`)
	json_write_string(&builder, agent_record_id)
	strings.write_string(&builder, `","agent_instance_id":"`)
	json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `","display_name":"`)
	json_write_string(&builder, display_name)
	strings.write_string(&builder, `","template_id":"`)
	json_write_string(&builder, template_id)
	strings.write_string(&builder, `","provider_profile":"`)
	json_write_string(&builder, provider_profile)
	strings.write_string(&builder, `","project_id":"`)
	json_write_string(&builder, project_id)
	strings.write_string(&builder, `","conversation_id":"`)
	json_write_string(&builder, conversation_id_for_instance(agent_instance_id))
	strings.write_string(&builder, `","agent_token":"`)
	json_write_string(&builder, agent_token)
	strings.write_string(&builder, `","wrapper_log":"`)
	json_write_string(&builder, log_path)
	strings.write_string(&builder, `"}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

agent_instance_record_json :: proc(builder: ^strings.Builder, rec: Agent_Instance_Record) {
	strings.write_string(builder, `{"agent_record_id":"`); json_write_string(builder, rec.agent_record_id)
	strings.write_string(builder, `","agent_instance_id":"`); json_write_string(builder, rec.agent_instance_id)
	strings.write_string(builder, `","display_name":"`); json_write_string(builder, rec.display_name)
	strings.write_string(builder, `","template_id":"`); json_write_string(builder, rec.template_id)
	strings.write_string(builder, `","provider_profile":"`); json_write_string(builder, rec.provider_profile)
	strings.write_string(builder, `","project_id":"`); json_write_string(builder, rec.project_id)
	project_name := ""
	if rec.project_id != "" {
		if pidx := project_index(rec.project_id); pidx >= 0 do project_name = project_records[pidx].name
	}
	strings.write_string(builder, `","project_name":"`); json_write_string(builder, project_name)
	strings.write_string(builder, `","run_dir":"`); json_write_string(builder, rec.run_dir)
	model_tier := normalize_model_tier(rec.model_tier)
	strings.write_string(builder, `","model_tier":"`); json_write_string(builder, model_tier)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `,"archived_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.archived_at_unix_ms))
	strings.write_string(builder, `,"current_task_id":"`); json_write_string(builder, rec.current_task_id)
	strings.write_string(builder, `","current_task_since":`); strings.write_string(builder, fmt.tprintf("%d", rec.current_task_since))
	strings.write_string(builder, `,"last_needed_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.last_needed_at_unix_ms))
	strings.write_string(builder, `,"state":"`); json_write_string(builder, agent_store_agent_state(rec)); strings.write_string(builder, `"`)
	strings.write_string(builder, `,"order":`); strings.write_string(builder, fmt.tprintf("%d", rec.order))
	strings.write_string(builder, `,"conversation_id":"`); json_write_string(builder, conversation_id_for_instance(rec.agent_instance_id))
	if live_idx := registry_find_agent(rec.agent_instance_id); live_idx >= 0 {
		agent := agents[live_idx]
		strings.write_string(builder, `","tmux_pane":"`); json_write_string(builder, agent.tmux_pane)
		strings.write_string(builder, `","connected":`); strings.write_string(builder, "true" if agent.connected else "false")
		strings.write_string(builder, `,"connection_state":"`); json_write_string(builder, "connected" if agent.connected else "registered")
		strings.write_string(builder, `","last_seen_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", agent.last_seen_unix_ms))
		strings.write_string(builder, `,"startup_status":"`); json_write_string(builder, agent.startup_status)
		strings.write_string(builder, `","startup_reason_code":"`); json_write_string(builder, agent.startup_reason_code)
		strings.write_string(builder, `","safe_diagnostic":"`); json_write_string(builder, agent.startup_safe_diagnostic)
		strings.write_string(builder, `","startup_updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", agent.startup_updated_unix_ms))
		strings.write_string(builder, `,"exec_state":"`); json_write_string(builder, agent.exec_state)
		strings.write_string(builder, `","exec_state_since_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", agent.exec_state_since_unix_ms))
		strings.write_string(builder, `,"blocked_reason":"`); json_write_string(builder, agent.blocked_reason); strings.write_string(builder, `"`)
	} else {
		strings.write_string(builder, `","tmux_pane":"","connected":false,"connection_state":"offline","exec_state":"","exec_state_since_unix_ms":0,"blocked_reason":""`)
	}
	strings.write_string(builder, `}`)
}

write_agent_ok_response :: proc(client: net.TCP_Socket, message: string, rec: Agent_Instance_Record) {
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"message":"`); json_write_string(&b, message); strings.write_string(&b, `","agent":`); agent_instance_record_json(&b, rec); strings.write_string(&b, `}`); write_response(client, 200, "OK", strings.to_string(b))
}

query_param :: proc(request, name: string) -> string {
	first := strings.index_byte(request, ' ')
	if first < 0 do return ""
	second := strings.index_byte(request[first + 1:], ' ')
	if second < 0 do return ""
	path := request[first + 1:first + 1 + second]
	q := strings.index_byte(path, '?')
	if q < 0 do return ""
	query := path[q + 1:]
	key := fmt.tprintf("%s=", name)
	idx := strings.index(query, key)
	if idx < 0 do return ""
	start := idx + len(key)
	end := strings.index_byte(query[start:], '&')
	if end < 0 do return query[start:]
	return query[start:start + end]
}

launch_wrapper_detached :: proc(agent_instance_id, selected_agent, config_path, log_path, agent_token, display_name, model_tier, project_id: string, launch_source: string = "", chain_id: string = "", team_id: string = "", task_id: string = "") -> bool {
	spawn_start_ms := router_now_unix_ms()
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=wrapper_spawn_build_begin source=%s chain=%s team=%s task=%s target=%s provider=%s tier=%s project=%s log=%s", spawn_start_ms, launch_source, chain_id, team_id, task_id, agent_instance_id, selected_agent, model_tier, project_id, log_path)
	_ = os.make_directory_all(parent_dir(log_path))
	wrapper_bin := default_wrapper_bin()

	builder := strings.builder_make()
	strings.write_string(&builder, "nohup ")
	strings.write_string(&builder, shell_quote(wrapper_bin))
	strings.write_string(&builder, " --overwrite --config ")
	strings.write_string(&builder, shell_quote(config_path))
	if selected_agent != "" {
		strings.write_string(&builder, " --agent ")
		strings.write_string(&builder, shell_quote(selected_agent))
	}
	if agent_token != "" {
		strings.write_string(&builder, " --agent-token ")
		strings.write_string(&builder, shell_quote(agent_token))
	}
	if display_name != "" {
		strings.write_string(&builder, " --display-name ")
		strings.write_string(&builder, shell_quote(display_name))
	}
	tier := normalize_model_tier(model_tier)
	strings.write_string(&builder, " --tier ")
	strings.write_string(&builder, shell_quote(tier))
	if project_id != "" {
		strings.write_string(&builder, " --project-id ")
		strings.write_string(&builder, shell_quote(project_id))
	}
	strings.write_string(&builder, " ")
	strings.write_string(&builder, shell_quote(agent_instance_id))
	strings.write_string(&builder, " > ")
	strings.write_string(&builder, shell_quote(log_path))
	strings.write_string(&builder, " 2>&1 < /dev/null &")

	cmd := strings.to_string(builder)
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_process_start_begin source=%s chain=%s team=%s task=%s target=%s wrapper_bin=%s", router_now_unix_ms(), router_now_unix_ms() - spawn_start_ms, launch_source, chain_id, team_id, task_id, agent_instance_id, wrapper_bin)
	process, err := os.process_start(os.Process_Desc{command = []string{"sh", "-c", cmd}})
	if err != nil {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_process_start_failed source=%s chain=%s team=%s task=%s target=%s", router_now_unix_ms(), router_now_unix_ms() - spawn_start_ms, launch_source, chain_id, team_id, task_id, agent_instance_id)
		fmt.println("wrapper launch failed")
		return false
	}
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_process_start_done source=%s chain=%s team=%s task=%s target=%s shell_pid=%v", router_now_unix_ms(), router_now_unix_ms() - spawn_start_ms, launch_source, chain_id, team_id, task_id, agent_instance_id, process.handle)
	_ = process
	return true
}

default_wrapper_bin :: proc() -> string {
	if server_wrapper_bin != "" do return server_wrapper_bin
	if len(os.args) > 0 {
		exe := os.args[0]
		slash := strings.last_index_byte(exe, '/')
		if slash >= 0 do return fmt.tprintf("%s/ham-wrapper", exe[:slash])
	}
	return "ham-wrapper"
}

wrapper_log_path :: proc(agent_instance_id: string) -> string {
	data_dir := expand_home(server_data_dir)
	return fmt.tprintf("%s/logs/wrapper-%s.log", data_dir, safe_path_part(agent_instance_id))
}

parent_dir :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash <= 0 do return "."
	return path[:slash]
}

expand_home :: proc(path: string) -> string {
	home := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if home == "" {
		home = os.get_env_alloc("HOME", context.allocator)
	}
	if path == "~" {
		if home != "" do return home
	}
	if strings.has_prefix(path, "~/") {
		if home != "" do return fmt.tprintf("%s/%s", home, path[2:])
	}
	return path
}

safe_path_part :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

shell_quote :: proc(value: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "'")
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "'\\''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	strings.write_string(&builder, "'")
	return strings.to_string(builder)
}

handle_agent_template_create_update :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", "")
	if template_id == "" { write_response(client, 400, "Bad Request", `{"ok":false,"message":"template_id required"}`); return }
	ev: Agent_Template_Event
	ev.kind = .Agent_Template_Upserted
	ev.template_id = template_id
	ev.display_name = extract_json_string(body, "display_name", template_id)
	ev.description = extract_json_string(body, "description", "")
	ev.persona = extract_json_string(body, "persona", "")
	ev.instructions = extract_json_string(body, "instructions", "")
	ev.role_hint = extract_json_string(body, "role_hint", "")
	ev.parent_template_id = extract_json_string(body, "parent_template_id", "")
	ev.default_provider_profile = extract_json_string(body, "default_provider_profile", extract_json_string(body, "provider_profile", ""))
	ev.bootstrap_defaults = extract_json_string(body, "bootstrap_defaults", "")
	ev.suggested_model_tier = extract_json_string(body, "suggested_model_tier", "normal")
	ev.author = "api"
	agent_parse_string_array_field(body, "memory_templates", &ev.memory_templates, &ev.memory_template_count)
	if !agent_template_append_event(ev) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent template"}`); return }
	idx := agent_template_index(template_id)
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"template":`); agent_template_record_json(&b, agent_template_records[idx]); strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agent_template_show :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", query_param(body, "template_id"))
	idx := agent_template_index(template_id)
	if idx < 0 || agent_template_records[idx].archived_at_unix_ms != 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"template not found"}`); return }
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"template":`); agent_template_record_json(&b, agent_template_records[idx]); strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agent_template_archive :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", "")
	if agent_template_index(template_id) < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"template not found"}`); return }
	if !agent_template_append_event(Agent_Template_Event{kind = .Agent_Template_Archived, template_id = template_id, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to archive agent template"}`); return }
	write_response(client, 200, "OK", `{"ok":true,"message":"archived"}`)
}

handle_agent_instance_show :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 || agent_instance_records[idx].archived_at_unix_ms != 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	write_agent_ok_response(client, "ok", agent_instance_records[idx])
}

handle_agent_instance_update :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	display_name := extract_json_string(body, "display_name", rec.display_name)
	template_id := extract_json_string(body, "template_id", rec.template_id)
	provider_profile := extract_json_string(body, "provider_profile", rec.provider_profile)
	project_id := extract_json_string(body, "project_id", rec.project_id)
	run_dir := extract_json_string(body, "run_dir", rec.run_dir)
	model_tier := normalize_model_tier(rec.model_tier)
	if req_tier := extract_json_string(body, "model_tier", ""); req_tier != "" {
		if !valid_model_tier(req_tier) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid model_tier; expected cheap, normal, or smart"}`); return }
		model_tier = normalize_model_tier(req_tier)
	}
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = display_name, template_id = template_id, provider_profile = provider_profile, project_id = project_id, run_dir = run_dir, model_tier = model_tier, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent instance"}`); return }
	write_agent_ok_response(client, "updated", agent_instance_records[agent_record_index(rec.agent_record_id)])
}

handle_agent_instance_create :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	display_name := extract_json_string(body, "display_name", extract_json_string(body, "name", ""))
	provider_profile := extract_json_string(body, "provider_profile", extract_json_string(body, "agent", ""))
	template_id := extract_json_string(body, "template_id", "")
	project_id := extract_json_string(body, "project_id", "")
	model_tier := extract_json_string(body, "model_tier", "normal")
	if !valid_model_tier(model_tier) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid model_tier; expected cheap, normal, or smart"}`); return }
	model_tier = normalize_model_tier(model_tier)
	if agent_instance_id == "" {
		id_base := display_name if display_name != "" else template_id
		agent_instance_id = agent_generated_instance_id(id_base, project_id)
	}
	if display_name == "" do display_name = agent_instance_id
	if template_id == "" do template_id = derive_agent_class(agent_instance_id)
	if !valid_agent_instance_id(agent_instance_id) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`); return }
	agent_record_id, _, upsert_ok := agent_record_upsert(agent_instance_id, display_name, template_id, provider_profile, project_id, "", model_tier)
	if !upsert_ok { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent instance"}`); return }
	write_agent_ok_response(client, "created", agent_instance_records[agent_record_index(agent_record_id)])
}

handle_agent_instance_archive :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Archived, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to archive agent instance"}`); return }
	write_response(client, 200, "OK", `{"ok":true,"message":"archived"}`)
}

agent_template_record_json :: proc(builder: ^strings.Builder, rec: Agent_Template_Record) {
	strings.write_string(builder, `{"template_id":"`); json_write_string(builder, rec.template_id)
	strings.write_string(builder, `","display_name":"`); json_write_string(builder, rec.display_name)
	strings.write_string(builder, `","description":"`); json_write_string(builder, rec.description)
	strings.write_string(builder, `","persona":"`); json_write_string(builder, rec.persona)
	strings.write_string(builder, `","instructions":"`); json_write_string(builder, rec.instructions)
	strings.write_string(builder, `","role_hint":"`); json_write_string(builder, rec.role_hint)
	strings.write_string(builder, `","parent_template_id":"`); json_write_string(builder, rec.parent_template_id)
	strings.write_string(builder, `","default_provider_profile":"`); json_write_string(builder, rec.default_provider_profile)
	strings.write_string(builder, `","bootstrap_defaults":"`); json_write_string(builder, rec.bootstrap_defaults)
	strings.write_string(builder, `","suggested_model_tier":"`); json_write_string(builder, rec.suggested_model_tier)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `,"archived_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.archived_at_unix_ms))
	strings.write_string(builder, `,"memory_templates":[`)
	for i in 0..<rec.memory_template_count { if i > 0 do strings.write_string(builder, `,`); strings.write_string(builder, `"`); json_write_string(builder, rec.memory_templates[i]); strings.write_string(builder, `"`) }
	strings.write_string(builder, `]}`)
}

handle_agents_test_connectivity :: proc(client: net.TCP_Socket, body: string) {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"results":[`)
	
	target_providers_str := extract_json_string(body, "providers", "")
	
	first := true
	
	// Helper to check if a provider should be tested
	should_test := proc(name: string, filter: string) -> bool {
		if filter == "" do return true
		
		// Simple comma-separated substring check
		parts := strings.split(filter, ",")
		defer delete(parts)
		for part in parts {
			if strings.trim_space(part) == name do return true
		}
		return false
	}
	
	if len(server_config.wrapper.agent_commands) > 0 {
		for cmd in server_config.wrapper.agent_commands {
			if !should_test(cmd.name, target_providers_str) do continue
			
			if !first do strings.write_string(&b, ",")
			first = false
			
			success, err_msg := test_single_agent_command(cmd.name, cmd.command)
			fmt.sbprintf(&b, `{"name":"%s","ok":%t,"message":"%s"}`, cmd.name, success, err_msg)
		}
	}
	
	if len(server_config.wrapper.command) > 0 {
		if should_test("default", target_providers_str) {
			if !first do strings.write_string(&b, ",")
			success, err_msg := test_single_agent_command("default", server_config.wrapper.command)
			fmt.sbprintf(&b, `{"name":"default","ok":%t,"message":"%s"}`, success, err_msg)
		}
	}
	
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

test_single_agent_command :: proc(name: string, command_slice: []string) -> (ok: bool, message: string) {
	if len(command_slice) == 0 do return false, "No command configured"
	
	exe := command_slice[0]
	
	desc := os.Process_Desc{
		command = []string{"which", exe},
	}
	
	process, err := os.process_start(desc)
	if err != nil {
		return false, fmt.tprintf("Failed to execute check: %v", err)
	}
	
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		return false, fmt.tprintf("Failed to wait for check: %v", wait_err)
	}
	
	if !state.success {
		return false, fmt.tprintf("Executable '%s' not found or not runnable on this system.", exe)
	}
	
	return true, fmt.tprintf("Executable verified: %s", exe)
}

handle_agent_reorder :: proc(client: net.TCP_Socket, body: string) {
	agent_ids := extract_json_string_array(body, "agent_ids")
	defer {
		for s in agent_ids do delete(s)
		delete(agent_ids)
	}
	for id, order in agent_ids {
		idx := agent_record_index_by_instance(id)
		if idx < 0 do continue
		rec := agent_instance_records[idx]
		event := Agent_Instance_Event{
			kind = .Agent_Instance_Upserted,
			agent_record_id = rec.agent_record_id,
			agent_instance_id = rec.agent_instance_id,
			display_name = rec.display_name,
			template_id = rec.template_id,
			provider_profile = rec.provider_profile,
			project_id = rec.project_id,
			run_dir = rec.run_dir,
			model_tier = rec.model_tier,
			order = order,
			author = "api",
		}
		if !agent_store_append_event(event) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent reorder event"}`)
			return
		}
	}
	write_response(client, 200, "OK", `{"ok":true,"message":"agents reordered"}`)
}
