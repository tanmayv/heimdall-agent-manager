package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import http "odin_test:lib/http_client"

guide_rpc_try_handle :: proc(client: net.TCP_Socket, action, body, from_agent_instance_id: string) -> bool {
	if !strings.has_prefix(action, "guide_") do return false
	if !guide_agent_is_singleton(from_agent_instance_id) {
		fmt.printfln("GUIDE_RPC ts_unix_ms=%d stage=rejected action=%s from=%s reason=not_guide", router_now_unix_ms(), action, from_agent_instance_id)
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"guide RPC actions are restricted to guide@heimdall"}`)
		return true
	}
	fmt.printfln("GUIDE_RPC ts_unix_ms=%d stage=handle action=%s from=%s", router_now_unix_ms(), action, from_agent_instance_id)
	if action == "guide_status" {
		write_response(client, 200, "OK", guide_rpc_status_json())
		return true
	}
	if action == "guide_state_summary" {
		write_response(client, 200, "OK", guide_rpc_state_summary_json())
		return true
	}
	if action == "guide_list_chains" {
		limit := extract_json_int(body, "limit", 20)
		if limit <= 0 || limit > 100 do limit = 20
		write_response(client, 200, "OK", guide_rpc_list_chains_json(limit, extract_json_string(body, "status", "")))
		return true
	}
	if action == "guide_show_chain" {
		chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
		write_response(client, 200, "OK", guide_rpc_show_chain_json(chain_id))
		return true
	}
	if action == "guide_list_agents" || action == "guide_show_agent_runtime" {
		agent_id := extract_json_string(body, "agent_instance_id", extract_json_string(body, "agent", ""))
		write_response(client, 200, "OK", guide_rpc_agents_json(agent_id))
		return true
	}
	if action == "guide_list_projects" {
		write_response(client, 200, "OK", project_list_json())
		return true
	}
	if action == "guide_ui_debug_status" {
		write_response(client, 200, "OK", guide_rpc_ui_debug_status_json())
		return true
	}
	if action == "guide_ui_debug_action" {
		write_response(client, 200, "OK", guide_rpc_ui_debug_action_json(body))
		return true
	}
	write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported guide RPC action"}`)
	return true
}

guide_rpc_status_json :: proc() -> string {
	b := strings.builder_make()
	agent_id := guide_agent_instance_id()
	strings.write_string(&b, `{"ok":true,"agent_instance_id":"`); json_write_string(&b, agent_id)
	strings.write_string(&b, `","enabled":`); strings.write_string(&b, "true" if server_config.guide_agent.enabled else "false")
	strings.write_string(&b, `,"autostart":`); strings.write_string(&b, "true" if server_config.guide_agent.autostart else "false")
	strings.write_string(&b, `,"restart_if_stopped":`); strings.write_string(&b, "true" if server_config.guide_agent.restart_if_stopped else "false")
	strings.write_string(&b, `,"template_id":"`); json_write_string(&b, server_config.guide_agent.template_id)
	strings.write_string(&b, `","provider_profile":"`); json_write_string(&b, server_config.guide_agent.provider_profile)
	strings.write_string(&b, `","model_tier":"`); json_write_string(&b, server_config.guide_agent.model_tier)
	if idx := registry_find_agent(agent_id); idx >= 0 {
		ag := agents[idx]
		strings.write_string(&b, `","connected":`); strings.write_string(&b, "true" if ag.connected else "false")
		strings.write_string(&b, `,"startup_status":"`); json_write_string(&b, ag.startup_status)
		strings.write_string(&b, `","startup_reason_code":"`); json_write_string(&b, ag.startup_reason_code)
		strings.write_string(&b, `","activity_status":"`); json_write_string(&b, ag.activity_status)
		strings.write_string(&b, `","activity_checked_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", ag.activity_checked_unix_ms))
		strings.write_string(&b, `,"tmux_pane":"`); json_write_string(&b, ag.tmux_pane)
		strings.write_string(&b, `"`)
	} else {
		strings.write_string(&b, `","connected":false,"startup_status":"offline","startup_reason_code":"","activity_status":"unknown","activity_checked_unix_ms":0,"tmux_pane":""`)
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

guide_rpc_state_summary_json :: proc() -> string {
	active_chains := 0
	for chain in store_all_chains() {
		if !chain.archived && chain.status != "completed" && chain.status != "cancelled" && chain.status != "abandoned" do active_chains += 1
	}
	live_agents := 0
	for i in 0..<agent_instance_record_count {
		if agent_instance_records[i].archived_at_unix_ms == 0 do live_agents += 1
	}
	connected_agents := 0
	for i in 0..<agent_count {
		if agents[i].connected || agents[i].has_ws do connected_agents += 1
	}
	pending_attention := 0
	for state in store_all_tasks() {
		if isUserActionableTask_for_guide(state) do pending_attention += 1
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"projects":`); strings.write_string(&b, fmt.tprintf("%d", project_record_count))
	strings.write_string(&b, `,"chains":`); strings.write_string(&b, fmt.tprintf("%d", store_chain_count()))
	strings.write_string(&b, `,"active_chains":`); strings.write_string(&b, fmt.tprintf("%d", active_chains))
	strings.write_string(&b, `,"tasks":`); strings.write_string(&b, fmt.tprintf("%d", store_task_count()))
	strings.write_string(&b, `,"agents":`); strings.write_string(&b, fmt.tprintf("%d", live_agents))
	strings.write_string(&b, `,"connected_agents":`); strings.write_string(&b, fmt.tprintf("%d", connected_agents))
	strings.write_string(&b, `,"pending_task_attention":`); strings.write_string(&b, fmt.tprintf("%d", pending_attention))
	strings.write_string(&b, `,"guide_agent_id":"`); json_write_string(&b, guide_agent_instance_id())
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

isUserActionableTask_for_guide :: proc(task: Task_State) -> bool {
	if task.status == .Review_Ready && task_requires_user_review(task) do return true
	if task.status == .Blocked do return strings.contains(task.description, "user") || strings.contains(task.description, "operator")
	return false
}

guide_rpc_list_chains_json :: proc(limit: int, status_filter: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"chains":[`)
	first := true
	count := 0
	chains := store_all_chains()
	for i := len(chains) - 1; i >= 0; i -= 1 {
		chain := chains[i]
		if status_filter != "" && chain.status != status_filter do continue
		if count >= limit do break
		if !first do strings.write_string(&b, `,`)
		first = false
		task_write_chain_json(&b, chain)
		count += 1
	}
	strings.write_string(&b, `],"count":`); strings.write_string(&b, fmt.tprintf("%d", count)); strings.write_string(&b, `}`)
	return strings.to_string(b)
}

guide_rpc_show_chain_json :: proc(chain_id: string) -> string {
	if chain_id == "" do return `{"ok":false,"message":"chain_id required"}`
	chain, found := store_get_chain(chain_id)
	if !found do return `{"ok":false,"message":"unknown chain_id"}`
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"chain":`)
	task_write_chain_json(&b, chain)
	strings.write_string(&b, `,"tasks":[`)
	first := true
	for state in store_tasks_in_chain(chain_id) {
		if !first do strings.write_string(&b, `,`)
		first = false
		guide_rpc_write_task_json(&b, state)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

guide_rpc_write_task_json :: proc(b: ^strings.Builder, task: Task_State) {
	strings.write_string(b, `{"task_id":"`); json_write_string(b, task.task_id)
	strings.write_string(b, `","chain_id":"`); json_write_string(b, task.chain_id)
	strings.write_string(b, `","title":"`); json_write_string(b, task.title)
	strings.write_string(b, `","status":"`); json_write_string(b, task_status_to_string(task.status))
	strings.write_string(b, `","priority":"`); json_write_string(b, task.priority)
	strings.write_string(b, `","assignee_agent_instance_id":"`); json_write_string(b, task.assignee_agent_instance_id)
	strings.write_string(b, `","depends_on":"`); json_write_string(b, task.depends_on)
	strings.write_string(b, `","updated_at_unix_ms":`); strings.write_string(b, fmt.tprintf("%d", task.updated_at_unix_ms))
	strings.write_string(b, `}`)
}

guide_rpc_agents_json :: proc(agent_id: string) -> string {
	b := strings.builder_make()
	if agent_id != "" {
		idx := agent_record_index_by_instance(agent_id)
		if idx < 0 do return `{"ok":false,"message":"unknown agent_instance_id"}`
		strings.write_string(&b, `{"ok":true,"agent":`)
		agent_instance_record_json(&b, agent_instance_records[idx])
		strings.write_string(&b, `}`)
		return strings.to_string(b)
	}
	strings.write_string(&b, `{"ok":true,"agents":[`)
	first := true
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		agent_instance_record_json(&b, rec)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

guide_rpc_ui_debug_status_json :: proc() -> string {
	registry := guide_rpc_ui_debug_registry_json()
	port, found := guide_rpc_ui_debug_first_port(registry)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"available":`); strings.write_string(&b, "true" if found else "false")
	strings.write_string(&b, `,"active_port":`); strings.write_string(&b, fmt.tprintf("%d", port))
	strings.write_string(&b, `,"registry_path":"`); json_write_string(&b, guide_rpc_ui_debug_registry_path())
	strings.write_string(&b, `","instances":`)
	if registry == "" {
		strings.write_string(&b, `[]`)
	} else {
		strings.write_string(&b, registry)
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

guide_rpc_ui_debug_action_json :: proc(body: string) -> string {
	registry := guide_rpc_ui_debug_registry_json()
	port, found := guide_rpc_ui_debug_first_port(registry)
	if !found do return `{"ok":false,"message":"no active Electron debug server registered"}`
	debug_action := extract_json_string(body, "debug_action", extract_json_string(body, "debug", ""))
	path := ""
	switch debug_action {
	case "info": path = "/info"
	case "state": path = "/state"
	case "elements": path = "/elements"
	case "logs": path = "/logs"
	case:
		return `{"ok":false,"message":"unsupported or mutating UI debug action; allowed: info, state, elements, logs"}`
	}
	base := fmt.tprintf("http://127.0.0.1:%d", port)
	resp, ok := http.get(base, path)
	if !ok do return `{"ok":false,"message":"Electron debug server request failed"}`
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"debug_action":"`); json_write_string(&b, debug_action)
	strings.write_string(&b, `","port":`); strings.write_string(&b, fmt.tprintf("%d", port))
	strings.write_string(&b, `,"status":`); strings.write_string(&b, fmt.tprintf("%d", resp.status))
	strings.write_string(&b, `,"result":`)
	if strings.trim_space(resp.body) == "" {
		strings.write_string(&b, `null`)
	} else {
		strings.write_string(&b, resp.body)
	}
	strings.write_string(&b, `}`)
	fmt.printfln("GUIDE_UI_DEBUG ts_unix_ms=%d action=%s port=%d status=%d", router_now_unix_ms(), debug_action, port, resp.status)
	return strings.to_string(b)
}

guide_rpc_ui_debug_registry_path :: proc() -> string {
	if server_data_dir != "" do return fmt.tprintf("%s/debug-instances.json", server_data_dir)
	return "debug-instances.json"
}

guide_rpc_ui_debug_registry_json :: proc() -> string {
	path := guide_rpc_ui_debug_registry_path()
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return ""
	defer delete(data)
	text := strings.trim_space(string(data))
	if text == "" do return ""
	return strings.clone(text)
}

guide_rpc_ui_debug_first_port :: proc(registry: string) -> (int, bool) {
	if registry == "" do return 0, false
	search := registry
	for {
		idx := strings.index(search, `"port"`)
		if idx < 0 do return 0, false
		after := search[idx + len(`"port"`):]
		colon := strings.index(after, ":")
		if colon < 0 do return 0, false
		rest := strings.trim_left(after[colon + 1:], " \t\r\n")
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
		if end > 0 {
			if parsed, ok := strconv.parse_int(rest[:end]); ok && parsed > 0 do return int(parsed), true
		}
		if len(after) <= colon + 1 do return 0, false
		search = after[colon + 1:]
	}
}
