package ws

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

WS_KEY :: "dGhlIHNhbXBsZSBub25jZQ=="

Connection :: struct {
	socket: net.TCP_Socket,
	secure: bool,
	process: os.Process,
	stdin_w: ^os.File,
	stdout_r: ^os.File,
	connected: bool,
	pending_texts: [dynamic]string,
	pending_bytes: [dynamic]byte,
}

connect :: proc(ws_url: string) -> (Connection, bool) {
	return connect_with_bearer(ws_url, "")
}

connect_with_bearer :: proc(ws_url, bearer_token: string) -> (Connection, bool) {
	host, port, path, secure, ok := parse_ws_url(ws_url)
	if !ok do return {}, false
	if secure do return connect_tls_with_bearer(host, port, path, bearer_token)

	socket, err := net.dial_tcp_from_hostname_with_port_override(host, int(port))
	if err != nil do return {}, false

	auth_header := ""
	if strings.trim_space(bearer_token) != "" {
		auth_header = fmt.tprintf("Authorization: Bearer %s\r\n", bearer_token)
	}
	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n",
		path,
		host,
		port,
		WS_KEY,
		auth_header,
	)
	_, send_err := net.send_tcp(socket, transmute([]byte)request)
	if send_err != nil {
		net.close(socket)
		return {}, false
	}

	buf: [4096]byte
	n, recv_err := net.recv_tcp(socket, buf[:])
	if recv_err != nil || n <= 0 {
		net.close(socket)
		return {}, false
	}

	response := string(buf[:n])
	if !(strings.has_prefix(response, "HTTP/1.1 101") || strings.has_prefix(response, "HTTP/1.0 101")) {
		net.close(socket)
		return {}, false
	}

	pending_bytes := make([dynamic]byte)
	if header_end := strings.index(response, "\r\n\r\n"); header_end >= 0 {
		extra_start := header_end + 4
		if extra_start < n do append(&pending_bytes, ..buf[extra_start:n])
	}
	_ = net.set_blocking(socket, false)
	return Connection{socket = socket, secure = false, connected = true, pending_texts = make([dynamic]string), pending_bytes = pending_bytes}, true
}

connect_tls_with_bearer :: proc(host: string, port: u16, path, bearer_token: string) -> (Connection, bool) {
	stdin_r, stdin_w, stdin_err := os.pipe()
	if stdin_err != nil do return {}, false
	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil { _ = os.close(stdin_r); _ = os.close(stdin_w); return {}, false }
	cmd := tls_client_command(host, port)
	process, start_err := os.process_start(os.Process_Desc{command = cmd, stdin = stdin_r, stdout = stdout_w})
	_ = os.close(stdin_r)
	_ = os.close(stdout_w)
	if start_err != nil { _ = os.close(stdin_w); _ = os.close(stdout_r); return {}, false }

	auth_header := ""
	if strings.trim_space(bearer_token) != "" {
		auth_header = fmt.tprintf("Authorization: Bearer %s\r\n", bearer_token)
	}
	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n",
		path,
		host,
		port,
		WS_KEY,
		auth_header,
	)
	_, send_err := os.write(stdin_w, transmute([]byte)request)
	if send_err != nil {
		_ = os.close(stdin_w)
		_ = os.close(stdout_r)
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		return {}, false
	}

	data := make([dynamic]byte)
	buf: [4096]byte
	deadline := time.to_unix_nanoseconds(time.now()) + i64(5 * time.Second)
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if ready, pipe_err := os.pipe_has_data(stdout_r); pipe_err != nil {
			break
		} else if ready {
			n, read_err := os.read(stdout_r, buf[:])
			if read_err != nil || n <= 0 do break
			append(&data, ..buf[:n])
			if strings.contains(string(data[:]), "\r\n\r\n") do break
		} else {
			time.sleep(10 * time.Millisecond)
		}
	}
	response := string(data[:])
	if !(strings.has_prefix(response, "HTTP/1.1 101") || strings.has_prefix(response, "HTTP/1.0 101")) {
		_ = os.close(stdin_w)
		_ = os.close(stdout_r)
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		return {}, false
	}
	pending_bytes := make([dynamic]byte)
	if header_end := strings.index(response, "\r\n\r\n"); header_end >= 0 {
		extra_start := header_end + 4
		if extra_start < len(data) do append(&pending_bytes, ..data[extra_start:])
	}
	return Connection{secure = true, process = process, stdin_w = stdin_w, stdout_r = stdout_r, connected = true, pending_texts = make([dynamic]string), pending_bytes = pending_bytes}, true
}

close :: proc(conn: ^Connection) {
	if conn.connected {
		if conn.secure {
			if conn.stdin_w != nil do _ = os.close(conn.stdin_w)
			if conn.stdout_r != nil do _ = os.close(conn.stdout_r)
			_ = os.process_terminate(conn.process)
			_, _ = os.process_wait(conn.process, 250 * time.Millisecond)
		} else {
			net.close(conn.socket)
		}
		conn.connected = false
	}
}

poll_text :: proc(conn: ^Connection) -> (text: string, ok: bool) {
	if !conn.connected do return "", false
	if len(conn.pending_texts) > 0 {
		text = conn.pending_texts[0]
		ordered_remove(&conn.pending_texts, 0)
		return text, true
	}

	buf: [131072]byte
	n := 0
	if conn.secure {
		if ready, pipe_err := os.pipe_has_data(conn.stdout_r); pipe_err != nil {
			conn.connected = false
			return "", false
		} else if !ready {
			return "", false
		}
		read_n, read_err := os.read(conn.stdout_r, buf[:])
		if read_err != nil || read_n <= 0 {
			conn.connected = false
			return "", false
		}
		n = read_n
	} else {
		read_n, err := net.recv_tcp(conn.socket, buf[:])
		if err != nil {
			if err == .Would_Block do return "", false
			conn.connected = false
			return "", false
		}
		if read_n == 0 {
			conn.connected = false
			return "", false
		}
		n = read_n
	}
	append(&conn.pending_bytes, ..buf[:n])

	first_text := ""
	pos := 0
	for pos + 2 <= len(conn.pending_bytes) {
		opcode := conn.pending_bytes[pos] & 0x0f
		payload_len := int(conn.pending_bytes[pos + 1] & 0x7f)
		header_len := 2
		if payload_len == 126 {
			if pos + 4 > len(conn.pending_bytes) do break
			payload_len = int(conn.pending_bytes[pos + 2]) << 8 | int(conn.pending_bytes[pos + 3])
			header_len = 4
		} else if payload_len == 127 {
			conn.connected = false
			return "", false
		}
		frame_end := pos + header_len + payload_len
		if frame_end > len(conn.pending_bytes) do break
		if opcode == 0x8 {
			conn.connected = false
			return "", false
		}
		if opcode == 0x1 {
			frame_text := strings.clone(string(conn.pending_bytes[pos + header_len:frame_end]))
			if first_text == "" {
				first_text = frame_text
			} else {
				append(&conn.pending_texts, frame_text)
			}
		}
		pos = frame_end
	}
	if pos > 0 {
		remaining := make([dynamic]byte)
		if pos < len(conn.pending_bytes) do append(&remaining, ..conn.pending_bytes[pos:])
		conn.pending_bytes = remaining
	}

	if first_text == "" do return "", false
	return first_text, true
}

send_text :: proc(conn: ^Connection, text: string) -> bool {
	if !conn.connected do return false
	n := len(text)
	if n > 65535 do return false
	header_len := 2
	if n > 125 do header_len = 4
	frame := make([]byte, header_len + n)
	frame[0] = 0x81
	if n <= 125 {
		frame[1] = byte(n)
	} else {
		frame[1] = 126
		frame[2] = byte((n >> 8) & 0xff)
		frame[3] = byte(n & 0xff)
	}
	copy(frame[header_len:], transmute([]byte)text)
	if conn.secure do return send_all_file(conn.stdin_w, frame)
	return send_all_tcp(conn.socket, frame)
}

send_all_tcp :: proc(socket: net.TCP_Socket, bytes: []byte) -> bool {
	sent := 0
	deadline := time.to_unix_nanoseconds(time.now()) + i64(5 * time.Second)
	for sent < len(bytes) {
		if time.to_unix_nanoseconds(time.now()) > deadline do return false
		n, err := net.send_tcp(socket, bytes[sent:])
		if err != nil {
			if err == .Would_Block { time.sleep(10 * time.Millisecond); continue }
			return false
		}
		if n <= 0 do return false
		sent += n
	}
	return true
}

send_all_file :: proc(file: ^os.File, bytes: []byte) -> bool {
	sent := 0
	for sent < len(bytes) {
		n, err := os.write(file, bytes[sent:])
		if err != nil || n <= 0 do return false
		sent += n
	}
	return true
}

// tls_client_command builds the argv for the subprocess that terminates TLS for
// the bridge->hub wss:// control channel. The transport is selected by the
// HAM_TLS_BACKEND env toggle:
//   - "s_client"      -> legacy `openssl s_client` (kept as an instant, no-rebuild
//                        fallback; suffers the 16 KB multi-read teardown).
//   - anything else   -> `socat OPENSSL-CONNECT` (the DEFAULT: a purpose-built
//     (default socat)   full-duplex relay that does not tear down on multi-read
//                        bursts, which is what unblocks large FS reads/artifacts).
// SHARED CONTRACT: the exact same rule ("s_client" == legacy, else socat) is
// duplicated in src/lib/http_client/http_client.odin and in the bridge's
// bridge_tls_backend_is_socat (src/bridge/fs_management.odin) — keep them in sync.
tls_client_command :: proc(host: string, port: u16) -> []string {
	clean_host := host
	if len(clean_host) >= 2 && clean_host[0] == '[' && clean_host[len(clean_host)-1] == ']' {
		clean_host = clean_host[1:len(clean_host)-1]
	}
	ca_file := strings.trim_space(os.get_env("HAM_TLS_CA_FILE", context.temp_allocator))
	backend := strings.to_lower(strings.trim_space(os.get_env("HAM_TLS_BACKEND", context.temp_allocator)))
	if backend == "s_client" {
		return openssl_s_client_command(clean_host, port, ca_file)
	}
	return socat_openssl_command(clean_host, port, ca_file)
}

// openssl_s_client_command is the legacy fallback transport (HAM_TLS_BACKEND=s_client).
openssl_s_client_command :: proc(clean_host: string, port: u16, ca_file: string) -> []string {
	cmd := make([dynamic]string)
	append(&cmd, "openssl")
	append(&cmd, "s_client")
	append(&cmd, "-quiet")
	append(&cmd, "-verify_return_error")
	append(&cmd, "-servername")
	append(&cmd, clean_host)
	append(&cmd, "-verify_hostname")
	append(&cmd, clean_host)
	if ca_file != "" {
		append(&cmd, "-CAfile")
		append(&cmd, ca_file)
	}
	append(&cmd, "-connect")
	append(&cmd, fmt.tprintf("%s:%d", clean_host, port))
	return cmd[:]
}

// socat_openssl_command is the default transport. It relays STDIO <-> an OpenSSL
// TLS connection. TLS verification is EQUIVALENT to the s_client path and MUST NOT
// be weakened:
//   - verify=1        : require + verify the peer certificate chain (fail closed).
//   - commonname=<h>  : check the cert's CN/SAN against the intended host — this is
//                       the hostname verification (mirrors s_client -verify_hostname).
//   - snihost=<h>     : send SNI so the server presents the right cert (mirrors
//                       s_client -servername).
//   - cafile=<ca>     : trust anchor when HAM_TLS_CA_FILE is set; when unset, socat
//                       uses OpenSSL's default CA store, exactly like s_client with
//                       no -CAfile. NEVER emit verify=0.
socat_openssl_command :: proc(clean_host: string, port: u16, ca_file: string) -> []string {
	opts := strings.builder_make()
	fmt.sbprintf(&opts, "OPENSSL-CONNECT:%s:%d", clean_host, port)
	fmt.sbprintf(&opts, ",snihost=%s", clean_host)
	strings.write_string(&opts, ",verify=1")
	fmt.sbprintf(&opts, ",commonname=%s", clean_host)
	if ca_file != "" {
		fmt.sbprintf(&opts, ",cafile=%s", ca_file)
	}
	cmd := make([dynamic]string)
	append(&cmd, "socat")
	append(&cmd, "STDIO")
	append(&cmd, strings.to_string(opts))
	return cmd[:]
}

parse_ws_url :: proc(ws_url: string) -> (host: string, port: u16, path: string, secure: bool, ok: bool) {
	url := ws_url
	default_port: u16 = 80
	if strings.has_prefix(url, "wss://") {
		url = url[len("wss://"):]
		default_port = 443
		secure = true
	} else if strings.has_prefix(url, "ws://") {
		url = url[len("ws://"):]
		default_port = 80
	}

	slash := strings.index_byte(url, '/')
	if slash < 0 do return "", 0, "", false, false

	host_port := url[:slash]
	path = url[slash:]
	colon := strings.last_index_byte(host_port, ':')
	if colon < 0 {
		host = host_port
		return host, default_port, path, secure, strings.trim_space(host) != ""
	}

	host = host_port[:colon]
	port_s := host_port[colon + 1:]
	port_i, port_ok := strconv.parse_int(port_s)
	if !port_ok do return "", 0, "", false, false

	return host, u16(port_i), path, secure, true
}
