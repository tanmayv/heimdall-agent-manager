package http

import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import platform "odin_test:hub/platform"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

Bridge_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	bridges: ^bridge_service.Bridge_Service,
	agents: ^agent_service.Agent_Service,
	event_bus: ^events.User_Event_Bus,
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
}

create_bridge_enrollment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	label := json_string(req.body, "label")
	if json_key_present(req.body, "expires_at") do return respond_error(domain.domain_error(.Validation_Failed, "expires_at is not accepted; use expires_in_seconds"), req.request_id)
	expires_in_seconds := json_int(req.body, "expires_in_seconds", 900)
	if expires_in_seconds <= 0 || expires_in_seconds > 86400 do return respond_error(domain.domain_error(.Validation_Failed, "expires_in_seconds must be between 1 and 86400"), req.request_id)
	expires_at := platform.expires_at_after_seconds(expires_in_seconds)
	result, result_ok, err := bridge_service.create_enrollment(h.bridges, auth_ctx, bridge_service.Create_Enrollment_Input{label = label, expires_at = expires_at})
	if !result_ok do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"enrollment_id\":\"")
	write_handler_json_string(&b, result.enrollment.enrollment_id)
	strings.write_string(&b, "\",\"expires_at\":\"")
	write_handler_json_string(&b, result.enrollment.expires_at)
	strings.write_string(&b, "\",\"setup_command\":\"ham-bridge enroll --hub $HAM_HUB_URL\",\"enrollment_token\":\"")
	write_handler_json_string(&b, result.token)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

list_bridge_enrollments_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	enrollments, err := bridge_service.list_enrollments(h.bridges, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for enrollment, i in enrollments {
		if i > 0 do strings.write_byte(&b, ',')
		write_enrollment_json(&b, enrollment)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

revoke_bridge_enrollment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	enrollment_id := suffix_after(req.path, "/api/v1/bridge-enrollments/")
	enrollment, revoke_ok, err := bridge_service.revoke_enrollment(h.bridges, auth_ctx, enrollment_id)
	if !revoke_ok do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_enrollment_json(&b, enrollment)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

enroll_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok || !strings.has_prefix(token, "hbe_") do return respond_error(domain.domain_error(.Unauthenticated, "enrollment bearer token is required"), req.request_id)
	hostname := json_string(req.body, "hostname")
	if hostname == "" do return respond_error(domain.domain_error(.Validation_Failed, "machine.hostname is required"), req.request_id)
	result, ok, err := bridge_service.enroll_bridge(h.bridges, bridge_service.Enroll_Bridge_Input{enrollment_token = token, machine_hostname = hostname, machine_os = json_string(req.body, "os"), machine_arch = json_string(req.body, "arch"), capabilities_json = req.body, hub_url = json_string(req.body, "hub_url")})
	if !ok do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\"")
	write_handler_json_string(&b, result.bridge.bridge_id)
	strings.write_string(&b, "\",\"bridge_token\":\"")
	write_handler_json_string(&b, result.bridge_token)
	strings.write_string(&b, "\",\"hub_url\":\""); write_handler_json_string(&b, result.bridge.hub_url); strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

list_bridges_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridges, err := bridge_service.list_bridges(h.bridges, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for bridge, i in bridges {
		if i > 0 do strings.write_byte(&b, ',')
		write_bridge_json(&b, bridge, h.agents)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

bridge_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	bridge_id := suffix_after(req.path, "/api/v1/bridges/")
	if strings.contains(bridge_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	auth_ctx: contracts.Auth_Context
	if token, has_bearer := bearer_token(req); has_bearer {
		if rejected, resp := reject_query_or_body_token(req); rejected do return resp
		bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
		if !bridge_ok do return respond_error(bridge_err, req.request_id)
		if bridge_auth.bridge_id != bridge_id do return respond_error(domain.domain_error(.Not_Found, "bridge not found"), req.request_id)
		auth_ctx = bridge_auth
	} else {
		user_auth, ok, auth_resp := require_auth(h.auth, req)
		if !ok do return auth_resp
		auth_ctx = user_auth
	}
	bridge, bridge_ok, err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_bridge_json(&b, bridge, h.agents)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

rename_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := suffix_after(req.path, "/api/v1/bridges/")
	bridge, rename_ok, err := bridge_service.rename_bridge(h.bridges, auth_ctx, bridge_id, json_string(req.body, "label"))
	if !rename_ok do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_bridge_json(&b, bridge, h.agents)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_bridge_providers_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_provider_relay(h, req, path_part(req.path, 4), "list_providers", "", "")
	if !ok do return bridge_provider_error_response(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

put_bridge_provider_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	name := path_part(req.path, 6)
	if strings.trim_space(name) == "" do return bridge_provider_error_response(domain.domain_error(.Validation_Failed, "provider name is required"), req.request_id)
	result, ok, err := bridge_provider_relay(h, req, path_part(req.path, 4), "upsert_provider", name, req.body)
	if !ok do return bridge_provider_error_response(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

delete_bridge_provider_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_provider_relay(h, req, path_part(req.path, 4), "delete_provider", path_part(req.path, 6), "")
	if !ok do return bridge_provider_error_response(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

test_bridge_provider_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_provider_relay(h, req, path_part(req.path, 4), "test_provider", path_part(req.path, 6), req.body)
	if !ok do return bridge_provider_error_response(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

refresh_bridge_providers_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_provider_relay(h, req, path_part(req.path, 4), "refresh_capabilities", "", "")
	if !ok do return bridge_provider_error_response(err, req.request_id)
	_, _, _ = bridge_service.update_runtime_capabilities(h.bridges, path_part(req.path, 4), result)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

bridge_provider_error_response :: proc(err: domain.Domain_Error, request_id: string) -> Response {
	if err.code != .Validation_Failed do return respond_error(err, request_id)
	return Response{status = 422, content_type = "application/json", body = contracts.api_error_json(contracts.API_Error{code = domain.error_code_string(err.code), message = err.message, details_json = err.details_json}, contracts.api_meta(request_id, ""))}
}

bridge_provider_relay :: proc(h: ^Bridge_Handlers, req: Request, bridge_id, command_type, provider_name, body: string) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp.body, false, domain.domain_error(.Unauthenticated, "authentication required")
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_provider_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := bridge_provider_command_json(command_type, command_id, provider_name, body)
	timeout_ms := 10000
	if command_type == "test_provider" do timeout_ms = json_int(cmd_body, "hard_deadline_ms", 90000) + 10000
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, timeout_ms)
	if !reply_ok do return "", false, reply_err
	reply_type := json_string(reply, "type")
	if command_type == "list_providers" && reply_type == "providers_report" {
		payload, _ := json_object_raw_balanced(reply, "payload")
		if payload == "" do payload = "{}"
		return payload, true, domain.Domain_Error{}
	}
	status := json_string(reply, "status")
	result, _ := json_object_raw_balanced(reply, "result")
	if result == "" do result = "{}"
	if status == "failed" {
		message := json_string(result, "error")
		if message == "" do message = json_string(result, "message")
		if message == "" do message = "provider command failed"
		return "", false, domain.domain_error(.Validation_Failed, message)
	}
	return result, true, domain.Domain_Error{}
}

bridge_provider_test_bound_int :: proc(body, key: string, fallback, min, max: int) -> int {
	value := json_int(body, key, fallback)
	if value < min do return min
	if value > max do return max
	return value
}

bridge_provider_command_json :: proc(command_type, command_id, provider_name, body: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, command_type)
	strings.write_string(&b, "\",\"protocol_version\":1,\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":")
	switch command_type {
	case "list_providers", "refresh_capabilities":
		strings.write_string(&b, "{}")
	case "upsert_provider":
		strings.write_string(&b, "{\"name\":\""); write_handler_json_string(&b, provider_name)
		strings.write_string(&b, "\",\"profile\":")
		if strings.trim_space(body) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, body) }
		strings.write_string(&b, "}")
	case "delete_provider":
		strings.write_string(&b, "{\"name\":\""); write_handler_json_string(&b, provider_name); strings.write_string(&b, "\"}")
	case "test_provider":
		strings.write_string(&b, "{\"name\":\""); write_handler_json_string(&b, provider_name); strings.write_string(&b, "\"")
		tier := json_string(body, "tier")
		if tier != "" { strings.write_string(&b, ",\"tier\":\""); write_handler_json_string(&b, tier); strings.write_string(&b, "\"") }
		strings.write_string(&b, ",\"capture_frames\":"); strings.write_string(&b, "true" if strings.contains(body, "\"capture_frames\":true") else "false")
		launch_deadline_ms := bridge_provider_test_bound_int(body, "launch_deadline_ms", 20000, 1000, 300000)
		start_success_deadline_ms := bridge_provider_test_bound_int(body, "start_success_deadline_ms", 60000, 1000, 300000)
		hard_deadline_ms := bridge_provider_test_bound_int(body, "hard_deadline_ms", 90000, start_success_deadline_ms, 300000)
		frame_interval_ms := bridge_provider_test_bound_int(body, "frame_interval_ms", 500, 200, 5000)
		strings.write_string(&b, ",\"launch_deadline_ms\":"); strings.write_string(&b, fmt.tprintf("%d", launch_deadline_ms))
		strings.write_string(&b, ",\"start_success_deadline_ms\":"); strings.write_string(&b, fmt.tprintf("%d", start_success_deadline_ms))
		strings.write_string(&b, ",\"hard_deadline_ms\":"); strings.write_string(&b, fmt.tprintf("%d", hard_deadline_ms))
		strings.write_string(&b, ",\"frame_interval_ms\":"); strings.write_string(&b, fmt.tprintf("%d", frame_interval_ms))
		strings.write_string(&b, "}")
	case:
		strings.write_string(&b, "{}")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_ws_upgrade_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected { write_upgrade_error(client, resp); return }
	token, token_ok := bearer_token(req)
	if !token_ok { write_upgrade_error(client, respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)); return }
	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" { write_upgrade_error(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id)); return }
	if !write_ws_upgrade_response(client, ws_accept_key(key)) do return
	hello_text, hello_frame_ok := read_ws_text_blocking(client, 3 * time.Second)
	if !hello_frame_ok do return
	bridge, connect_ok, err := bridge_service.bridge_runtime_connect(h.bridges, token, json_string(hello_text, "hostname"), json_string(hello_text, "os"), json_string(hello_text, "arch"), hello_text)
	if !connect_ok { _ = write_ws_text_frame(client, bridge_ws_error_payload(err.message)); return }
	body_bridge_id := json_string(hello_text, "bridge_id")
	if body_bridge_id != "" && body_bridge_id != bridge.bridge_id { _ = write_ws_text_frame(client, bridge_ws_error_payload("bridge_id does not match bearer token")); return }
	hello, hello_ok, hello_err := bridge_runtime_service.runtime_accept_hello(h.bridge_runtime_registry, bridge.bridge_id, json_int(hello_text, "protocol_version", 1), json_string(hello_text, "validation_ws_url"))
	if !hello_ok { _ = write_ws_text_frame(client, bridge_ws_error_payload(hello_err.message)); return }
	project_service.bridge_runtime_registry_set_command_socket(h.bridge_runtime_registry, bridge.bridge_id, client)
	_ = write_ws_text_frame(client, bridge_ready_payload(bridge.bridge_id, hello.generation, hello.replaced_existing))
	bridge_ws_runtime_loop(h, bridge.bridge_id, hello.generation, client)
}

bridge_ws_runtime_loop :: proc(h: ^Bridge_Handlers, bridge_id: string, connection_generation: int, client: net.TCP_Socket) {
	defer project_service.bridge_runtime_registry_mark_offline(h.bridge_runtime_registry, bridge_id, connection_generation)
	for {
		text, ok := read_ws_text_blocking(client, 60 * time.Second)
		if !ok do return
		if project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) != connection_generation {
			_ = write_ws_text_frame(client, bridge_connection_replaced_payload())
			return
		}
		type := json_string(text, "type")
		switch type {
		case "bridge_heartbeat":
			if strings.contains(text, "\"capabilities\"") { _, _, _ = bridge_service.update_runtime_capabilities(h.bridges, bridge_id, text) }
			active := json_string_array(text, "active_instance_ids")
			digest_active := bridge_apply_heartbeat_digest(h, bridge_id, text)
			if len(active) == 0 && len(digest_active) > 0 do active = digest_active
			reconciled := bridge_runtime_service.runtime_reconcile_digest(h.bridge_runtime_registry, active)
			if h.agents != nil do reconciled += agent_service.reconcile_bridge_heartbeat(h.agents, bridge_id, active)
			_ = write_ws_text_frame(client, bridge_heartbeat_ack_payload(reconciled))
		case "agent_instance_status":
			instance_id := json_string(text, "agent_instance_id")
			state_seq := json_int(text, "state_seq", 0)
			runtime_status := json_string(text, "runtime_status")
			activity_status := json_string(text, "activity_status")
			_ = bridge_runtime_service.runtime_apply_state_report(h.bridge_runtime_registry, instance_id, state_seq, runtime_status, activity_status)
			if h.agents != nil {
				if inst, applied, _ := agent_service.apply_bridge_status_report(h.agents, bridge_id, instance_id, state_seq, runtime_status, activity_status); applied {
					events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status))
				}
			}
			current_runtime, _, current_seq, got := bridge_runtime_service.runtime_instance_status(h.bridge_runtime_registry, instance_id)
			_ = got
			applied := current_seq == state_seq && current_runtime == runtime_status
			_ = write_ws_text_frame(client, bridge_state_ack_payload(instance_id, applied, current_seq, current_runtime))
		case "command_result", "project_path_validation_result", "providers_report":
			command_id := json_string(text, "command_id")
			_, _ = bridge_runtime_service.runtime_command_result_idempotent(h.bridge_runtime_registry, bridge_id, command_id, text)
		case "capability_report":
			_, _, _ = bridge_service.update_runtime_capabilities(h.bridges, bridge_id, text)
		case "provider_test_status", "provider_test_frame":
			owner_user_id := bridge_service.bridge_owner_user_id(h.bridges, bridge_id)
			events.publish_raw_to_user(h.event_bus, owner_user_id, text)
		}

	}
}

bridge_apply_heartbeat_digest :: proc(h: ^Bridge_Handlers, bridge_id, text: string) -> []string {
	active := make([dynamic]string)
	search_from := 0
	for search_from < len(text) {
		rel := strings.index(text[search_from:], "\"agent_instance_id\"")
		if rel < 0 do break
		idx := search_from + rel
		next_rel := strings.index(text[idx + len("\"agent_instance_id\""):], "\"agent_instance_id\"")
		end := len(text)
		if next_rel >= 0 do end = idx + len("\"agent_instance_id\"") + next_rel
		entry := text[idx:end]
		instance_id := json_string(entry, "agent_instance_id")
		state_seq := json_int(entry, "state_seq", 0)
		runtime_status := json_string(entry, "runtime_status")
		activity_status := json_string(entry, "activity_status")
		if instance_id != "" {
			_ = bridge_runtime_service.runtime_apply_state_report(h.bridge_runtime_registry, instance_id, state_seq, runtime_status, activity_status)
			if h.agents != nil {
				if inst, applied, _ := agent_service.apply_bridge_status_report(h.agents, bridge_id, instance_id, state_seq, runtime_status, activity_status); applied {
					events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status))
				}
			}
			append(&active, instance_id)
		}
		search_from = end
	}
	return active[:]
}

bridge_ws_handler :: proc(ctx: rawptr, req: Request) -> Response {
	_ = ctx
	return respond_error(domain.domain_error(.Validation_Failed, "bridge runtime requires WebSocket upgrade"), req.request_id)
}

bridge_instance_bootstrap_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	instance_id := path_part(req.path, 5)
	bundle, bundle_ok, bundle_err := agent_service.bootstrap_json_for_bridge(h.agents, domain.User_ID(bridge_auth.user_id), bridge_auth.bridge_id, instance_id)
	if !bundle_ok do return respond_error(bundle_err, req.request_id)
	return respond_success(bundle, req.request_id, auth_ctx_server_time(req))
}

revoke_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/revoke")
	bridge, revoke_ok, err := bridge_service.revoke_bridge(h.bridges, auth_ctx, bridge_id)
	if !revoke_ok do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_bridge_json(&b, bridge, h.agents)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

bearer_token :: proc(req: Request) -> (string, bool) {
	authz := header_value(req.headers, "Authorization")
	if !strings.has_prefix(authz, "Bearer ") do return "", false
	return strings.trim_space(authz[len("Bearer "):]), true
}

suffix_after :: proc(value, prefix: string) -> string {
	if strings.has_prefix(value, prefix) do return value[len(prefix):]
	return ""
}

write_enrollment_json :: proc(b: ^strings.Builder, e: domain.Bridge_Enrollment) {
	strings.write_string(b, "{\"enrollment_id\":\""); write_handler_json_string(b, e.enrollment_id)
	strings.write_string(b, "\",\"label\":\""); write_handler_json_string(b, e.label)
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, domain.enrollment_status_string(e.status))
	strings.write_string(b, "\",\"expires_at\":\""); write_handler_json_string(b, e.expires_at)
	strings.write_string(b, "\",\"consumed_at\":\""); write_handler_json_string(b, e.consumed_at)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, e.created_at)
	strings.write_string(b, "\"}")
}

write_bridge_json :: proc(b: ^strings.Builder, br: domain.Bridge, agents: ^agent_service.Agent_Service) {
	strings.write_string(b, "{\"bridge_id\":\""); write_handler_json_string(b, br.bridge_id)
	strings.write_string(b, "\",\"label\":\""); write_handler_json_string(b, br.label)
	strings.write_string(b, "\",\"label_is_user_customized\":"); strings.write_string(b, "true" if br.label_is_user_customized else "false")
	strings.write_string(b, ",\"machine_hostname\":\""); write_handler_json_string(b, br.machine_hostname)
	strings.write_string(b, "\",\"machine_os\":\""); write_handler_json_string(b, br.machine_os)
	strings.write_string(b, "\",\"machine_arch\":\""); write_handler_json_string(b, br.machine_arch)
	strings.write_string(b, "\",\"hub_url\":\""); write_handler_json_string(b, br.hub_url)
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, domain.bridge_status_string(br.status))
	strings.write_string(b, "\",\"capabilities\":"); strings.write_string(b, bridge_capabilities_json(br))
	strings.write_string(b, ",\"active_instance_count\":"); strings.write_string(b, fmt.tprintf("%d", agent_service.active_instance_count_for_bridge(agents, br.bridge_id)))
	strings.write_string(b, ",\"last_seen_at\":\""); write_handler_json_string(b, br.last_seen_at)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, br.updated_at)
	strings.write_string(b, "\",\"revoked_at\":\""); write_handler_json_string(b, br.revoked_at)
	strings.write_string(b, "\"}")
}

json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 {
		if rest[i] == '"' do return rest[1:i]
	}
	return ""
}

json_object_raw_balanced :: proc(body, key: string) -> (string, bool) {
	start := json_member_value_start_bridge(body, key)
	if start < 0 do return "", false
	rest := strings.trim_space(body[start:])
	if len(rest) == 0 || rest[0] != '{' do return "", false
	return json_balanced_from_bridge(rest, '{', '}')
}

json_array_raw_balanced :: proc(body, key: string) -> (string, bool) {
	start := json_member_value_start_bridge(body, key)
	if start < 0 do return "", false
	rest := strings.trim_space(body[start:])
	if len(rest) == 0 || rest[0] != '[' do return "", false
	return json_balanced_from_bridge(rest, '[', ']')
}

json_member_value_start_bridge :: proc(body, key: string) -> int {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return -1
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return -1
	return idx + len(needle) + colon + 1
}

json_balanced_from_bridge :: proc(rest: string, open, close: byte) -> (string, bool) {
	depth := 0
	in_string := false
	escaped := false
	for i in 0..<len(rest) {
		ch := rest[i]
		if in_string {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' { in_string = true; continue }
		if ch == open do depth += 1
		if ch == close {
			depth -= 1
			if depth == 0 do return rest[:i + 1], true
		}
	}
	return "", false
}

bridge_capabilities_json :: proc(br: domain.Bridge) -> string {
	if br.capabilities_json == "" || !strings.contains(br.capabilities_json, "capabilities") do return "[]"
	if caps, ok := json_array_raw_balanced(br.capabilities_json, "capabilities"); ok do return caps
	provider := json_string(br.capabilities_json, "provider")
	default_tier := json_string(br.capabilities_json, "default_tier")
	if provider == "" do return "[]"
	b := strings.builder_make()
	strings.write_string(&b, "[{\"provider\":\""); write_handler_json_string(&b, provider)
	strings.write_string(&b, "\",\"tiers\":[]")
	strings.write_string(&b, ",\"default_tier\":\""); write_handler_json_string(&b, default_tier)
	strings.write_string(&b, "\"}]")
	return strings.to_string(b)
}

json_key_present :: proc(body, key: string) -> bool {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	return strings.index(body, needle) >= 0
}

bridge_ready_payload :: proc(bridge_id: string, generation: int, replaced: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_ready\",\"protocol_version\":1,\"payload\":{\"bridge_id\":\"")
	write_handler_json_string(&b, bridge_id)
	strings.write_string(&b, "\",\"heartbeat_interval_seconds\":15,\"command_ack_timeout_seconds\":10,\"connection_generation\":")
	strings.write_string(&b, fmt.tprintf("%d", generation))
	strings.write_string(&b, ",\"replaced_existing\":")
	strings.write_string(&b, "true" if replaced else "false")
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_connection_replaced_payload :: proc() -> string {
	return "{\"type\":\"connection_replaced\",\"protocol_version\":1,\"payload\":{\"reason\":\"newer_bridge_connection\"}}"
}

bridge_heartbeat_ack_payload :: proc(reconciled: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat_ack\",\"protocol_version\":1,\"payload\":{\"reconciled_unreachable_count\":")
	strings.write_string(&b, fmt.tprintf("%d", reconciled))
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

agent_instance_status_summary_json :: proc(runtime_status, startup_status, activity_status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"runtime_status\":\""); write_handler_json_string(&b, runtime_status)
	strings.write_string(&b, "\",\"startup_status\":\""); write_handler_json_string(&b, startup_status)
	strings.write_string(&b, "\",\"activity_status\":\""); write_handler_json_string(&b, activity_status)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_state_ack_payload :: proc(instance_id: string, applied: bool, state_seq: int, runtime_status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"agent_instance_status_ack\",\"protocol_version\":1,\"payload\":{\"agent_instance_id\":\"")
	write_handler_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"applied\":")
	strings.write_string(&b, "true" if applied else "false")
	strings.write_string(&b, ",\"state_seq\":")
	strings.write_string(&b, fmt.tprintf("%d", state_seq))
	strings.write_string(&b, ",\"runtime_status\":\"")
	write_handler_json_string(&b, runtime_status)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_ws_error_payload :: proc(message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_error\",\"protocol_version\":1,\"payload\":{\"message\":\"")
	write_handler_json_string(&b, message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

write_upgrade_error :: proc(client: net.TCP_Socket, resp: Response) { write_http_response(client, resp) }

write_ws_upgrade_response :: proc(client: net.TCP_Socket, accept_key: string) -> bool {
	response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept_key)
	_, err := net.send_tcp(client, transmute([]byte)response)
	return err == nil
}

ws_accept_key :: proc(key: string) -> string {
	GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	combined := fmt.tprintf("%s%s", key, GUID)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:])
}

read_ws_text_blocking :: proc(client: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(client, .Receive_Timeout, timeout)
	buf: [8192]byte
	n, err := net.recv_tcp(client, buf[:])
	if err != nil || n < 2 do return "", false
	opcode := buf[0] & 0x0f
	if opcode != 0x1 do return "", false
	masked := (buf[1] & 0x80) != 0
	payload_len := int(buf[1] & 0x7f)
	offset := 2
	if payload_len == 126 {
		if n < 4 do return "", false
		payload_len = int(buf[2]) << 8 | int(buf[3])
		offset = 4
	}
	mask_key: [4]byte
	if masked {
		if n < offset + 4 do return "", false
		mask_key = {buf[offset], buf[offset + 1], buf[offset + 2], buf[offset + 3]}
		offset += 4
	}
	if n < offset + payload_len do return "", false
	payload := make([]byte, payload_len)
	copy(payload, buf[offset:offset + payload_len])
	if masked { for i in 0..<payload_len { payload[i] = payload[i] ~ mask_key[i % 4] } }
	return string(payload), true
}

write_ws_text_frame :: proc(client: net.TCP_Socket, text: string) -> bool {
	n := len(text)
	if n > 65535 do return false
	header_len := 2
	if n > 125 do header_len = 4
	frame := make([]byte, header_len + n)
	frame[0] = 0x81
	if n <= 125 { frame[1] = byte(n) } else { frame[1] = 126; frame[2] = byte((n >> 8) & 0xff); frame[3] = byte(n & 0xff) }
	copy(frame[header_len:], transmute([]byte)text)
	_, err := net.send_tcp(client, frame)
	return err == nil
}

json_string_array :: proc(body, key: string) -> []string {
	out := make([dynamic]string)
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return out[:]
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return out[:]
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '[' do return out[:]
	i := 1
	for i < len(rest) && rest[i] != ']' {
		for i < len(rest) && rest[i] != '"' && rest[i] != ']' do i += 1
		if i >= len(rest) || rest[i] == ']' do break
		start := i + 1
		i = start
		for i < len(rest) && rest[i] != '"' do i += 1
		if i <= len(rest) { append(&out, rest[start:i]) }
		i += 1
	}
	return out[:]
}

json_int :: proc(body, key: string, default_value: int) -> int {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return default_value
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return default_value
	rest = strings.trim_space(rest[colon + 1:])
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
	if end == 0 do return default_value
	v, ok := strconv.parse_int(rest[:end])
	if !ok do return default_value
	return int(v)
}
