package http

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:thread"
import contracts "odin_test:contracts"

Server_Config :: struct {
	bind_host: string,
	port: int,
}

serve :: proc(router: ^Router, config: Server_Config) -> bool {
	address := net.IP4_Loopback
	if config.bind_host != "127.0.0.1" {
		if parsed, ok := net.parse_ip4_address(config.bind_host); ok do address = parsed
	}
	listener, err := net.listen_tcp({address, config.port})
	if err != nil {
		fmt.eprintln("ham-hub listen failed", config.bind_host, config.port, err)
		return false
	}
	defer net.close(listener)
	fmt.println("ham-hub listening", config.bind_host, config.port)
	for {
		client, source, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		thread.run_with_poly_data3(client, source, router, handle_client_thread)
	}
}

handle_client_thread :: proc(client: net.TCP_Socket, source: net.Endpoint, router: ^Router) { handle_client(client, source, router) }

handle_client :: proc(client: net.TCP_Socket, source: net.Endpoint, router: ^Router) {
	defer net.close(client)
	request, ok := read_http_request(client)
	if !ok do return
	method, target := request_method_target(request)
	path, query := split_target_query(target)
	body := request_body(request)
	headers := parse_headers(request)
	defer free_request_headers(headers)
	request_id := header_value(headers, "X-Request-Id")
	if request_id == "" do request_id = "req_local"
	req_obj := Request{
		method = method,
		path = path,
		query = query,
		body = body,
		request_id = request_id,
		remote_addr = net.address_to_string_allocator(source.address),
		headers = headers,
	}
	if ascii_equal_fold(header_value(headers, "Upgrade"), "websocket") && router_dispatch_upgrade(router, req_obj, client) do return
	resp := router_dispatch(router, req_obj)
	write_http_response(client, resp)
}


read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [8192]byte
	data := make([dynamic]byte, 0, 8192)
	for {
		n, recv_err := net.recv_tcp(client, buf[:])
		if recv_err != nil || n <= 0 do return "", false
		append(&data, ..buf[:n])
		raw := string(data[:])
		if request_complete(raw) do return strings.clone(raw), true
		if len(data) > 1024 * 1024 do return "", false
	}
}

request_complete :: proc(raw: string) -> bool {
	idx := strings.index(raw, "\r\n\r\n")
	if idx < 0 do return false
	return len(raw[idx + 4:]) >= content_length(raw[:idx])
}

content_length :: proc(headers: string) -> int {
	text := headers
	for line in strings.split_lines_iterator(&text) {
		if ascii_has_prefix_fold(line, "Content-Length:") {
			if parsed, ok := strconv.parse_int(strings.trim_space(line[len("Content-Length:"):])); ok do return int(parsed)
		}
	}
	return 0
}

request_method_target :: proc(request: string) -> (string, string) {
	line_end := strings.index(request, "\r\n")
	if line_end < 0 do return "", ""
	parts := strings.split(request[:line_end], " ")
	defer delete(parts)
	if len(parts) < 2 do return "", ""
	return strings.clone(parts[0]), strings.clone(parts[1])
}

split_target_query :: proc(target: string) -> (string, string) {
	idx := strings.index_byte(target, '?')
	if idx < 0 do return target, ""
	return target[:idx], target[idx + 1:]
}

parse_headers :: proc(request: string) -> []contracts.HTTP_Header {
	out := make([dynamic]contracts.HTTP_Header)
	head_end := strings.index(request, "\r\n\r\n")
	if head_end < 0 do return out[:]
	head := request[:head_end]
	first := true
	for line in strings.split_lines_iterator(&head) {
		if first { first = false; continue }
		colon := strings.index_byte(line, ':')
		if colon <= 0 do continue
		append(&out, contracts.HTTP_Header{name = strings.clone(strings.trim_space(line[:colon])), value = strings.clone(strings.trim_space(line[colon + 1:]))})
	}
	return out[:]
}

free_request_headers :: proc(headers: []contracts.HTTP_Header) {
	for h in headers {
		delete(h.name)
		delete(h.value)
	}
	delete(headers)
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if ascii_equal_fold(h.name, name) do return strings.trim_space(h.value)
	}
	return ""
}

request_body :: proc(request: string) -> string {
	idx := strings.index(request, "\r\n\r\n")
	if idx < 0 do return ""
	return request[idx + 4:]
}

write_http_response :: proc(client: net.TCP_Socket, resp: Response) {
	body := resp.body
	content_type := resp.content_type
	if content_type == "" do content_type = "application/json"
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", resp.status, status_text(resp.status), content_type, len(body)))
	strings.write_string(&b, body)
	raw := strings.to_string(b)
	_, _ = net.send_tcp(client, transmute([]byte)raw)
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200: return "OK"
	case 201: return "Created"
	case 202: return "Accepted"
	case 204: return "No Content"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 409: return "Conflict"
	case 429: return "Too Many Requests"
	case 500: return "Internal Server Error"
	case 503: return "Service Unavailable"
	}
	return "OK"
}

ascii_has_prefix_fold :: proc(value, prefix: string) -> bool {
	if len(value) < len(prefix) do return false
	return ascii_equal_fold(value[:len(prefix)], prefix)
}

ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' do ca += 32
		if cb >= 'A' && cb <= 'Z' do cb += 32
		if ca != cb do return false
	}
	return true
}
