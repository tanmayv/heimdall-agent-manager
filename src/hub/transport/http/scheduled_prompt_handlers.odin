package http

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import content_service "odin_test:hub/service/content"

Scheduled_Prompt_Handlers :: struct {
	auth:            ^auth_service.Auth_Service,
	agents:          ^agent_service.Agent_Service,
	bridges:         ^bridge_service.Bridge_Service,
	content:         ^content_service.Content_Service,
	repo:            ^iface.Scheduled_Prompt_Repository,
	clock:           ^platform.Clock,
	ids:             ^platform.ID_Generator,
	mutex:           sync.Mutex,
	bridge_versions: map[string]int,
}

get_scheduled_prompts_bridge_version :: proc(raw: rawptr, bridge_id: string) -> int {
	if raw == nil || bridge_id == "" do return 0
	h := (^Scheduled_Prompt_Handlers)(raw)
	sync.mutex_lock(&h.mutex)
	defer sync.mutex_unlock(&h.mutex)
	if h.bridge_versions == nil do return 0
	return h.bridge_versions[bridge_id]
}

bump_bridge_version :: proc(h: ^Scheduled_Prompt_Handlers, bridge_id: string) {
	if h == nil || bridge_id == "" do return
	sync.mutex_lock(&h.mutex)
	defer sync.mutex_unlock(&h.mutex)
	if h.bridge_versions == nil {
		h.bridge_versions = make(map[string]int)
	}
	h.bridge_versions[bridge_id] += 1
}

// Parses an interval string into seconds.
// Supported formats: [0-9]+[smhd] (e.g. "60s", "5m", "2h", "1d"), or bare positive integer seconds.
// Returns 0 if invalid or non-positive.
parse_interval_seconds :: proc(interval: string) -> int {
	s := strings.trim_space(interval)
	if len(s) == 0 do return 0
	unit := s[len(s)-1]
	val_str := s[:len(s)-1]
	val, ok := strconv.parse_int(val_str)
	if !ok || val <= 0 do return 0
	switch unit {
	case 's': return val
	case 'm': return val * 60
	case 'h': return val * 3600
	case 'd': return val * 86400
	case:
		// Also support bare integer seconds, e.g. "90" -> 90s, format [0-9]+[smhd]
		num, num_ok := strconv.parse_int(s)
		if num_ok && num > 0 do return num
		return 0
	}
}

advance_target_run_at :: proc(curr_target_run_at: string, interval: string) -> string {
	secs := parse_interval_seconds(interval)
	if secs <= 0 do return curr_target_run_at
	return platform.expires_at_after_seconds(secs)
}

write_scheduled_prompt_json :: proc(b: ^strings.Builder, sp: domain.Scheduled_Prompt) {
	strings.write_string(b, "{\"id\":\"")
	write_handler_json_string(b, string(sp.id))
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, string(sp.owner_user_id))
	strings.write_string(b, "\",\"target_instance_id\":\"")
	write_handler_json_string(b, string(sp.target_instance_id))
	strings.write_string(b, "\",\"prompt_text\":\"")
	write_handler_json_string(b, sp.prompt_text)
	strings.write_string(b, "\",\"target_run_at\":\"")
	write_handler_json_string(b, sp.target_run_at)
	strings.write_string(b, "\",\"interval\":\"")
	write_handler_json_string(b, sp.interval)
	strings.write_string(b, "\",\"state\":\"")
	switch sp.state {
	case .In_Flight: strings.write_string(b, "in_flight")
	case .Completed: strings.write_string(b, "completed")
	case .Active: strings.write_string(b, "active")
	}
	strings.write_string(b, "\",\"in_flight\":")
	strings.write_string(b, "true" if sp.in_flight else "false")
	strings.write_string(b, ",\"leased_at\":\"")
	write_handler_json_string(b, sp.leased_at)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, sp.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, sp.updated_at)
	strings.write_string(b, "\"}")
}

list_scheduled_prompts_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Scheduled_Prompt_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	prompts, err := h.repo.list(h.repo.ctx, domain.User_ID(auth_ctx.user_id))
	if err.code != .None do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":[")
	for sp, i in prompts {
		if i > 0 do strings.write_string(&b, ",")
		write_scheduled_prompt_json(&b, sp)
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

create_scheduled_prompt_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Scheduled_Prompt_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	target_instance_id := json_string(req.body, "target_instance_id")
	prompt_text := json_string(req.body, "prompt_text")
	target_run_at := json_string(req.body, "target_run_at")
	interval := json_string(req.body, "interval")

	if target_instance_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "target_instance_id is required"), req.request_id)
	if prompt_text == "" do return respond_error(domain.domain_error(.Validation_Failed, "prompt_text is required"), req.request_id)
	if target_run_at == "" do return respond_error(domain.domain_error(.Validation_Failed, "target_run_at is required"), req.request_id)
	if interval != "" {
		secs := parse_interval_seconds(interval)
		if secs < 60 {
			return respond_error(domain.domain_error(.Validation_Failed, "interval must be at least 60 seconds (format: <number>[smhd])"), req.request_id)
		}
	}

	inst, inst_ok, inst_err := agent_service.get_instance(h.agents, auth_ctx, target_instance_id)
	if !inst_ok do return respond_error(inst_err, req.request_id)

	now := platform.clock_now(h.clock)
	sp := domain.Scheduled_Prompt{
		id = domain.Scheduled_Prompt_ID(platform.generate_id(h.ids, "sp_")),
		owner_user_id = domain.User_ID(auth_ctx.user_id),
		target_instance_id = domain.Agent_Instance_ID(target_instance_id),
		prompt_text = prompt_text,
		target_run_at = target_run_at,
		interval = interval,
		state = .Active,
		in_flight = false,
		created_at = now,
		updated_at = now,
	}

	saved, save_ok, save_err := h.repo.save(h.repo.ctx, sp)
	if !save_ok do return respond_error(save_err, req.request_id)

	bump_bridge_version(h, inst.bridge_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":")
	write_scheduled_prompt_json(&b, saved)
	strings.write_string(&b, "}")
	return Response{status = 201, content_type = "application/json", body = strings.to_string(b)}
}

get_scheduled_prompt_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Scheduled_Prompt_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	id := domain.Scheduled_Prompt_ID(path_part(req.path, 4))
	sp, sp_ok, _ := h.repo.get(h.repo.ctx, id)
	if !sp_ok do return respond_error(domain.domain_error(.Not_Found, "scheduled prompt not found"), req.request_id)
	if string(sp.owner_user_id) != auth_ctx.user_id do return respond_error(domain.domain_error(.Not_Found, "scheduled prompt not found"), req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":")
	write_scheduled_prompt_json(&b, sp)
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

patch_scheduled_prompt_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Scheduled_Prompt_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	id := domain.Scheduled_Prompt_ID(path_part(req.path, 4))
	sp, sp_ok, _ := h.repo.get(h.repo.ctx, id)
	if !sp_ok do return respond_error(domain.domain_error(.Not_Found, "scheduled prompt not found"), req.request_id)
	if string(sp.owner_user_id) != auth_ctx.user_id do return respond_error(domain.domain_error(.Not_Found, "scheduled prompt not found"), req.request_id)

	if json_key_present(req.body, "prompt_text") do sp.prompt_text = json_string(req.body, "prompt_text")
	if json_key_present(req.body, "target_run_at") do sp.target_run_at = json_string(req.body, "target_run_at")
	if json_key_present(req.body, "interval") {
		new_interval := json_string(req.body, "interval")
		if new_interval != "" {
			secs := parse_interval_seconds(new_interval)
			if secs < 60 {
				return respond_error(domain.domain_error(.Validation_Failed, "interval must be at least 60 seconds (format: <number>[smhd])"), req.request_id)
			}
		}
		sp.interval = new_interval
	}
	if json_key_present(req.body, "state") {
		st := json_string(req.body, "state")
		switch st {
		case "in_flight": sp.state = .In_Flight
		case "completed": sp.state = .Completed
		case "active": sp.state = .Active
		}
	}
	now := platform.clock_now(h.clock)
	sp.updated_at = now

	saved, save_ok, save_err := h.repo.save(h.repo.ctx, sp)
	if !save_ok do return respond_error(save_err, req.request_id)

	inst, inst_ok, _ := iface.agent_get_instance(h.agents.agents, string(sp.target_instance_id))
	if inst_ok do bump_bridge_version(h, inst.bridge_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":")
	write_scheduled_prompt_json(&b, saved)
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

delete_scheduled_prompt_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Scheduled_Prompt_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	id := domain.Scheduled_Prompt_ID(path_part(req.path, 4))
	sp, sp_ok, _ := h.repo.get(h.repo.ctx, id)
	if !sp_ok do return respond_error(domain.domain_error(.Not_Found, "scheduled prompt not found"), req.request_id)
	if string(sp.owner_user_id) != auth_ctx.user_id do return respond_error(domain.domain_error(.Not_Found, "scheduled prompt not found"), req.request_id)

	del_ok, del_err := h.repo.delete_prompt(h.repo.ctx, id)
	if !del_ok do return respond_error(del_err, req.request_id)

	inst, inst_ok, _ := iface.agent_get_instance(h.agents.agents, string(sp.target_instance_id))
	if inst_ok do bump_bridge_version(h, inst.bridge_id)

	return Response{status = 200, content_type = "application/json", body = "{\"deleted\":true}"}
}

bridge_list_scheduled_prompts_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Scheduled_Prompt_Handlers)(ctx)
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)

	bridge_id := bridge_auth.bridge_id
	version := get_scheduled_prompts_bridge_version(h, bridge_id)
	etag := fmt.tprintf("W/\"%d\"", version)

	if_none_match := strings.trim_space(header_value(req.headers, "If-None-Match"))
	if if_none_match != "" && (if_none_match == etag || etag_unquote(if_none_match) == fmt.tprintf("%d", version)) {
		headers := make([]contracts.HTTP_Header, 1)
		headers[0] = contracts.HTTP_Header{name = "ETag", value = etag}
		return Response{status = 304, content_type = "application/json", body = "", headers = headers}
	}

	instances, inst_err := iface.agent_list_instances_by_bridge(h.agents.agents, bridge_id)
	prompts := make([dynamic]domain.Scheduled_Prompt)
	if inst_err.code == .None {
		for inst in instances {
			list, _ := h.repo.list_by_instance(h.repo.ctx, domain.Agent_Instance_ID(inst.agent_instance_id))
			for item in list {
				append(&prompts, item)
			}
		}
	}

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":[")
	for sp, i in prompts {
		if i > 0 do strings.write_string(&b, ",")
		write_scheduled_prompt_json(&b, sp)
	}
	strings.write_string(&b, "]}")

	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = contracts.HTTP_Header{name = "ETag", value = etag}
	return Response{status = 200, content_type = "application/json", body = strings.to_string(b), headers = headers}
}

bridge_execute_scheduled_prompt_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Scheduled_Prompt_Handlers)(ctx)
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)

	// Route: /api/v1/bridge/scheduled-prompts/*/execute -> id is at path_part index 5
	id := domain.Scheduled_Prompt_ID(path_part(req.path, 5))
	sp, sp_ok, _ := h.repo.get(h.repo.ctx, id)
	if !sp_ok do return respond_error(domain.domain_error(.Not_Found, "scheduled prompt not found"), req.request_id)

	inst, inst_ok, _ := iface.agent_get_instance(h.agents.agents, string(sp.target_instance_id))
	if !inst_ok || inst.bridge_id != bridge_auth.bridge_id {
		return respond_error(domain.domain_error(.Forbidden, "prompt target instance does not belong to this bridge"), req.request_id)
	}

	now := platform.clock_now(h.clock)

	// Atomic CAS lease
	leased, _ := h.repo.cas_lease(h.repo.ctx, id, now, now)
	if !leased {
		return respond_error(domain.domain_error(.Conflict, "prompt is not eligible for execution or already in flight"), req.request_id)
	}

	conv_id := inst.conversation_id
	if conv_id == "" {
		// Deliberately construct user owner Auth_Context to resolve conversation on behalf of prompt owner
		c, conv_ok, _ := content_service.get_conversation_by_instance(h.content, contracts.Auth_Context{kind = .User_Token, user_id = string(sp.owner_user_id)}, inst.agent_instance_id)
		if conv_ok do conv_id = c.conversation_id
	}

	if conv_id == "" {
		return respond_error(domain.domain_error(.Internal_Error, "target instance conversation not found"), req.request_id)
	}

	// Deliberately construct user owner Auth_Context so content_service sends message on behalf of the prompt's owner
	msg, msg_ok, msg_err := content_service.send_message(
		h.content,
		contracts.Auth_Context{kind = .User_Token, user_id = string(sp.owner_user_id)},
		conv_id,
		content_service.Message_Input{
			body = sp.prompt_text,
			message_type = "scheduled",
		},
	)
	if !msg_ok {
		return respond_error(msg_err, req.request_id)
	}

	if sp.interval != "" {
		secs := parse_interval_seconds(sp.interval)
		if secs <= 0 do secs = 60
		sp.target_run_at = platform.expires_at_after_seconds(secs)
		sp.state = .Active
		sp.in_flight = false
		sp.updated_at = now
	} else {
		sp.state = .Completed
		sp.in_flight = false
		sp.updated_at = now
	}

	_, _, _ = h.repo.save(h.repo.ctx, sp)
	bump_bridge_version(h, inst.bridge_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"message_id\":\"")
	write_handler_json_string(&b, msg.message_id)
	strings.write_string(&b, "\",\"data\":")
	write_scheduled_prompt_json(&b, sp)
	strings.write_string(&b, "}")
	return Response{status = 200, content_type = "application/json", body = strings.to_string(b)}
}
