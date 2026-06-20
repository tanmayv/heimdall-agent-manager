package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

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
}
