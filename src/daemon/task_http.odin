package main

import "core:fmt"
import "core:net"
import "core:strings"

handle_task_create :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_create_task(Task_Create_Command{
		task_id                       = extract_json_string(body, "task_id", ""),
		chain_id                      = extract_json_string(body, "chain_id", ""),
		project_id                    = extract_json_string(body, "project_id", ""),
		standalone                    = extract_json_bool(body, "standalone", false),
		title                         = extract_json_string(body, "title", ""),
		description                   = extract_json_string(body, "description", ""),
		acceptance_criteria           = extract_json_string(body, "acceptance_criteria", ""),
		priority                      = extract_json_string(body, "priority", ""),
		status                        = extract_json_string(body, "status", ""),
		assignee_agent_instance_id    = extract_json_string(body, "assignee_agent_instance_id", ""),
		reviewer_agent_instance_id    = extract_json_string(body, "reviewer_agent_instance_id", ""),
		depends_on                    = extract_json_string(body, "depends_on", ""),
		created_by                    = author,
		author_agent_instance_id      = author,
	})
	write_task_service_response(client, result)
}

handle_task_chain_create :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_create_chain(Task_Chain_Create_Command{
		chain_id                           = extract_json_string(body, "chain_id", ""),
		project_id                         = extract_json_string(body, "project_id", ""),
		title                              = extract_json_string(body, "title", ""),
		description                        = extract_json_string(body, "description", ""),
		coordinator_agent_instance_id      = extract_json_string(body, "coordinator_agent_instance_id", ""),
		default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""),
		author_agent_instance_id           = author,
	})
	write_task_service_response(client, result)
}

handle_task_chain_activate :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_activate_chain(Task_Chain_Activate_Command{
		chain_id                 = extract_json_string(body, "chain_id", ""),
		author_agent_instance_id = author,
	})
	write_task_service_response(client, result)
}

handle_task_comment :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_comment(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "body", ""), author)
	write_task_service_response(client, result)
}

handle_task_comment_resolve :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_comment_resolve(Task_Comment_Resolve_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
		comment_id               = extract_json_string(body, "comment_id", ""),
		author_agent_instance_id = author,
	})
	write_task_service_response(client, result)
}

handle_task_comments :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body)
	if !ok do return
	task_id       := extract_json_string(body, "task_id", "")
	unresolved_only := extract_json_bool(body, "unresolved_only", false)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"comments":[`)
	first := true
	for i in 0..<task_comment_count {
		c := task_comments[i]
		if c.task_id != task_id do continue
		if unresolved_only && c.resolved do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, `{"comment_id":"`);              json_write_string(&b, c.comment_id)
		strings.write_string(&b, `","body":"`);                   json_write_string(&b, c.body)
		strings.write_string(&b, `","author_agent_instance_id":"`); json_write_string(&b, c.author_agent_instance_id)
		strings.write_string(&b, `","resolved":`);                strings.write_string(&b, "true" if c.resolved else "false")
		strings.write_string(&b, `,"created_unix_ms":`);          strings.write_string(&b, fmt.tprintf("%d", c.created_unix_ms))
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
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

handle_task_participant_remove :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_remove_participant(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "agent_instance_id", ""), extract_json_string(body, "role", ""), author)
	write_task_service_response(client, result)
}

handle_task_status :: proc(client: net.TCP_Socket, body: string) {
	author, is_user, ok := task_author_and_type_from_body(client, body)
	if !ok do return
	if !is_user {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"manual status changes restricted to user tokens"}`)
		return
	}
	result := task_service_set_status(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "status", ""), extract_json_string(body, "body", ""), author)
	write_task_service_response(client, result)
}

handle_task_done :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_set_status(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), "review_ready", extract_json_string(body, "body", "Done."), author)
	write_task_service_response(client, result)
}

handle_task_blocked :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_set_status(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), "blocked", extract_json_string(body, "body", "Blocked."), author)
	write_task_service_response(client, result)
}

handle_task_later :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_set_status(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), "ready", extract_json_string(body, "body", "Later/Deferred."), author)
	write_task_service_response(client, result)
}

handle_task_review_vote :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result_str := extract_json_string(body, "result", "")
	approved   := result_str == "lgtm" || result_str == "approved" || result_str == "true"
	result := task_service_review_vote(Task_Review_Vote_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
		approved                 = approved,
		comment                  = extract_json_string(body, "comment", ""),
		author_agent_instance_id = author,
	})
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
	result := task_service_update_chain(Task_Chain_Update_Command{
		chain_id                      = extract_json_string(body, "chain_id", ""),
		title                         = extract_json_string(body, "title", ""),
		description                   = extract_json_string(body, "description", ""),
		coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""),
		final_summary                 = extract_json_string(body, "final_summary", ""),
		author_agent_instance_id      = author,
	})
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
	summary  := extract_json_string(body, "summary", extract_json_string(body, "final_summary", ""))
	result   := task_service_complete_chain(chain_id, summary, author)
	write_task_service_response(client, result)
}

handle_task_chain_evaluate :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	chain_id   := extract_json_string(body, "chain_id", "")
	evaluation := extract_json_string(body, "evaluation", "")
	result     := task_service_evaluate_chain(chain_id, evaluation, author)
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
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"task":`)
	task_write_state_json(&b, state)
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_task_show :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body)
	if !ok do return
	task_id := extract_json_string(body, "task_id", "")
	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id {
			b := strings.builder_make()
			strings.write_string(&b, `{"ok":true,"task":`)
			task_write_state_json(&b, task_states[i])
			strings.write_string(&b, `}`)
			write_response(client, 200, "OK", strings.to_string(b))
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
			b := strings.builder_make()
			strings.write_string(&b, `{"ok":true,"chain":`)
			task_write_chain_json(&b, task_chains[i])
			strings.write_string(&b, `}`)
			write_response(client, 200, "OK", strings.to_string(b))
			return
		}
	}
	write_response(client, 404, "Not Found", `{"ok":false,"message":"chain not found"}`)
}

task_author_from_body :: proc(client: net.TCP_Socket, body: string) -> (string, bool) {
	token := extract_json_string(body, "agent_token", "")
	itype, iid := auth_db_get_identity(token)
	if itype == "" || iid == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`)
		return "", false
	}
	return iid, true
}

task_author_and_type_from_body :: proc(client: net.TCP_Socket, body: string) -> (id: string, is_user: bool, ok: bool) {
	token := extract_json_string(body, "agent_token", "")
	itype, iid := auth_db_get_identity(token)
	if itype == "" || iid == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`)
		return "", false, false
	}
	return iid, itype == "user", true
}

write_task_service_response :: proc(client: net.TCP_Socket, result: Task_Service_Result) {
	status_text := "OK"
	if result.status_code == 400 do status_text = "Bad Request"
	if result.status_code == 401 do status_text = "Unauthorized"
	if result.status_code == 403 do status_text = "Forbidden"
	if result.status_code == 404 do status_text = "Not Found"
	if result.status_code == 409 do status_text = "Conflict"
	if result.status_code == 500 do status_text = "Internal Server Error"
	write_response(client, result.status_code, status_text, result.message)
}

task_store_state_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"task_count":`)
	strings.write_string(&b, fmt.tprintf("%d", task_state_count))
	strings.write_string(&b, `,"chain_count":`)
	strings.write_string(&b, fmt.tprintf("%d", task_chain_count))
	strings.write_string(&b, `,"event_count":`)
	strings.write_string(&b, fmt.tprintf("%d", task_event_count))
	strings.write_string(&b, `,"tasks":[`)
	for i in 0..<task_state_count {
		if i > 0 do strings.write_string(&b, `,`)
		task_write_state_json(&b, task_states[i])
	}
	strings.write_string(&b, `],"participants":[`)
	for i in 0..<task_participant_count {
		if i > 0 do strings.write_string(&b, `,`)
		p := task_participants[i]
		strings.write_string(&b, `{"task_id":"`);           json_write_string(&b, p.task_id)
		strings.write_string(&b, `","chain_id":"`);         json_write_string(&b, p.chain_id)
		strings.write_string(&b, `","agent_instance_id":"`); json_write_string(&b, p.agent_instance_id)
		strings.write_string(&b, `","role":"`);              json_write_string(&b, p.role)
		strings.write_string(&b, `"}`)
	}
	strings.write_string(&b, `],"chains":[`)
	for i in 0..<task_chain_count {
		if i > 0 do strings.write_string(&b, `,`)
		task_write_chain_json(&b, task_chains[i])
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// task_claim_next_for_agent finds the best ready task for an agent and returns it.
// The task will already be in in_progress via auto-claim from task_recompute_promotions,
// but this provides a direct "give me my next task" endpoint.
task_claim_next_for_agent :: proc(agent_instance_id: string) -> (Task_State, bool) {
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != .In_Progress do continue
		if state.assignee_agent_instance_id != agent_instance_id do continue
		return state, true
	}
	// Also check ready (may not have been auto-claimed yet)
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != .Ready do continue
		if state.assignee_agent_instance_id != "" && state.assignee_agent_instance_id != agent_instance_id do continue
		if !task_dependencies_satisfied(state.depends_on) do continue
		if task_active_slot_blocker(agent_instance_id, state.task_id) != "" do continue
		task_service_auto_claim(state.task_id)
		return task_states[task_state_index(state.task_id, state.chain_id)], true
	}
	return Task_State{}, false
}
