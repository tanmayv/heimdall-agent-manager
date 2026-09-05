package http_client

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

DEFAULT_TIMEOUT_MS :: 20000

Response :: struct {
	status: int,
	body: string,
}

Header :: struct {
	name: string,
	value: string,
}

get :: proc(base_url, path: string) -> (Response, bool) {
	return request_with_timeout("GET", base_url, path, "", DEFAULT_TIMEOUT_MS)
}

get_with_timeout :: proc(base_url, path: string, timeout_ms: int) -> (Response, bool) {
	return request_with_timeout("GET", base_url, path, "", timeout_ms)
}

post :: proc(base_url, path, body: string) -> (Response, bool) {
	return request_with_timeout("POST", base_url, path, body, DEFAULT_TIMEOUT_MS)
}

post_with_timeout :: proc(base_url, path, body: string, timeout_ms: int) -> (Response, bool) {
	return request_with_timeout("POST", base_url, path, body, timeout_ms)
}

request :: proc(method, base_url, path, body: string) -> (Response, bool) {
	return request_with_timeout(method, base_url, path, body, DEFAULT_TIMEOUT_MS)
}

request_with_timeout :: proc(method, base_url, path, body: string, timeout_ms: int) -> (Response, bool) {
	return request_blocking(method, base_url, path, body, timeout_ms)
}

request_with_headers_timeout :: proc(method, base_url, path, body: string, headers: []Header, timeout_ms: int) -> (Response, bool) {
	return request_blocking_with_headers(method, base_url, path, body, headers, timeout_ms)
}

request_blocking :: proc(method, base_url, path, body: string, timeout_ms := 0) -> (Response, bool) {
	return request_blocking_with_headers(method, base_url, path, body, nil, timeout_ms)
}

request_blocking_with_headers :: proc(method, base_url, path, body: string, extra_headers: []Header, timeout_ms := 0) -> (Response, bool) {
	host, port, secure, ok := parse_base_url(base_url)
	if !ok do return {}, false
	if secure do return request_tls_with_headers(method, host, port, path, body, extra_headers, timeout_ms)

	socket, dial_ok := dial_tcp_with_timeout(host, int(port), timeout_ms)
	if !dial_ok do return {}, false
	defer net.close(socket)
	if timeout_ms > 0 {
		timeout := time.Duration(timeout_ms) * time.Millisecond
		if net.set_option(socket, .Send_Timeout, timeout) != nil do return {}, false
		if net.set_option(socket, .Receive_Timeout, timeout) != nil do return {}, false
	}

	req := build_http_request(method, host, port, path, body, extra_headers)
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

	return parse_response_bytes(data[:])
}

request_tls_with_headers :: proc(method, host: string, port: u16, path, body: string, extra_headers: []Header, timeout_ms := 0) -> (Response, bool) {
	stdin_r, stdin_w, stdin_err := os.pipe()
	if stdin_err != nil do return {}, false
	defer os.close(stdin_r)
	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil { _ = os.close(stdin_w); return {}, false }
	defer os.close(stdout_r)

	command := tls_client_command(host, port)
	process, start_err := os.process_start(os.Process_Desc{command = command, stdin = stdin_r, stdout = stdout_w})
	_ = os.close(stdout_w)
	if start_err != nil { _ = os.close(stdin_w); return {}, false }

	req := build_http_request(method, host, port, path, body, extra_headers)
	_, write_err := os.write(stdin_w, transmute([]byte)req)
	_ = os.close(stdin_w)
	if write_err != nil {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		return {}, false
	}

	deadline := time.to_unix_nanoseconds(time.now()) + i64(time.Duration(timeout_ms if timeout_ms > 0 else DEFAULT_TIMEOUT_MS) * time.Millisecond)
	data := make([dynamic]byte, 0, 8192)
	buf: [8192]byte
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if ready, pipe_err := os.pipe_has_data(stdout_r); pipe_err != nil {
			break
		} else if ready {
			n, read_err := os.read(stdout_r, buf[:])
			if read_err != nil || n <= 0 do break
			append(&data, ..buf[:n])
			if response_complete(string(data[:])) do break
		} else {
			if state, wait_err := os.process_wait(process, 0); wait_err == nil {
				_ = state
				break
			}
			time.sleep(10 * time.Millisecond)
		}
	}
	_ = os.process_terminate(process)
	_, _ = os.process_wait(process, 250 * time.Millisecond)
	if len(data) == 0 do return {}, false
	return parse_response_bytes(data[:])
}

build_http_request :: proc(method, host: string, port: u16, path, body: string, extra_headers: []Header) -> string {
	req_b := strings.builder_make()
	strings.write_string(&req_b, fmt.tprintf("%s %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\n", method, path, host, port))
	for h in extra_headers {
		if strings.trim_space(h.name) == "" do continue
		strings.write_string(&req_b, h.name)
		strings.write_string(&req_b, ": ")
		strings.write_string(&req_b, h.value)
		strings.write_string(&req_b, "\r\n")
	}
	strings.write_string(&req_b, fmt.tprintf("Content-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body))
	return strings.to_string(req_b)
}

parse_response_bytes :: proc(data: []byte) -> (Response, bool) {
	raw := string(data)
	response_body := raw
	body_is_owned := false
	if idx := strings.index(raw, "\r\n\r\n"); idx >= 0 {
		headers := raw[:idx]
		response_body = raw[idx + 4:]
		if response_transfer_chunked(headers) {
			// response_decode_chunked_body allocates a fresh string.
			response_body = response_decode_chunked_body(response_body)
			body_is_owned = true
		} else {
			content_length := response_content_length(headers)
			if content_length >= 0 {
				if len(response_body) < content_length do return {}, false
				if len(response_body) > content_length do response_body = response_body[:content_length]
			}
		}
	}

	status := 0
	if len(raw) >= 12 && (strings.has_prefix(raw, "HTTP/1.1 ") || strings.has_prefix(raw, "HTTP/1.0 ")) {
		if parsed_status, status_ok := strconv.parse_int(raw[9:12]); status_ok {
			status = int(parsed_status)
		}
	}

	// Response.body must be an independently-heap-allocated string so callers can
	// safely `delete(resp.body)`. In the non-chunked path response_body is a slice
	// into the transient `data` buffer (its pointer lands mid-buffer, right after
	// the \r\n\r\n header terminator); returning that slice caused callers that
	// free the body to hit an invalid-free (SIGABRT). Clone it here so ownership is
	// unambiguous.
	if !body_is_owned {
		response_body = strings.clone(response_body)
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

response_transfer_chunked :: proc(headers: string) -> bool {
	header_text := headers
	for line in strings.split_lines_iterator(&header_text) {
		if strings.has_prefix(line, "Transfer-Encoding:") || strings.has_prefix(line, "transfer-encoding:") {
			return strings.contains(strings.to_lower(line), "chunked")
		}
	}
	return false
}

response_decode_chunked_body :: proc(body: string) -> string {
	b := strings.builder_make()
	pos := 0
	for pos < len(body) {
		line_end := strings.index(body[pos:], "\r\n")
		if line_end < 0 do break
		size_line := strings.trim_space(body[pos:pos + line_end])
		if semi := strings.index(size_line, ";"); semi >= 0 do size_line = size_line[:semi]
		size, ok := parse_hex_size(size_line)
		if !ok do break
		pos += line_end + 2
		if size == 0 do break
		if pos + size > len(body) do break
		strings.write_string(&b, body[pos:pos + size])
		pos += size
		if pos + 2 <= len(body) && body[pos:pos + 2] == "\r\n" do pos += 2
	}
	return strings.to_string(b)
}

parse_hex_size :: proc(text: string) -> (int, bool) {
	trimmed := strings.trim_space(text)
	if trimmed == "" do return 0, false
	value := 0
	for i in 0..<len(trimmed) {
		ch := trimmed[i]
		digit := -1
		if ch >= '0' && ch <= '9' {
			digit = int(ch - '0')
		} else if ch >= 'a' && ch <= 'f' {
			digit = int(ch - 'a') + 10
		} else if ch >= 'A' && ch <= 'F' {
			digit = int(ch - 'A') + 10
		} else {
			return 0, false
		}
		value = value * 16 + digit
	}
	return value, true
}

dial_tcp_with_timeout :: proc(host: string, port, timeout_ms: int) -> (net.TCP_Socket, bool) {
	endpoint, endpoint_ok := resolve_host_with_timeout(host, port, timeout_ms)
	if !endpoint_ok do return 0, false

	sock_any, sock_err := net.create_socket(net.family_from_endpoint(endpoint), .TCP)
	if sock_err != nil do return 0, false
	socket := sock_any.(net.TCP_Socket)
	success := false
	defer if !success { net.close(socket) }
	if net.set_blocking(socket, false) != nil do return 0, false

	sockaddr, addr_len := endpoint_to_sockaddr(endpoint)
	result := posix.connect(posix.FD(socket), (^posix.sockaddr)(&sockaddr), addr_len)
	if result != .OK {
		errno := posix.errno()
		if errno != .EINPROGRESS do return 0, false
		poll_timeout := i32(-1) if timeout_ms <= 0 else i32(timeout_ms)
		poll_fd := posix.pollfd{fd = posix.FD(socket), events = {.OUT}}
		ready := posix.poll(&poll_fd, 1, poll_timeout)
		if ready <= 0 do return 0, false
		so_error: posix.Errno
		size := posix.socklen_t(size_of(so_error))
		if posix.getsockopt(posix.FD(socket), posix.SOL_SOCKET, .ERROR, &so_error, &size) != .OK do return 0, false
		if so_error != nil do return 0, false
	}
	if net.set_blocking(socket, true) != nil do return 0, false
	success = true
	return socket, true
}

resolve_host_with_timeout :: proc(host: string, port, timeout_ms: int) -> (net.Endpoint, bool) {
	clean_host := host_trim_brackets(host)
	if endpoint, ok := resolve_host_without_dns(clean_host, port); ok do return endpoint, true
	if timeout_ms > 0 {
		return resolve_host_via_command(clean_host, port, timeout_ms)
	}
	return resolve_host_blocking(clean_host, port)
}

resolve_host_without_dns :: proc(host: string, port: int) -> (net.Endpoint, bool) {
	if host == "localhost" {
		return net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}, true
	}
	if ip4, ok := net.parse_ip4_address(host); ok {
		return net.Endpoint{address = ip4, port = port}, true
	}
	if ip6, ok := net.parse_ip6_address(host); ok {
		return net.Endpoint{address = ip6, port = port}, true
	}
	return net.Endpoint{}, false
}

resolve_host_blocking :: proc(host: string, port: int) -> (net.Endpoint, bool) {
	ep4, ep6, err := net.resolve(fmt.tprintf("%s:%d", host, port))
	if err != nil do return net.Endpoint{}, false
	endpoint := ep4 if ep4.address != nil else ep6
	if endpoint.address == nil || endpoint.port == 0 do return net.Endpoint{}, false
	return endpoint, true
}

resolve_host_via_command :: proc(host: string, port, timeout_ms: int) -> (net.Endpoint, bool) {
	command: []string
	when ODIN_OS == .Linux {
		command = []string{"getent", "ahosts", host}
	} else when ODIN_OS == .Darwin {
		command = []string{"dscacheutil", "-q", "host", "-a", "name", host}
	} else {
		return net.Endpoint{}, false
	}
	stdout_r, stdout_w, pipe_err := os.pipe()
	if pipe_err != nil do return net.Endpoint{}, false
	defer os.close(stdout_r)
	process, start_err := os.process_start(os.Process_Desc{
		command = command,
		stdout = stdout_w,
	})
	if start_err != nil {
		_ = os.close(stdout_w)
		return net.Endpoint{}, false
	}
	_ = os.close(stdout_w)
	state, wait_err := os.process_wait(process, time.Duration(timeout_ms) * time.Millisecond)
	if wait_err != nil {
		if os_error_is_timeout(wait_err) {
			_ = os.process_kill(process)
			_, _ = os.process_wait(process)
		}
		return net.Endpoint{}, false
	}
	if !state.success do return net.Endpoint{}, false
	output, read_err := os.read_entire_file(stdout_r, context.temp_allocator)
	if read_err != nil do return net.Endpoint{}, false
	return endpoint_from_resolution_output(string(output), port)
}

endpoint_from_resolution_output :: proc(output: string, port: int) -> (net.Endpoint, bool) {
	text := output
	for field in strings.fields_iterator(&text) {
		token := strings.trim(field, " \t\r\n,[]")
		if strings.has_suffix(token, ":") && strings.count(token, ":") == 1 {
			token = token[:len(token)-1]
		}
		if token == "" do continue
		if endpoint, ok := resolve_host_without_dns(token, port); ok do return endpoint, true
	}
	return net.Endpoint{}, false
}

tls_client_command :: proc(host: string, port: u16) -> []string {
	cmd := make([dynamic]string)
	append(&cmd, "openssl")
	append(&cmd, "s_client")
	append(&cmd, "-quiet")
	append(&cmd, "-verify_return_error")
	append(&cmd, "-servername")
	append(&cmd, host_trim_brackets(host))
	append(&cmd, "-verify_hostname")
	append(&cmd, host_trim_brackets(host))
	if ca_file := strings.trim_space(os.get_env("HAM_TLS_CA_FILE", context.temp_allocator)); ca_file != "" {
		append(&cmd, "-CAfile")
		append(&cmd, ca_file)
	}
	append(&cmd, "-connect")
	append(&cmd, fmt.tprintf("%s:%d", host_trim_brackets(host), port))
	return cmd[:]
}

host_trim_brackets :: proc(host: string) -> string {
	if len(host) >= 2 && host[0] == '[' && host[len(host)-1] == ']' {
		return host[1:len(host)-1]
	}
	return host
}

os_error_is_timeout :: proc(err: os.Error) -> bool {
	if err == nil do return false
	general, ok := err.(os.General_Error)
	if !ok do return false
	return general == .Timeout
}

endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: posix.sockaddr_storage, addr_len: posix.socklen_t) {
	switch a in ep.address {
	case net.IP4_Address:
		when ODIN_OS == .Linux {
			(^posix.sockaddr_in)(&sockaddr)^ = posix.sockaddr_in{
				sin_family = .INET,
				sin_port = u16be(ep.port),
				sin_addr = transmute(posix.in_addr)a,
			}
		} else {
			(^posix.sockaddr_in)(&sockaddr)^ = posix.sockaddr_in{
				sin_len = size_of(posix.sockaddr_in),
				sin_family = .INET,
				sin_port = u16be(ep.port),
				sin_addr = transmute(posix.in_addr)a,
			}
		}
		addr_len = posix.socklen_t(size_of(posix.sockaddr_in))
		return
	case net.IP6_Address:
		when ODIN_OS == .Linux {
			(^posix.sockaddr_in6)(&sockaddr)^ = posix.sockaddr_in6{
				sin6_family = .INET6,
				sin6_port = u16be(ep.port),
				sin6_addr = transmute(posix.in6_addr)a,
			}
		} else {
			(^posix.sockaddr_in6)(&sockaddr)^ = posix.sockaddr_in6{
				sin6_len = size_of(posix.sockaddr_in6),
				sin6_family = .INET6,
				sin6_port = u16be(ep.port),
				sin6_addr = transmute(posix.in6_addr)a,
			}
		}
		addr_len = posix.socklen_t(size_of(posix.sockaddr_in6))
		return
	case:
		return
	}
}

parse_base_url :: proc(base_url: string) -> (host: string, port: u16, secure: bool, ok: bool) {
	url := base_url
	default_port: u16 = 80
	if strings.has_prefix(url, "https://") {
		url = url[len("https://"):]
		default_port = 443
		secure = true
	} else if strings.has_prefix(url, "http://") {
		url = url[len("http://"):]
		default_port = 80
	}
	url = strings.trim_right(url, "/")
	if slash := strings.index_byte(url, '/'); slash >= 0 do url = url[:slash]

	colon := strings.last_index_byte(url, ':')
	if colon < 0 {
		host = url
		return host, default_port, secure, strings.trim_space(host) != ""
	}

	host = url[:colon]
	port_s := url[colon + 1:]
	port_i, port_ok := strconv.parse_int(port_s)
	if !port_ok do return "", 0, false, false

	return host, u16(port_i), secure, true
}
