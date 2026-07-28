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
