package http

// T7: Hub WS attach/stream endpoint + HTTP input/resize fallback.
// REQ-SH-CONTRACT §2 row 12, §7 (terminal view).

import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import iface "odin_test:hub/repository/iface"
import shell_session_svc "odin_test:hub/service/shell_session"
import project_service "odin_test:hub/service/project"

Shell_Session_Stream_Handlers :: struct {
	auth:                ^auth_service.Auth_Service,
	ws_tickets:          ^User_WS_Ticket_Store,
	bridges:             ^bridge_service.Bridge_Service,
	shell_sessions:      ^shell_session_svc.Shell_Session_Service,
	shell_repo:          ^iface.Shell_Session_Repository,
	bridge_command_sink: project_service.Bridge_Command_Sink,
}

// GET /api/v1/shells/{session_id}/stream — WS upgrade; §2 row 12.
shell_session_stream_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Shell_Session_Stream_Handlers)(ctx)

	ticket := query_value(req.query, "ticket")
	if ticket == "" {
		write_http_response(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket required for shell stream"), req.request_id))
		return
	}
	auth_ctx, auth_ok := user_ws_ticket_store_consume(h.ws_tickets, ticket)
	if !auth_ok {
		write_http_response(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket is invalid or expired"), req.request_id))
		return
	}

	session_id := path_part(req.path, 4)
	if session_id == "" || strings.contains(session_id, "/") {
		write_http_response(client, respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id))
		return
	}

	session, found, repo_err := iface.shell_session_get(h.shell_repo, auth_ctx.user_id, session_id)
	if !found || repo_err.code != .None {
		write_http_response(client, respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id))
		return
	}
	if session.owner_user_id != auth_ctx.user_id {
		write_http_response(client, respond_error(domain.domain_error(.Forbidden, "not the session owner"), req.request_id))
		return
	}

	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" {
		write_http_response(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id))
		return
	}
	if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) do return

	// Send ready frame.
	ready_b := strings.builder_make()
	strings.write_string(&ready_b, "{\"type\":\"ready\",\"session_id\":\"")
	write_handler_json_string(&ready_b, session_id)
	strings.write_string(&ready_b, "\"}")
	ready_json := strings.to_string(ready_b)
	_ = write_ws_text_frame(client, ready_json)
	delete(ready_json)

	shell_session_svc.shell_session_attach(h.shell_sessions, session_id, client)
	defer shell_session_svc.shell_session_detach(h.shell_sessions, session_id, client)

	reader := bridge_ws_reader_make(client)
	defer bridge_ws_reader_destroy(&reader)

	sink_override: project_service.Bridge_Command_Sink = {}
	for {
		text, ok := read_ws_text_blocking(&reader, 120 * time.Second)
		if !ok do return
		defer delete(text)

		frame_type := json_string(text, "type")
		defer delete(frame_type)

		switch frame_type {
		case "input":
			data_b64 := json_string(text, "data_b64")
			if data_b64 != "" {
				decoded, decode_err := base64.decode(data_b64)
				delete(data_b64)
				if decode_err == nil && decoded != nil {
					raw_data := string(decoded)
					bridge_service.send_shell_input(h.bridges, auth_ctx, session.bridge_id, session_id, raw_data, sink_override)
					delete(decoded)
				}
			} else {
				delete(data_b64)
			}
		case "resize":
			rows := json_int(text, "rows", 0)
			cols := json_int(text, "cols", 0)
			if rows >= 1 && cols >= 1 {
				bridge_service.send_shell_resize(h.bridges, auth_ctx, session.bridge_id, session_id, rows, cols, sink_override)
			}
		}
	}
}

// POST /api/v1/shells/{session_id}/input — HTTP fallback; §2 row 10.
shell_session_input_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Stream_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell input"), req.request_id)
	}

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	session, found, _ := iface.shell_session_get(h.shell_repo, auth_ctx.user_id, session_id)
	if !found {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}
	if session.owner_user_id != auth_ctx.user_id {
		return respond_error(domain.domain_error(.Forbidden, "not the session owner"), req.request_id)
	}

	data := json_string(req.body, "data")
	defer delete(data)

	sink_override: project_service.Bridge_Command_Sink = {}
	sent, err := bridge_service.send_shell_input(h.bridges, auth_ctx, session.bridge_id, session_id, data, sink_override)
	if !sent do return respond_error(err, req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/shells/{session_id}/resize — HTTP fallback; §2 row 11.
shell_session_resize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Stream_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell resize"), req.request_id)
	}

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	session, found, _ := iface.shell_session_get(h.shell_repo, auth_ctx.user_id, session_id)
	if !found {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}
	if session.owner_user_id != auth_ctx.user_id {
		return respond_error(domain.domain_error(.Forbidden, "not the session owner"), req.request_id)
	}

	rows := json_int(req.body, "rows", 0)
	cols := json_int(req.body, "cols", 0)
	if rows < 1 || cols < 1 {
		return respond_error(domain.domain_error(.Validation_Failed, "rows and cols must each be at least 1"), req.request_id)
	}

	sink_override: project_service.Bridge_Command_Sink = {}
	sent, err := bridge_service.send_shell_resize(h.bridges, auth_ctx, session.bridge_id, session_id, rows, cols, sink_override)
	if !sent do return respond_error(err, req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

// ANY /api/v1/preview/{session_id}/**  — preview tunnel proxy; REQ-SH-CONTRACT §6.
shell_session_preview_proxy_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Stream_Handlers)(ctx)

	// Standard session auth.
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	// Preview token: ?pt=pvt_... or ham_preview_{session_id} cookie.
	pt_token := query_value(req.query, "pt")
	if pt_token == "" {
		cookie_hdr := header_value(req.headers, "Cookie")
		if cookie_hdr != "" {
			cookie_prefix := strings.concatenate({"ham_preview_", session_id, "="})
			defer delete(cookie_prefix)
			parts := strings.split(cookie_hdr, ";")
			defer delete(parts)
			for part in parts {
				trimmed := strings.trim_space(part)
				if strings.has_prefix(trimmed, cookie_prefix) {
					pt_token = trimmed[len(cookie_prefix):]
					break
				}
			}
		}
	}
	if pt_token == "" {
		return Response{status = 401, content_type = "application/json", body = "{\"error\":\"preview token required\"}"}
	}

	// Validate pvt_ token.
	tok_session_id, tok_owner, tok_ok := shell_session_svc.shell_session_validate_preview_token(h.shell_sessions, pt_token)
	if !tok_ok || tok_session_id != session_id {
		return Response{status = 401, content_type = "application/json", body = "{\"error\":\"invalid or expired preview token\"}"}
	}
	if tok_owner != string(auth_ctx.user_id) {
		return Response{status = 403, content_type = "application/json", body = "{\"error\":\"preview token owner mismatch\"}"}
	}

	// Resolve session: must be kind=server, running, server_port>0.
	session, found, _ := iface.shell_session_get(h.shell_repo, string(auth_ctx.user_id), session_id)
	if !found {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}
	if session.kind != "server" {
		return Response{status = 409, content_type = "application/json", body = "{\"error\":\"session is not a server session\"}"}
	}
	if session.status != "running" {
		return Response{status = 409, content_type = "application/json", body = "{\"error\":\"session is not running\"}"}
	}
	if session.server_port <= 0 {
		return Response{status = 409, content_type = "application/json", body = "{\"error\":\"session has no server port\"}"}
	}

	// Allocate stream_id.
	stream_id := fmt.tprintf("st_%x", time.to_unix_nanoseconds(time.now()))

	// Register tunnel stream BEFORE sending tunnel_open to bridge.
	stream := shell_session_svc.shell_session_tunnel_register(h.shell_sessions, stream_id)
	defer shell_session_svc.shell_session_tunnel_unregister(h.shell_sessions, stream_id)

	// Compute forwarded path (strip /api/v1/preview/{session_id}).
	session_prefix := strings.concatenate({"/api/v1/preview/", session_id})
	defer delete(session_prefix)
	forwarded_path := req.path[len(session_prefix):]
	if forwarded_path == "" do forwarded_path = "/"

	// Send tunnel_open to bridge (fire-and-forget).
	open_json := _preview_tunnel_open_json(stream_id, session_id, req.remote_addr)
	defer delete(open_json)
	project_service.bridge_command_send_runtime(
		h.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = open_json},
	)

	// Build and send raw HTTP request as tunnel_data frames (≤48KB base64 chunks).
	raw_req := _preview_build_http_request(req.method, forwarded_path, req.query, req.headers, req.body, session.server_port)
	defer delete(raw_req)
	raw_bytes := transmute([]byte)raw_req
	CHUNK_SIZE :: 48 * 1024
	seq := 0
	off := 0
	for {
		end := off + CHUNK_SIZE
		if end > len(raw_bytes) do end = len(raw_bytes)
		chunk := raw_bytes[off:end]
		is_last := end >= len(raw_bytes)
		encoded := base64.encode(chunk)
		data_json := _preview_tunnel_data_json(stream_id, string(encoded), seq, is_last)
		delete(encoded)
		project_service.bridge_command_send_runtime(
			h.bridge_command_sink,
			project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = data_json},
		)
		delete(data_json)
		seq += 1
		off = end
		if is_last do break
	}

	// Poll for response (bridge sends tunnel_data back, then tunnel_close).
	TIMEOUT_NS :: i64(30 * 1_000_000_000)
	deadline := time.to_unix_nanoseconds(time.now()) + TIMEOUT_NS
	for {
		if time.to_unix_nanoseconds(time.now()) >= deadline {
			close_json := _preview_tunnel_close_json(stream_id, "timeout")
			project_service.bridge_command_send_runtime(
				h.bridge_command_sink,
				project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = close_json},
			)
			delete(close_json)
			return Response{status = 504, content_type = "application/json", body = "{\"error\":\"preview tunnel timeout\"}"}
		}
		sync.mutex_lock(&stream.mu)
		is_closed := stream.closed
		sync.mutex_unlock(&stream.mu)
		if is_closed do break
		time.sleep(10 * time.Millisecond)
	}

	// Reassemble response bytes from all delivered chunks.
	sync.mutex_lock(&stream.mu)
	resp_bytes := make([dynamic]byte)
	for chunk in stream.chunks do append(&resp_bytes, ..chunk)
	sync.mutex_unlock(&stream.mu)
	defer delete(resp_bytes)

	// Send tunnel_close to bridge to signal we are done.
	close_json := _preview_tunnel_close_json(stream_id, "done")
	project_service.bridge_command_send_runtime(
		h.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = close_json},
	)
	delete(close_json)

	if len(resp_bytes) == 0 {
		return Response{status = 502, content_type = "application/json", body = "{\"error\":\"empty response from tunnel\"}"}
	}
	return _preview_parse_http_response(string(resp_bytes[:]))
}

// --- preview tunnel helpers ---

_preview_tunnel_open_json :: proc(stream_id, session_id, client_ip: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"tunnel_open\",\"stream_id\":\"")
	write_handler_json_string(&b, stream_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	write_handler_json_string(&b, session_id)
	strings.write_string(&b, "\",\"client_ip\":\"")
	write_handler_json_string(&b, client_ip)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_preview_tunnel_data_json :: proc(stream_id, data_b64: string, seq: int, last: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"tunnel_data\",\"stream_id\":\"")
	write_handler_json_string(&b, stream_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	write_handler_json_string(&b, data_b64)
	strings.write_string(&b, "\",\"seq\":")
	strings.write_int(&b, seq)
	strings.write_string(&b, ",\"last\":")
	strings.write_string(&b, "true" if last else "false")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_preview_tunnel_close_json :: proc(stream_id, reason: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"tunnel_close\",\"stream_id\":\"")
	write_handler_json_string(&b, stream_id)
	strings.write_string(&b, "\",\"reason\":\"")
	write_handler_json_string(&b, reason)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_preview_build_http_request :: proc(method, fwd_path, query: string, headers: []contracts.HTTP_Header, body: string, server_port: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, method)
	strings.write_byte(&b, ' ')
	strings.write_string(&b, fwd_path)
	if query != "" {
		strings.write_byte(&b, '?')
		strings.write_string(&b, query)
	}
	strings.write_string(&b, " HTTP/1.1\r\nHost: 127.0.0.1:")
	strings.write_int(&b, server_port)
	strings.write_string(&b, "\r\nConnection: close\r\n")
	for hdr in headers {
		lower := strings.to_lower(hdr.name)
		defer delete(lower)
		switch lower {
		case "accept", "accept-encoding", "accept-language", "content-type", "content-length",
		     "cache-control", "range", "if-none-match", "if-modified-since":
			strings.write_string(&b, hdr.name)
			strings.write_string(&b, ": ")
			strings.write_string(&b, hdr.value)
			strings.write_string(&b, "\r\n")
		}
	}
	strings.write_string(&b, "\r\n")
	if body != "" do strings.write_string(&b, body)
	return strings.to_string(b)
}

_preview_parse_http_response :: proc(raw: string) -> Response {
	header_end := strings.index(raw, "\r\n\r\n")
	status_code := 200
	content_type := strings.clone("application/octet-stream")
	body_raw := raw

	if header_end >= 0 {
		header_section := raw[:header_end]
		body_raw = raw[header_end + 4:]

		// Parse status line: "HTTP/1.1 200 OK"
		line_end := strings.index(header_section, "\r\n")
		status_line := header_section[:line_end if line_end >= 0 else len(header_section)]
		parts := strings.split(status_line, " ")
		defer delete(parts)
		if len(parts) >= 2 {
			if code, ok := strconv.parse_int(parts[1]); ok do status_code = code
		}

		// Find Content-Type header.
		rest_hdr := header_section
		if line_end >= 0 do rest_hdr = header_section[line_end + 2:]
		hdr_lines := strings.split(rest_hdr, "\r\n")
		defer delete(hdr_lines)
		for line in hdr_lines {
			colon := strings.index_byte(line, ':')
			if colon < 0 do continue
			name_lower := strings.to_lower(line[:colon])
			defer delete(name_lower)
			if name_lower == "content-type" {
				delete(content_type)
				content_type = strings.clone(strings.trim_space(line[colon + 1:]))
				break
			}
		}
	}

	return Response{status = status_code, content_type = content_type, body = strings.clone(body_raw)}
}
