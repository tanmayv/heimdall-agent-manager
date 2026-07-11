package main

import "core:net"

handle_memory_propose :: proc(client: net.TCP_Socket, body, action: string) {
	author, ok := memory_author_from_body(client, body)
	if !ok do return
	write_memory_service_response(client, memory_service_propose(action, body, author))
}

handle_memory_decide :: proc(client: net.TCP_Socket, body: string) {
	author, ok := memory_author_from_body(client, body)
	if !ok do return
	write_memory_service_response(client, memory_service_decide(extract_json_string(body, "decision", extract_json_string(body, "result", "")), body, author))
}

handle_memory_list :: proc(client: net.TCP_Socket, body: string) {
	_, ok := memory_author_from_body(client, body)
	if !ok do return
	write_response(client, 200, "OK", memory_service_list_json(body))
}

handle_memory_show :: proc(client: net.TCP_Socket, body: string) {
	_, ok := memory_author_from_body(client, body)
	if !ok do return
	out := memory_service_show_json(body)
	if extract_json_string(out, "message", "") == "memory not found" { write_response(client, 404, "Not Found", out); return }
	write_response(client, 200, "OK", out)
}

handle_memory_history :: proc(client: net.TCP_Socket, body: string) {
	_, ok := memory_author_from_body(client, body)
	if !ok do return
	write_response(client, 200, "OK", memory_service_history_json(body))
}

memory_author_from_body :: proc(client: net.TCP_Socket, body: string) -> (string, bool) {
	if token := extract_json_string(body, "agent_token", ""); token != "" {
		author := registry_agent_instance_for_token(token)
		if author == "" { write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`); return "", false }
		return author, true
	}
	client_instance_id := extract_json_string(body, "client_instance_id", "")
	client_token := extract_json_string(body, "client_token", "")
	if client_instance_id != "" || client_token != "" {
		user_id := user_client_user_for_token(client_instance_id, client_token)
		if user_id == "" { write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid client token"}`); return "", false }
		return user_id, true
	}
	write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`)
	return "", false
}

write_memory_service_response :: proc(client: net.TCP_Socket, result: Memory_Service_Result) {
	status_text := "OK"
	if result.status_code == 400 do status_text = "Bad Request"
	if result.status_code == 401 do status_text = "Unauthorized"
	if result.status_code == 404 do status_text = "Not Found"
	if result.status_code == 409 do status_text = "Conflict"
	if result.status_code == 500 do status_text = "Internal Server Error"
	write_response(client, result.status_code, status_text, result.message)
}
