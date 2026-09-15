package http

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"

require_auth :: proc(auth: ^auth_service.Auth_Service, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, err := auth_service.resolve_auth(auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, false, respond_error(err, req.request_id)
	return ctx, true, Response{}
}

reject_query_or_body_token :: proc(req: Request) -> (bool, Response) {
	if auth_service.token_in_query_or_body(req.query, req.body) {
		return true, respond_error(domain.domain_error(.Unauthenticated, "bearer tokens must use the Authorization header"), req.request_id)
	}
	return false, Response{}
}

require_auth_any :: proc(auth: ^auth_service.Auth_Service, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, err := auth_service.resolve_auth_any(auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, false, respond_error(err, req.request_id)
	if ctx.kind == .Bridge_Token {
		// Checkpoint 1 (monitor): a BARE bridge token was accepted on a shared
		// endpoint. This kind only arises from the monitor bare-token path in
		// resolve_auth_any, so it is an unambiguous signal; log it here where the
		// full request (method/path/request_id) is available.
		auth_service.log_bridge_auth_monitor("bare_token_shared_endpoint", req.method, req.path, ctx.bridge_id, ctx.user_id, "", req.request_id)
	}
	return ctx, true, Response{}
}

require_auth_or_bridge_token :: proc(auth: ^auth_service.Auth_Service, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, err := auth_service.resolve_auth_or_bridge_token(auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, false, respond_error(err, req.request_id)
	return ctx, true, Response{}
}
