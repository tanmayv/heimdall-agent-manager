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

Action_Handlers :: struct {
	auth:            ^auth_service.Auth_Service,
	agents:          ^agent_service.Agent_Service,
	bridges:         ^bridge_service.Bridge_Service,
	content:         ^content_service.Content_Service,
	repo:            ^iface.Action_Repository,
	clock:           ^platform.Clock,
	ids:             ^platform.ID_Generator,
	mutex:           ^sync.Mutex,
	bridge_versions: ^map[string]int,
}

Scheduled_Prompt_Handlers :: Action_Handlers

get_actions_bridge_version :: proc(raw: rawptr, bridge_id: string) -> int {
	if raw == nil || bridge_id == "" do return 0
	h := (^Action_Handlers)(raw)
	if h.mutex == nil || h.bridge_versions == nil do return 0
	sync.mutex_lock(h.mutex)
	defer sync.mutex_unlock(h.mutex)
	return h.bridge_versions^[bridge_id]
}

get_scheduled_prompts_bridge_version :: get_actions_bridge_version

bump_bridge_version :: proc(h: ^Action_Handlers, bridge_id: string) {
	if h == nil || bridge_id == "" do return
	if h.mutex == nil || h.bridge_versions == nil do return
	sync.mutex_lock(h.mutex)
	defer sync.mutex_unlock(h.mutex)
	h.bridge_versions^[bridge_id] += 1
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
		num, num_ok := strconv.parse_int(s)
		if num_ok && num > 0 do return num
		return 0
	}
}

validate_cron_field :: proc(field: string, min_val, max_val: int) -> bool {
	f := strings.trim_space(field)
	if f == "" do return false
	if f == "*" do return true

	// Step: */N or A-B/N
	if strings.contains(f, "/") {
		slash_parts := strings.split(f, "/")
		defer delete(slash_parts)
		if len(slash_parts) != 2 do return false
		base := slash_parts[0]
		step_val, step_ok := strconv.parse_int(slash_parts[1])
		if !step_ok || step_val <= 0 do return false
		if base != "*" {
			if !validate_cron_field(base, min_val, max_val) do return false
		}
		return true
	}

	// Comma separated values: A,B,C
	if strings.contains(f, ",") {
		subparts := strings.split(f, ",")
		defer delete(subparts)
		if len(subparts) == 0 do return false
		for sp in subparts {
			if !validate_cron_field(sp, min_val, max_val) do return false
		}
		return true
	}

	// Range: A-B
	if strings.contains(f, "-") {
		dash_parts := strings.split(f, "-")
		defer delete(dash_parts)
		if len(dash_parts) != 2 do return false
		v1, ok1 := strconv.parse_int(dash_parts[0])
		v2, ok2 := strconv.parse_int(dash_parts[1])
		if !ok1 || !ok2 do return false
		if v1 < min_val || v2 > max_val || v1 > v2 do return false
		return true
	}

	// Single integer
	val, ok := strconv.parse_int(f)
	if !ok do return false
	if val < min_val || val > max_val do return false
	return true
}

validate_cron_expression :: proc(cron_expr: string) -> (bool, string) {
	trimmed := strings.trim_space(cron_expr)
	if trimmed == "" do return false, "cron_expr cannot be empty"

	parts := strings.fields(trimmed)
	defer delete(parts)

	if len(parts) != 5 {
		return false, "cron_expr must have exactly 5 fields (minute hour day-of-month month day-of-week)"
	}

	if !validate_cron_field(parts[0], 0, 59) {
		return false, "invalid minute field in cron_expr (must be 0-59, *, range, or step)"
	}
	if !validate_cron_field(parts[1], 0, 23) {
		return false, "invalid hour field in cron_expr (must be 0-23, *, range, or step)"
	}
	if !validate_cron_field(parts[2], 1, 31) {
		return false, "invalid day-of-month field in cron_expr (must be 1-31, *, range, or step)"
	}
	if !validate_cron_field(parts[3], 1, 12) {
		return false, "invalid month field in cron_expr (must be 1-12, *, range, or step)"
	}
	if !validate_cron_field(parts[4], 0, 7) {
		return false, "invalid day-of-week field in cron_expr (must be 0-7, *, range, or step)"
	}

	return true, ""
}

write_action_json :: proc(b: ^strings.Builder, a: domain.Action) {
	strings.write_string(b, "{\"id\":\"")
	write_handler_json_string(b, string(a.id))
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, string(a.owner_user_id))
	strings.write_string(b, "\",\"target_instance_id\":\"")
	write_handler_json_string(b, string(a.target_instance_id))
	strings.write_string(b, "\",\"prompt_text\":\"")
	write_handler_json_string(b, a.prompt_text)
	strings.write_string(b, "\",\"cron_expr\":\"")
	write_handler_json_string(b, a.cron_expr)
	strings.write_string(b, "\",\"timezone\":\"")
	write_handler_json_string(b, a.timezone if a.timezone != "" else "UTC")
	strings.write_string(b, "\",\"blackout_dates\":")
	strings.write_string(b, a.blackout_dates if a.blackout_dates != "" else "[]")
	strings.write_string(b, ",\"active_from\":\"")
	write_handler_json_string(b, a.active_from)
	strings.write_string(b, "\",\"active_until\":\"")
	write_handler_json_string(b, a.active_until)
	strings.write_string(b, "\",\"target_run_at\":\"")
	write_handler_json_string(b, a.target_run_at)
	strings.write_string(b, "\",\"interval\":\"")
	write_handler_json_string(b, a.interval)
	strings.write_string(b, "\",\"state\":\"")
	switch a.state {
	case .In_Flight: strings.write_string(b, "in_flight")
	case .Completed: strings.write_string(b, "completed")
	case .Active: strings.write_string(b, "active")
	}
	strings.write_string(b, "\",\"in_flight\":")
	strings.write_string(b, "true" if a.in_flight else "false")
	strings.write_string(b, ",\"leased_at\":\"")
	write_handler_json_string(b, a.leased_at)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, a.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, a.updated_at)
	strings.write_string(b, "\"}")
}

write_scheduled_prompt_json :: write_action_json

list_actions_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	actions, err := h.repo.list(h.repo.ctx, domain.User_ID(auth_ctx.user_id))
	if err.code != .None do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":[")
	for act, i in actions {
		if i > 0 do strings.write_string(&b, ",")
		write_action_json(&b, act)
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_scheduled_prompts_handler :: list_actions_handler

create_action_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	target_instance_id := json_string(req.body, "target_instance_id")
	prompt_text := json_string(req.body, "prompt_text")
	cron_expr := strings.trim_space(json_string(req.body, "cron_expr"))
	timezone := strings.trim_space(json_string(req.body, "timezone"))
	blackout_dates := strings.trim_space(json_string(req.body, "blackout_dates"))
	active_from := strings.trim_space(json_string(req.body, "active_from"))
	active_until := strings.trim_space(json_string(req.body, "active_until"))
	target_run_at := strings.trim_space(json_string(req.body, "target_run_at"))
	interval := strings.trim_space(json_string(req.body, "interval"))

	if target_instance_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "target_instance_id is required"), req.request_id)
	if prompt_text == "" do return respond_error(domain.domain_error(.Validation_Failed, "prompt_text is required"), req.request_id)

	if cron_expr != "" {
		valid, cron_err := validate_cron_expression(cron_expr)
		if !valid {
			return respond_error(domain.domain_error(.Validation_Failed, fmt.tprintf("invalid cron_expr: %s", cron_err)), req.request_id)
		}
	}

	if interval != "" {
		secs := parse_interval_seconds(interval)
		if secs < 60 {
			return respond_error(domain.domain_error(.Validation_Failed, "interval must be at least 60 seconds (format: <number>[smhd])"), req.request_id)
		}
	}

	if blackout_dates != "" {
		if !strings.has_prefix(blackout_dates, "[") || !strings.has_suffix(blackout_dates, "]") {
			return respond_error(domain.domain_error(.Validation_Failed, "blackout_dates must be a JSON array of YYYY-MM-DD strings"), req.request_id)
		}
	} else {
		blackout_dates = "[]"
	}

	if timezone == "" do timezone = "UTC"

	inst, inst_ok, inst_err := agent_service.get_instance(h.agents, auth_ctx, target_instance_id)
	if !inst_ok do return respond_error(inst_err, req.request_id)

	now := platform.clock_now(h.clock)
	// For cron actions we must NOT seed target_run_at = now, or the action fires
	// immediately on create and (with a minutely expression) every tick after.
	// Leaving it empty lets the bridge compute the first real cron slot in the
	// action's timezone (bridge_action_scheduler_sync -> compute_next_run when
	// target_run_at is unset). Interval actions have no wall-clock schedule, so
	// firing the first run now is the intended behavior.
	if target_run_at == "" && interval != "" && cron_expr == "" {
		target_run_at = now
	}

	act := domain.Action{
		id = domain.Action_ID(platform.generate_id(h.ids, "act_")),
		owner_user_id = domain.User_ID(auth_ctx.user_id),
		target_instance_id = domain.Agent_Instance_ID(target_instance_id),
		prompt_text = prompt_text,
		cron_expr = cron_expr,
		timezone = timezone,
		blackout_dates = blackout_dates,
		active_from = active_from,
		active_until = active_until,
		target_run_at = target_run_at,
		interval = interval,
		state = .Active,
		in_flight = false,
		created_at = now,
		updated_at = now,
	}

	saved, save_ok, save_err := h.repo.save(h.repo.ctx, act)
	if !save_ok do return respond_error(save_err, req.request_id)

	bump_bridge_version(h, inst.bridge_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":")
	write_action_json(&b, saved)
	strings.write_string(&b, "}")
	return Response{status = 201, content_type = "application/json", body = strings.to_string(b)}
}

create_scheduled_prompt_handler :: create_action_handler

get_action_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	id := domain.Action_ID(path_part(req.path, 4))
	act, act_ok, _ := h.repo.get(h.repo.ctx, id)
	if !act_ok do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)
	if string(act.owner_user_id) != auth_ctx.user_id do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":")
	write_action_json(&b, act)
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

get_scheduled_prompt_handler :: get_action_handler

patch_action_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	id := domain.Action_ID(path_part(req.path, 4))
	act, act_ok, _ := h.repo.get(h.repo.ctx, id)
	if !act_ok do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)
	if string(act.owner_user_id) != auth_ctx.user_id do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)

	if json_key_present(req.body, "prompt_text") do act.prompt_text = json_string(req.body, "prompt_text")
	if json_key_present(req.body, "cron_expr") {
		ce := strings.trim_space(json_string(req.body, "cron_expr"))
		if ce != "" {
			valid, cron_err := validate_cron_expression(ce)
			if !valid {
				return respond_error(domain.domain_error(.Validation_Failed, fmt.tprintf("invalid cron_expr: %s", cron_err)), req.request_id)
			}
		}
		act.cron_expr = ce
	}
	if json_key_present(req.body, "timezone") {
		tz := strings.trim_space(json_string(req.body, "timezone"))
		if tz == "" do tz = "UTC"
		act.timezone = tz
	}
	if json_key_present(req.body, "blackout_dates") {
		bd := strings.trim_space(json_string(req.body, "blackout_dates"))
		if bd != "" && (!strings.has_prefix(bd, "[") || !strings.has_suffix(bd, "]")) {
			return respond_error(domain.domain_error(.Validation_Failed, "blackout_dates must be a JSON array of YYYY-MM-DD strings"), req.request_id)
		}
		if bd == "" do bd = "[]"
		act.blackout_dates = bd
	}
	if json_key_present(req.body, "active_from") do act.active_from = json_string(req.body, "active_from")
	if json_key_present(req.body, "active_until") do act.active_until = json_string(req.body, "active_until")
	if json_key_present(req.body, "target_run_at") do act.target_run_at = json_string(req.body, "target_run_at")
	if json_key_present(req.body, "interval") {
		new_interval := json_string(req.body, "interval")
		if new_interval != "" {
			secs := parse_interval_seconds(new_interval)
			if secs < 60 {
				return respond_error(domain.domain_error(.Validation_Failed, "interval must be at least 60 seconds (format: <number>[smhd])"), req.request_id)
			}
		}
		act.interval = new_interval
	}
	if json_key_present(req.body, "state") {
		st := json_string(req.body, "state")
		switch st {
		case "in_flight": act.state = .In_Flight
		case "completed": act.state = .Completed
		case "active": act.state = .Active
		}
	}
	now := platform.clock_now(h.clock)
	act.updated_at = now

	saved, save_ok, save_err := h.repo.save(h.repo.ctx, act)
	if !save_ok do return respond_error(save_err, req.request_id)

	inst, inst_ok, _ := iface.agent_get_instance(h.agents.agents, string(act.target_instance_id))
	if inst_ok do bump_bridge_version(h, inst.bridge_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":")
	write_action_json(&b, saved)
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

patch_scheduled_prompt_handler :: patch_action_handler

delete_action_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	id := domain.Action_ID(path_part(req.path, 4))
	act, act_ok, _ := h.repo.get(h.repo.ctx, id)
	if !act_ok do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)
	if string(act.owner_user_id) != auth_ctx.user_id do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)

	del_ok, del_err := h.repo.delete_action(h.repo.ctx, id)
	if !del_ok do return respond_error(del_err, req.request_id)

	inst, inst_ok, _ := iface.agent_get_instance(h.agents.agents, string(act.target_instance_id))
	if inst_ok do bump_bridge_version(h, inst.bridge_id)

	return Response{status = 200, content_type = "application/json", body = "{\"deleted\":true}"}
}

delete_scheduled_prompt_handler :: delete_action_handler

run_action_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	id := domain.Action_ID(path_part(req.path, 4))
	act, act_ok, _ := h.repo.get(h.repo.ctx, id)
	if !act_ok do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)
	if string(act.owner_user_id) != auth_ctx.user_id do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)

	inst, inst_ok, inst_err := agent_service.get_instance(h.agents, auth_ctx, string(act.target_instance_id))
	if !inst_ok do return respond_error(inst_err, req.request_id)

	// Ensure target instance is running (wake/relaunch via existing plumbing if stopped/failed/unreachable)
	if inst.runtime_status == "stopped" || inst.runtime_status == "failed" || inst.runtime_status == "unreachable" {
		_, restarted, restart_err := agent_service.restart_instance(h.agents, auth_ctx, string(act.target_instance_id))
		if !restarted do return respond_error(restart_err, req.request_id)
	}

	conv_id := inst.conversation_id
	if conv_id == "" {
		c, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth_ctx, inst.agent_instance_id)
		if conv_ok do conv_id = c.conversation_id
	}
	if conv_id == "" {
		return respond_error(domain.domain_error(.Internal_Error, "target instance conversation not found"), req.request_id)
	}

	msg, msg_ok, msg_err := content_service.send_message(
		h.content,
		auth_ctx,
		conv_id,
		content_service.Message_Input{
			body = act.prompt_text,
			message_type = "action",
		},
	)
	if !msg_ok do return respond_error(msg_err, req.request_id)

	bump_bridge_version(h, inst.bridge_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"message_id\":\"")
	write_handler_json_string(&b, msg.message_id)
	strings.write_string(&b, "\",\"data\":")
	write_action_json(&b, act)
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

bridge_list_actions_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)

	bridge_id := bridge_auth.bridge_id
	version := get_actions_bridge_version(h, bridge_id)
	etag := fmt.tprintf("W/\"%d\"", version)

	if_none_match := strings.trim_space(header_value(req.headers, "If-None-Match"))
	if if_none_match != "" && (if_none_match == etag || etag_unquote(if_none_match) == fmt.tprintf("%d", version)) {
		headers := make([]contracts.HTTP_Header, 1)
		headers[0] = contracts.HTTP_Header{name = "ETag", value = etag}
		return Response{status = 304, content_type = "application/json", body = "", headers = headers}
	}

	instances, inst_err := iface.agent_list_instances_by_bridge(h.agents.agents, bridge_id)
	actions := make([dynamic]domain.Action)
	if inst_err.code == .None {
		for inst in instances {
			list, _ := h.repo.list_by_instance(h.repo.ctx, domain.Agent_Instance_ID(inst.agent_instance_id))
			for item in list {
				append(&actions, item)
			}
		}
	}

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":[")
	for act, i in actions {
		if i > 0 do strings.write_string(&b, ",")
		write_action_json(&b, act)
	}
	strings.write_string(&b, "]}")

	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = contracts.HTTP_Header{name = "ETag", value = etag}
	return Response{status = 200, content_type = "application/json", body = strings.to_string(b), headers = headers}
}

bridge_list_scheduled_prompts_handler :: bridge_list_actions_handler

bridge_execute_action_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Action_Handlers)(ctx)
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)

	// Route: /api/v1/bridge/actions/*/execute or /api/v1/bridge/scheduled-prompts/*/execute -> id is at path_part index 5
	id := domain.Action_ID(path_part(req.path, 5))
	act, act_ok, _ := h.repo.get(h.repo.ctx, id)
	if !act_ok do return respond_error(domain.domain_error(.Not_Found, "action not found"), req.request_id)

	inst, inst_ok, _ := iface.agent_get_instance(h.agents.agents, string(act.target_instance_id))
	if !inst_ok || inst.bridge_id != bridge_auth.bridge_id {
		return respond_error(domain.domain_error(.Forbidden, "action target instance does not belong to this bridge"), req.request_id)
	}

	now := platform.clock_now(h.clock)

	// Atomic CAS lease
	leased, _ := h.repo.cas_lease(h.repo.ctx, id, now, now)
	if !leased {
		return respond_error(domain.domain_error(.Conflict, "action is not eligible for execution or already in flight"), req.request_id)
	}

	conv_id := inst.conversation_id
	if conv_id == "" {
		c, conv_ok, _ := content_service.get_conversation_by_instance(h.content, contracts.Auth_Context{kind = .User_Token, user_id = string(act.owner_user_id)}, inst.agent_instance_id)
		if conv_ok do conv_id = c.conversation_id
	}

	if conv_id == "" {
		return respond_error(domain.domain_error(.Internal_Error, "target instance conversation not found"), req.request_id)
	}

	// Message type is 'action'
	msg, msg_ok, msg_err := content_service.send_message(
		h.content,
		contracts.Auth_Context{kind = .User_Token, user_id = string(act.owner_user_id)},
		conv_id,
		content_service.Message_Input{
			body = act.prompt_text,
			message_type = "action",
		},
	)
	if !msg_ok {
		return respond_error(msg_err, req.request_id)
	}

	next_run := json_string(req.body, "target_run_at")
	if next_run == "" do next_run = json_string(req.body, "next_target_run_at")

	// The bridge is the scheduling authority: it computes the next fire slot
	// (cron in the action's timezone + blackout/active-window handling, or the
	// interval advance) and sends it as target_run_at on every execute. So:
	//   - next_run present  -> trust it verbatim (recurring; reschedule).
	//   - next_run absent   -> the schedule is exhausted (one-shot, or the bridge
	//                          found no further slot within the active window);
	//                          complete the action.
	// Previously an absent next_run made the hub blindly reschedule cron/interval
	// actions by +60s (or +interval), which resurrected exhausted actions and,
	// for minutely crons, produced an every-minute execute loop. The bridge never
	// omits a genuine next slot, so a blind server-side advance is always wrong.
	if next_run != "" {
		act.target_run_at = next_run
		act.state = .Active
		act.in_flight = false
		act.leased_at = ""
		act.updated_at = now
	} else {
		act.state = .Completed
		act.in_flight = false
		act.leased_at = ""
		act.updated_at = now
	}

	_, _, _ = h.repo.save(h.repo.ctx, act)
	bump_bridge_version(h, inst.bridge_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"message_id\":\"")
	write_handler_json_string(&b, msg.message_id)
	strings.write_string(&b, "\",\"data\":")
	write_action_json(&b, act)
	strings.write_string(&b, "}")
	return Response{status = 200, content_type = "application/json", body = strings.to_string(b)}
}

bridge_execute_scheduled_prompt_handler :: bridge_execute_action_handler
