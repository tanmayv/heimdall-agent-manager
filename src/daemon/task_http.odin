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
	description := extract_json_string(body, "description", "")
	if description == "" do description = extract_json_string(body, "goal", "")
	result := task_service_create_chain(Task_Chain_Create_Command{
		chain_id                           = extract_json_string(body, "chain_id", ""),
		project_id                         = extract_json_string(body, "project_id", ""),
		kind                               = extract_json_string(body, "kind", ""),
		title                              = extract_json_string(body, "title", ""),
		description                        = description,
		scaffold                           = extract_json_string(body, "scaffold", ""),
		no_scaffold                        = extract_json_bool(body, "no_scaffold", false),
		coordinator_agent_instance_id      = extract_json_string(body, "coordinator_agent_instance_id", ""),
		default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""),
		wants_vcs                          = extract_json_bool(body, "wants_vcs", true),
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
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	comment_body := extract_json_string(body, "body", "")
	artifact_content_base64 := extract_json_string(body, "artifact_content_base64", "")
	created_artifact := Artifact_Record{}
	if strings.trim_space(artifact_content_base64) != "" {
		state, found := store_get_task_in_chain(task_id, chain_id)
		if !found {
			write_response(client, 404, "Not Found", `{"ok":false,"message":"task not found"}`)
			return
		}
		resolved_chain_id := state.chain_id
		project_id := ""
		if chain, chain_found := store_get_chain(resolved_chain_id); chain_found {
			project_id = chain.project_id
		}
		artifact_result := artifact_create_record(author, false, extract_json_string(body, "artifact_name", ""), extract_json_string(body, "artifact_kind", ""), "", project_id, "comment", task_id, "", artifact_content_base64)
		if !artifact_result.ok {
			artifact_write_error(client, artifact_result.status, artifact_result.status_text, artifact_result.error_kind, artifact_result.message)
			return
		}
		created_artifact = artifact_result.rec
		comment_body = artifact_append_link_body(comment_body, created_artifact.artifact_id)
		if chain_id == "" do chain_id = resolved_chain_id
	}
	result := task_service_comment(task_id, chain_id, comment_body, author)
	if !result.ok && created_artifact.artifact_id != "" do artifact_cleanup_failed_inline_attach(created_artifact)
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
	comments := store_comments_of(task_id)
	defer delete(comments)
	for c in comments {
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
	force := extract_json_bool(body, "force", false)
	if !is_user && !force {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"manual status changes restricted to user tokens unless force is used by coordinator"}`)
		return
	}
	result := task_service_status_command(Task_Status_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), status = extract_json_string(body, "status", ""), body = extract_json_string(body, "body", ""), force = force, author_agent_instance_id = author})
	write_task_service_response(client, result)
}

handle_task_update :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_update_task(Task_Update_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
		title                    = extract_json_string(body, "title", ""),
		description              = extract_json_string(body, "description", ""),
		description_present      = json_has_key(body, "description"),
		author_agent_instance_id = author,
	})
	write_task_service_response(client, result)
}

handle_task_done :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	force := extract_json_bool(body, "force", false)
	status := "review_ready"
	if force do status = "approved"
	result := task_service_status_command(Task_Status_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), status = status, body = extract_json_string(body, "body", "Done."), force = force, author_agent_instance_id = author})
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
	reason := extract_json_string(body, "body", "Later/Deferred.")
	result := task_service_set_status(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), "queued", strings.concatenate({"system_auto:manual_unblocked:", reason}), author)
	write_task_service_response(client, result)
}

handle_task_review_vote :: proc(client: net.TCP_Socket, body: string) {
	author, is_user, ok := task_author_and_type_from_body(client, body)
	if !ok do return
	result_str := extract_json_string(body, "result", "")
	approved   := result_str == "lgtm" || result_str == "approved" || result_str == "true"
	result := task_service_review_vote(Task_Review_Vote_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
		approved                 = approved,
		comment                  = extract_json_string(body, "comment", ""),
		author_agent_instance_id = author,
		author_is_user           = is_user,
	})
	write_task_service_response(client, result)
}

handle_task_nudge :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	nudge_body := extract_json_string(body, "body", "")
	interrupt := extract_json_bool(body, "interrupt", false)

	result := task_service_nudge(task_id, chain_id, nudge_body, author, interrupt)
	write_task_service_response(client, result)
}

handle_task_chain_update :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_update_chain(Task_Chain_Update_Command{
		chain_id                           = extract_json_string(body, "chain_id", ""),
		title                              = extract_json_string(body, "title", ""),
		description                        = extract_json_string(body, "description", ""),
		coordinator_agent_instance_id      = extract_json_string(body, "coordinator_agent_instance_id", ""),
		default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""),
		final_summary                      = extract_json_string(body, "final_summary", ""),
		author_agent_instance_id           = author,
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
	_ = agent_store_set_current_task(author, state.task_id)
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
	if state, found := store_get_task(task_id); found {
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":true,"task":`)
		task_write_state_json(&b, state)
		strings.write_string(&b, `}`)
		write_response(client, 200, "OK", strings.to_string(b))
		return
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
	chain, found := store_get_chain(chain_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"chain not found"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"chain":`)
	task_write_chain_json(&b, chain)
	strings.write_string(&b, `,"events":[`)
	first := true
	for event in store_all_events() {
		if event.chain_id != chain_id || event.task_id != "" do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, task_event_json(event))
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
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
	strings.write_string(&b, fmt.tprintf("%d", store_task_count()))
	strings.write_string(&b, `,"chain_count":`)
	strings.write_string(&b, fmt.tprintf("%d", store_chain_count()))
	strings.write_string(&b, `,"event_count":`)
	strings.write_string(&b, fmt.tprintf("%d", store_event_count()))
	strings.write_string(&b, `,"tasks":[`)
	for state, i in store_all_tasks() {
		if i > 0 do strings.write_string(&b, `,`)
		task_write_state_json(&b, state)
	}
	strings.write_string(&b, `],"participants":[`)
	for p, i in store_all_participants() {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"task_id":"`);           json_write_string(&b, p.task_id)
		strings.write_string(&b, `","chain_id":"`);         json_write_string(&b, p.chain_id)
		strings.write_string(&b, `","agent_instance_id":"`); json_write_string(&b, p.agent_instance_id)
		strings.write_string(&b, `","role":"`);              json_write_string(&b, p.role)
		strings.write_string(&b, `"}`)
	}
	strings.write_string(&b, `],"chains":[`)
	for chain, i in store_all_chains() {
		if i > 0 do strings.write_string(&b, `,`)
		task_write_chain_json(&b, chain)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// task_claim_next_for_agent finds the best ready task for an agent and returns it.
// The task will already be in in_progress via auto-claim from task_recompute_promotions,
// but this provides a direct "give me my next task" endpoint.
task_claim_next_for_agent :: proc(agent_instance_id: string) -> (Task_State, bool) {
	for state in store_all_tasks() {
		if state.status != .In_Progress do continue
		if state.assignee_agent_instance_id != agent_instance_id do continue
		return state, true
	}
	// Also check ready (may not have been auto-claimed yet)
	for state in store_all_tasks() {
		if state.status != .Queued do continue
		if !task_chain_allows_execution(state.chain_id) do continue
		if state.assignee_agent_instance_id != "" && state.assignee_agent_instance_id != agent_instance_id do continue
		if !task_dependencies_satisfied(state.depends_on) do continue
		if task_active_slot_blocker(agent_instance_id, state.task_id) != "" do continue
		event := Task_Event{
			kind                     = .Task_Status_Changed,
			task_id                  = state.task_id,
			chain_id                 = state.chain_id,
			status                   = "in_progress",
			body                     = "system_auto:auto_claimed",
			author_agent_instance_id = "system-auto-claim",
		}
		if task_store_append_event(event) {
			_ = agent_store_set_current_task(agent_instance_id, state.task_id)
			task_notify_event(event)
		}
		if updated, found := store_get_task_in_chain(state.task_id, state.chain_id); found do return updated, true
		return state, true
	}
	return Task_State{}, false
}
