package http

import "core:strings"
import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import user_service "odin_test:hub/service/user"

// Exactly one strong ETag containing a canonical nonnegative decimal integer.
// Lists, wildcard and weak tags cannot express this API's CAS precondition.
home_layout_if_match :: proc(value: string) -> (i64, bool) {
	if len(value) < 3 || value[0] != '"' || value[len(value)-1] != '"' do return 0, false
	digits := value[1:len(value)-1]
	if len(digits) > 1 && digits[0] == '0' do return 0, false
	n: i64
	for digit in digits {
		if digit < '0' || digit > '9' do return 0, false
		if n > (domain.HOME_LAYOUT_MAX_VERSION - i64(digit - '0')) / 10 do return 0, false
		n = n * 10 + i64(digit - '0')
	}
	return n, n < domain.HOME_LAYOUT_MAX_VERSION
}

home_layout_header_count :: proc(req: Request, name: string) -> int {
	count := 0
	for header in req.headers do if strings.equal_fold(header.name, name) do count += 1
	return count
}

home_layout_handler :: proc(ctx: rawptr, req: Request) -> Response {
	resp := home_layout_handle(ctx, req)
	headers := make([]contracts.HTTP_Header, len(resp.headers) + 1, context.temp_allocator)
	copy(headers, resp.headers)
	headers[len(resp.headers)] = {"Cache-Control", "no-store"}
	resp.headers = headers
	return resp
}

@(private = "file")
home_layout_handle :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^User_Handlers)(ctx)
	auth, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	if home_layout_header_count(req, EXPECTED_USER_HEADER) != 1 do return respond_error(domain.domain_error(.Validation_Failed, "one X-Heimdall-Expected-User header is required"), req.request_id)
	expected_user := header_value(req.headers, EXPECTED_USER_HEADER)
	if err := user_service.home_layout_account_guard(auth, expected_user); err.code != .None do return respond_error(err, req.request_id)
	layout: domain.Home_Layout
	err: domain.Domain_Error
	switch req.method {
	case "GET":
		layout, err = user_service.get_home_layout(h.home_layouts, auth, expected_user)
	case "PUT":
		version, valid := home_layout_if_match(header_value(req.headers, "If-Match"))
		if home_layout_header_count(req, "If-Match") != 1 || !valid do return respond_error(domain.domain_error(.Validation_Failed, "If-Match must contain one quoted Home layout version"), req.request_id)
		layout, err = user_service.put_home_layout(h.home_layouts, auth, expected_user, version, req.body)
	case:
		return respond_error(domain.domain_error(.Validation_Failed, "unsupported Home layout method"), req.request_id)
	}
	if err.code != .None do return respond_error(err, req.request_id)
	resp := respond_success_typed(layout, req.request_id, auth_ctx_server_time(req))
	resp.headers = make([]contracts.HTTP_Header, 1, context.temp_allocator)
	resp.headers[0] = {"ETag", fmt.tprintf("\"%d\"", layout.version)}
	return resp
}
