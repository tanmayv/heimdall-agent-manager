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
	agent_runtime_tracker_observe_ws_connected(agent_instance_id)
	task_notifications_flush_queue(agent_instance_id)
	agent_lifecycle_emit(agent_instance_id, "connected", "websocket_connected")
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
			if registry_clear_ws_if_socket(agent_instance_id, client) {
				agent_runtime_tracker_observe_disconnected(agent_instance_id, "websocket_closed")
				agent_lifecycle_emit(agent_instance_id, "disconnected", "websocket_closed")
			}
			fmt.println("ws disconnected", agent_instance_id)
			return
		}
		if n < 2 do continue

		opcode := buf[0] & 0x0f
		masked := (buf[1] & 0x80) != 0
		payload_len := int(buf[1] & 0x7f)

		offset := 2
		if payload_len == 126 {
			if n < 4 do continue
			payload_len = int(buf[2]) << 8 | int(buf[3])
			offset = 4
		} else if payload_len == 127 {
			continue
		}

		mask_key: [4]byte
		if masked {
			if n < offset + 4 do continue
			mask_key = {buf[offset], buf[offset+1], buf[offset+2], buf[offset+3]}
			offset += 4
			for i in 0..<payload_len {
				buf[offset + i] = buf[offset + i] ~ mask_key[i % 4]
			}
		}

		if offset + payload_len > n do continue

		if opcode == 0x1 && payload_len > 0 {
			text := string(buf[offset:offset+payload_len])
			ws_dispatch_agent_message(agent_instance_id, text)
		} else if opcode == 0x8 {
			if registry_clear_ws_if_socket(agent_instance_id, client) {
				agent_runtime_tracker_observe_disconnected(agent_instance_id, "ws_close_frame")
				agent_lifecycle_emit(agent_instance_id, "disconnected", "ws_close_frame")
			}
			fmt.println("ws close frame", agent_instance_id)
			return
		}
	}
}

ws_dispatch_agent_message :: proc(agent_instance_id: string, text: string) {
	msg_type := extract_json_string(text, "type", "")
	fmt.println("ws agent message", agent_instance_id, msg_type)
	if msg_type == "stop_done" {
		registry_update_startup(agent_instance_id, "stopped", "stop_done", "Agent stopped gracefully", "", "", "")
		registry_clear_ws(agent_instance_id)
		agent_runtime_tracker_observe_disconnected(agent_instance_id, "stop_done")
		agent_lifecycle_emit(agent_instance_id, "offline", "stop_done")
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
