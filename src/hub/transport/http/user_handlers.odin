package http

import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import auth_service "odin_test:hub/service/auth"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"

User_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	event_bus: ^events.User_Event_Bus,
}

me_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"user_id\":\"")
	write_handler_json_string(&builder, auth_ctx.user_id)
	strings.write_string(&builder, "\",\"name\":\"")
	write_handler_json_string(&builder, auth_ctx.name)
	strings.write_string(&builder, "\",\"display_name\":\"")
	write_handler_json_string(&builder, auth_ctx.display_name)
	strings.write_string(&builder, "\",\"email\":\"")
	write_handler_json_string(&builder, auth_ctx.email)
	strings.write_string(&builder, "\"}")
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}

user_ws_upgrade_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	handlers := (^User_Handlers)(ctx)
	auth_ctx, ok, err := auth_service.resolve_auth(handlers.auth, auth_service.Auth_Request{remote_addr = req.remote_addr, query = req.query, body = req.body, headers = req.headers})
	if !ok { write_http_response(client, respond_error(err, req.request_id)); return }
	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" { write_http_response(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id)); return }
	if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) do return
	idx := events.user_ws_add(handlers.event_bus, auth_ctx.user_id, client)
	defer events.user_ws_remove(handlers.event_bus, idx)
	_ = events.write_ws_text_frame(client, "{\"type\":\"user_ws_ready\",\"protocol_version\":1}")
	for {
		if _, frame_ok := read_user_ws_text_blocking(client, 60 * time.Second); !frame_ok do return
	}
}

logout_url_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	_, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"logout_url\":\"")
	write_handler_json_string(&builder, auth_service.logout_url(handlers.auth))
	strings.write_string(&builder, "\"}")
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}

write_user_ws_upgrade_response :: proc(client: net.TCP_Socket, accept_key: string) -> bool {
	response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept_key)
	_, err := net.send_tcp(client, transmute([]byte)response)
	return err == nil
}

user_ws_accept_key :: proc(key: string) -> string {
	GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	combined := fmt.tprintf("%s%s", key, GUID)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:])
}

read_user_ws_text_blocking :: proc(client: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(client, .Receive_Timeout, timeout)
	buf: [1024]byte
	n, err := net.recv_tcp(client, buf[:])
	if err != nil || n < 2 do return "", false
	if (buf[0] & 0x0f) == 0x8 do return "", false
	return string(buf[:n]), true
}

write_handler_json_string :: proc(builder: ^strings.Builder, value: string) {
	for i in 0..<len(value) {
		ch := value[i]
		switch ch {
		case '"': strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case: strings.write_byte(builder, ch)
		}
	}
}

auth_ctx_server_time :: proc(req: Request) -> string {
	_ = req
	// The app composition root injects a real clock for service logic; this helper
	// keeps transport handlers deterministic until the HTTP server adapter passes
	// per-request server_time through Request in a later phase.
	return "2026-07-22T10:00:00Z"
}
