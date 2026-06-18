package http_client

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

Response :: struct {
	status: int,
	body: string,
}

get :: proc(base_url, path: string) -> (Response, bool) {
	return request("GET", base_url, path, "")
}

post :: proc(base_url, path, body: string) -> (Response, bool) {
	return request("POST", base_url, path, body)
}

request :: proc(method, base_url, path, body: string) -> (Response, bool) {
	host, port, ok := parse_base_url(base_url)
	if !ok do return {}, false

	socket, err := net.dial_tcp_from_hostname_with_port_override(host, int(port))
	if err != nil do return {}, false
	defer net.close(socket)

	req := fmt.tprintf(
		"%s %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		method,
		path,
		host,
		port,
		len(body),
		body,
	)
	_, send_err := net.send_tcp(socket, transmute([]byte)req)
	if send_err != nil do return {}, false

	data := make([dynamic]byte, 0, 8192)
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(socket, buf[:])
		if recv_err != nil do return {}, false
		if n == 0 do break
		append(&data, ..buf[:n])
		if response_complete(string(data[:])) do break
	}

	raw := string(data[:])
	response_body := raw
	if idx := strings.index(raw, "\r\n\r\n"); idx >= 0 {
		response_body = raw[idx + 4:]
		content_length := response_content_length(raw[:idx])
		if content_length >= 0 && len(response_body) > content_length {
			response_body = response_body[:content_length]
		}
	}

	status := 0
	if len(raw) >= 12 && (strings.has_prefix(raw, "HTTP/1.1 ") || strings.has_prefix(raw, "HTTP/1.0 ")) {
		if parsed_status, status_ok := strconv.parse_int(raw[9:12]); status_ok {
			status = int(parsed_status)
		}
	}

	return Response{status = status, body = response_body}, true
}

response_complete :: proc(raw: string) -> bool {
	idx := strings.index(raw, "\r\n\r\n")
	if idx < 0 do return false
	content_length := response_content_length(raw[:idx])
	if content_length < 0 do return false
	return len(raw[idx + 4:]) >= content_length
}

response_content_length :: proc(headers: string) -> int {
	header_text := headers
	for line in strings.split_lines_iterator(&header_text) {
		if strings.has_prefix(line, "Content-Length:") || strings.has_prefix(line, "content-length:") {
			value := strings.trim_space(line[len("Content-Length:"):])
			if parsed, ok := strconv.parse_int(value); ok do return int(parsed)
		}
	}
	return -1
}

parse_base_url :: proc(base_url: string) -> (host: string, port: u16, ok: bool) {
	url := base_url
	if strings.has_prefix(url, "http://") {
		url = url[len("http://"):]
	}

	colon := strings.last_index_byte(url, ':')
	if colon < 0 do return "", 0, false

	host = url[:colon]
	port_s := url[colon + 1:]
	port_i, port_ok := strconv.parse_int(port_s)
	if !port_ok do return "", 0, false

	return host, u16(port_i), true
}
