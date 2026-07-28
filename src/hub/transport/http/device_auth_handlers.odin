// HTTP handlers for the device-authorization flow (ELDA-1 / ELDA-2).
//
// Public: POST /api/v1/device/authorize (no auth — the device is not yet
// authenticated).
//
// Trusted-proxy-authenticated (ELDA-2/HBR-5): GET /api/v1/device (HTML page),
// POST /api/v1/device/verify, POST /api/v1/device/approve. These refuse with
// 401 when the request did not arrive through the trusted proxy.

package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"

Device_Auth_Handlers :: struct {
	service: ^device_auth.Device_Auth_Service,
	auth:    ^auth_service.Auth_Service,
}

// device_authorize_handler is the public POST /api/v1/device/authorize endpoint.
device_authorize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	input := device_auth.Authorize_Input{
		client = json_string(req.body, "client"),
		device_label = json_string(req.body, "device_label"),
		os = json_string(req.body, "os"),
		app_version = json_string(req.body, "app_version"),
	}
	xff := header_value(req.headers, "X-Forwarded-For")
	result, ok, err := device_auth.authorize(handlers.service, input, req.remote_addr, xff)
	if !ok do return respond_error(err, req.request_id)
	data := strings.builder_make()
	strings.write_string(&data, "{\"device_code\":\"")
	write_handler_json_string(&data, result.device_code)
	strings.write_string(&data, "\",\"user_code\":\"")
	write_handler_json_string(&data, result.user_code)
	strings.write_string(&data, "\",\"verification_uri\":\"")
	write_handler_json_string(&data, result.verification_uri)
	strings.write_string(&data, fmt.tprintf("\",\"interval\":%d", result.interval))
	strings.write_string(&data, fmt.tprintf(",\"expires_in\":%d", result.expires_in))
	strings.write_string(&data, "}")
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}

// device_page_handler serves the self-contained HTML confirm page (ELDA-2/AC1).
// Trusted-proxy-authenticated: the browser reaches it through the trusted proxy
// (outpost/dev-proxy), so the identity headers are present. 401 otherwise.
device_page_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	_, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	return Response{status = 200, content_type = "text/html; charset=utf-8", body = device_auth.DEVICE_PAGE_HTML}
}

// device_verify_handler shows the requesting device's info for the given
// user_code (ELDA-2/AC3). Trusted-proxy-authenticated. Unknown/expired code ->
// generic 404 "invalid or expired code" (no enumeration); terminal -> 410.
device_verify_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	_, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	request_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	info, vok, err := device_auth.verify_with_ip(handlers.service, json_string(req.body, "user_code"), request_ip)
	if !vok do return respond_error(err, req.request_id)
	data := strings.builder_make()
	strings.write_string(&data, "{\"device_label\":\"")
	write_handler_json_string(&data, info.device_label)
	strings.write_string(&data, "\",\"os\":\"")
	write_handler_json_string(&data, info.os)
	strings.write_string(&data, "\",\"app_version\":\"")
	write_handler_json_string(&data, info.app_version)
	strings.write_string(&data, "\",\"client\":\"")
	write_handler_json_string(&data, info.client)
	strings.write_string(&data, "\",\"request_ip\":\"")
	write_handler_json_string(&data, info.request_ip)
	strings.write_string(&data, fmt.tprintf("\",\"requested_at\":%d}", info.requested_at))
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}

// device_approve_handler records the user's terminal decision (ELDA-2/AC4/AC5/
// AC6). Trusted-proxy-authenticated. owner_user_id is bound from Auth_Context
// ONLY — any client-supplied owner field in the body is ignored (ELDA-6).
device_approve_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	input := device_auth.Approve_Input{
		user_code = json_string(req.body, "user_code"),
		// approve defaults to false; body must explicitly send true to approve.
		approve = json_bool(req.body, "approve"),
	}
	// ELDA-6: owner comes from Auth_Context, NEVER from the body. We deliberately
	// do NOT read owner_user_id/user from req.body.
	approver_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	approver_ua := header_value(req.headers, "User-Agent")
	aok, err := device_auth.approve(
		handlers.service, input, auth_ctx.user_id, approver_ip, approver_ua)
	if !aok do return respond_error(err, req.request_id)
	return respond_success("{}", req.request_id, "", 200)
}

// device_token_handler is the public POST /api/v1/device/token poll endpoint
// (ELDA-3). No auth. Returns the device-poll lifecycle: pending (incl. unknown
// device_code, anti-enumeration), approved (+access_token, single-use), denied,
// expired, or slow_down (429 + Retry-After). Per-IP rate-limited.
device_token_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	device_code := json_string(req.body, "device_code")
	request_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	result, err := device_auth.poll(handlers.service, device_code, request_ip)
	if err.code == .Rate_Limited {
		// slow_down: 429. The body carries status=slow_down so the device backs off.
		retry_after := handlers.service.store.config.interval
		if retry_after <= 0 do retry_after = 5
		headers := make([]contracts.HTTP_Header, 1)
		headers[0] = contracts.HTTP_Header{name = "Retry-After", value = fmt.tprintf("%d", retry_after)}
		return Response{
			status = 429,
			content_type = "application/json",
			body = contracts.api_success_json(strings.concatenate({"{\"status\":\"slow_down\",\"interval\":", fmt.tprintf("%d", retry_after), "}"}), contracts.api_meta(req.request_id, "")),
			headers = headers,
		}
	}
	data := strings.builder_make()
	#partial switch result.status {
	case .Approved:
		strings.write_string(&data, "{\"status\":\"approved\",\"access_token\":\"")
		write_handler_json_string(&data, result.access_token)
		strings.write_string(&data, "\",\"token_id\":\"")
		write_handler_json_string(&data, result.token_id)
		strings.write_string(&data, fmt.tprintf("\",\"expires_in\":%d}", result.expires_in))
	case .Denied:
		strings.write_string(&data, "{\"status\":\"denied\"}")
	case .Expired:
		strings.write_string(&data, "{\"status\":\"expired\"}")
	case .Slow_Down:
		strings.write_string(&data, "{\"status\":\"slow_down\"}")
	case: // .Pending (covers unknown device_code too — anti-enumeration)
		strings.write_string(&data, "{\"status\":\"pending\"}")
	}
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}
// json_bool extracts a boolean field from a JSON body (default false). Tolerates
// optional whitespace after the colon.
json_bool :: proc(body, key: string) -> bool {
	needle := strings.concatenate({"\"", key, "\":"})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 {
		needle2 := strings.concatenate({"\"", key, "\": "})
		defer delete(needle2)
		idx = strings.index(body, needle2)
		if idx < 0 do return false
	}
	rest := body[idx + len(needle):]
	rest = strings.trim_space(rest)
	return strings.has_prefix(rest, "true")
}
