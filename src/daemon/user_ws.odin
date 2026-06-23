package main

import "core:fmt"
import "core:net"
import "core:strings"

handle_user_ws :: proc(client: net.TCP_Socket, request: string) {
	client_instance_id := user_ws_client_instance_id(request)
	client_token := user_ws_client_token(request)
	if !valid_client_instance_id(client_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid client_instance_id"}`)
		return
	}
	if client_token == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"missing client token"}`)
		return
	}
	if user_client_find(client_instance_id) < 0 {
		itype, user_id := auth_db_get_identity(client_token)
		if itype == "user" && user_id != "" {
			_, ok, _ := user_client_register(user_id, client_instance_id, client_token)
			if !ok {
				write_response(client, 500, "Internal Error", `{"ok":false,"message":"failed to recover token registration"}`)
				return
			}
		} else {
			write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown user client"}`)
			return
		}
	}
	key := extract_header(request, "Sec-WebSocket-Key")
	if key == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"missing websocket key"}`)
		return
	}
	if !user_client_set_ws(client_instance_id, client_token, client) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid client token"}`)
		return
	}
	write_ws_upgrade(client, ws_accept_key(key))
	fmt.println("user-ws connected", client_instance_id)
	user_ws_read_loop(strings.clone(client_instance_id), client)
}

user_ws_client_instance_id :: proc(request: string) -> string {
	prefix := "GET /user-ws/"
	start := len(prefix)
	end := strings.index_byte(request[start:], ' ')
	if end < 0 do return ""
	path := request[start:start + end]
	if q := strings.index_byte(path, '?'); q >= 0 do return path[:q]
	return path
}

user_ws_client_token :: proc(request: string) -> string {
	prefix := "GET /user-ws/"
	start := len(prefix)
	end := strings.index_byte(request[start:], ' ')
	if end < 0 do return ""
	path := request[start:start + end]
	q := strings.index_byte(path, '?')
	if q < 0 do return ""
	query := path[q + 1:]
	key := "client_token="
	idx := strings.index(query, key)
	if idx < 0 do return ""
	value_start := idx + len(key)
	value_end := strings.index_byte(query[value_start:], '&')
	if value_end < 0 do return query[value_start:]
	return query[value_start:value_start + value_end]
}

user_ws_read_loop :: proc(client_instance_id: string, client: net.TCP_Socket) {
	buf: [4096]byte
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n == 0 {
			user_client_clear_ws(client_instance_id)
			fmt.println("user-ws disconnected", client_instance_id)
			return
		}
		fmt.println("user-ws received", client_instance_id, n, "bytes")
	}
}
