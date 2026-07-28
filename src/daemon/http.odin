package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

Request_Telemetry :: struct {
	method:     string,
	path:       string,
	params:     string,
	start_tick: time.Tick,
}

Response_Header :: struct {
	name:  string,
	value: string,
}

@(thread_local)
current_telemetry: ^Request_Telemetry

read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [4096]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return "", false

	request := strings.clone(string(buf[:n]))
	for !http_request_complete(request) {
		m, err := net.recv_tcp(client, buf[:])
		if err != nil || m <= 0 do break
		request = strings.concatenate({request, string(buf[:m])})
	}
	return request, true
}

http_request_complete :: proc(request: string) -> bool {
	head_end := strings.index(request, "\r\n\r\n")
	if head_end < 0 do return false
	content_length := request_content_length(request)
	if content_length <= 0 do return true
	body_len := len(request) - (head_end + 4)
	return body_len >= content_length
}

request_content_length :: proc(request: string) -> int {
	value := extract_header(request, "Content-Length")
	if value == "" do value = extract_header(request, "content-length")
	if value == "" do return 0
	if parsed, ok := strconv.parse_int(value); ok {
		return int(parsed)
	}
	return 0
}

request_body :: proc(request: string) -> string {
	if idx := strings.index(request, "\r\n\r\n"); idx >= 0 {
		return request[idx + 4:]
	}
	return ""
}

// request_line_matches reports whether the HTTP request line is `<method> <path>`
// optionally followed by a query string. Unlike a strict `has_prefix(request,
// "<method> <path> ")` check, this tolerates `<method> <path>?query ...`, which
// federation forwards produce by appending `?peer_token=...&peer_daemon_id=...`.
// Without this, forwarded routes fall through to the catch-all 404 and surface as
// a 502 "not found" on the origin daemon.
request_line_matches :: proc(request, method, path: string) -> bool {
	prefix := fmt.tprintf("%s %s", method, path)
	if !strings.has_prefix(request, prefix) do return false
	rest := request[len(prefix):]
	// The char immediately after the path must be a space (no query) or '?'.
	if len(rest) == 0 do return false
	return rest[0] == ' ' || rest[0] == '?'
}

extract_header :: proc(request, name: string) -> string {
	pattern := fmt.tprintf("%s:", name)
	idx := strings.index(request, pattern)
	if idx < 0 do return ""

	start := idx + len(pattern)
	end := strings.index(request[start:], "\r\n")
	if end < 0 do return ""

	return strings.trim_space(request[start:start + end])
}

write_response :: proc(client: net.TCP_Socket, status: int, status_text, body: string) {
	write_binary_response(client, status, status_text, "application/json", transmute([]byte)body)
}

tcp_send_all :: proc(client: net.TCP_Socket, data: []byte) -> bool {
	sent_total := 0
	for sent_total < len(data) {
		sent, err := net.send_tcp(client, data[sent_total:])
		if err != nil || sent <= 0 do return false
		sent_total += sent
	}
	return true
}

write_binary_response :: proc(client: net.TCP_Socket, status: int, status_text, content_type: string, body: []byte, headers: []Response_Header = nil) {
	builder := strings.builder_make()
	strings.write_string(&builder, fmt.tprintf("HTTP/1.1 %d %s\r\n", status, status_text))
	strings.write_string(&builder, "Content-Type: ")
	strings.write_string(&builder, content_type)
	strings.write_string(&builder, "\r\n")
	strings.write_string(&builder, fmt.tprintf("Content-Length: %d\r\n", len(body)))
	strings.write_string(&builder, "Access-Control-Allow-Origin: *\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Headers: Content-Type, Authorization\r\n")
	for header in headers {
		if header.name == "" do continue
		strings.write_string(&builder, header.name)
		strings.write_string(&builder, ": ")
		strings.write_string(&builder, header.value)
		strings.write_string(&builder, "\r\n")
	}
	strings.write_string(&builder, "Connection: close\r\n\r\n")
	header_bytes := transmute([]byte)strings.to_string(builder)
	if !tcp_send_all(client, header_bytes) do return
	if len(body) > 0 && !tcp_send_all(client, body) do return
	log_http_response(status, body)
}

log_http_response :: proc(status: int, body: []byte) {
	if current_telemetry == nil do return
	t := current_telemetry
	if t.path == "/heartbeat" || t.path == "/user-client/heartbeat" do return
	duration := time.duration_milliseconds(time.tick_diff(t.start_tick, time.tick_now()))
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock_from_time(now)
	ms := (time.to_unix_nanoseconds(now) / 1_000_000) % 1000
	body_log := ""
	if len(body) < 100 {
		body_log = fmt.tprintf(" | Body: %s", string(body))
	}
	params_log := t.params
	if len(params_log) > 200 {
		params_log = fmt.tprintf("%s...", params_log[:200])
	}
	fmt.printf("[RPC TELEMETRY] %04d-%02d-%02d %02d:%02d:%02d.%03d | %s %s | Params: %s | Status: %d | Latency: %.1fms | Size: %d bytes%s\n",
		y, int(mo), d, h, mi, s, ms,
		t.method,
		t.path,
		params_log,
		status,
		duration,
		len(body),
		body_log,
	)
}
