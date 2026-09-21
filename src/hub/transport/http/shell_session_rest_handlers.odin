package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import shell_session_svc "odin_test:hub/service/shell_session"

Shell_Session_Rest_Handlers :: struct {
	auth:           ^auth_service.Auth_Service,
	shell_sessions: ^shell_session_svc.Shell_Session_Service,
}

// --- JSON serialization ---

write_shell_session_json :: proc(b: ^strings.Builder, s: domain.Shell_Session) {
	strings.write_string(b, "{\"session_id\":\"")
	write_handler_json_string(b, s.session_id)
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, s.owner_user_id)
	strings.write_string(b, "\",\"bridge_id\":\"")
	write_handler_json_string(b, s.bridge_id)
	strings.write_string(b, "\",\"project_id\":\"")
	write_handler_json_string(b, s.project_id)
	strings.write_string(b, "\",\"chain_id\":\"")
	write_handler_json_string(b, s.chain_id)
	strings.write_string(b, "\",\"agent_instance_id\":\"")
	write_handler_json_string(b, s.agent_instance_id)
	strings.write_string(b, "\",\"kind\":\"")
	write_handler_json_string(b, s.kind)
	strings.write_string(b, "\",\"label\":\"")
	write_handler_json_string(b, s.label)
	strings.write_string(b, "\",\"cmd\":\"")
	write_handler_json_string(b, s.cmd)
	strings.write_string(b, "\",\"cwd\":\"")
	write_handler_json_string(b, s.cwd)
	strings.write_string(b, "\",\"status\":\"")
	write_handler_json_string(b, s.status)
	strings.write_string(b, "\"")
	if s.exit_code_set {
		strings.write_string(b, fmt.tprintf(",\"exit_code\":%d", s.exit_code))
	} else {
		strings.write_string(b, ",\"exit_code\":null")
	}
	strings.write_string(b, fmt.tprintf(",\"pid\":%d", s.pid))
	strings.write_string(b, fmt.tprintf(",\"server_port\":%d", s.server_port))
	if s.preview_enabled {
		strings.write_string(b, ",\"preview_enabled\":true")
	} else {
		strings.write_string(b, ",\"preview_enabled\":false")
	}
	strings.write_string(b, ",\"started_at\":\"")
	write_handler_json_string(b, s.started_at)
	strings.write_string(b, "\",\"finished_at\":\"")
	write_handler_json_string(b, s.finished_at)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, s.created_at)
	strings.write_string(b, "\",\"last_activity_at\":\"")
	write_handler_json_string(b, s.last_activity_at)
	strings.write_string(b, "\"}")
}

// --- REST handlers ---

// POST /api/v1/bridges/{bridge_id}/shells
shell_session_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge token cannot create shell sessions"), req.request_id)
	}

	bridge_id := path_part(req.path, 4)
	if bridge_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	input := shell_session_svc.Shell_Session_Create_Input{
		bridge_id         = bridge_id,
		kind              = json_string(req.body, "kind"),
		cmd               = json_string(req.body, "cmd"),
		cwd               = json_string(req.body, "cwd"),
		label             = json_string(req.body, "label"),
		project_id        = json_string(req.body, "project_id"),
		chain_id          = json_string(req.body, "chain_id"),
		agent_instance_id = json_string(req.body, "agent_instance_id"),
		server_port       = json_int(req.body, "server_port", 0),
	}
	defer {
		delete(input.kind)
		delete(input.cmd)
		delete(input.cwd)
		delete(input.label)
		delete(input.project_id)
		delete(input.chain_id)
		delete(input.agent_instance_id)
	}

	session, created, err := shell_session_svc.shell_session_create(h.shell_sessions, auth_ctx, input)
	if !created do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/bridges/{bridge_id}/shells
shell_session_list_by_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	if bridge_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	status_filter := query_value(req.query, "status")
	cursor        := query_value(req.query, "cursor")
	limit         := query_int(req.query, "limit", 25)

	sessions, next_cursor, err := shell_session_svc.shell_session_list_by_bridge(h.shell_sessions, auth_ctx, bridge_id, status_filter, cursor, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.shell_sessions_destroy(sessions)
	defer delete(next_cursor)

	body := _shell_session_list_json(sessions[:], next_cursor)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/projects/{project_id}/shells
shell_session_list_by_project_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	project_id    := path_part(req.path, 4)
	status_filter := query_value(req.query, "status")
	cursor        := query_value(req.query, "cursor")
	limit         := query_int(req.query, "limit", 25)

	sessions, next_cursor, err := shell_session_svc.shell_session_list_by_project(h.shell_sessions, auth_ctx, project_id, status_filter, cursor, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.shell_sessions_destroy(sessions)
	defer delete(next_cursor)

	body := _shell_session_list_json(sessions[:], next_cursor)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells?chain_id=<id>
shell_session_list_by_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	chain_id      := query_value(req.query, "chain_id")
	status_filter := query_value(req.query, "status")
	cursor        := query_value(req.query, "cursor")
	limit         := query_int(req.query, "limit", 25)

	if chain_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "chain_id query parameter is required"), req.request_id)
	}

	sessions, next_cursor, err := shell_session_svc.shell_session_list_by_chain(h.shell_sessions, auth_ctx, chain_id, status_filter, cursor, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.shell_sessions_destroy(sessions)
	defer delete(next_cursor)

	body := _shell_session_list_json(sessions[:], next_cursor)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}
shell_session_get_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	session, found, err := shell_session_svc.shell_session_get(h.shell_sessions, auth_ctx, session_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if !found do return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// DELETE /api/v1/shells/{session_id} — sends kill to bridge.
shell_session_kill_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	sent, err := shell_session_svc.shell_session_kill(h.shell_sessions, auth_ctx, session_id)
	if !sent do return respond_error(err, req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/shells/{session_id}/signal
shell_session_signal_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	signal := json_int(req.body, "signal", 0)
	if signal <= 0 {
		return respond_error(domain.domain_error(.Validation_Failed, "signal must be a positive integer"), req.request_id)
	}

	sent, err := shell_session_svc.shell_session_signal(h.shell_sessions, auth_ctx, session_id, signal)
	if !sent do return respond_error(err, req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/shells/{session_id}/restart
shell_session_restart_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	session, ok2, err := shell_session_svc.shell_session_restart(h.shell_sessions, auth_ctx, session_id)
	if !ok2 do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}/log
shell_session_log_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	offset    := query_int(req.query, "offset", 0)
	limit_val := query_int(req.query, "limit", 100)
	grep      := query_value(req.query, "grep")

	result, got, err := shell_session_svc.shell_session_get_log(h.shell_sessions, auth_ctx, session_id, offset, limit_val, grep)
	if !got do return respond_error(err, req.request_id)
	defer delete(result.lines_raw)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"lines\":")
	if result.lines_raw != "" do strings.write_string(&b, result.lines_raw)
	else do strings.write_string(&b, "[]")
	if result.truncated {
		strings.write_string(&b, ",\"truncated\":true")
	} else {
		strings.write_string(&b, ",\"truncated\":false")
	}
	strings.write_string(&b, fmt.tprintf(",\"total_lines\":%d}", result.total_lines))
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}/capture
shell_session_capture_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	result, got, err := shell_session_svc.shell_session_capture(h.shell_sessions, auth_ctx, session_id)
	if !got do return respond_error(err, req.request_id)
	defer delete(result.content)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"content\":\"")
	write_handler_json_string(&b, result.content)
	strings.write_string(&b, fmt.tprintf("\",\"rows\":%d,\"cols\":%d}", result.rows, result.cols))
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}/pane — polled screen snapshot with since_hash diffing
// (REQ-PTY-STREAM-1). Modelled on get_agent_instance_pane_handler and returns the same
// payload shape. Owner scoping goes through shell_session_svc.shell_session_get, the
// auth-scoped getter — deliberately NOT the unscoped get_by_id BUG-8 added for the
// bridge-event path.
shell_session_pane_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" || strings.contains(session_id, "/") {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	since_hash := query_value(req.query, "since_hash")
	width := query_int(req.query, "width", 80)
	if width <= 0 do width = 80
	line_limit := query_int(req.query, "line_limit", 120)
	if line_limit <= 0 do line_limit = 120

	reply, got, err := shell_session_svc.shell_session_get_pane(h.shell_sessions, auth_ctx, session_id, since_hash, width, line_limit)
	if !got do return respond_error(err, req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

// --- private ---

_shell_session_list_json :: proc(sessions: []domain.Shell_Session, next_cursor: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"sessions\":[")
	for s, i in sessions {
		if i > 0 do strings.write_string(&b, ",")
		write_shell_session_json(&b, s)
	}
	strings.write_string(&b, "],\"next_cursor\":\"")
	write_handler_json_string(&b, next_cursor)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}
