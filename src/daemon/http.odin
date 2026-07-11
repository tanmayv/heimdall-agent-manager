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
	response := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nConnection: close\r\n\r\n%s",
		status,
		status_text,
		len(body),
		body,
	)
	net.send_tcp(client, transmute([]byte)response)

	if current_telemetry != nil {
		t := current_telemetry
		// ponytail: skip telemetry for heartbeat routes to avoid cluttering daemon logs
		if t.path != "/heartbeat" && t.path != "/user-client/heartbeat" {
			duration := time.duration_milliseconds(time.tick_diff(t.start_tick, time.tick_now()))

			now := time.now()
		y, mo, d := time.date(now)
		h, mi, s := time.clock_from_time(now)
		ms := (time.to_unix_nanoseconds(now) / 1_000_000) % 1000

		body_log := ""
		if len(body) < 100 {
			body_log = fmt.tprintf(" | Body: %s", body)
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
	}
}
