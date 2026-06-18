package ws

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

WS_KEY :: "dGhlIHNhbXBsZSBub25jZQ=="

Connection :: struct {
	socket: net.TCP_Socket,
	connected: bool,
}

connect :: proc(ws_url: string) -> (Connection, bool) {
	host, port, path, ok := parse_ws_url(ws_url)
	if !ok do return {}, false

	socket, err := net.dial_tcp_from_hostname_with_port_override(host, int(port))
	if err != nil do return {}, false

	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		path,
		host,
		port,
		WS_KEY,
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
	return Connection{socket = socket, connected = true}, true
}

close :: proc(conn: ^Connection) {
	if conn.connected {
		net.close(conn.socket)
		conn.connected = false
	}
}

poll_text :: proc(conn: ^Connection) -> (text: string, ok: bool) {
	if !conn.connected do return "", false

	buf: [4096]byte
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
	if n < 2 do return "", false

	opcode := buf[0] & 0x0f
	payload_len := int(buf[1] & 0x7f)
	header_len := 2
	if payload_len == 126 {
		if n < 4 do return "", false
		payload_len = int(buf[2]) << 8 | int(buf[3])
		header_len = 4
	}
	if opcode == 0x8 {
		conn.connected = false
		return "", false
	}
	if opcode != 0x1 do return "", false
	if payload_len > n - header_len do return "", false

	return string(buf[header_len:header_len + payload_len]), true
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
