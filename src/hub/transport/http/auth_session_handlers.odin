package http

import "core:fmt"
import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"

// Browser login routes (docs/plans/oidc-only-auth.md, "Browser session flow").
// All are public. Cookies use the __Host- prefix (Secure, Path=/, no Domain) so
// no sibling origin -- including the preview origin -- can set or read them.

AUTH_ERROR_REDIRECT :: "/?auth_error=1"
AUTH_FORBIDDEN_REDIRECT :: "/?auth_error=forbidden"

// plain_response builds a text/plain response whose headers live in the request's
// temp allocator (safe to return).
plain_response :: proc(status: int, body: string, headers: ..contracts.HTTP_Header) -> Response {
	out := make([]contracts.HTTP_Header, len(headers), context.temp_allocator)
	copy(out, headers)
	return Response{status = status, content_type = "text/plain", body = body, headers = out}
}

redirect_response :: proc(location: string, cookies: ..string) -> Response {
	headers := make([]contracts.HTTP_Header, 2 + len(cookies), context.temp_allocator)
	headers[0] = {"Location", location}
	headers[1] = {"Cache-Control", "no-store"}
	for cookie, i in cookies do headers[2 + i] = {"Set-Cookie", cookie}
	return Response{status = 302, content_type = "text/plain", body = "", headers = headers}
}

// GET /api/v1/auth/login?return_to=<same-origin path>
auth_login_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	if !auth_service.web_login_enabled(handlers.auth) do return respond_error(domain.domain_error(.Not_Found, "browser login is not configured"), req.request_id)
	client_ip := device_auth.resolve_client_ip(req.remote_addr, header_value(req.headers, "X-Forwarded-For"), handlers.forwarded_for_cidrs)
	prompt_login := query_value(req.query, "add_account") == "1" || query_value(req.query, "prompt") == "login"
	url, sealed, ok, err := auth_service.web_login_begin(handlers.auth, query_value(req.query, "return_to"), client_ip, prompt_login)
	if !ok {
		if err.code == .Validation_Failed || err.code == .Rate_Limited do return respond_error(err, req.request_id)
		fmt.printfln("ham-hub oidc_login_rejected stage=begin")
		return redirect_response(AUTH_ERROR_REDIRECT)
	}
	return redirect_response(url, auth_service.login_cookie_header(sealed))
}

// GET /api/v1/auth/callback?code=...&state=...
auth_callback_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	if !auth_service.web_login_enabled(handlers.auth) do return respond_error(domain.domain_error(.Not_Found, "browser login is not configured"), req.request_id)
	clear_login := auth_service.expired_cookie_header(auth_service.LOGIN_COOKIE)
	query_state := query_value(req.query, "state")
	login_cookie, _ := auth_service.cookie_value(req.headers, auth_service.LOGIN_COOKIE)
	if query_value(req.query, "error") != "" {
		// The provider refused (user cancelled, consent denied, ...). Consume the
		// state so it cannot be used later; never echo the provider's text.
		auth_service.web_login_abort(handlers.auth, query_state, login_cookie)
		fmt.printfln("ham-hub oidc_login_rejected stage=provider_error")
		return redirect_response(AUTH_ERROR_REDIRECT, clear_login)
	}
	raw_session, return_to, failure, stage := auth_service.web_login_complete(handlers.auth, query_state, login_cookie, query_value(req.query, "code"), header_value(req.headers, "User-Agent"))
	switch failure {
	case .None:
	case .Forbidden:
		fmt.printfln("ham-hub oidc_login_rejected stage=%s", stage)
		return redirect_response(AUTH_FORBIDDEN_REDIRECT, clear_login)
	case .Failed:
		fmt.printfln("ham-hub oidc_login_rejected stage=%s", stage)
		return redirect_response(AUTH_ERROR_REDIRECT, clear_login)
	}
	ttl := handlers.auth.web.session_ttl_ms
	if ttl <= 0 do ttl = auth_service.DEFAULT_SESSION_TTL_HOURS * 3_600_000
	ring, merge_err := auth_service.merge_session_into_ring(handlers.auth, req.headers, raw_session)
	if merge_err.code != .None {
		_, _ = auth_service.revoke_browser_session(handlers.auth, raw_session)
		return redirect_response(AUTH_ERROR_REDIRECT, clear_login)
	}
	return redirect_response(return_to, auth_service.session_cookie_header(raw_session, ttl / 1000), auth_service.sessions_ring_cookie_header(ring[:], ttl / 1000), clear_login)
}

// All session replies are private and must never be cached, even if no cookie
// repair was needed. Raw tokens are used only in these Set-Cookie headers.
auth_ring_response :: proc(resp: Response, auth: ^auth_service.Auth_Service, ring: []string, set_cookies: bool) -> Response {
	out := resp
	headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	append(&headers, ..resp.headers)
	append(&headers, contracts.HTTP_Header{"Cache-Control", "no-store"})
	if set_cookies {
		ttl := i64(auth_service.DEFAULT_SESSION_TTL_HOURS * 3_600_000)
		if auth != nil && auth.web.session_ttl_ms > 0 do ttl = auth.web.session_ttl_ms
		active_cookie := auth_service.expired_cookie_header(auth_service.SESSION_COOKIE)
		if len(ring) > 0 do active_cookie = auth_service.session_cookie_header(ring[0], ttl / 1000)
		append(&headers, contracts.HTTP_Header{"Set-Cookie", active_cookie}, contracts.HTTP_Header{"Set-Cookie", auth_service.sessions_ring_cookie_header(ring, ttl / 1000)})
	}
	out.headers = headers[:]
	return out
}

auth_account_user :: proc(account: auth_service.Auth_Account_Entry) -> Auth_User_Reply {
	return {user_id = account.user_id, name = account.name, display_name = account.display_name, email = account.email}
}

// GET /api/v1/auth/sessions. Cookie repair is allowed; DB writes are not.
auth_sessions_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	_, ring, accounts, changed := auth_service.resolve_session_ring(handlers.auth, req.headers)
	active_user_id := ""
	if len(accounts) > 0 do active_user_id = accounts[0].user_id
	resp := respond_success_typed(Auth_Sessions_Reply{active_user_id, accounts[:]}, req.request_id, auth_ctx_server_time(req))
	return auth_ring_response(resp, handlers.auth, ring[:], changed)
}

// Decode only the documented fields and types, including on optional logout.
auth_ring_input :: proc(body: string, allow_empty: bool) -> (user_id: string, all: bool, ok: bool) {
	if strings.trim_space(body) == "" do return "", false, allow_empty
	if len(body) > 4096 do return "", false, false
	value, err := json.parse_string(body, .JSON, true, context.temp_allocator)
	object, is_object := value.(json.Object)
	if err != .None || !is_object do return "", false, false
	for key, field in object {
		switch key {
		case "user_id":
			text, valid := field.(json.String)
			if !valid do return "", false, false
			user_id = string(text)
		case "all":
			flag, valid := field.(json.Boolean)
			if !allow_empty || !valid do return "", false, false
			all = bool(flag)
		case: return "", false, false
		}
	}
	return user_id, all, true
}

// POST /api/v1/auth/switch. csrf_decide runs before route dispatch.
auth_switch_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	user_id, _, valid := auth_ring_input(req.body, false)
	if !valid do return respond_error(domain.domain_error(.Validation_Failed, "expected a user_id string"), req.request_id)
	ring, accounts, err := auth_service.web_switch_account(handlers.auth, req.headers, user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	resp := respond_success_typed(Auth_Switch_Reply{accounts[0].user_id, auth_account_user(accounts[0]), accounts[:]}, req.request_id, auth_ctx_server_time(req))
	return auth_ring_response(resp, handlers.auth, ring[:], true)
}

// POST /api/v1/auth/logout. Empty input signs out the active account.
auth_logout_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	user_id, all, valid := auth_ring_input(req.body, true)
	if !valid do return respond_error(domain.domain_error(.Validation_Failed, "expected optional user_id string and all boolean"), req.request_id)
	url, ring, accounts, switched, err := auth_service.web_logout_ring(handlers.auth, req.headers, user_id, all)
	if err.code != .None do return respond_error(err, req.request_id)
	active_user_id := ""
	switched_user: json.Value = json.Null(nil)
	if len(accounts) > 0 {
		active_user_id = accounts[0].user_id
		if switched {
			user := auth_account_user(accounts[0])
			object := make(json.Object, context.temp_allocator)
			object["user_id"], object["name"] = json.String(user.user_id), json.String(user.name)
			object["display_name"], object["email"] = json.String(user.display_name), json.String(user.email)
			switched_user = object
		}
	}
	resp := respond_success_typed(Auth_Logout_Reply{url, active_user_id, switched_user, accounts[:]}, req.request_id, auth_ctx_server_time(req))
	return auth_ring_response(resp, handlers.auth, ring[:], true)
}

// Stream_Auth_Guard re-validates a long-lived stream's principal: a Session is
// checked against the session store (logout or expiry ends the stream), an OIDC
// bearer against its token expiry. Checks are
// throttled; non-user principals (agents, bridges) are not re-checked here.
STREAM_AUTH_RECHECK_MS :: 30_000

Stream_Auth_Guard :: struct {
	auth: ^auth_service.Auth_Service,
	principal: contracts.Auth_Context,
	next_check_ms: i64,
}

stream_auth_guard_make :: proc(auth: ^auth_service.Auth_Service, principal: contracts.Auth_Context) -> Stream_Auth_Guard {
	return Stream_Auth_Guard{auth = auth, principal = principal}
}

// stream_auth_still_valid returns false once the principal must be disconnected.
stream_auth_still_valid :: proc(guard: ^Stream_Auth_Guard) -> bool {
	if guard == nil || guard.auth == nil do return true
	if !contracts.is_user_auth(guard.principal) do return true
	now, ok := auth_service.now_unix_ms(guard.auth)
	if !ok do return true
	// A hard bound (session absolute expiry / token exp) is enforced on every call.
	if guard.principal.expires_ms > 0 && now >= guard.principal.expires_ms do return false
	if now < guard.next_check_ms do return true
	guard.next_check_ms = now + STREAM_AUTH_RECHECK_MS
	return auth_service.live_user_authorized(guard.auth, guard.principal)
}
