package main

import "core:fmt"
import "core:net"
import "core:strings"

handle_task_create :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_create_task(Task_Create_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), standalone = extract_json_bool(body, "standalone", false), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), acceptance_criteria = extract_json_string(body, "acceptance_criteria", ""), priority = extract_json_string(body, "priority", ""), status = extract_json_string(body, "status", ""), assignee_agent_instance_id = extract_json_string(body, "assignee_agent_instance_id", ""), reviewer_agent_instance_id = extract_json_string(body, "reviewer_agent_instance_id", ""), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), depends_on = extract_json_string(body, "depends_on", ""), created_by = author, author_agent_instance_id = author})
	write_task_service_response(client, result)
}

handle_task_chain_create :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_create_chain(Task_Chain_Create_Command{chain_id = extract_json_string(body, "chain_id", ""), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), status = extract_json_string(body, "status", ""), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""), author_agent_instance_id = author})
	write_task_service_response(client, result)
}

handle_task_comment :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_comment(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "body", ""), author)
	write_task_service_response(client, result)
}

handle_task_assign :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_assign(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "agent_instance_id", ""), author)
	write_task_service_response(client, result)
}

handle_task_participant :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_add_participant(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "agent_instance_id", ""), extract_json_string(body, "role", ""), author)
	write_task_service_response(client, result)
}

handle_task_status :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_set_status(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "status", ""), extract_json_string(body, "body", ""), author)
	write_task_service_response(client, result)
}

handle_task_review :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_review(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "result", ""), extract_json_string(body, "comment", ""), author)
	write_task_service_response(client, result)
}

handle_task_nudge :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_nudge(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "body", ""), author)
	write_task_service_response(client, result)
}

handle_task_chain_update :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_update_chain(Task_Chain_Update_Command{chain_id = extract_json_string(body, "chain_id", ""), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""), final_summary = extract_json_string(body, "final_summary", ""), author_agent_instance_id = author})
	write_task_service_response(client, result)
}

handle_task_chain_status :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_set_chain_status(extract_json_string(body, "chain_id", ""), extract_json_string(body, "status", ""), extract_json_string(body, "final_summary", ""), author)
	write_task_service_response(client, result)
}

handle_task_chain_complete :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
	summary := extract_json_string(body, "summary", extract_json_string(body, "final_summary", ""))
	result := task_service_complete_chain(chain_id, summary, author)
	write_task_service_response(client, result)
}

handle_task_archive_retry :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body)
	if !ok do return
	write_task_service_response(client, task_service_retry_pending_archives())
}

handle_task_list :: proc(client: net.TCP_Socket) {
	write_response(client, 200, "OK", task_store_state_json())
}

handle_task_list_authed :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body)
	if !ok do return
	write_response(client, 200, "OK", task_store_state_json())
}

handle_task_next :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	task_recompute_promotions(author)
	state, found := task_claim_next_for_agent(author)
	if !found {
		write_response(client, 200, "OK", `{"ok":true,"task":null}`)
		return
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"task":`)
	task_write_state_json(&builder, state)
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_task_show :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body)
	if !ok do return
	task_id := extract_json_string(body, "task_id", "")
	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id {
			builder := strings.builder_make()
			strings.write_string(&builder, `{"ok":true,"task":`)
			task_write_state_json(&builder, task_states[i])
			strings.write_string(&builder, `}`)
			write_response(client, 200, "OK", strings.to_string(builder))
			return
		}
	}
	write_response(client, 404, "Not Found", `{"ok":false,"message":"task not found"}`)
}

handle_task_log :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body)
	if !ok do return
	write_response(client, 200, "OK", task_log_json(extract_json_string(body, "task_id", "")))
}

handle_task_chain_show :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body)
	if !ok do return
	chain_id := extract_json_string(body, "chain_id", "")
	for i in 0..<task_chain_count {
		if task_chains[i].chain_id == chain_id {
			builder := strings.builder_make()
			strings.write_string(&builder, `{"ok":true,"chain":`)
			task_write_chain_json(&builder, task_chains[i])
			strings.write_string(&builder, `}`)
			write_response(client, 200, "OK", strings.to_string(builder))
			return
		}
	}
	write_response(client, 404, "Not Found", `{"ok":false,"message":"chain not found"}`)
}

task_author_from_body :: proc(client: net.TCP_Socket, body: string) -> (string, bool) {
	token := extract_json_string(body, "agent_token", "")
	author := registry_agent_instance_for_token(token)
	if author == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`)
		return "", false
	}
	return author, true
}

write_task_service_response :: proc(client: net.TCP_Socket, result: Task_Service_Result) {
	status_text := "OK"
	if result.status_code == 400 do status_text = "Bad Request"
	if result.status_code == 401 do status_text = "Unauthorized"
	if result.status_code == 404 do status_text = "Not Found"
	if result.status_code == 409 do status_text = "Conflict"
	if result.status_code == 500 do status_text = "Internal Server Error"
	write_response(client, result.status_code, status_text, result.message)
}

task_store_state_json :: proc() -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"task_count":`)
	strings.write_string(&builder, fmt.tprintf("%d", task_state_count))
	strings.write_string(&builder, `,"chain_count":`)
	strings.write_string(&builder, fmt.tprintf("%d", task_chain_count))
	strings.write_string(&builder, `,"event_count":`)
	strings.write_string(&builder, fmt.tprintf("%d", task_event_count))
	strings.write_string(&builder, `,"tasks":[`)
	for i in 0..<task_state_count {
		if i > 0 do strings.write_string(&builder, `,`)
		state := task_states[i]
		strings.write_string(&builder, `{"task_id":"`); json_write_string(&builder, state.task_id)
		strings.write_string(&builder, `","chain_id":"`); json_write_string(&builder, state.chain_id)
		strings.write_string(&builder, `","title":"`); json_write_string(&builder, state.title)
		strings.write_string(&builder, `","description":"`); json_write_string(&builder, state.description)
		strings.write_string(&builder, `","acceptance_criteria":"`); json_write_string(&builder, state.acceptance_criteria)
		strings.write_string(&builder, `","priority":"`); json_write_string(&builder, state.priority)
		strings.write_string(&builder, `","status":"`); json_write_string(&builder, state.status)
		strings.write_string(&builder, `","assignee_agent_instance_id":"`); json_write_string(&builder, state.assignee_agent_instance_id)
		strings.write_string(&builder, `","reviewer_agent_instance_id":"`); json_write_string(&builder, state.reviewer_agent_instance_id)
		strings.write_string(&builder, `","coordinator_agent_instance_id":"`); json_write_string(&builder, state.coordinator_agent_instance_id)
		strings.write_string(&builder, `","depends_on":"`); json_write_string(&builder, state.depends_on)
		strings.write_string(&builder, `","created_by":"`); json_write_string(&builder, state.created_by)
		strings.write_string(&builder, `","created_at_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", state.created_at_unix_ms))
		strings.write_string(&builder, `,"updated_at_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", state.updated_at_unix_ms))
		strings.write_string(&builder, `}`)
	}
	strings.write_string(&builder, `],"participants":[`)
	for i in 0..<task_participant_count {
		if i > 0 do strings.write_string(&builder, `,`)
		p := task_participants[i]
		strings.write_string(&builder, `{"task_id":"`); json_write_string(&builder, p.task_id)
		strings.write_string(&builder, `","chain_id":"`); json_write_string(&builder, p.chain_id)
		strings.write_string(&builder, `","agent_instance_id":"`); json_write_string(&builder, p.agent_instance_id)
		strings.write_string(&builder, `","role":"`); json_write_string(&builder, p.role)
		strings.write_string(&builder, `"}`)
	}
	strings.write_string(&builder, `],"chains":[`)
	for i in 0..<task_chain_count {
		if i > 0 do strings.write_string(&builder, `,`)
		chain := task_chains[i]
		strings.write_string(&builder, `{"chain_id":"`); json_write_string(&builder, chain.chain_id)
		strings.write_string(&builder, `","title":"`); json_write_string(&builder, chain.title)
		strings.write_string(&builder, `","description":"`); json_write_string(&builder, chain.description)
		strings.write_string(&builder, `","status":"`); json_write_string(&builder, chain.status)
		strings.write_string(&builder, `","coordinator_agent_instance_id":"`); json_write_string(&builder, chain.coordinator_agent_instance_id)
		strings.write_string(&builder, `","default_reviewer_agent_instance_id":"`); json_write_string(&builder, chain.default_reviewer_agent_instance_id)
		strings.write_string(&builder, `","final_summary":"`); json_write_string(&builder, chain.final_summary)
		strings.write_string(&builder, `","created_at_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", chain.created_at_unix_ms))
		strings.write_string(&builder, `,"completed_at_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", chain.completed_at_unix_ms))
		strings.write_string(&builder, `,"archive_pending":`); strings.write_string(&builder, "true" if chain.archive_pending else "false")
		strings.write_string(&builder, `,"archived":`); strings.write_string(&builder, "true" if chain.archived else "false")
		strings.write_string(&builder, `}`)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}
