package ws

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

WS_KEY :: "dGhlIHNhbXBsZSBub25jZQ=="

Connection :: struct {
	socket: net.TCP_Socket,
	connected: bool,
	pending_texts: [dynamic]string,
	pending_bytes: [dynamic]byte,
}

connect :: proc(ws_url: string) -> (Connection, bool) {
	return connect_with_bearer(ws_url, "")
}

connect_with_bearer :: proc(ws_url, bearer_token: string) -> (Connection, bool) {
	host, port, path, ok := parse_ws_url(ws_url)
	if !ok do return {}, false

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

	_ = net.set_blocking(socket, false)
	return Connection{socket = socket, connected = true, pending_texts = make([dynamic]string), pending_bytes = make([dynamic]byte)}, true
}

close :: proc(conn: ^Connection) {
	if conn.connected {
		net.close(conn.socket)
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
	n, err := net.recv_tcp(conn.socket, buf[:])
	if err != nil {
		if err == .Would_Block do return "", false
		conn.connected = false
		return "", false
	}
	if n == 0 {
		conn.connected = false
		return "", false
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
	_, err := net.send_tcp(conn.socket, frame)
	return err == nil
}

parse_ws_url :: proc(ws_url: string) -> (host: string, port: u16, path: string, ok: bool) {
	url := ws_url
	if strings.has_prefix(url, "ws://") {
		url = url[len("ws://"):]
	}

	slash := strings.index_byte(url, '/')
	if slash < 0 do return "", 0, "", false

	host_port := url[:slash]
	path = url[slash:]
	colon := strings.last_index_byte(host_port, ':')
	if colon < 0 do return "", 0, "", false

	host = host_port[:colon]
	port_s := host_port[colon + 1:]
	port_i, port_ok := strconv.parse_int(port_s)
	if !port_ok do return "", 0, "", false

	return host, u16(port_i), path, true
}
