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
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import taskchain_service "odin_test:hub/service/taskchain"
import shell_session_svc "odin_test:hub/service/shell_session"

Bridge_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	bridges: ^bridge_service.Bridge_Service,
	agents: ^agent_service.Agent_Service,
	content: ^content_service.Content_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	projects: ^project_service.Project_Service,
	event_bus: ^events.User_Event_Bus,
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
	actions: rawptr,
	scheduled_prompts: rawptr,
	shell_sessions: ^shell_session_svc.Shell_Session_Service,
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
	// Accept user tokens AND bridge-relayed instance tokens so a coordinator agent
	// can DISCOVER bridges it owns (H5); list_bridges is same-owner scoped in the
	// service (owner_from_auth).
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
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

// POST /api/v1/bridges/{bridge_id}/shells/{shell_id}/input
// Delivers interactive keystrokes and raw PTY input to any target bridge shell.
bridge_shell_input_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell input"), req.request_id)
	}

	bridge_id := path_part(req.path, 4)
	shell_id := path_part(req.path, 6)
	if strings.contains(bridge_id, "/") || strings.contains(shell_id, "/") || strings.trim_space(bridge_id) == "" || strings.trim_space(shell_id) == "" {
		return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	}

	data := json_string(req.body, "data")
	defer delete(data)

	sink_override: project_service.Bridge_Command_Sink = {}
	if h.agents != nil {
		sink_override = h.agents.bridge_command_sink
	}

	sent, err := bridge_service.send_shell_input(h.bridges, auth_ctx, bridge_id, shell_id, data, sink_override)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_bridge_shell_input_handler :: bridge_shell_input_handler

// POST /api/v1/bridges/{bridge_id}/shells/{shell_id}/resize
// Updates the PTY terminal geometry (rows and cols) for any target bridge shell.
bridge_shell_resize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell resize"), req.request_id)
	}

	bridge_id := path_part(req.path, 4)
	shell_id := path_part(req.path, 6)
	if strings.contains(bridge_id, "/") || strings.contains(shell_id, "/") || strings.trim_space(bridge_id) == "" || strings.trim_space(shell_id) == "" {
		return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	}

	rows := json_int(req.body, "rows", 0)
	if rows <= 0 {
		str_val := json_string(req.body, "rows")
		defer delete(str_val)
		if parsed, ok_parse := strconv.parse_int(str_val); ok_parse do rows = int(parsed)
	}

	cols := json_int(req.body, "cols", 0)
	if cols <= 0 {
		str_val := json_string(req.body, "cols")
		defer delete(str_val)
		if parsed, ok_parse := strconv.parse_int(str_val); ok_parse do cols = int(parsed)
	}

	if rows < 1 || cols < 1 {
		return respond_error(domain.domain_error(.Validation_Failed, "rows and cols must be at least 1"), req.request_id)
	}

	sink_override: project_service.Bridge_Command_Sink = {}
	if h.agents != nil {
		sink_override = h.agents.bridge_command_sink
	}

	sent, err := bridge_service.send_shell_resize(h.bridges, auth_ctx, bridge_id, shell_id, rows, cols, sink_override)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_bridge_shell_resize_handler :: bridge_shell_resize_handler

// --- Bridge filesystem directory management (browse/stat/mkdir) -----------
// Live pass-through to the target bridge (no hub persistence). Same owner + online
// guards as the provider relay; the bridge sandboxes every path to its fs_root.

bridge_fs_relay :: proc(h: ^Bridge_Handlers, req: Request, bridge_id, command_type, path: string) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_fs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := bridge_fs_command_json(command_type, command_id, path)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	// The bridge fs_* result IS the payload we return verbatim (already a flat JSON
	// object with ok/path/entries/error). Strip nothing.
	return reply, true, domain.Domain_Error{}
}

bridge_fs_command_json :: proc(command_type, command_id, path: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"path\":\""); write_handler_json_string(&b, path)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

list_bridge_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_fs_relay(h, req, path_part(req.path, 4), "fs_list_dir", query_value(req.query, "path"))
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

stat_bridge_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_fs_relay(h, req, path_part(req.path, 4), "fs_stat", query_value(req.query, "path"))
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

mkdir_bridge_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_fs_relay(h, req, path_part(req.path, 4), "fs_make_dir", json_string(req.body, "path"))
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// --- Project-scoped filesystem browser (browse/read/CRUD) -----------------
// Resolves (project_id -> bridge_id, root_path) via Project_Bridge_Path, then
// relays a WS command carrying that project root so the bridge re-sandboxes every
// path to the project (not the whole bridge fs_root). Same owner + online guards
// as bridge_fs_relay. Request paths are RELATIVE to the project root. The bridge
// result JSON is returned verbatim (already the flat {ok,...,error} envelope).

Project_Fs_Command :: struct {
	command_type: string,
	path:         string, // primary path (relative to project root)
	// list options
	include_hidden: bool,
	send_include_hidden: bool,
	cursor: string,
	limit:  int,
	send_limit: bool,
	// move
	from: string,
	to:   string,
	send_from_to: bool,
	// delete
	recursive: bool,
	send_recursive: bool,
	// read-file byte-range pagination
	offset: int,
	send_offset: bool,
	read_limit: int,
	send_read_limit: bool,
	// single-file write
	content: string,
	send_content: bool,
	// multi-file batch write
	raw_files_json: string,
	send_raw_files: bool,
	// search / quick-open options
	query: string,
	send_query: bool,
	case_sensitive: bool,
	send_case_sensitive: bool,
}

project_fs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Project_Fs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	project_id := domain.Project_ID(path_part(req.path, 4))
	bridge_hint := query_value(req.query, "bridge_id")
	target, target_ok, target_err := project_service.resolve_fs_target(h.projects, auth_ctx, project_id, bridge_hint)
	if !target_ok do return "", false, target_err
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, target.bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_pfs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := project_fs_command_json(cmd, command_id, target.root_path)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

project_fs_command_json :: proc(cmd: Project_Fs_Command, command_id, root_path: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, cmd.command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"root\":\""); write_handler_json_string(&b, root_path)
	strings.write_string(&b, "\"")
	if cmd.send_from_to {
		strings.write_string(&b, ",\"from\":\""); write_handler_json_string(&b, cmd.from)
		strings.write_string(&b, "\",\"to\":\""); write_handler_json_string(&b, cmd.to); strings.write_string(&b, "\"")
	} else {
		strings.write_string(&b, ",\"path\":\""); write_handler_json_string(&b, cmd.path); strings.write_string(&b, "\"")
	}
	if cmd.send_include_hidden {
		strings.write_string(&b, ",\"include_hidden\":"); strings.write_string(&b, "true" if cmd.include_hidden else "false")
	}
	if cmd.cursor != "" {
		strings.write_string(&b, ",\"cursor\":\""); write_handler_json_string(&b, cmd.cursor); strings.write_string(&b, "\"")
	}
	if cmd.send_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.limit)
	}
	if cmd.send_recursive {
		strings.write_string(&b, ",\"recursive\":"); strings.write_string(&b, "true" if cmd.recursive else "false")
	}
	if cmd.send_offset {
		strings.write_string(&b, ",\"offset\":"); strings.write_int(&b, cmd.offset)
	}
	if cmd.send_read_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.read_limit)
	}
	if cmd.send_content {
		strings.write_string(&b, ",\"content\":\""); write_handler_json_string(&b, cmd.content); strings.write_string(&b, "\"")
	}
	if cmd.send_raw_files {
		strings.write_string(&b, ",\"files\":"); strings.write_string(&b, cmd.raw_files_json)
	}
	if cmd.send_query {
		strings.write_string(&b, ",\"query\":\""); write_handler_json_string(&b, cmd.query); strings.write_string(&b, "\"")
	}
	if cmd.send_case_sensitive {
		strings.write_string(&b, ",\"case_sensitive\":"); strings.write_string(&b, "true" if cmd.case_sensitive else "false")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

list_project_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	limit := query_int(req.query, "limit", 0)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_list_dir",
		path = query_value(req.query, "path"),
		include_hidden = query_bool(req.query, "include_hidden", false), send_include_hidden = true,
		cursor = query_value(req.query, "cursor"),
		limit = limit, send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

read_project_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// Byte-range pagination: ?offset= (default 0) & ?limit= (bytes; 0 = bridge
	// default page). Lets the UI stream a large text file in chunks over the
	// size-limited WS relay instead of one frame that times out.
	offset := query_int(req.query, "offset", 0)
	rlimit := query_int(req.query, "limit", 0)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_read_file",
		path = query_value(req.query, "path"),
		offset = offset, send_offset = offset > 0,
		read_limit = rlimit, send_read_limit = rlimit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

create_project_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_create_file", path = json_string(req.body, "path")})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

write_project_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	path := json_string(req.body, "path")
	if path == "" do return respond_error(domain.domain_error(.Validation_Failed, "path is required"), req.request_id)
	content := json_string(req.body, "content")
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_write_file",
		path = path,
		content = content,
		send_content = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

batch_write_project_files_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	files_json, has_files := json_array_raw_balanced(req.body, "files")
	if !has_files {
		trimmed := strings.trim_space(req.body)
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			files_json = trimmed
			has_files = true
		}
	}
	if !has_files do return respond_error(domain.domain_error(.Validation_Failed, "files array is required"), req.request_id)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_batch_write",
		raw_files_json = files_json,
		send_raw_files = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

create_project_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_make_dir", path = json_string(req.body, "path")})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

move_project_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_move", from = json_string(req.body, "from"), to = json_string(req.body, "to"), send_from_to = true})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

delete_project_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_delete", path = query_value(req.query, "path"), recursive = query_bool(req.query, "recursive", false), send_recursive = true})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// --- Project-scoped VCS relay (read-only) ---------------------------------
// Resolves (project_id -> bridge_id, root_path) exactly like project_fs_relay,
// then relays a read-only vcs_* WS command carrying the project root so the
// bridge computes VCS status/diff against the project checkout. Same owner +
// online guards as project_fs_relay. The bridge result JSON is returned verbatim.

Project_Vcs_Command :: struct {
	command_type:  string, // vcs_capabilities | vcs_status | vcs_files | vcs_diff | vcs_log | vcs_commit_diff | vcs_workspaces | vcs_stage | vcs_unstage | vcs_revert
	path:          string, // file path for diff/write commands; empty for others
	cursor:        string,
	limit:         int,
	base_ref:      string, // vcs_commit_diff: compare base
	head_ref:      string, // vcs_commit_diff: compare head (empty/WORKDIR = worktree)
	content:       string, // vcs_save_file: full file text to write
	message:       string, // vcs_commit: commit message
	list_files:    bool, // vcs_commit_diff: return a changed-file list instead of hunks
	send_path:     bool, // whether to include path in JSON body
	send_cursor:   bool,
	send_limit:    bool,
	send_base_ref: bool,
	send_head_ref: bool,
	send_content:  bool, // whether to include content in JSON body
	send_list_files: bool, // whether to include list_files in JSON body
	send_message:  bool, // whether to include message in JSON body
}

project_vcs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Project_Vcs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	project_id := domain.Project_ID(path_part(req.path, 4))
	bridge_hint := query_value(req.query, "bridge_id")
	target, target_ok, target_err := project_service.resolve_fs_target(h.projects, auth_ctx, project_id, bridge_hint)
	if !target_ok do return "", false, target_err
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, target.bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	// Resolve the effective repo root, honoring an optional ?worktree_path override
	// validated against the bridge's vcs_workspaces whitelist (path-traversal guard).
	root_path, root_ok, root_err := project_vcs_effective_root(h, req, bridge.bridge_id, target.root_path)
	if !root_ok do return "", false, root_err
	return project_vcs_send(h, bridge.bridge_id, cmd, root_path)
}

// project_vcs_send builds the vcs_* WS command carrying root_path and relays it to
// the bridge, returning the bridge result JSON verbatim.
project_vcs_send :: proc(h: ^Bridge_Handlers, bridge_id: string, cmd: Project_Vcs_Command, root_path: string) -> (string, bool, domain.Domain_Error) {
	command_id := fmt.tprintf("cmd_pvcs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := project_vcs_command_json(cmd, command_id, root_path)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

// project_vcs_effective_root resolves the repo root the vcs_* command runs against.
// Absent/empty ?worktree_path keeps the project's registered root_path (unchanged
// behavior). When supplied, the path must be absolute AND appear in the bridge's
// vcs_workspaces list for the project root; otherwise the request is rejected with
// HTTP 400 (validation_failed). This is the path-traversal guard: only paths the
// bridge itself advertises as workspaces may be targeted.
project_vcs_effective_root :: proc(h: ^Bridge_Handlers, req: Request, bridge_id: string, root_path: string) -> (string, bool, domain.Domain_Error) {
	worktree := strings.trim_space(query_value(req.query, "worktree_path"))
	if worktree == "" do return root_path, true, domain.Domain_Error{}
	if !strings.has_prefix(worktree, "/") do return "", false, worktree_path_rejected_error(worktree)
	ws_reply, ws_ok, ws_err := project_vcs_send(h, bridge_id, Project_Vcs_Command{command_type = "vcs_workspaces"}, root_path)
	if !ws_ok do return "", false, ws_err
	if vcs_workspaces_has_path(ws_reply, worktree) do return worktree, true, domain.Domain_Error{}
	return "", false, worktree_path_rejected_error(worktree)
}

// worktree_path_rejected_error is the shared 400 for a worktree_path that is not in
// the project's vcs_workspaces whitelist. details carries the machine-readable code
// and the supplied path so callers can surface exactly which override was refused.
worktree_path_rejected_error :: proc(supplied: string) -> domain.Domain_Error {
	b := strings.builder_make()
	strings.write_string(&b, "{\"error\":\"worktree_path_not_in_workspaces\",\"path\":\"")
	write_handler_json_string(&b, supplied)
	strings.write_string(&b, "\"}")
	return domain.domain_error(.Validation_Failed, "worktree_path_not_in_workspaces", strings.to_string(b))
}

// vcs_workspaces_has_path reports whether target exactly equals one of the workspace
// paths in a vcs_workspaces_result. Each workspace object carries a single "path"
// member; we scan every one in the workspaces array and compare unescaped values.
vcs_workspaces_has_path :: proc(ws_reply, target: string) -> bool {
	arr, ok := json_array_raw_balanced(ws_reply, "workspaces")
	if !ok do return false
	needle := "\"path\""
	off := 0
	for {
		idx := strings.index(arr[off:], needle)
		if idx < 0 do break
		if json_string_unescaped(arr[off + idx:], "path") == target do return true
		off += idx + len(needle)
	}
	return false
}

project_vcs_command_json :: proc(cmd: Project_Vcs_Command, command_id, root_path: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, cmd.command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"root\":\""); write_handler_json_string(&b, root_path)
	strings.write_string(&b, "\"")
	if cmd.send_path {
		strings.write_string(&b, ",\"path\":\""); write_handler_json_string(&b, cmd.path); strings.write_string(&b, "\"")
	}
	if cmd.send_base_ref {
		strings.write_string(&b, ",\"base_ref\":\""); write_handler_json_string(&b, cmd.base_ref); strings.write_string(&b, "\"")
	}
	if cmd.send_head_ref {
		strings.write_string(&b, ",\"head_ref\":\""); write_handler_json_string(&b, cmd.head_ref); strings.write_string(&b, "\"")
	}
	if cmd.send_cursor && cmd.cursor != "" {
		strings.write_string(&b, ",\"cursor\":\""); write_handler_json_string(&b, cmd.cursor); strings.write_string(&b, "\"")
	}
	if cmd.send_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.limit)
	}
	if cmd.send_content {
		strings.write_string(&b, ",\"content\":\""); write_handler_json_string(&b, cmd.content); strings.write_string(&b, "\"")
	}
	if cmd.send_list_files && cmd.list_files {
		strings.write_string(&b, ",\"list_files\":true")
	}
	if cmd.send_message && cmd.message != "" {
		strings.write_string(&b, ",\"message\":\""); write_handler_json_string(&b, cmd.message); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

project_handle_vcs_capabilities :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_capabilities"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_status :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_status"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_files :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_files",
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 100), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_diff :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// Accept either "file" or "path" as the query param (diff-view fallback from
	// origin/main ae48d955): the file panel calls with "path", the VCS tab with "file".
	file := query_value(req.query, "file")
	if file == "" do file = query_value(req.query, "path")
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_diff",
		path = file, send_path = true,
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 50), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_log :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_log",
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 50), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_commit_diff :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// list_files mode returns a flat changed-file list (not paginated), so cursor and
	// limit are only forwarded in the default hunk mode.
	list_files := query_bool(req.query, "list_files", false)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_commit_diff",
		base_ref = query_value(req.query, "base_ref"), send_base_ref = true,
		head_ref = query_value(req.query, "head_ref"), send_head_ref = true,
		path = query_value(req.query, "file"), send_path = true,
		list_files = list_files, send_list_files = true,
		cursor = query_value(req.query, "cursor"), send_cursor = !list_files,
		limit = query_int(req.query, "limit", 50), send_limit = !list_files,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_workspaces :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_workspaces"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// project_handle_vcs_write is the shared body for the stage/unstage/revert POST
// endpoints: it maps the JSON body {"file":"<relative-path>"} onto the bridge write
// command's "path" field and relays it. Not cached (mutation).
project_handle_vcs_write :: proc(h: ^Bridge_Handlers, req: Request, command_type: string) -> Response {
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = command_type,
		path = json_string(req.body, "file"), send_path = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_stage :: proc(ctx: rawptr, req: Request) -> Response {
	return project_handle_vcs_write((^Bridge_Handlers)(ctx), req, "vcs_stage")
}

project_handle_vcs_unstage :: proc(ctx: rawptr, req: Request) -> Response {
	return project_handle_vcs_write((^Bridge_Handlers)(ctx), req, "vcs_unstage")
}

project_handle_vcs_revert :: proc(ctx: rawptr, req: Request) -> Response {
	return project_handle_vcs_write((^Bridge_Handlers)(ctx), req, "vcs_revert")
}

// project_handle_vcs_save_file relays an editor save: body {"file":"<relative>",
// "content":"<full text>"[, "worktree_path":".."]} maps onto the bridge vcs_save_file
// command's "path"/"content" fields. worktree_path (query) is validated against the
// vcs_workspaces whitelist by project_vcs_relay like every other write. Not cached.
project_handle_vcs_save_file :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	file := json_string(req.body, "file")
	if file == "" do return respond_error(domain.domain_error(.Validation_Failed, "file is required"), req.request_id)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_save_file",
		path = file, send_path = true,
		content = json_string(req.body, "content"), send_content = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// project_handle_vcs_commit relays a commit: body {"message":"<text>"[, "worktree_path"]}
// maps onto the bridge vcs_commit command's "message" field. worktree_path (query) is
// validated against the vcs_workspaces whitelist by project_vcs_relay like every other
// write. Not cached (mutation). An empty message is rejected with 400 before relaying.
project_handle_vcs_commit :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	message := strings.trim_space(json_string(req.body, "message"))
	if message == "" do return respond_error(domain.domain_error(.Validation_Failed, "message is required"), req.request_id)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_commit",
		message = message, send_message = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// --- Agent instance run-dir browser (READ-ONLY) ---------------------------
// Resolves (instance_id -> owner-checked instance -> bridge_id) then relays a
// read-only agent_run_dir_* command carrying the instance_id. The bridge computes
// the run dir from the id (bridge_runtime_default_run_dir) and re-sandboxes every
// path to it, so the hub never needs to know the run-dir layout. Two-layer owner
// check: get_instance is same-owner scoped (Not_Found for others) and get_bridge
// is owner-scoped. Request paths are RELATIVE to the run-dir root. No mutation
// commands exist for this surface (read-only by construction). The bridge reuses
// the fs_list_dir_result / fs_read_file_result envelopes, returned verbatim.

Instance_Fs_Command :: struct {
	command_type:        string,
	path:                string, // relative to the instance run-dir root
	include_hidden:      bool,
	send_include_hidden: bool,
	cursor:              string,
	limit:               int,
	send_limit:          bool,
	// read-file byte-range pagination
	offset:              int,
	send_offset:         bool,
	read_limit:          int,
	send_read_limit:     bool,
}

instance_fs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Instance_Fs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	instance_id := path_part(req.path, 4)
	inst, got, inst_err := agent_service.get_instance(h.agents, auth_ctx, instance_id)
	if !got do return "", false, inst_err
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, inst.bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_ifs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := instance_fs_command_json(cmd, command_id, inst.agent_instance_id)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

instance_fs_command_json :: proc(cmd: Instance_Fs_Command, command_id, instance_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, cmd.command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"instance_id\":\""); write_handler_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"path\":\""); write_handler_json_string(&b, cmd.path); strings.write_string(&b, "\"")
	if cmd.send_include_hidden {
		strings.write_string(&b, ",\"include_hidden\":"); strings.write_string(&b, "true" if cmd.include_hidden else "false")
	}
	if cmd.cursor != "" {
		strings.write_string(&b, ",\"cursor\":\""); write_handler_json_string(&b, cmd.cursor); strings.write_string(&b, "\"")
	}
	if cmd.send_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.limit)
	}
	if cmd.send_offset {
		strings.write_string(&b, ",\"offset\":"); strings.write_int(&b, cmd.offset)
	}
	if cmd.send_read_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.read_limit)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

list_instance_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	limit := query_int(req.query, "limit", 0)
	// include_hidden defaults TRUE for the run-dir browser (show .heimdall/, dotfiles).
	result, ok, err := instance_fs_relay(h, req, Instance_Fs_Command{
		command_type = "agent_run_dir_list",
		path = query_value(req.query, "path"),
		include_hidden = query_bool(req.query, "include_hidden", true), send_include_hidden = true,
		cursor = query_value(req.query, "cursor"),
		limit = limit, send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

read_instance_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	offset := query_int(req.query, "offset", 0)
	rlimit := query_int(req.query, "limit", 0)
	result, ok, err := instance_fs_relay(h, req, Instance_Fs_Command{
		command_type = "agent_run_dir_read",
		path = query_value(req.query, "path"),
		offset = offset, send_offset = offset > 0,
		read_limit = rlimit, send_read_limit = rlimit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
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

set_bridge_provider_defaults_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_provider_relay(h, req, path_part(req.path, 4), "set_provider_defaults", "", req.body)
	if !ok do return bridge_provider_error_response(err, req.request_id)
	_, _, _ = bridge_service.update_runtime_capabilities(h.bridges, path_part(req.path, 4), result)
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
	// Accept user tokens AND bridge-relayed instance tokens so a running agent can
	// discover a bridge's providers (agent API v2 `bridge providers`). Same-owner
	// scoping is enforced by get_bridge via the auth context.
	auth_ctx, auth_ok, auth_resp := require_auth_any(h.auth, req)
	if !auth_ok do return auth_resp.body, false, domain.domain_error(.Unauthenticated, "authentication required")
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_provider_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := bridge_provider_command_json(command_type, command_id, provider_name, body)
	timeout_ms := 10000
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
	case "set_provider_defaults":
		strings.write_string(&b, "{\"provider\":\""); write_handler_json_string(&b, json_string(body, "provider"))
		strings.write_string(&b, "\",\"tier\":\""); write_handler_json_string(&b, json_string(body, "tier"))
		strings.write_string(&b, "\"}")
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
	// One reader for the whole connection so a hello coalesced with the first frame
	// (or any later coalescing) is never dropped.
	reader := bridge_ws_reader_make(client)
	defer bridge_ws_reader_destroy(&reader)
	hello_text, hello_frame_ok := read_ws_text_blocking(&reader, 3 * time.Second)
	if !hello_frame_ok do return
	defer delete(hello_text)
	hostname := json_string(hello_text, "hostname"); defer delete(hostname)
	os_str := json_string(hello_text, "os"); defer delete(os_str)
	arch_str := json_string(hello_text, "arch"); defer delete(arch_str)
	validation_url := json_string(hello_text, "validation_ws_url"); defer delete(validation_url)
	body_bridge_id := json_string(hello_text, "bridge_id"); defer delete(body_bridge_id)
	bridge, connect_ok, err := bridge_service.bridge_runtime_connect(h.bridges, token, hostname, os_str, arch_str, hello_text)
	if !connect_ok { _ = write_ws_text_frame(client, bridge_ws_error_payload(err.message)); return }
	if body_bridge_id != "" && body_bridge_id != bridge.bridge_id { _ = write_ws_text_frame(client, bridge_ws_error_payload("bridge_id does not match bearer token")); return }
	hello, hello_ok, hello_err := bridge_runtime_service.runtime_accept_hello(h.bridge_runtime_registry, bridge.bridge_id, json_int(hello_text, "protocol_version", 1), validation_url)
	if !hello_ok { _ = write_ws_text_frame(client, bridge_ws_error_payload(hello_err.message)); return }
	project_service.bridge_runtime_registry_set_command_socket(h.bridge_runtime_registry, bridge.bridge_id, client)
	// From here the socket is registered, so other threads (fs/file commands) may
	// write it — serialize this and every subsequent write.
	_ = write_ws_text_frame_locked(h, client, bridge_ready_payload(bridge.bridge_id, hello.generation, hello.replaced_existing))
	// Orphan recovery: replay actionable-task notifications for this bridge's
	// instances. A cross-bridge cascade (or any status change) that fanned out to
	// this bridge while it was offline was dropped (fire-and-forget); on reconnect
	// we re-fire the current actionable state so agents get woken/nudged. Runs
	// once per (re)connect, after bridge_ready so the command socket is registered.
	if h.taskchains != nil {
		_ = taskchain_service.replay_bridge_actionable_notifications(h.taskchains, domain.User_ID(bridge.owner_user_id), bridge.bridge_id)
	}
	bridge_ws_runtime_loop(h, bridge.bridge_id, hello.generation, &reader)
}

// BRIDGE_INSTANCE_STALE_MS: an instance still in an active runtime state whose
// last_seen_at is older than this is reaped to "unreachable" by the opportunistic
// sweep on bridge heartbeats. Generously above the ~2s heartbeat cadence so a
// briefly-slow bridge is never falsely reaped.
BRIDGE_INSTANCE_STALE_MS :: 90_000

// bridge_ws_disconnect clears the durable runtime state of a disconnected
// bridge's instances (registry offline alone leaves them "running" forever) and
// fans out resource_changed so the UI updates immediately.
bridge_ws_disconnect :: proc(h: ^Bridge_Handlers, bridge_id: string, connection_generation: int) {
	// Only run the cascade if THIS connection generation is still the live one.
	// registry_mark_offline is generation-guarded (a newer reconnect already
	// replaced us => it returns without removing the live entry), so gate the
	// durable offline/cascade on the same generation to stay idempotent and avoid
	// clobbering a fresh reconnect's instances.
	still_current := project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) == connection_generation
	project_service.bridge_runtime_registry_mark_offline(h.bridge_runtime_registry, bridge_id, connection_generation)
	if !still_current do return
	// Mark the durable bridge record offline (bridge_runtime_connect set it .Online
	// but nothing marked it back down on WS close). Idempotent + skips revoked.
	if h.bridges != nil {
		if bridge, changed, _ := bridge_service.mark_bridge_offline(h.bridges, bridge_id); changed {
			summary := bridge_status_summary_json(domain.bridge_status_string(bridge.status))
			events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), "bridge", bridge.bridge_id, "status_changed", summary)
			delete(summary)
		}
	}
	if h.agents == nil do return
	// The bridge is gone; its registry entry was just removed above. The durable DB
	// is authoritative here, so we only persist the cleared state and notify the UI.
	cleared := agent_service.mark_bridge_instances_unreachable(h.agents, bridge_id)
	defer domain.agent_instances_destroy(cleared)
	for inst in cleared {
		summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
		events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
		delete(summary)
	}
}

// Bridge_Chunk_Reassembly buffers the fragments of one in-flight chunk stream on
// the hub-runtime read path, keyed by chunk_id (which equals the frame's
// stream_id on the wire).
Bridge_Chunk_Reassembly :: struct {
	chunk_id:        string,
	chunk_count:     int,
	total_bytes:     int,
	received_chunks: int,
	received_bytes:  int,
	fragments:       []string,
}

// bridge_ws_reassemble_chunk ingests one kind:"chunk" frame and, once its stream
// is complete, returns the reassembled original frame text. Mirrors the bridge's
// own inbound reassembly (bridge_ws_handle_chunk_skeleton): key by chunk_id;
// validate metadata; enforce the contract caps; ignore duplicate/retransmitted
// fills; concat fragments in index order. ACK-LESS — the bridge does not wait for
// an ack on this channel (single ordered connection), so none is sent.
//
// Returns (assembled, complete, ok):
//   ok=false       -> malformed or over-cap: caller drops the frame (no dispatch)
//   complete=false -> buffered, awaiting more chunks: caller continues
//   complete=true  -> assembled is the full original frame text to dispatch
bridge_ws_reassemble_chunk :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, text: string) -> (assembled: string, complete: bool, ok: bool) {
	// json_string returns freshly-allocated strings; free the two transient lookups
	// here (chunk_id is cloned into the buffer, the fragment is decoded) so chunking
	// a large read does not leak per chunk on this hot path.
	chunk_id := json_string(text, "chunk_id")
	defer delete(chunk_id)
	fragment_b64 := json_string(text, "payload_fragment")
	defer delete(fragment_b64)
	chunk_index := json_int(text, "chunk_index", -1)
	chunk_count := json_int(text, "chunk_count", 0)
	total_bytes := json_int(text, "total_bytes", 0)
	if chunk_id == "" || chunk_index < 0 || chunk_count <= 0 || chunk_index >= chunk_count || total_bytes <= 0 || fragment_b64 == "" {
		return "", false, false
	}
	// Contract caps: reject impossible/oversized streams before allocating.
	if chunk_count > contracts.BRIDGE_WS_MAX_CHUNK_COUNT || chunk_count > total_bytes || total_bytes > contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES {
		return "", false, false
	}
	decoded, derr := base64.decode(fragment_b64)
	if derr != nil || len(decoded) == 0 {
		return "", false, false
	}
	defer delete(decoded)
	decoded_text := string(decoded)

	idx := -1
	for i in 0 ..< len(reassemblies) {
		if reassemblies[i].chunk_id == chunk_id { idx = i; break }
	}
	if idx < 0 {
		// Bound concurrent reassemblies per connection.
		if len(reassemblies) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES do return "", false, false
		append(reassemblies, Bridge_Chunk_Reassembly{
			chunk_id    = strings.clone(chunk_id),
			chunk_count = chunk_count,
			total_bytes = total_bytes,
			fragments   = make([]string, chunk_count),
		})
		idx = len(reassemblies) - 1
	}
	// Conflicting metadata for the same chunk_id: drop this frame, keep the stream.
	if reassemblies[idx].chunk_count != chunk_count || reassemblies[idx].total_bytes != total_bytes {
		return "", false, false
	}
	// Duplicate/retransmit: only fill an empty slot; never exceed declared total.
	if reassemblies[idx].fragments[chunk_index] == "" {
		if reassemblies[idx].received_bytes + len(decoded_text) > reassemblies[idx].total_bytes {
			return "", false, false
		}
		reassemblies[idx].fragments[chunk_index] = strings.clone(decoded_text)
		reassemblies[idx].received_chunks += 1
		reassemblies[idx].received_bytes += len(decoded_text)
	}
	if reassemblies[idx].received_chunks == reassemblies[idx].chunk_count {
		if reassemblies[idx].received_bytes != reassemblies[idx].total_bytes {
			bridge_chunk_reassembly_remove(reassemblies, idx)
			return "", false, false
		}
		b := strings.builder_make()
		for frag in reassemblies[idx].fragments {
			strings.write_string(&b, frag)
		}
		out := strings.to_string(b)
		bridge_chunk_reassembly_remove(reassemblies, idx)
		return out, true, true
	}
	return "", false, true
}

// bridge_chunk_reassembly_remove frees one reassembly's owned strings and removes
// it from the buffer (order among the remaining streams is irrelevant).
bridge_chunk_reassembly_remove :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, idx: int) {
	for frag in reassemblies[idx].fragments do delete(frag)
	delete(reassemblies[idx].fragments)
	delete(reassemblies[idx].chunk_id)
	unordered_remove(reassemblies, idx)
}

// bridge_chunk_reassemblies_free drops every buffered (incomplete) stream when the
// connection ends, so a bridge that disconnects mid-stream leaks nothing.
bridge_chunk_reassemblies_free :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly) {
	for i in 0 ..< len(reassemblies) {
		for frag in reassemblies[i].fragments do delete(frag)
		delete(reassemblies[i].fragments)
		delete(reassemblies[i].chunk_id)
	}
	delete(reassemblies^)
}

bridge_ws_runtime_loop :: proc(h: ^Bridge_Handlers, bridge_id: string, connection_generation: int, reader: ^Bridge_WS_Reader) {
	client := reader.socket
	defer bridge_ws_disconnect(h, bridge_id, connection_generation)
	// Per-connection chunk reassembly buffer. The bridge (bridge_hub_send) splits
	// any bridge->hub frame larger than the edge proxy's ~16KB per-message cap into
	// ordered kind:"chunk" frames; we rebuild the original frame here before it is
	// dispatched. Reads for one connection are single-threaded (this loop), so the
	// buffer needs no lock; it is freed on loop return / disconnect.
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	for {
		// 120s read deadline decoupled from the bridge's idle heartbeat cadence
		// (BRIDGE_HUB_HEARTBEAT_INTERVAL = 45s): a single delayed/dropped heartbeat
		// still leaves a full extra beat of margin before we treat the bridge as
		// gone, so we never tear down a healthy connection at the cadence edge.
		text, ok := read_ws_text_blocking(reader, 120 * time.Second)
		if !ok do return
		if !bridge_ws_process_frame(h, bridge_id, connection_generation, client, &reassemblies, text) {
			return
		}
	}
}

bridge_ws_process_frame :: proc(h: ^Bridge_Handlers, bridge_id: string, connection_generation: int, client: net.TCP_Socket, reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, raw_text: string) -> bool {
	text := raw_text
	if project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) != connection_generation {
		delete(text)
		_ = write_ws_text_frame_locked(h, client, bridge_connection_replaced_payload())
		return false
	}
	type := json_string(text, "type")
	// Chunk reassembly. A real chunk frame has kind:"chunk" and NO top-level
	// "type" (its payload_fragment is base64, so it can never contain a "type"
	// key) — that is what distinguishes it from a normal frame whose file
	// CONTENT merely embeds "kind":"chunk". Buffer until the stream completes,
	// then dispatch the reassembled original frame by its real type. Non-chunk
	// frames — including heartbeats interleaved between chunks — fall straight
	// through untouched. Ack-less: see the bridge's bridge_hub_send.
	if type == "" {
		kind := json_string(text, "kind")
		if kind == contracts.BRIDGE_WS_FRAME_KIND_CHUNK {
			delete(kind)
			delete(type)
			assembled, complete, cok := bridge_ws_reassemble_chunk(reassemblies, text)
			delete(text)
			if !cok || !complete do return true
			text = assembled
			type = json_string(text, "type")
		} else {
			delete(kind)
		}
	}
	is_command_result := false
	defer if !is_command_result do delete(text)
	defer delete(type)

	switch type {
	case "bridge_heartbeat":
		if strings.contains(text, "\"capabilities\"") { _, _, _ = bridge_service.update_runtime_capabilities(h.bridges, bridge_id, text) }
		active := json_string_array(text, "active_instance_ids")
		digest_active := bridge_apply_heartbeat_digest(h, bridge_id, text)
		used_digest := false
		if len(active) == 0 && len(digest_active) > 0 {
			delete(active)
			active = digest_active
			used_digest = true
		}
		reconciled := bridge_runtime_service.runtime_reconcile_digest(h.bridge_runtime_registry, active)
		// H7 cross-bridge reap: any instance this bridge reports active whose
		// canonical bridge_id is now a DIFFERENT bridge has been relaunched
		// elsewhere. Tell this bridge to invalidate those instances' local tokens
		// (via the ack) so the stale old ham-wrapper self-terminates.
		superseded: []string
		if h.agents != nil do superseded = agent_service.detect_superseded_instances(h.agents, bridge_id, active)
		if h.agents != nil do reconciled += agent_service.reconcile_bridge_heartbeat(h.agents, bridge_id, active)
		// Opportunistic time-based reap: catches instances stranded by a
		// disconnect the hub never observed (hub restart with persisted DB, or a
		// lost WS close). Request-driven, so no background thread is required.
		if h.agents != nil {
			reaped := agent_service.reap_stale_instances(h.agents, BRIDGE_INSTANCE_STALE_MS)
			for inst in reaped {
				summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
				events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
				delete(summary)
				reconciled += 1
			}
			domain.agent_instances_destroy(reaped)
		}
		schedules_version := 0
		if h.actions != nil {
			schedules_version = get_actions_bridge_version(h.actions, bridge_id)
		} else if h.scheduled_prompts != nil {
			schedules_version = get_scheduled_prompts_bridge_version(h.scheduled_prompts, bridge_id)
		}
		ack := bridge_heartbeat_ack_payload(reconciled, superseded, schedules_version)
		_ = write_ws_text_frame_locked(h, client, ack)
		delete(ack)
		if superseded != nil {
			for s in superseded do delete(s)
			delete(superseded)
		}
		if used_digest {
			for s in active do delete(s)
			delete(active)
		} else {
			delete(active)
			if digest_active != nil {
				for s in digest_active do delete(s)
				delete(digest_active)
			}
		}
	case "agent_instance_status":
		instance_id := json_string(text, "agent_instance_id")
		state_seq := json_int(text, "state_seq", 0)
		runtime_status := json_string(text, "runtime_status")
		activity_status := json_string(text, "activity_status")
		_ = bridge_runtime_service.runtime_apply_state_report(h.bridge_runtime_registry, instance_id, state_seq, runtime_status, activity_status)
		if h.agents != nil {
			if inst, applied, _ := agent_service.apply_bridge_status_report(h.agents, bridge_id, instance_id, state_seq, runtime_status, activity_status); applied {
				summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
				events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
				delete(summary)
				domain.agent_instance_destroy(&inst)
			}
		}
		current_runtime, _, current_seq, got := bridge_runtime_service.runtime_instance_status(h.bridge_runtime_registry, instance_id)
		_ = got
		applied := current_seq == state_seq && current_runtime == runtime_status
		ack := bridge_state_ack_payload(instance_id, applied, current_seq, current_runtime)
		_ = write_ws_text_frame_locked(h, client, ack)
		delete(ack)
		delete(instance_id)
		delete(runtime_status)
		delete(activity_status)
	case "command_result", "project_path_validation_result", "providers_report", "fs_list_dir_result", "fs_stat_result", "fs_make_dir_result", "fs_read_file_result", "fs_create_file_result", "fs_write_file_result", "fs_batch_write_result", "fs_move_result", "fs_delete_result", "vcs_capabilities_result", "vcs_status_result", "vcs_files_result", "vcs_diff_result", "vcs_log_result", "vcs_commit_diff_result", "vcs_workspaces_result", "vcs_stage_result", "vcs_unstage_result", "vcs_revert_result", "vcs_save_file_result", "vcs_commit_result", "fs_find_files_result", "fs_grep_result", "shell_start_result", "shell_restart_result", "shell_list_result", "shell_logs_result", "shell_capture_result", "shell_set_port_result":
		command_id := json_string(text, "command_id")
		_, existed := bridge_runtime_service.runtime_command_result_idempotent(h.bridge_runtime_registry, bridge_id, command_id, text)
		if existed {
			delete(command_id)
		} else {
			is_command_result = true
		}
	case "pane_capture_result":
		if json_int(text, "protocol_version", 0) != 1 do return true
		if h.content != nil {
			input := content_service.Pane_Capture_Result_Input{
				command_id = json_string_unescaped(text, "command_id"),
				pane_capture_request_id = json_string_unescaped(text, "pane_capture_request_id"),
				conversation_id = json_string_unescaped(text, "conversation_id"),
				message_id = json_string_unescaped(text, "message_id"),
				agent_instance_id = json_string_unescaped(text, "agent_instance_id"),
				ok = json_bool_value(text, "ok"),
				output = json_string_unescaped(text, "output"),
				error_code = json_string_unescaped(text, "error_code"),
				message = json_string_unescaped(text, "message"),
				width = json_int(text, "width", 80),
				line_count = json_int(text, "line_count", 0),
				truncated = json_bool_value(text, "truncated"),
			}
			if msg, conv, applied, _ := content_service.complete_pane_capture(h.content, bridge_id, input); applied {
				evt := pane_capture_chat_event_json(conv, msg)
				events.publish_owned(h.event_bus, string(conv.owner_user_id), evt)
			}
			delete(input.command_id)
			delete(input.pane_capture_request_id)
			delete(input.conversation_id)
			delete(input.message_id)
			delete(input.agent_instance_id)
			delete(input.output)
			delete(input.error_code)
			delete(input.message)
		}
	case "capability_report":
		_, _, _ = bridge_service.update_runtime_capabilities(h.bridges, bridge_id, text)
	case "shell_pty_output":
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			data_b64 := json_string(text, "data_b64")
			if session_id != "" && data_b64 != "" {
				shell_session_svc.shell_session_broadcast_output(h.shell_sessions, session_id, data_b64)
			}
			delete(session_id)
			delete(data_b64)
		}
	case "shell_exited":
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			status := json_string(text, "status")
			if status == "" do status = strings.clone("exited")
			exit_code := json_int(text, "exit_code", 0)
			exit_code_set := json_key_present(text, "exit_code")
			if session_id != "" {
				shell_session_svc.shell_session_broadcast_status(h.shell_sessions, session_id, status, exit_code, exit_code_set)
				shell_session_svc.shell_session_handle_exited(h.shell_sessions, session_id, bridge_id, status, exit_code, exit_code_set)
			}
			delete(session_id)
			delete(status)
		}
	// tunnel_data: bridge→hub direction — response bytes from the dev server.
	case "tunnel_data":
		if h.shell_sessions != nil {
			stream_id := json_string(text, "stream_id")
			data_b64 := json_string(text, "data_b64")
			if stream_id != "" && data_b64 != "" {
				decoded, decode_err := base64.decode(data_b64)
				if decode_err == nil && len(decoded) > 0 {
					shell_session_svc.shell_session_tunnel_deliver(h.shell_sessions, stream_id, decoded)
				}
				delete(decoded)
			}
			delete(stream_id)
			delete(data_b64)
		}
	// tunnel_close: bridge→hub direction — dev server connection closed.
	case "tunnel_close":
		if h.shell_sessions != nil {
			stream_id := json_string(text, "stream_id")
			if stream_id != "" {
				shell_session_svc.shell_session_tunnel_close_stream(h.shell_sessions, stream_id)
			}
			delete(stream_id)
		}
	// REQ-XM-4 (bridge_proxy_relay.odin): streams a bridge ORIGINATES toward the hub, as
	// opposed to the tunnel_* frames above which belong to streams the hub originated
	// toward a bridge. Deliberately separate names: the two directions have different
	// lifecycles and sharing the names would make both harder to follow.
	case "proxy_open":
		if h.shell_sessions != nil do bridge_proxy_handle_open(h, bridge_id, text)
	case "proxy_data":
		if h.shell_sessions != nil do bridge_proxy_handle_data(h, bridge_id, text)
	case "proxy_close":
		if h.shell_sessions != nil do bridge_proxy_handle_close(h, bridge_id, text)
	}

	return true
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
					summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
					events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
					delete(summary)
					domain.agent_instance_destroy(&inst)
				}
			}
			append(&active, instance_id)
		} else {
			delete(instance_id)
		}
		delete(runtime_status)
		delete(activity_status)
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
	// Manifest-only path: the legacy bundle response has been removed (HUB-4).
	// The bridge always fetches the manifest and resolves fragment/skill blobs
	// via per-hash GETs; per-instance data is injected by the bridge locally.
	instance_id := path_part(req.path, 5)
	manifest, manifest_ok, manifest_err := agent_service.bootstrap_manifest_json_for_bridge(h.agents, domain.User_ID(bridge_auth.user_id), bridge_auth.bridge_id, instance_id)
	if !manifest_ok do return respond_error(manifest_err, req.request_id)
	return respond_success(manifest, req.request_id, auth_ctx_server_time(req))
}

// bridge_agent_manifest_handler serves the conditional, agent-keyed bootstrap
// manifest (HUB-2). It is keyed by (agent_id, role, provider, project) — NO
// per-instance data — and honors If-None-Match: an unchanged agent yields a 304
// (indexed version compare only; no render, no memories scan), while a changed
// input yields 200 + manifest + a fresh ETag. LOG-1: every request logs whether
// it was a 304 HIT or a 200 MISS (render) with agent/role/provider/version.
bridge_agent_manifest_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	// /api/v1/bridge/agents/{agent_id}/bootstrap-manifest -> agent_id at index 5.
	agent_id := path_part(req.path, 5)
	role := query_value(req.query, "role")
	provider := query_value(req.query, "provider")
	project := query_value(req.query, "project")
	// If-None-Match arrives quoted on the wire (RFC 7232); the service compares
	// against the raw ETag value, so strip the surrounding quotes first.
	if_none_match := etag_unquote(strings.trim_space(header_value(req.headers, "If-None-Match")))

	result, ok, err := agent_service.bootstrap_manifest_conditional(h.agents, domain.User_ID(bridge_auth.user_id), agent_id, role, provider, project, bridge_auth.bridge_id, if_none_match)
	if !ok do return respond_error(err, req.request_id)

	if result.status == 304 {
		fmt.println("bootstrap-manifest HIT (304)", "agent=", agent_id, "role=", role, "provider=", provider, "project=", project, "version=", result.version)
		headers := make([]contracts.HTTP_Header, 1)
		headers[0] = contracts.HTTP_Header{name = "ETag", value = etag_quote(result.etag)}
		return Response{status = 304, content_type = "application/json", body = "", headers = headers}
	}
	fmt.println("bootstrap-manifest MISS (200 render)", "agent=", agent_id, "role=", role, "provider=", provider, "project=", project, "version=", result.version)
	resp := respond_success(result.manifest_json, req.request_id, auth_ctx_server_time(req))
	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = contracts.HTTP_Header{name = "ETag", value = etag_quote(result.etag)}
	resp.headers = headers
	return resp
}

// etag_quote wraps a raw ETag value in double quotes if not already quoted, per
// RFC 7232. Matching against If-None-Match uses the raw value; the wire form is
// quoted.
etag_quote :: proc(value: string) -> string {
	if strings.has_prefix(value, "\"") do return value
	return strings.concatenate({"\"", value, "\""})
}

// etag_unquote strips surrounding double quotes (and an optional weak "W/"
// prefix) from a wire ETag so it can be compared against the raw stored value.
etag_unquote :: proc(value: string) -> string {
	v := value
	if strings.has_prefix(v, "W/") do v = v[2:]
	v = strings.trim_space(v)
	if len(v) >= 2 && strings.has_prefix(v, "\"") && strings.has_suffix(v, "\"") do return v[1:len(v) - 1]
	return v
}

// bridge_blobs_handler is the optional cold-start warmup: POST a batch of hashes,
// receive the fragment bodies (HUB-3 keeps this only as a warmup convenience; the
// primary path is the per-hash immutable GET below).
bridge_blobs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	_, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	result := agent_service.resolve_blobs_json(h.agents, req.body)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// bridge_blob_handler serves ONE immutable content-addressed fragment by hash
// (HUB-3). Because a sha256 hash is its own validity token, the response is
// marked immutable with a one-year max-age so the bridge's disk cache and any
// intermediary can cache it forever. LOG-1: log the hash served.
bridge_blob_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	_, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	// /api/v1/bridge/blobs/{hash} -> hash at index 5. Hashes are url-encoded
	// ("sha256%3A..") since they contain a colon; decode before lookup.
	hash := query_component_decode(path_part(req.path, 5))
	body, found := agent_service.resolve_single_blob(h.agents, hash)
	if !found {
		fmt.println("bootstrap-blob MISS (404)", "hash=", hash)
		return respond_error(domain.domain_error(.Not_Found, "blob not found"), req.request_id)
	}
	fmt.println("bootstrap-blob served", "hash=", hash)
	b := strings.builder_make()
	strings.write_string(&b, "{\"hash\":\"")
	write_handler_json_string(&b, hash)
	strings.write_string(&b, "\",\"body\":\"")
	write_handler_json_string(&b, body)
	strings.write_string(&b, "\"}")
	resp := respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = contracts.HTTP_Header{name = "Cache-Control", value = "immutable, max-age=31536000"}
	resp.headers = headers
	return resp
}

// bridge_actionable_tasks_handler returns the compact actionable-task set for the
// calling bridge's hosted instances. The Bridge scheduler polls this once per
// tick to drive auto-promotion and auto-nudge locally, keeping the Hub lean.
bridge_actionable_tasks_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	if h.taskchains == nil do return respond_error(domain.domain_error(.Internal_Error, "taskchain service is not configured"), req.request_id)
	items, err := taskchain_service.actionable_tasks_for_bridge(h.taskchains, domain.User_ID(bridge_auth.user_id), bridge_auth.bridge_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"tasks\":[")
	for item, i in items {
		if i > 0 do strings.write_byte(&b, ',')
		write_actionable_task_json(&b, item)
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_actionable_task_json :: proc(b: ^strings.Builder, t: taskchain_service.Actionable_Task) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id))
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status))
	strings.write_string(b, "\",\"target_instance_id\":\""); write_handler_json_string(b, t.target_instance_id)
	strings.write_string(b, "\",\"target_role\":\""); write_handler_json_string(b, taskchain_service.target_string(t.target_role))
	strings.write_string(b, "\",\"action\":\""); write_handler_json_string(b, t.action)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, t.updated_at)
	strings.write_string(b, "\",\"deps_satisfied\":"); strings.write_string(b, "true" if t.deps_satisfied else "false")
	strings.write_string(b, "}")
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
	return json_string_unescaped(body, key)
}

json_string_unescaped :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	b := strings.builder_make()
	escaped := false
	for i := 1; i < len(rest); i += 1 {
		ch := rest[i]
		if escaped {
			switch ch {
			case 'n': strings.write_byte(&b, '\n')
			case 'r': strings.write_byte(&b, '\r')
			case 't': strings.write_byte(&b, '\t')
			case '"': strings.write_byte(&b, '"')
			case '\\': strings.write_byte(&b, '\\')
			case 'u':
				if i + 4 < len(rest) {
					hex_str := rest[i + 1:i + 5]
					val, ok := strconv.parse_int(hex_str, 16)
					if ok {
						if val < 128 {
							strings.write_byte(&b, byte(val))
						} else {
							strings.write_rune(&b, rune(val))
						}
						i += 4
					} else {
						strings.write_byte(&b, 'u')
					}
				} else {
					strings.write_byte(&b, 'u')
				}
			case: strings.write_byte(&b, ch)
			}
			escaped = false
			continue
		}
		if ch == '\\' { escaped = true; continue }
		if ch == '"' do return strings.to_string(b)
		strings.write_byte(&b,ch)
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

bridge_heartbeat_ack_payload :: proc(reconciled: int, superseded_instance_ids: []string = nil, schedules_version: int = 0) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat_ack\",\"protocol_version\":1,\"payload\":{\"reconciled_unreachable_count\":")
	strings.write_string(&b, fmt.tprintf("%d", reconciled))
	strings.write_string(&b, ",\"schedules_version\":")
	strings.write_string(&b, fmt.tprintf("%d", schedules_version))
	// H7: instance ids the reporting bridge must reap (relaunched on another
	// bridge). The bridge invalidates their local tokens so the stale wrapper exits.
	strings.write_string(&b, ",\"superseded_instance_ids\":[")
	for id, i in superseded_instance_ids {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		write_handler_json_string(&b, id)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "]}}")
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

bridge_status_summary_json :: proc(status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"status\":\""); write_handler_json_string(&b, status)
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

// Bridge_WS_Reader holds the bridge command socket and a DURABLE receive buffer
// that persists across read_ws_text_blocking calls. The kernel can deliver several
// WS frames in one recv (e.g. a heartbeat/state frame coalesced with an fs_read_
// file_result); the previous per-call buffer returned the first frame and threw the
// rest away, so the coalesced result was permanently lost and the fs request timed
// out (the size-correlated >16KB failure). Keeping leftover bytes here — mirroring
// the bridge side's ws.Connection.pending_bytes — means every frame is delivered.
Bridge_WS_Reader :: struct {
	socket:  net.TCP_Socket,
	pending: [dynamic]byte,
}

bridge_ws_reader_make :: proc(socket: net.TCP_Socket) -> Bridge_WS_Reader {
	return Bridge_WS_Reader{socket = socket}
}

bridge_ws_reader_destroy :: proc(reader: ^Bridge_WS_Reader) {
	if reader != nil do delete(reader.pending)
}

// bridge_ws_take_frame extracts ONE complete masked text frame from the front of
// reader.pending, consuming its bytes and leaving any trailing (coalesced) bytes
// for the next call. ok=false with fatal=false means "need more bytes"; fatal=true
// means the stream is unusable (non-text opcode, or an unsupported 64-bit length) —
// preserving the previous reader's behavior of ending the connection on those.
// NOTE: the bridge<->hub chunk protocol (kind:"chunk", reassembled in
// bridge_ws_runtime_loop) is APPLICATION-LEVEL — each chunk is a self-contained
// opcode-0x1 JSON text frame under 65535 bytes, NOT a WS continuation/fragmentation
// frame — so this reader needs no WS-fragmentation path.
bridge_ws_take_frame :: proc(reader: ^Bridge_WS_Reader) -> (text: string, ok: bool, fatal: bool) {
	b := reader.pending[:]
	if len(b) < 2 do return "", false, false
	if b[0] & 0x0f != 0x1 do return "", false, true // only text frames are expected
	masked := (b[1] & 0x80) != 0
	payload_len := int(b[1] & 0x7f)
	header_len := 2
	if payload_len == 126 {
		if len(b) < 4 do return "", false, false
		payload_len = int(b[2]) << 8 | int(b[3])
		header_len = 4
	} else if payload_len == 127 {
		return "", false, true // 64-bit lengths are not used on this control channel
	}
	data_off := header_len
	mask_key: [4]byte
	if masked {
		if len(b) < header_len + 4 do return "", false, false
		mask_key = {b[header_len], b[header_len + 1], b[header_len + 2], b[header_len + 3]}
		data_off = header_len + 4
	}
	frame_end := data_off + payload_len
	if len(b) < frame_end do return "", false, false
	payload := make([]byte, payload_len)
	copy(payload, b[data_off:frame_end])
	if masked { for i in 0..<payload_len { payload[i] = payload[i] ~ mask_key[i % 4] } }
	// Consume this frame, compacting any trailing coalesced bytes to the front.
	remaining := len(reader.pending) - frame_end
	if remaining > 0 do copy(reader.pending[:], reader.pending[frame_end:])
	resize(&reader.pending, remaining)
	return string(payload), true, false
}

read_ws_text_blocking :: proc(reader: ^Bridge_WS_Reader, timeout: time.Duration) -> (string, bool) {
	// A frame may already be buffered from a previous coalesced recv — return it
	// without blocking on the socket.
	if text, ok, fatal := bridge_ws_take_frame(reader); fatal {
		return "", false
	} else if ok {
		return text, true
	}
	_ = net.set_option(reader.socket, .Receive_Timeout, timeout)
	buf: [8192]byte
	for {
		n, err := net.recv_tcp(reader.socket, buf[:])
		if err != nil || n <= 0 do return "", false
		append(&reader.pending, ..buf[:n])
		if text, ok, fatal := bridge_ws_take_frame(reader); fatal {
			return "", false
		} else if ok {
			return text, true
		}
	}
}

write_ws_text_frame :: proc(client: net.TCP_Socket, text: string) -> bool {
	n := len(text)
	if n > 65535 do return false
	header_len := 2
	if n > 125 do header_len = 4
	frame := make([]byte, header_len + n)
	defer delete(frame)
	frame[0] = 0x81
	if n <= 125 { frame[1] = byte(n) } else { frame[1] = 126; frame[2] = byte((n >> 8) & 0xff); frame[3] = byte(n & 0xff) }
	copy(frame[header_len:], transmute([]byte)text)
	_, err := net.send_tcp(client, frame)
	return err == nil
}

// write_ws_text_frame_locked serializes a write to the bridge command socket with
// every other write to it (the runtime loop's acks AND concurrent fs/file command
// sends on other threads), holding the registry command lock only for the write so
// bytes never interleave into a corrupt frame. Use this for any write AFTER the
// command socket is registered.
write_ws_text_frame_locked :: proc(h: ^Bridge_Handlers, client: net.TCP_Socket, text: string) -> bool {
	project_service.bridge_runtime_registry_command_lock(h.bridge_runtime_registry)
	defer project_service.bridge_runtime_registry_command_unlock(h.bridge_runtime_registry)
	return write_ws_text_frame(client, text)
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

json_bool_value :: proc(body,key:string)->bool{ needle:=strings.concatenate({"\"",key,"\""}); defer delete(needle); idx:=strings.index(body,needle); if idx<0 do return false; rest:=body[idx+len(needle):]; colon:=strings.index_byte(rest,':'); if colon<0 do return false; rest=strings.trim_space(rest[colon+1:]); return strings.has_prefix(rest,"true") }

pane_capture_chat_event_json :: proc(c:domain.Chat_Conversation,m:domain.Chat_Message)->string{ b:=strings.builder_make(); strings.write_string(&b,"{\"type\":\"chat_event\",\"event\":\"chat_updated\",\"agent_instance_id\":\""); write_handler_json_string(&b,c.agent_instance_id); strings.write_string(&b,"\",\"conversation_id\":\""); write_handler_json_string(&b,c.conversation_id); strings.write_string(&b,"\",\"message_id\":\""); write_handler_json_string(&b,m.message_id); strings.write_string(&b,"\",\"direction\":\"pane_capture\",\"fetch_required\":true,\"fetch_kind\":\"chat_message\",\"fetch_id\":\""); write_handler_json_string(&b,m.message_id); strings.write_string(&b,"\",\"message_type\":\""); write_handler_json_string(&b,m.message_type); strings.write_string(&b,"\",\"message_status\":\""); write_handler_json_string(&b,m.message_status); strings.write_string(&b,"\"}"); return strings.to_string(b) }

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
