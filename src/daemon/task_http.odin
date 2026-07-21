package main

import "core:fmt"
import "core:net"
import "core:strings"

write_remote_task_callback_response :: proc(client: net.TCP_Socket, work: Federation_Remote_Work_Record, payload, idempotency_key, kind, task_id: string) {
	_ = federation_delivery_outbox_insert_pending(work.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, payload)
	bridge_accepted := false
	_, dest_daemon_id, peer_status, found := federation_direct_peer_lookup(work.owner_peer_id, work.origin_daemon_id)
	if found && peer_status == PEER_STATUS_LINKED {
		bridge_accepted = dest_daemon_id != "" && bridge_send(dest_daemon_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
	}
	// Bridge accepted/queued is not destination durable delivery; the callback
	// outbox entry remains pending until delivery_ack arrives.
	_ = federation_delivery_outbox_mark_attempt(work.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, false)
	if federation_delivery_outbox_pending_exists(work.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key) {
		write_response(client, 202, "Accepted", federation_task_callback_pending_json(kind, task_id))
		return
	}
	write_response(client, 503, "Service Unavailable", `{"ok":false,"message":"failed to queue remote callback"}`)
}

write_remote_task_identity_ambiguous_response :: proc(client: net.TCP_Socket, task_id: string) {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"message":"ambiguous remote task identity; include origin_daemon_id with task_id","task_id":"`)
	json_write_string(&b, task_id)
	strings.write_string(&b, `"}`)
	write_response(client, 409, "Conflict", strings.to_string(b))
}

write_remote_chain_identity_ambiguous_response :: proc(client: net.TCP_Socket, chain_id: string) {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"message":"ambiguous remote chain identity; include origin_daemon_id with chain_id","chain_id":"`)
	json_write_string(&b, chain_id)
	strings.write_string(&b, `"}`)
	write_response(client, 409, "Conflict", strings.to_string(b))
}

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
	if json_has_key(body, "kind") || json_has_key(body, "scaffold") || json_has_key(body, "no_scaffold") {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"chain create no longer accepts kind/scaffold; use goal plus scaffold skills"}`)
		return
	}
	description := extract_json_string(body, "description", "")
	if description == "" do description = extract_json_string(body, "goal", "")
	extracted_status := extract_json_string(body, "status", "in_progress")
	result := task_service_create_chain(Task_Chain_Create_Command{
		chain_id                           = extract_json_string(body, "chain_id", ""),
		project_id                         = extract_json_string(body, "project_id", ""),
		title                              = extract_json_string(body, "title", ""),
		description                        = description,
		status                             = extracted_status,
		coordinator_agent_instance_id      = extract_json_string(body, "coordinator_agent_instance_id", ""),
		default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""),
		wants_vcs                          = extract_json_bool(body, "wants_vcs", false),
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
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		created_artifact := Artifact_Record{}
		if strings.trim_space(artifact_content_base64) != "" {
			artifact_result := artifact_create_record(author, false, extract_json_string(body, "artifact_name", ""), extract_json_string(body, "artifact_kind", ""), "", "", "comment", task_id, "", artifact_content_base64)
			if !artifact_result.ok {
				artifact_write_error(client, artifact_result.status, artifact_result.status_text, artifact_result.error_kind, artifact_result.message)
				return
			}
			created_artifact = artifact_result.rec
			comment_body = artifact_append_link_body(comment_body, created_artifact.artifact_id)
		}
		if chain_id == "" do chain_id = remote_work.chain_id
		idempotency_key := fmt.tprintf("task-comment:%s:%s:%d", task_id, author, router_now_unix_ms())
		payload := federation_task_comment_callback_json(remote_work, author, comment_body, idempotency_key, created_artifact)
		write_remote_task_callback_response(client, remote_work, payload, idempotency_key, FEDERATION_ENVELOPE_TASK_COMMENT, task_id)
		return
	}
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
	author, ok := task_author_from_body(client, body)
	if !ok do return
	task_id       := extract_json_string(body, "task_id", "")
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		resp, forwarded := federation_remote_task_comments_fetch_response(remote_work)
		federation_write_forwarded_response(client, resp, forwarded)
		return
	}
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
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	status_value := extract_json_string(body, "status", "")
	status_body := extract_json_string(body, "body", "")
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		if chain_id == "" do chain_id = remote_work.chain_id
		idempotency_key := fmt.tprintf("task-status:%s:%s:%s:%d", task_id, status_value, author, router_now_unix_ms())
		payload := federation_task_status_callback_json(remote_work, author, status_value, status_body, idempotency_key, force)
		write_remote_task_callback_response(client, remote_work, payload, idempotency_key, FEDERATION_ENVELOPE_TASK_STATUS, task_id)
		return
	}
	if !is_user && !force {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"manual status changes restricted to user tokens unless force is used by coordinator"}`)
		return
	}
	result := task_service_status_command(Task_Status_Command{task_id = task_id, chain_id = chain_id, status = status_value, body = status_body, force = force, author_agent_instance_id = author})
	write_task_service_response(client, result)
}

handle_task_update :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_update_task(Task_Update_Command{
		task_id                     = extract_json_string(body, "task_id", ""),
		chain_id                    = extract_json_string(body, "chain_id", ""),
		title                       = extract_json_string(body, "title", ""),
		description                 = extract_json_string(body, "description", ""),
		description_present         = json_has_key(body, "description"),
		acceptance_criteria         = extract_json_string(body, "acceptance_criteria", ""),
		acceptance_criteria_present = json_has_key(body, "acceptance_criteria"),
		depends_on                  = extract_json_string(body, "depends_on", ""),
		depends_on_present          = json_has_key(body, "depends_on"),
		author_agent_instance_id    = author,
	})
	write_task_service_response(client, result)
}

handle_task_delete :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	result := task_service_delete_task(Task_Delete_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
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
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	status_body := extract_json_string(body, "body", "Done.")
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		if chain_id == "" do chain_id = remote_work.chain_id
		idempotency_key := fmt.tprintf("task-status:%s:%s:%s:%d", task_id, status, author, router_now_unix_ms())
		payload := federation_task_status_callback_json(remote_work, author, status, status_body, idempotency_key, force)
		write_remote_task_callback_response(client, remote_work, payload, idempotency_key, FEDERATION_ENVELOPE_TASK_STATUS, task_id)
		return
	}
	result := task_service_status_command(Task_Status_Command{task_id = task_id, chain_id = chain_id, status = status, body = status_body, force = force, author_agent_instance_id = author})
	write_task_service_response(client, result)
}

handle_task_blocked :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	status_body := extract_json_string(body, "body", "Blocked.")
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		if chain_id == "" do chain_id = remote_work.chain_id
		idempotency_key := fmt.tprintf("task-status:%s:blocked:%s:%d", task_id, author, router_now_unix_ms())
		payload := federation_task_status_callback_json(remote_work, author, "blocked", status_body, idempotency_key, false)
		write_remote_task_callback_response(client, remote_work, payload, idempotency_key, FEDERATION_ENVELOPE_TASK_STATUS, task_id)
		return
	}
	result := task_service_set_status(task_id, chain_id, "blocked", status_body, author)
	write_task_service_response(client, result)
}

handle_task_later :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	reason := extract_json_string(body, "body", "Later/Deferred.")
	queued_body := strings.concatenate({"system_auto:manual_unblocked:", reason})
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		if chain_id == "" do chain_id = remote_work.chain_id
		idempotency_key := fmt.tprintf("task-status:%s:queued:%s:%d", task_id, author, router_now_unix_ms())
		payload := federation_task_status_callback_json(remote_work, author, "queued", queued_body, idempotency_key, false)
		write_remote_task_callback_response(client, remote_work, payload, idempotency_key, FEDERATION_ENVELOPE_TASK_STATUS, task_id)
		return
	}
	result := task_service_set_status(task_id, chain_id, "queued", queued_body, author)
	write_task_service_response(client, result)
}

handle_task_review_vote :: proc(client: net.TCP_Socket, body: string) {
	author, is_user, ok := task_author_and_type_from_body(client, body)
	if !ok do return
	result_str := extract_json_string(body, "result", "")
	comment_body := extract_json_string(body, "comment", "")
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	approved   := result_str == "lgtm" || result_str == "approved" || result_str == "true"
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		if chain_id == "" do chain_id = remote_work.chain_id
		idempotency_key := fmt.tprintf("task-vote:%s:%s:%d", task_id, author, router_now_unix_ms())
		payload := federation_task_vote_callback_json(remote_work, author, comment_body, result_str, idempotency_key)
		write_remote_task_callback_response(client, remote_work, payload, idempotency_key, FEDERATION_ENVELOPE_TASK_VOTE, task_id)
		return
	}
	result := task_service_review_vote(Task_Review_Vote_Command{
		task_id                  = task_id,
		chain_id                 = chain_id,
		approved                 = approved,
		comment                  = comment_body,
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
	write_response(client, 410, "Gone", `{"ok":false,"message":"GET /tasks without auth is deprecated; use REST endpoint with Bearer token"}`)
}

handle_task_list_authed :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	if remote_rows := federation_remote_work_list_for_agent(author); len(remote_rows) > 0 {
		for row in remote_rows {
			delete(row.task_id); delete(row.chain_id); delete(row.owner_peer_id); delete(row.origin_daemon_id); delete(row.local_agent_instance_id); delete(row.proxy_agent_instance_id); delete(row.status)
		}
		delete(remote_rows)
		write_response(client, 200, "OK", federation_remote_tasks_state_json(author))
		return
	}

	chain_id := extract_json_string(body, "chain_id", "")
	created_after := extract_json_i64(body, "created_after", 0)
	created_before := extract_json_i64(body, "created_before", 0)
	updated_after := extract_json_i64(body, "updated_after", 0)
	updated_before := extract_json_i64(body, "updated_before", 0)
	limit := extract_json_int(body, "limit", 100) // Default to 100 to bound it
	offset := extract_json_int(body, "offset", 0)

	b := strings.builder_make()
	strings.write_string(&b, `{"tasks":[`)
	matched_count := write_tasks_list_json(&b, chain_id, created_after, created_before, updated_after, updated_before, limit, offset)
	strings.write_string(&b, `],"total_count":`)
	strings.write_string(&b, fmt.tprintf("%d", matched_count))
	strings.write_string(&b, `}`)
	
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_task_next :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	task_recompute_promotions(author)
	state, found := task_claim_next_for_agent(author)
	if !found {
		if remote_next_json, remote_ok := federation_remote_task_next_json(author); remote_ok {
			write_response(client, 200, "OK", remote_next_json)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"task":null}`)
		return
	}
	_ = agent_store_set_current_task(author, state.task_id)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"task":`)
	task_write_state_json(&b, state, true)
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_task_show :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	task_id := extract_json_string(body, "task_id", "")
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_task_identity_ambiguous_response(client, task_id)
		return
	} else if remote {
		resp, forwarded := federation_remote_task_fetch_response(remote_work)
		federation_write_forwarded_response(client, resp, forwarded)
		return
	}
	if state, found := store_get_task(task_id); found {
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":true,"task":`)
		task_write_state_json(&b, state, true)
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
	author, ok := task_author_from_body(client, body)
	if !ok do return
	chain_id := extract_json_string(body, "chain_id", "")
	remote_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
	if remote_work, remote, ambiguous := federation_remote_work_resolve_chain(chain_id, remote_origin_daemon_id, author); ambiguous {
		write_remote_chain_identity_ambiguous_response(client, chain_id)
		return
	} else if remote {
		resp, forwarded := federation_remote_chain_fetch_response(remote_work)
		federation_write_forwarded_response(client, resp, forwarded)
		return
	}
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
