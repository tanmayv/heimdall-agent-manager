package main

import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"

handle_ws :: proc(client: net.TCP_Socket, request: string) {
	agent_instance_id := ws_agent_instance_id(request)
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`)
		return
	}
	if !registry_agent_exists(agent_instance_id) {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown agent instance"}`)
		return
	}

	key := extract_header(request, "Sec-WebSocket-Key")
	if key == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"missing websocket key"}`)
		return
	}

	write_ws_upgrade(client, ws_accept_key(key))
	registry_set_ws(agent_instance_id, client)
	fmt.println("ws connected", agent_instance_id)
	ws_read_loop(strings.clone(agent_instance_id), client)
}

ws_agent_instance_id :: proc(request: string) -> string {
	prefix := "GET /ws/"
	start := len(prefix)
	end := strings.index_byte(request[start:], ' ')
	if end < 0 do return ""
	return request[start:start + end]
}

ws_accept_key :: proc(key: string) -> string {
	GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	combined := fmt.tprintf("%s%s", key, GUID)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:])
}

ws_read_loop :: proc(agent_instance_id: string, client: net.TCP_Socket) {
	buf: [4096]byte
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n == 0 {
			registry_clear_ws(agent_instance_id)
			fmt.println("ws disconnected", agent_instance_id)
			return
		}
		fmt.println("ws received", agent_instance_id, n, "bytes")
	}
}

write_ws_upgrade :: proc(client: net.TCP_Socket, accept_key: string) {
	response := fmt.tprintf(
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		accept_key,
	)
	net.send_tcp(client, transmute([]byte)response)
}

ws_send_text :: proc(socket: net.TCP_Socket, text: string) -> bool {
	if len(text) > 4090 do return false

	frame: [4096]byte
	frame[0] = 0x81
	header_len := 2
	if len(text) <= 125 {
		frame[1] = byte(len(text))
	} else {
		frame[1] = 126
		frame[2] = byte((len(text) >> 8) & 0xff)
		frame[3] = byte(len(text) & 0xff)
		header_len = 4
	}
	copy(frame[header_len:], transmute([]byte)text)
	_, err := net.send_tcp(socket, frame[:header_len + len(text)])
	return err == nil
}
