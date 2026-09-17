package http

import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"

// POST /api/v1/agent-instances/{id}/input
// Streams interactive keystrokes and raw terminal input to a running agent instance.
agent_instance_input_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send instance input"), req.request_id)
	}

	instance_id := path_part(req.path, 4)
	if strings.contains(instance_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)

	data := json_string(req.body, "data")
	defer delete(data)

	sent, err := agent_service.agent_service_send_pty_input(h.agents, auth_ctx, instance_id, data)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_agent_instance_input_handler :: agent_instance_input_handler

// POST /api/v1/agent-instances/{id}/resize
// Updates the PTY terminal window size (rows and cols) for an agent instance.
agent_instance_resize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send instance resize"), req.request_id)
	}

	instance_id := path_part(req.path, 4)
	if strings.contains(instance_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)

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

	if rows > 65535 do rows = 65535
	if cols > 65535 do cols = 65535

	sent, err := agent_service.agent_service_send_pty_resize(h.agents, auth_ctx, instance_id, rows, cols)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_agent_instance_resize_handler :: agent_instance_resize_handler
