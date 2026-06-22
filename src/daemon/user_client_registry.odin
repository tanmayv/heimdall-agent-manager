package main

import "core:math/rand"
import "core:net"
import "core:strings"

MAX_USER_CLIENTS :: 2048
USER_CLIENT_HEARTBEAT_FRESH_MS :: i64(15_000)

User_Client_Record :: struct {
	user_id: string,
	client_instance_id: string,
	client_token: string,
	connected: bool,
	last_seen_unix_ms: i64,
	has_ws: bool,
	ws_socket: net.TCP_Socket,
}

user_clients: [MAX_USER_CLIENTS]User_Client_Record
user_client_count: int

user_client_registry_init :: proc() {
	user_client_count = 0
}

user_client_register :: proc(user_id, client_instance_id, requested_token: string) -> (User_Client_Record, bool, string) {
	if !valid_user_id(user_id) do return User_Client_Record{}, false, "invalid user_id"
	if !valid_client_instance_id(client_instance_id) do return User_Client_Record{}, false, "invalid client_instance_id"
	token := requested_token
	if token == "" {
		// Try to recover token from persistent storage
		token = auth_db_get_token("user", user_id)
		if token == "" {
			// No stored token found, generate new one
			token = generate_client_token()
		}
		// Store the token (insert or replace)
		if !auth_db_store_token(token, "user", user_id, now_unix_ms()) {
			fmt.println("WARNING: failed to store user token for", user_id)
		}
	}
	if idx := user_client_find(client_instance_id); idx >= 0 {
		if user_clients[idx].user_id != user_id do return User_Client_Record{}, false, "client_instance_id belongs to another user"
		user_clients[idx].client_token = strings.clone(token)
		user_clients[idx].connected = true
		user_clients[idx].last_seen_unix_ms = now_unix_ms()
		return user_clients[idx], true, ""
	}
	if user_client_count >= MAX_USER_CLIENTS do return User_Client_Record{}, false, "too many user clients"
	record := User_Client_Record{user_id = strings.clone(user_id), client_instance_id = strings.clone(client_instance_id), client_token = strings.clone(token), connected = true, last_seen_unix_ms = now_unix_ms()}
	user_clients[user_client_count] = record
	user_client_count += 1
	return record, true, ""
}

user_client_heartbeat :: proc(client_instance_id, client_token: string) -> bool {
	if idx := user_client_find(client_instance_id); idx >= 0 && user_clients[idx].client_token == client_token {
		user_clients[idx].connected = true
		user_clients[idx].last_seen_unix_ms = now_unix_ms()
		// Update last_seen in persistent storage
		auth_db_update_last_seen(client_token, user_clients[idx].last_seen_unix_ms)
		return true
	}
	return false
}

user_client_user_for_token :: proc(client_instance_id, client_token: string) -> string {
	if idx := user_client_find(client_instance_id); idx >= 0 && user_clients[idx].client_token == client_token {
		return user_clients[idx].user_id
	}
	return ""
}

user_client_user_exists :: proc(user_id: string) -> bool {
	for i in 0..<user_client_count {
		if user_clients[i].user_id == user_id do return true
	}
	return false
}

user_client_has_ws :: proc(user_id: string) -> bool {
	for i in 0..<user_client_count {
		if user_clients[i].user_id == user_id && user_clients[i].has_ws do return true
	}
	return false
}

user_client_fanout_ws_text :: proc(user_id, text: string) -> int {
	sent := 0
	for i in 0..<user_client_count {
		client := &user_clients[i]
		if client.user_id != user_id || !client.has_ws do continue
		if ws_send_text(client.ws_socket, text) {
			sent += 1
		} else {
			client.has_ws = false
			client.connected = false
		}
	}
	return sent
}

user_client_fanout_all_ws_text :: proc(text: string) -> int {
	sent := 0
	for i in 0..<user_client_count {
		client := &user_clients[i]
		if !client.has_ws do continue
		if ws_send_text(client.ws_socket, text) {
			sent += 1
		} else {
			client.has_ws = false
			client.connected = false
		}
	}
	return sent
}

user_client_set_ws :: proc(client_instance_id, client_token: string, socket: net.TCP_Socket) -> bool {
	if idx := user_client_find(client_instance_id); idx >= 0 && user_clients[idx].client_token == client_token {
		user_clients[idx].has_ws = true
		user_clients[idx].connected = true
		user_clients[idx].last_seen_unix_ms = now_unix_ms()
		user_clients[idx].ws_socket = socket
		return true
	}
	return false
}

user_client_clear_ws :: proc(client_instance_id: string) {
	if idx := user_client_find(client_instance_id); idx >= 0 {
		user_clients[idx].has_ws = false
		user_clients[idx].connected = false
		user_clients[idx].last_seen_unix_ms = now_unix_ms()
	}
}

user_client_find :: proc(client_instance_id: string) -> int {
	for i in 0..<user_client_count {
		if user_clients[i].client_instance_id == client_instance_id do return i
	}
	return -1
}

user_presence_connected :: proc(user_id: string) -> bool {
	now := now_unix_ms()
	for i in 0..<user_client_count {
		client := user_clients[i]
		if client.user_id == user_id && client.connected && now - client.last_seen_unix_ms < USER_CLIENT_HEARTBEAT_FRESH_MS do return true
	}
	return false
}

user_presence_json :: proc() -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"users":[`)
	first := true
	for i in 0..<user_client_count {
		user_id := user_clients[i].user_id
		seen := false
		for j in 0..<i {
			if user_clients[j].user_id == user_id { seen = true; break }
		}
		if seen do continue
		if !first do strings.write_string(&builder, `,`)
		first = false
		strings.write_string(&builder, `{"user_id":"`); json_write_string(&builder, user_id)
		strings.write_string(&builder, `","connected":`); strings.write_string(&builder, "true" if user_presence_connected(user_id) else "false")
		strings.write_string(&builder, `}`)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

generate_client_token :: proc() -> string {
	bytes: [32]byte
	if rand.read(bytes[:]) != len(bytes) {
		now := u64(now_unix_ms())
		for i in 0..<len(bytes) {
			bytes[i] = byte((now >> uint((i % 8) * 8)) & 0xff)
		}
	}
	builder := strings.builder_make()
	strings.write_string(&builder, "uct_")
	for b in bytes do hex_write_byte(&builder, b)
	return strings.to_string(builder)
}

valid_user_id :: proc(value: string) -> bool {
	if len(value) == 0 do return false
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '.', '@': continue
		case: return false
		}
	}
	return true
}

valid_client_instance_id :: proc(value: string) -> bool {
	return valid_user_id(value)
}

user_client_register_response_json :: proc(record: User_Client_Record) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"user_id":"`); json_write_string(&builder, record.user_id)
	strings.write_string(&builder, `","client_instance_id":"`); json_write_string(&builder, record.client_instance_id)
	strings.write_string(&builder, `","client_token":"`); json_write_string(&builder, record.client_token)
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}

user_client_error_json :: proc(message: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":false,"message":"`)
	json_write_string(&builder, message)
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}
