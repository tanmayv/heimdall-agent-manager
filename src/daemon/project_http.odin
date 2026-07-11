package main

import "core:net"

handle_project_create :: proc(client: net.TCP_Socket, body: string) { author, ok := task_author_from_body(client, body); if !ok do return; write_project_service_response(client, project_create(body, author)) }
handle_project_update :: proc(client: net.TCP_Socket, body: string) { author, ok := task_author_from_body(client, body); if !ok do return; write_project_service_response(client, project_update(body, author)) }
handle_project_delete :: proc(client: net.TCP_Socket, body: string) { author, ok := task_author_from_body(client, body); if !ok do return; write_project_service_response(client, project_delete(body, author)) }
handle_project_list :: proc(client: net.TCP_Socket, body: string) { _, ok := task_author_from_body(client, body); if !ok do return; write_response(client, 200, "OK", project_list_json()) }
handle_project_show :: proc(client: net.TCP_Socket, body: string) { _, ok := task_author_from_body(client, body); if !ok do return; out, status := project_show_json(extract_json_string(body, "project_id", "")); if status == 404 { write_response(client, 404, "Not Found", out); return }; write_response(client, 200, "OK", out) }

write_project_service_response :: proc(client: net.TCP_Socket, result: Project_Service_Result) {
	status_text := "OK"; if result.status_code == 400 do status_text = "Bad Request"; if result.status_code == 401 do status_text = "Unauthorized"; if result.status_code == 404 do status_text = "Not Found"; if result.status_code == 500 do status_text = "Internal Server Error"
	write_response(client, result.status_code, status_text, result.message)
}
