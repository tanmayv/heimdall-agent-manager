package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"

Agent_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	agents: ^agent_service.Agent_Service,
	event_bus: ^events.User_Event_Bus,
}

list_agents_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	cursor := query_value(req.query, "cursor")
	agents, err := agent_service.list_agents(h.agents, auth_ctx, limit, cursor)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	next_cursor := ""
	for agent, i in agents { if i > 0 do strings.write_byte(&b, ','); write_agent_json(&b, h.agents, agent); next_cursor = agent.created_at }
	strings.write_byte(&b, ']')
	has_more := len(agents) >= limit
	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, next_cursor = next_cursor if has_more else "", has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}

create_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	agent, created, err := agent_service.create_agent(h.agents, auth_ctx, agent_input_from_body(req.body))
	if !created do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	agent_id := path_part(req.path, 4)
	if strings.contains(agent_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	agent, got, err := agent_service.get_agent(h.agents, auth_ctx, agent_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

update_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	agent, updated, err := agent_service.update_agent(h.agents, auth_ctx, path_part(req.path, 4), agent_input_from_body(req.body))
	if !updated do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

archive_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	agent, archived, err := agent_service.archive_agent(h.agents, auth_ctx, path_part(req.path, 4))
	if !archived do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	supports, err := agent_service.list_support(h.agents, auth_ctx, path_part(req.path, 4))
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for support, i in supports { if i > 0 do strings.write_byte(&b, ','); write_support_json(&b, support) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

put_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	inputs := support_inputs_from_body(req.body)
	supports, saved, err := agent_service.replace_supports(h.agents, auth_ctx, path_part(req.path, 4), inputs)
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for support, i in supports { if i > 0 do strings.write_byte(&b, ','); write_support_json(&b, support) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

patch_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return patch_agent_support_common(ctx, req, path_part(req.path, 6))
}

patch_agent_support_common :: proc(ctx: rawptr, req: Request, bridge_id: string) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	input := support_input_from_body(req.body)
	if input.bridge_id == "" do input.bridge_id = bridge_id
	support, saved, err := agent_service.upsert_support(h.agents, auth_ctx, path_part(req.path, 4), input)
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_support_json(&b, support)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

delete_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	deleted, err := agent_service.delete_support(h.agents, auth_ctx, path_part(req.path, 4), path_part(req.path, 6))
	if !deleted do return respond_error(err, req.request_id)
	return respond_success("{\"deleted\":true}", req.request_id, auth_ctx_server_time(req))
}

list_agent_instances_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	cursor := query_value(req.query, "cursor")
	instances, err := agent_service.list_instances_filtered(h.agents, auth_ctx, agent_service.List_Instances_Filter{agent_id = query_value(req.query, "agent_id"), bridge_id = query_value(req.query, "bridge_id"), runtime_status = query_value(req.query, "runtime_status")}, limit, cursor)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	next_cursor := ""
	for inst, i in instances { if i > 0 do strings.write_byte(&b, ','); write_agent_instance_json(&b, inst); next_cursor = inst.created_at }
	strings.write_byte(&b, ']')
	has_more := len(instances) >= limit
	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, next_cursor = next_cursor if has_more else "", has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}

create_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	inst, created, err := agent_service.create_instance(h.agents, auth_ctx, instance_input_from_body(req.body))
	if !created do return respond_error(err, req.request_id)
	events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "created", agent_instance_summary_json(inst))
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_instance_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := path_part(req.path, 4)
	if strings.contains(instance_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	inst, got, err := agent_service.get_instance(h.agents, auth_ctx, instance_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

stop_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	inst, stopped, err := agent_service.stop_instance(h.agents, auth_ctx, path_part(req.path, 4), agent_service.Stop_Instance_Input{reason = json_string(req.body, "reason")})
	if !stopped do return respond_error(err, req.request_id)
	events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", agent_instance_summary_json(inst))
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

restart_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	inst, restarted, err := agent_service.restart_instance(h.agents, auth_ctx, path_part(req.path, 4))
	if !restarted do return respond_error(err, req.request_id)
	events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", agent_instance_summary_json(inst))
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

patch_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	inst, updated, err := agent_service.reconfigure_instance(h.agents, auth_ctx, path_part(req.path, 4), reconfigure_input_from_body(req.body))
	if !updated do return respond_error(err, req.request_id)
	events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", agent_instance_summary_json(inst))
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

agent_input_from_body :: proc(body: string) -> agent_service.Create_Agent_Input {
	return agent_service.Create_Agent_Input{name = json_string(body, "name"), slug = json_string(body, "slug"), template_id = json_string(body, "template_id"), default_provider = json_string(body, "default_provider"), default_tier = json_string(body, "default_tier"), instructions = json_string(body, "instructions"), has_default_provider = strings.contains(body, "\"default_provider\""), has_default_tier = strings.contains(body, "\"default_tier\"")}
}

instance_input_from_body :: proc(body: string) -> agent_service.Create_Instance_Input {
	return agent_service.Create_Instance_Input{agent_id = json_string(body, "agent_id"), bridge_id = json_string(body, "bridge_id"), provider = json_string(body, "provider"), tier = json_string(body, "tier"), project_id = domain.Project_ID(json_string(body, "project_id")), chain_id = json_string(body, "chain_id")}
}

reconfigure_input_from_body :: proc(body: string) -> agent_service.Reconfigure_Instance_Input {
	return agent_service.Reconfigure_Instance_Input{provider = json_string(body, "provider"), tier = json_string(body, "tier"), agent_id = json_string(body, "agent_id"), bridge_id = json_string(body, "bridge_id"), chain_id = json_string(body, "chain_id"), conversation_id = json_string(body, "conversation_id"), project_id = domain.Project_ID(json_string(body, "project_id")), has_agent_id = strings.contains(body, "\"agent_id\""), has_bridge_id = strings.contains(body, "\"bridge_id\""), has_project_id = strings.contains(body, "\"project_id\""), has_chain_id = strings.contains(body, "\"chain_id\""), has_conversation_id = strings.contains(body, "\"conversation_id\"")}
}

support_input_from_body :: proc(body: string) -> agent_service.Support_Input {
	return agent_service.Support_Input{bridge_id = json_string(body, "bridge_id"), enabled = !strings.contains(body, "\"enabled\":false"), provider = json_string(body, "provider"), tier = json_string(body, "tier"), priority = json_int(body, "priority", 0), max_instances = json_int(body, "max_instances", 0)}
}

support_inputs_from_body :: proc(body: string) -> []agent_service.Support_Input {
	out := make([dynamic]agent_service.Support_Input)
	bridges_array := json_array_optional(body, "bridges")
	if strings.trim_space(bridges_array) != "" && bridges_array != "[]" {
		for obj in support_object_list_from_array(bridges_array) do append(&out, support_input_from_body(obj))
		return out[:]
	}
	if strings.contains(body, "\"bridge_id\"") do append(&out, support_input_from_body(body))
	return out[:]
}

support_object_list_from_array :: proc(array: string) -> []string {
	out := make([dynamic]string)
	depth := 0
	in_string := false
	escaped := false
	start := -1
	for i := 0; i < len(array); i += 1 {
		ch := array[i]
		if in_string {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' { in_string = true; continue }
		if ch == '{' { if depth == 0 do start = i; depth += 1; continue }
		if ch == '}' { depth -= 1; if depth == 0 && start >= 0 { append(&out, array[start:i + 1]); start = -1 } }
	}
	return out[:]
}

write_agent_json :: proc(b: ^strings.Builder, service: ^agent_service.Agent_Service, a: domain.Agent) {
	strings.write_string(b, "{\"agent_id\":\""); write_handler_json_string(b, a.agent_id)
	strings.write_string(b, "\",\"name\":\""); write_handler_json_string(b, a.name)
	strings.write_string(b, "\",\"slug\":\""); write_handler_json_string(b, a.slug)
	strings.write_string(b, "\",\"template_id\":\""); write_handler_json_string(b, a.template_id)
	strings.write_string(b, "\",\"default_provider\":\""); write_handler_json_string(b, a.default_provider)
	strings.write_string(b, "\",\"default_tier\":\""); write_handler_json_string(b, a.default_tier)
	strings.write_string(b, "\",\"instructions\":\""); write_handler_json_string(b, a.instructions)
	strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, domain.agent_state_string(a.state))
	strings.write_string(b, "\",\"supported_bridge_count\":"); strings.write_string(b, i32_to_string_http(agent_service.supported_bridge_count_for_agent(service, a)))
	strings.write_string(b, ",\"active_instance_count\":"); strings.write_string(b, i32_to_string_http(agent_service.active_instance_count_for_agent(service, a)))
	strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, a.updated_at)
	strings.write_string(b, "\"}")
}

agent_instance_summary_json :: proc(inst: domain.Agent_Instance) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"runtime_status\":\""); write_handler_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"startup_status\":\""); write_handler_json_string(&b, inst.startup_status)
	strings.write_string(&b, "\",\"activity_status\":\""); write_handler_json_string(&b, inst.activity_status)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

write_agent_instance_json :: proc(b: ^strings.Builder, inst: domain.Agent_Instance) {
	strings.write_string(b, "{\"agent_instance_id\":\""); write_handler_json_string(b, inst.agent_instance_id)
	strings.write_string(b, "\",\"agent_id\":\""); write_handler_json_string(b, inst.agent_id)
	strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, inst.bridge_id)
	strings.write_string(b, "\",\"provider\":\""); write_handler_json_string(b, inst.provider)
	strings.write_string(b, "\",\"tier\":\""); write_handler_json_string(b, inst.tier)
	strings.write_string(b, "\",\"project_id\":\""); write_handler_json_string(b, string(inst.project_id))
	strings.write_string(b, "\",\"project_path\":\""); write_handler_json_string(b, inst.project_path)
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, inst.chain_id)
	strings.write_string(b, "\",\"conversation_id\":\""); write_handler_json_string(b, inst.conversation_id)
	strings.write_string(b, "\",\"runtime_status\":\""); write_handler_json_string(b, inst.runtime_status)
	strings.write_string(b, "\",\"startup_status\":\""); write_handler_json_string(b, inst.startup_status)
	strings.write_string(b, "\",\"activity_status\":\""); write_handler_json_string(b, inst.activity_status)
	strings.write_string(b, "\",\"last_applied_seq\":"); strings.write_string(b, i32_to_string_http(inst.last_applied_seq))
	strings.write_string(b, ",\"run_count\":"); strings.write_string(b, i32_to_string_http(inst.run_count))
	strings.write_string(b, ",\"started_at\":\""); write_handler_json_string(b, inst.started_at)
	strings.write_string(b, "\",\"stopped_at\":\""); write_handler_json_string(b, inst.stopped_at)
	strings.write_string(b, "\",\"last_seen_at\":\""); write_handler_json_string(b, inst.last_seen_at)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, inst.updated_at)
	strings.write_string(b, "\"}")
}

i32_to_string_http :: proc(v: int) -> string {
	return fmt.tprintf("%d", v)
}

write_support_json :: proc(b: ^strings.Builder, s: domain.Agent_Bridge_Support) {
	strings.write_string(b, "{\"agent_id\":\""); write_handler_json_string(b, s.agent_id)
	strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, s.bridge_id)
	strings.write_string(b, "\",\"enabled\":"); strings.write_string(b, "true" if s.enabled else "false")
	strings.write_string(b, ",\"provider\":\""); write_handler_json_string(b, s.provider)
	strings.write_string(b, "\",\"tier\":\""); write_handler_json_string(b, s.tier)
	strings.write_string(b, "\",\"priority\":"); strings.write_string(b, i32_to_string_http(s.priority))
	strings.write_string(b, ",\"max_instances\":"); strings.write_string(b, i32_to_string_http(s.max_instances))
	strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, s.updated_at)
	strings.write_string(b, "\"}")
}
