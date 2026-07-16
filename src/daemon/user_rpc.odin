package main

import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"

handle_user_rpc :: proc(client: net.TCP_Socket, body: string) {
	action := extract_json_string(body, "action", "")
	client_instance_id := extract_json_string(body, "client_instance_id", "")
	client_token := extract_json_string(body, "client_token", "")
	user_id := user_client_user_for_token(client_instance_id, client_token)
	if user_id == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid client token"}`)
		return
	}
	switch action {
	case "fetch_chat": handle_user_rpc_fetch_chat(client, body, user_id)
	case "list_chats": handle_user_rpc_list_chats(client, user_id)
	case "send_to_agent": handle_user_rpc_send_to_agent(client, body, user_id)
	case "mark_read": handle_user_rpc_mark_read(client, body, user_id)
	case "list_tasks": handle_user_rpc_list_tasks(client)
	case "task_log": handle_user_rpc_task_log(client, body)
	case "task_create": handle_user_rpc_task_create(client, body, user_id)
	case "task_chain_create": handle_user_rpc_task_chain_create(client, body, user_id)
	case "task_comment": handle_user_rpc_task_comment(client, body, user_id)
	case "task_comment_resolve": handle_user_rpc_task_comment_resolve(client, body, user_id)
	case "task_status": handle_user_rpc_task_status(client, body, user_id)
	case "task_update": handle_user_rpc_task_update(client, body, user_id)
	case "task_delete": handle_user_rpc_task_delete(client, body, user_id)
	case "task_assign": handle_user_rpc_task_assign(client, body, user_id)
	case "task_participant": handle_user_rpc_task_participant(client, body, user_id)
	case "task_participant_remove": handle_user_rpc_task_participant_remove(client, body, user_id)
	case "task_review_vote": handle_user_rpc_task_review_vote(client, body, user_id)
	case "task_nudge": handle_user_rpc_task_nudge(client, body, user_id)
	case "task_chain_update": handle_user_rpc_task_chain_update(client, body, user_id)
	case "task_chain_status": handle_user_rpc_task_chain_status(client, body, user_id)
	case "task_chain_evaluate": handle_user_rpc_task_chain_evaluate(client, body, user_id)
	case "memory_propose_new": write_memory_service_response(client, memory_service_propose("new", body, user_id))
	case "memory_propose_edit": write_memory_service_response(client, memory_service_propose("edit", body, user_id))
	case "memory_propose_archive": write_memory_service_response(client, memory_service_propose("archive", body, user_id))
	case "memory_propose_rollback": write_memory_service_response(client, memory_service_propose("rollback", body, user_id))
	case "memory_decide": write_memory_service_response(client, memory_service_decide(extract_json_string(body, "decision", extract_json_string(body, "result", "")), body, user_id))
	case "memory_list": out := memory_service_list_json(body, user_id); if !extract_json_bool(out, "ok", false) { write_response(client, 400, "Bad Request", out) } else { write_response(client, 200, "OK", out) }
	case "memory_applicable": write_memory_service_response(client, memory_service_applicable_json(body, user_id))
	case "memory_show": write_response(client, 200, "OK", memory_service_show_json(body))
	case "memory_history": write_response(client, 200, "OK", memory_service_history_json(body))
	case "project_list": write_response(client, 200, "OK", project_list_json())
	case "project_show": out, status := project_show_json(extract_json_string(body, "project_id", "")); if status == 404 { write_response(client, 404, "Not Found", out) } else { write_response(client, 200, "OK", out) }
	case "project_create": write_project_service_response(client, project_create(body, user_id))
	case "project_update": write_project_service_response(client, project_update(body, user_id))
	case "project_delete": write_project_service_response(client, project_delete(body, user_id))
	case "project_reorder": write_project_service_response(client, project_reorder(body, user_id))
	case "agent_reorder": handle_agent_reorder(client, body)
	case:
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported user-rpc action"}`)
	}
}

handle_user_rpc_send_to_agent :: proc(client: net.TCP_Socket, body, user_id: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	message_body := extract_json_string(body, "body", "")
	interrupt := extract_json_bool(body, "interrupt", false)
	is_interrupt := interrupt || strings.has_prefix(message_body, "\u001b")
	if strings.has_prefix(message_body, "\u001b") {
		message_body = message_body[len("\u001b"):]
	}

	fmt.println("DEBUG: handle_user_rpc_send_to_agent called for user", user_id, "to agent", agent_instance_id)
	if agent_instance_id == "" || message_body == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"send_to_agent requires agent_instance_id and body"}`)
		return
	}
	if proxy_result := task_service_user_proxy_review_reply(user_id, agent_instance_id, message_body); proxy_result.ok {
		write_task_service_response(client, proxy_result)
		return
	}
	if !valid_agent_instance_id(agent_instance_id) || !registry_agent_exists(agent_instance_id) {
		fmt.printf("WARNING: send_to_agent failed: agent '%s' is unknown or unregistered (requested by user '%s')\n", agent_instance_id, user_id)
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown agent"}`)
		return
	}
	message_id, ok := chat_store_append_message(user_id, agent_instance_id, "user_to_agent", message_body, is_interrupt)
	fmt.println("DEBUG: chat_store_append_message returned message_id =", message_id, "ok =", ok)
	if !ok {
		fmt.printf("ERROR: send_to_agent failed: chat_store_append_message failed for user '%s' to agent '%s'\n", user_id, agent_instance_id)
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"append chat failed"}`)
		return
	}

	sent := chat_event_fanout(user_id, agent_instance_id, message_id, "user_to_agent")
	if agent_chat_notify_user_message(agent_instance_id, user_id, message_id) {
		if chat_store_append_event(Chat_Event{kind = .Delivered_Marked, user_id = user_id, agent_instance_id = agent_instance_id, message_id = message_id, direction = "user_to_agent", delivered_unix_ms = router_now_unix_ms()}) {
			chat_event_fanout(user_id, agent_instance_id, message_id, "delivered")
		}
	} else {
		fmt.printf("WARNING: send_to_agent: failed to deliver WebSocket notification to agent '%s' for message '%s' (chat will load on manual fetch)\n", agent_instance_id, message_id)
	}
	write_response(client, 200, "OK", chat_send_response_json(message_id, sent))
}

handle_user_rpc_fetch_chat :: proc(client: net.TCP_Socket, body, user_id: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"fetch_chat requires agent_instance_id"}`)
		return
	}
	unread_only := extract_json_bool(body, "unread_only", true)
	limit := extract_json_int(body, "limit", 50)
	cursor := extract_json_i64(body, "cursor", 0)
	fmt.println("DEBUG: handle_user_rpc_fetch_chat for user", user_id, "agent", agent_instance_id, "unread_only =", unread_only, "limit =", limit, "cursor =", cursor)
	write_response(client, 200, "OK", chat_fetch_json(user_id, agent_instance_id, unread_only, "", limit, cursor))
}

handle_user_rpc_list_chats :: proc(client: net.TCP_Socket, user_id: string) {
	write_response(client, 200, "OK", chat_list_json(user_id))
}

handle_user_rpc_list_tasks :: proc(client: net.TCP_Socket) {
	write_response(client, 200, "OK", task_store_state_json())
}

handle_user_rpc_task_log :: proc(client: net.TCP_Socket, body: string) {
	task_id := extract_json_string(body, "task_id", "")
	if task_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"task_log requires task_id"}`)
		return
	}
	limit := extract_json_int(body, "limit", 0)
	cursor := extract_json_int(body, "cursor", 0)
	write_response(client, 200, "OK", task_log_json_paginated(task_id, limit, cursor))
}

handle_user_rpc_task_create :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_create_task(Task_Create_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), project_id = extract_json_string(body, "project_id", ""), standalone = extract_json_bool(body, "standalone", false), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), acceptance_criteria = extract_json_string(body, "acceptance_criteria", ""), priority = extract_json_string(body, "priority", ""), status = extract_json_string(body, "status", ""), assignee_agent_instance_id = extract_json_string(body, "assignee_agent_instance_id", ""), depends_on = extract_json_string(body, "depends_on", ""), created_by = user_id, author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_chain_create :: proc(client: net.TCP_Socket, body, user_id: string) {
	description := extract_json_string(body, "description", "")
	if description == "" do description = extract_json_string(body, "goal", "")
	result := task_service_create_chain(Task_Chain_Create_Command{chain_id = extract_json_string(body, "chain_id", ""), project_id = extract_json_string(body, "project_id", ""), kind = extract_json_string(body, "kind", ""), title = extract_json_string(body, "title", ""), description = description, scaffold = extract_json_string(body, "scaffold", ""), no_scaffold = extract_json_bool(body, "no_scaffold", false), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""), wants_vcs = extract_json_bool(body, "wants_vcs", true), author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_comment :: proc(client: net.TCP_Socket, body, user_id: string) {
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
		artifact_result := artifact_create_record(user_id, true, extract_json_string(body, "artifact_name", ""), extract_json_string(body, "artifact_kind", ""), "", project_id, "comment", task_id, "", artifact_content_base64)
		if !artifact_result.ok {
			artifact_write_error(client, artifact_result.status, artifact_result.status_text, artifact_result.error_kind, artifact_result.message)
			return
		}
		created_artifact = artifact_result.rec
		comment_body = artifact_append_link_body(comment_body, created_artifact.artifact_id)
		if chain_id == "" do chain_id = resolved_chain_id
	}
	result := task_service_comment(task_id, chain_id, comment_body, user_id)
	if !result.ok && created_artifact.artifact_id != "" do artifact_cleanup_failed_inline_attach(created_artifact)
	write_task_service_response(client, result)
}

handle_user_rpc_task_comment_resolve :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_comment_resolve(Task_Comment_Resolve_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
		comment_id               = extract_json_string(body, "comment_id", ""),
		author_agent_instance_id = user_id,
	})
	write_task_service_response(client, result)
}

handle_user_rpc_task_status :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_status_command(Task_Status_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), status = extract_json_string(body, "status", ""), body = extract_json_string(body, "body", ""), force = extract_json_bool(body, "force", false), author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_update :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_update_task(Task_Update_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), description_present = json_has_key(body, "description"), acceptance_criteria = extract_json_string(body, "acceptance_criteria", ""), acceptance_criteria_present = json_has_key(body, "acceptance_criteria"), depends_on = extract_json_string(body, "depends_on", ""), depends_on_present = json_has_key(body, "depends_on"), author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_delete :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_delete_task(Task_Delete_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_assign :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_assign(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "agent_instance_id", ""), user_id)
	write_task_service_response(client, result)
}

handle_user_rpc_task_participant :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_add_participant(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "agent_instance_id", ""), extract_json_string(body, "role", ""), user_id)
	write_task_service_response(client, result)
}

handle_user_rpc_task_nudge :: proc(client: net.TCP_Socket, body, user_id: string) {
	task_id := extract_json_string(body, "task_id", "")
	chain_id := extract_json_string(body, "chain_id", "")
	nudge_body := extract_json_string(body, "body", "")
	interrupt := extract_json_bool(body, "interrupt", false)

	result := task_service_nudge(task_id, chain_id, nudge_body, user_id, interrupt)
	write_task_service_response(client, result)
}

handle_user_rpc_task_chain_update :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_update_chain(Task_Chain_Update_Command{chain_id = extract_json_string(body, "chain_id", ""), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), default_reviewer_agent_instance_id = extract_json_string(body, "default_reviewer_agent_instance_id", ""), final_summary = extract_json_string(body, "final_summary", ""), author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_chain_status :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_set_chain_status(extract_json_string(body, "chain_id", ""), extract_json_string(body, "status", ""), extract_json_string(body, "final_summary", ""), user_id)
	write_task_service_response(client, result)
}

handle_user_rpc_mark_read :: proc(client: net.TCP_Socket, body, user_id: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	message_id := extract_json_string(body, "message_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"mark_read requires agent_instance_id"}`)
		return
	}
	now := router_now_unix_ms()
	if !chat_store_append_event(Chat_Event{kind = .Read_Marked, user_id = user_id, agent_instance_id = agent_instance_id, direction = "agent_to_user", message_id = message_id, read_unix_ms = now}) {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"mark_read failed"}`)
		return
	}
	chat_event_fanout(user_id, agent_instance_id, message_id, "read")
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"read_unix_ms":`)
	strings.write_string(&builder, fmt.tprintf("%d", now))
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

chat_send_response_json :: proc(message_id: string, fanout_count: int) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"message_id":"`); json_write_string(&builder, message_id)
	strings.write_string(&builder, `","fanout_count":`); strings.write_string(&builder, fmt.tprintf("%d", fanout_count))
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

chat_fetch_json :: proc(user_id, agent_instance_id: string, unread_only: bool = true, direction: string = "", limit: int = 50, cursor: i64 = 0, chain_id: string = "") -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"user_id":"`); json_write_string(&builder, user_id)
	strings.write_string(&builder, `","agent_instance_id":"`); json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `","messages":[`)

	messages := make([dynamic]Chat_Message)
	if unread_only {
		messages = message_db_fetch_unread(user_id, agent_instance_id, direction)
	} else {
		messages = message_db_fetch_all(user_id, agent_instance_id, direction)
	}

	first := true
	for msg in messages {
		if chain_id != "" && msg.chain_id != chain_id do continue
		if !first do strings.write_string(&builder, `,`)
		first = false
		chat_write_message_json(&builder, msg)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

// Derive a durable-ish conversation title server-side. Precedence:
//   1. explicit persisted instance display_name (when it is not just the id or
//      the durable agent_id),
//   2. first user->agent message body (truncated),
//   3. empty string (client renders a "New conversation" fallback while empty).
chat_list_derive_title :: proc(agent_instance_id, first_user_body: string) -> string {
	durable := agent_id_from_instance_id(agent_instance_id)
	defer delete(durable)
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		dn := strings.trim_space(agent_instance_records[idx].display_name)
		if dn != "" && dn != agent_instance_id && !strings.equal_fold(dn, durable) {
			return strings.clone(dn)
		}
	}
	body := strings.trim_space(first_user_body)
	if body == "" do return ""
	// Collapse internal whitespace to single spaces for a clean one-line title.
	collapsed := strings.builder_make()
	defer strings.builder_destroy(&collapsed)
	prev_space := false
	for r in body {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			if !prev_space do strings.write_rune(&collapsed, ' ')
			prev_space = true
		} else {
			strings.write_rune(&collapsed, r)
			prev_space = false
		}
	}
	one_line := strings.trim_space(strings.to_string(collapsed))
	if len(one_line) > 56 {
		return strings.clone(fmt.tprintf("%s…", one_line[:53]))
	}
	return strings.clone(one_line)
}

Chat_List_Row :: struct {
	agent_instance_id:    string,
	agent_id:             string,
	project_id:           string,
	title:                string,
	last_message_unix_ms: i64,
	unread_count:         int,
}

chat_list_free_rows :: proc(rows: [dynamic]Chat_List_Row) {
	for row in rows {
		delete(row.agent_instance_id)
		delete(row.agent_id)
		delete(row.project_id)
		delete(row.title)
	}
	delete(rows)
}

// Build the authoritative conversation-list rows for a user. Rows come from two
// sources unioned by agent_instance_id:
//   1. conversations that have messages (message-DB summaries: ordering ts +
//      first-user-message title source);
//   2. empty/new conversation instances that have no messages yet (durable
//      Agent_Instance_Records with durable id "conversation"), so the daemon
//      returns a stable fallback ordering (updated/created ts) + title fallback.
// The merged set is sorted most-recent-first with a deterministic id tiebreak.
chat_list_build_rows :: proc(user_id: string) -> [dynamic]Chat_List_Row {
	rows := make([dynamic]Chat_List_Row)
	seen := make(map[string]bool)
	defer delete(seen)

	summaries := message_db_get_chat_list_summaries(user_id)
	defer message_db_free_chat_list_summaries(summaries)
	for summary in summaries {
		agent_id := summary.agent_instance_id
		row := Chat_List_Row{}
		row.agent_instance_id = strings.clone(agent_id)
		row.agent_id = agent_id_from_instance_id(agent_id)
		row.title = chat_list_derive_title(agent_id, summary.first_user_body)
		if idx := agent_record_index_by_instance(agent_id); idx >= 0 do row.project_id = strings.clone(agent_instance_records[idx].project_id)
		else do row.project_id = strings.clone("")
		row.last_message_unix_ms = summary.last_message_unix_ms
		row.unread_count = chat_unread_count(user_id, agent_id)
		append(&rows, row)
		seen[agent_id] = true
	}

	// Add empty/new conversation instances that have no message row yet.
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if rec.agent_instance_id == "" do continue
		if seen[rec.agent_instance_id] do continue
		durable := agent_id_from_instance_id(rec.agent_instance_id)
		is_conversation := durable == "conversation" || rec.template_id == "conversation" || rec.agent_role == "conversation"
		if !is_conversation { delete(durable); continue }
		row := Chat_List_Row{}
		row.agent_instance_id = strings.clone(rec.agent_instance_id)
		row.agent_id = durable
		row.project_id = strings.clone(rec.project_id)
		row.title = chat_list_derive_title(rec.agent_instance_id, "")
		// Stable fallback ordering for empty threads: updated, else created.
		fallback_ts := rec.updated_unix_ms
		if fallback_ts == 0 do fallback_ts = rec.created_unix_ms
		row.last_message_unix_ms = fallback_ts
		row.unread_count = chat_unread_count(user_id, rec.agent_instance_id)
		append(&rows, row)
		seen[rec.agent_instance_id] = true
	}

	// Most-recent-first; deterministic id tiebreak for equal timestamps.
	slice.sort_by(rows[:], proc(a, b: Chat_List_Row) -> bool {
		if a.last_message_unix_ms != b.last_message_unix_ms do return a.last_message_unix_ms > b.last_message_unix_ms
		return a.agent_instance_id < b.agent_instance_id
	})
	return rows
}

chat_list_write_rows :: proc(builder: ^strings.Builder, rows: [dynamic]Chat_List_Row) {
	first := true
	for row in rows {
		if !first do strings.write_string(builder, `,`)
		first = false
		strings.write_string(builder, `{"agent_instance_id":"`); json_write_string(builder, row.agent_instance_id)
		strings.write_string(builder, `","agent_id":"`); json_write_string(builder, row.agent_id)
		strings.write_string(builder, `","project_id":"`); json_write_string(builder, row.project_id)
		strings.write_string(builder, `","title":"`); json_write_string(builder, row.title)
		strings.write_string(builder, `","last_message_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", row.last_message_unix_ms))
		strings.write_string(builder, `,"unread_count":`); strings.write_string(builder, fmt.tprintf("%d", row.unread_count))
		strings.write_string(builder, `}`)
	}
}

// Chat list for the conversation sidebar. The daemon is authoritative for both
// ordering (most recent durable message first, empty threads by created/updated)
// and titles; the client must not re-sort by locally-loaded messages.
chat_list_json :: proc(user_id: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"chats":[`)
	rows := chat_list_build_rows(user_id)
	defer chat_list_free_rows(rows)
	chat_list_write_rows(&builder, rows)
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

chat_write_message_json :: proc(builder: ^strings.Builder, msg: Chat_Message) {
	strings.write_string(builder, `{"message_id":"`); json_write_string(builder, msg.message_id)
	strings.write_string(builder, `","direction":"`); json_write_string(builder, msg.direction)
	strings.write_string(builder, `","body":"`); json_write_string(builder, msg.body)
	strings.write_string(builder, `","chain_id":"`); json_write_string(builder, msg.chain_id)
	strings.write_string(builder, `","delivered_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.delivered_unix_ms))
	strings.write_string(builder, `,"read_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.read_unix_ms))
	strings.write_string(builder, `,"delivery_failed_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.delivery_failed_unix_ms))
	strings.write_string(builder, `,"delivery_error":"`); json_write_string(builder, msg.delivery_error); strings.write_string(builder, `"`)
	strings.write_string(builder, `,"created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.created_unix_ms))
	strings.write_string(builder, `,"interrupt":`)
	strings.write_string(builder, "true" if msg.interrupt else "false")
	strings.write_string(builder, `}`)
}

handle_user_rpc_task_chain_evaluate :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_evaluate_chain(
		extract_json_string(body, "chain_id", ""),
		extract_json_string(body, "evaluation", ""),
		user_id,
	)
	write_task_service_response(client, result)
}

handle_user_rpc_task_participant_remove :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_remove_participant(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "agent_instance_id", ""), extract_json_string(body, "role", ""), user_id)
	write_task_service_response(client, result)
}

handle_user_rpc_task_review_vote :: proc(client: net.TCP_Socket, body, user_id: string) {
	approved_val := extract_json_string(body, "result", "") == "lgtm"
	result := task_service_review_vote(Task_Review_Vote_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
		approved                 = approved_val,
		comment                  = extract_json_string(body, "comment", ""),
		author_agent_instance_id = user_id,
		author_is_user           = true,
	})
	write_task_service_response(client, result)
}
