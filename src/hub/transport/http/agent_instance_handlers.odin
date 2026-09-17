package http

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

	sent, err := agent_service.agent_service_send_pty_input(h.agents, auth_ctx, instance_id, data)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_agent_instance_input_handler :: agent_instance_input_handler
