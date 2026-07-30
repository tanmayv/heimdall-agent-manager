package main

import "core:net"
import "core:strings"

handle_memory_propose :: proc(client: net.TCP_Socket, request, action: string) {
	body := request_body(request)
	author, ok := memory_author_from_request(client, request)
	if !ok do return
	write_memory_service_response(client, memory_service_propose(action, body, author))
}

handle_memory_decide :: proc(client: net.TCP_Socket, request: string) {
	body := request_body(request)
	author, ok := memory_author_from_request(client, request)
	if !ok do return
	write_memory_service_response(client, memory_service_decide(extract_json_string(body, "decision", extract_json_string(body, "result", "")), body, author))
}

handle_memory_list :: proc(client: net.TCP_Socket, request: string) {
	body := request_body(request)
	author, ok := memory_author_from_request(client, request)
	if !ok do return
	out := memory_service_list_json(body, author)
	if !extract_json_bool(out, "ok", false) { write_response(client, 400, "Bad Request", out); return }
	write_response(client, 200, "OK", out)
}

handle_memory_applicable :: proc(client: net.TCP_Socket, request: string) {
	body := request_body(request)
	author, ok := memory_author_from_request(client, request)
	if !ok do return
	write_memory_service_response(client, memory_service_applicable_json(body, author))
}

handle_memory_show :: proc(client: net.TCP_Socket, request: string) {
	body := request_body(request)
	_, ok := memory_author_from_request(client, request)
	if !ok do return
	out := memory_service_show_json(body)
	if extract_json_string(out, "message", "") == "memory not found" { write_response(client, 404, "Not Found", out); return }
	write_response(client, 200, "OK", out)
}

handle_memory_history :: proc(client: net.TCP_Socket, request: string) {
	body := request_body(request)
	_, ok := memory_author_from_request(client, request)
	if !ok do return
	write_response(client, 200, "OK", memory_service_history_json(body))
}

memory_author_from_request :: proc(client: net.TCP_Socket, request: string) -> (string, bool) {
	auth_header := extract_header(request, "Authorization")
	token := ""
	if strings.has_prefix(auth_header, "Bearer ") do token = strings.trim_space(auth_header[7:])
	else do token = strings.trim_space(auth_header)
	if token == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"missing bearer token"}`)
		return "", false
	}
	author := registry_agent_instance_for_token(token)
	if author == "" do author = user_client_id_for_token(token)
	if author == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid bearer token"}`)
		return "", false
	}
	return author, true
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
