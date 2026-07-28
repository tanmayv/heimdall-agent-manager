package http

import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"

User_WS_Ticket :: struct {
	ticket: string,
	user_id: string,
	name: string,
	display_name: string,
	email: string,
	expires_at: i64,
}

User_WS_Ticket_Store :: struct {
	mutex: sync.Mutex,
	tickets: map[string]User_WS_Ticket,
}

User_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	event_bus: ^events.User_Event_Bus,
	ws_tickets: User_WS_Ticket_Store,
}

auth_config_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"login_url\":\"")
	write_handler_json_string(&builder, auth_service.login_url(handlers.auth))
	strings.write_string(&builder, "\",\"logout_url\":\"")
	write_handler_json_string(&builder, auth_service.logout_url(handlers.auth))
	strings.write_string(&builder, "\"}")
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
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

list_my_tokens_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	tokens, err := auth_service.list_user_api_tokens(handlers.auth, domain.User_ID(auth_ctx.user_id))
	if err.code != .None do return respond_error(err, req.request_id)
	builder := strings.builder_make()
	strings.write_byte(&builder, '[')
	for token, i in tokens {
		if i > 0 do strings.write_byte(&builder, ',')
		write_user_token_json(&builder, token)
	}
	strings.write_byte(&builder, ']')
	return respond_list(strings.to_string(builder), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

issue_my_token_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	label := strings.trim_space(json_string(req.body, "label"))
	if label == "" do label = "Electron app"
	result, issued, err := auth_service.issue_user_api_token(handlers.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = domain.User_ID(auth_ctx.user_id), label = label, expires_at = json_string(req.body, "expires_at")})
	if !issued do return respond_error(err, req.request_id)
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"token\":")
	write_user_token_json(&builder, result.token)
	strings.write_string(&builder, ",\"plaintext\":\"")
	write_handler_json_string(&builder, result.plaintext)
	strings.write_string(&builder, "\"}")
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req), 201)
}

revoke_my_token_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	token, revoked, err := auth_service.revoke_user_api_token_for_owner(handlers.auth, domain.User_ID(auth_ctx.user_id), path_part(req.path, 5))
	if !revoked do return respond_error(err, req.request_id)
	builder := strings.builder_make()
	write_user_token_json(&builder, token)
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}

issue_user_ws_ticket_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	raw_ticket, ticket_ok := device_auth.generate_device_code()
	if !ticket_ok do return respond_error(domain.domain_error(.Internal_Error, "failed to generate websocket ticket"), req.request_id)
	defer delete(raw_ticket)
	ticket := strings.concatenate({"uwst_", raw_ticket})
	defer delete(ticket)
	expires_in := 30
	user_ws_ticket_store_put(&handlers.ws_tickets, ticket, auth_ctx, i64(expires_in))
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"ticket\":\"")
	write_handler_json_string(&builder, ticket)
	strings.write_string(&builder, fmt.tprintf("\",\"expires_in\":%d}", expires_in))
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}

user_ws_upgrade_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	handlers := (^User_Handlers)(ctx)
	auth_ctx: contracts.Auth_Context
	auth_ok := false
	auth_err := domain.Domain_Error{}
	ticket := query_value(req.query, "ticket")
	if ticket != "" {
		auth_ctx, auth_ok = user_ws_ticket_store_consume(&handlers.ws_tickets, ticket)
		if !auth_ok do auth_err = domain.domain_error(.Unauthenticated, "websocket ticket is invalid or expired")
	} else {
		auth_ctx, auth_ok, auth_err = auth_service.resolve_auth(handlers.auth, auth_service.Auth_Request{remote_addr = req.remote_addr, query = req.query, body = req.body, headers = req.headers})
	}
	if !auth_ok { write_http_response(client, respond_error(auth_err, req.request_id)); return }
	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" { write_http_response(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id)); return }
	if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) do return
	idx := events.user_ws_add(handlers.event_bus, auth_ctx.user_id, client)
	defer events.user_ws_remove(handlers.event_bus, idx)
	_ = events.write_ws_text_frame(client, "{\"type\":\"user_ws_ready\",\"protocol_version\":1}")
	for {
		// The browser client sends lightweight heartbeat frames every ~25s. Keep the
		// server idle timeout comfortably above that so normal sockets do not churn,
		// while still eventually collecting half-open dead connections.
		if _, frame_ok := read_user_ws_text_blocking(client, 120 * time.Second); !frame_ok do return
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

new_user_ws_ticket_store :: proc() -> User_WS_Ticket_Store {
	return User_WS_Ticket_Store{tickets = make(map[string]User_WS_Ticket)}
}

user_ws_ticket_store_free :: proc(store: ^User_WS_Ticket_Store) {
	if store == nil || store.tickets == nil do return
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	for ticket, _ in store.tickets do delete_key(&store.tickets, ticket)
	delete(store.tickets)
}

user_ws_ticket_store_put :: proc(store: ^User_WS_Ticket_Store, ticket: string, auth_ctx: contracts.Auth_Context, ttl_seconds: i64) {
	if store == nil do return
	now := time.to_unix_seconds(time.now())
	ttl := ttl_seconds
	if ttl <= 0 do ttl = 30
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	if store.tickets == nil do store.tickets = make(map[string]User_WS_Ticket)
	for existing, item in store.tickets {
		if item.expires_at <= now do delete_key(&store.tickets, existing)
	}
	store.tickets[strings.clone(ticket)] = User_WS_Ticket{ticket = strings.clone(ticket), user_id = auth_ctx.user_id, name = auth_ctx.name, display_name = auth_ctx.display_name, email = auth_ctx.email, expires_at = now + ttl}
}

user_ws_ticket_store_consume :: proc(store: ^User_WS_Ticket_Store, ticket: string) -> (contracts.Auth_Context, bool) {
	if store == nil || store.tickets == nil || ticket == "" do return contracts.Auth_Context{}, false
	now := time.to_unix_seconds(time.now())
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	item, ok := store.tickets[ticket]
	if !ok do return contracts.Auth_Context{}, false
	delete_key(&store.tickets, ticket)
	if item.expires_at <= now do return contracts.Auth_Context{}, false
	return contracts.Auth_Context{kind = .User_Token, user_id = item.user_id, name = item.name, display_name = item.display_name, email = item.email}, true
}

write_user_token_json :: proc(builder: ^strings.Builder, token: domain.User_API_Token) {
	status := "active"
	if token.revoked_at != "" do status = "revoked"
	strings.write_string(builder, "{\"token_id\":\"")
	write_handler_json_string(builder, token.token_id)
	strings.write_string(builder, "\",\"owner_user_id\":\"")
	write_handler_json_string(builder, string(token.owner_user_id))
	strings.write_string(builder, "\",\"label\":\"")
	write_handler_json_string(builder, token.label)
	strings.write_string(builder, "\",\"status\":\"")
	write_handler_json_string(builder, status)
	strings.write_string(builder, "\",\"created_at\":\"")
	write_handler_json_string(builder, token.created_at)
	strings.write_string(builder, "\",\"updated_at\":\"")
	write_handler_json_string(builder, token.updated_at)
	strings.write_string(builder, "\",\"last_used_at\":\"")
	write_handler_json_string(builder, token.last_used_at)
	strings.write_string(builder, "\",\"expires_at\":\"")
	write_handler_json_string(builder, token.expires_at)
	strings.write_string(builder, "\",\"revoked_at\":\"")
	write_handler_json_string(builder, token.revoked_at)
	strings.write_string(builder, "\",\"created_from\":\"")
	write_handler_json_string(builder, token.created_from)
	strings.write_string(builder, "\",\"device_label\":\"")
	write_handler_json_string(builder, token.device_label)
	strings.write_string(builder, "\"}")
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
