package main

import "core:fmt"
import "core:net"
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
	case "task_assign": handle_user_rpc_task_assign(client, body, user_id)
	case "task_participant": handle_user_rpc_task_participant(client, body, user_id)
	case "task_nudge": handle_user_rpc_task_nudge(client, body, user_id)
	case "task_chain_update": handle_user_rpc_task_chain_update(client, body, user_id)
	case "task_chain_status": handle_user_rpc_task_chain_status(client, body, user_id)
	case "task_chain_evaluate": handle_user_rpc_task_chain_evaluate(client, body, user_id)
	case "memory_propose_new": write_memory_service_response(client, memory_service_propose("new", body, user_id))
	case "memory_propose_edit": write_memory_service_response(client, memory_service_propose("edit", body, user_id))
	case "memory_propose_archive": write_memory_service_response(client, memory_service_propose("archive", body, user_id))
	case "memory_propose_rollback": write_memory_service_response(client, memory_service_propose("rollback", body, user_id))
	case "memory_decide": write_memory_service_response(client, memory_service_decide(extract_json_string(body, "decision", extract_json_string(body, "result", "")), body, user_id))
	case "memory_list": write_response(client, 200, "OK", memory_service_list_json(body))
	case "memory_show": write_response(client, 200, "OK", memory_service_show_json(body))
	case "memory_history": write_response(client, 200, "OK", memory_service_history_json(body))
	case "project_list": write_response(client, 200, "OK", project_list_json())
	case "project_show": out, status := project_show_json(extract_json_string(body, "project_id", "")); if status == 404 { write_response(client, 404, "Not Found", out) } else { write_response(client, 200, "OK", out) }
	case "project_create": write_project_service_response(client, project_create(body, user_id))
	case "project_update": write_project_service_response(client, project_update(body, user_id))
	case "project_reorder": write_project_service_response(client, project_reorder(body, user_id))
	case "agent_reorder": handle_agent_reorder(client, body)
	case:
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported user-rpc action"}`)
	}
}

handle_user_rpc_send_to_agent :: proc(client: net.TCP_Socket, body, user_id: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	message_body := extract_json_string(body, "body", "")
	fmt.println("DEBUG: handle_user_rpc_send_to_agent called for user", user_id, "to agent", agent_instance_id)
	if agent_instance_id == "" || message_body == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"send_to_agent requires agent_instance_id and body"}`)
		return
	}
	if !valid_agent_instance_id(agent_instance_id) || !registry_agent_exists(agent_instance_id) {
		fmt.printf("WARNING: send_to_agent failed: agent '%s' is unknown or unregistered (requested by user '%s')\n", agent_instance_id, user_id)
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown agent"}`)
		return
	}
	message_id, ok := chat_store_append_message(user_id, agent_instance_id, "user_to_agent", message_body)
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
	write_response(client, 200, "OK", task_log_json(task_id))
}

handle_user_rpc_task_create :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_create_task(Task_Create_Command{task_id = extract_json_string(body, "task_id", ""), chain_id = extract_json_string(body, "chain_id", ""), project_id = extract_json_string(body, "project_id", ""), standalone = extract_json_bool(body, "standalone", false), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), acceptance_criteria = extract_json_string(body, "acceptance_criteria", ""), priority = extract_json_string(body, "priority", ""), status = extract_json_string(body, "status", ""), assignee_agent_instance_id = extract_json_string(body, "assignee_agent_instance_id", ""), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), depends_on = extract_json_string(body, "depends_on", ""), created_by = user_id, author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_chain_create :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_create_chain(Task_Chain_Create_Command{chain_id = extract_json_string(body, "chain_id", ""), project_id = extract_json_string(body, "project_id", ""), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), author_agent_instance_id = user_id})
	write_task_service_response(client, result)
}

handle_user_rpc_task_comment :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_comment(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "body", ""), user_id)
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
	result := task_service_set_status(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "status", ""), extract_json_string(body, "body", ""), user_id)
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
	result := task_service_nudge(extract_json_string(body, "task_id", ""), extract_json_string(body, "chain_id", ""), extract_json_string(body, "body", ""), user_id)
	write_task_service_response(client, result)
}

handle_user_rpc_task_chain_update :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_update_chain(Task_Chain_Update_Command{chain_id = extract_json_string(body, "chain_id", ""), title = extract_json_string(body, "title", ""), description = extract_json_string(body, "description", ""), coordinator_agent_instance_id = extract_json_string(body, "coordinator_agent_instance_id", ""), final_summary = extract_json_string(body, "final_summary", ""), author_agent_instance_id = user_id})
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

chat_fetch_json :: proc(user_id, agent_instance_id: string, unread_only: bool = true, direction: string = "", limit: int = 50, cursor: i64 = 0) -> string {
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
		if !first do strings.write_string(&builder, `,`)
		first = false
		chat_write_message_json(&builder, msg)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

chat_list_json :: proc(user_id: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"chats":[`)

	agents := message_db_get_distinct_agents(user_id)

	first := true
	for agent_id in agents {
		if !first do strings.write_string(&builder, `,`)
		first = false
		strings.write_string(&builder, `{"agent_instance_id":"`); json_write_string(&builder, agent_id)
		strings.write_string(&builder, `","unread_count":`); strings.write_string(&builder, fmt.tprintf("%d", chat_unread_count(user_id, agent_id)))
		strings.write_string(&builder, `}`)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

chat_write_message_json :: proc(builder: ^strings.Builder, msg: Chat_Message) {
	strings.write_string(builder, `{"message_id":"`); json_write_string(builder, msg.message_id)
	strings.write_string(builder, `","direction":"`); json_write_string(builder, msg.direction)
	strings.write_string(builder, `","body":"`); json_write_string(builder, msg.body)
	strings.write_string(builder, `","delivered_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.delivered_unix_ms))
	strings.write_string(builder, `,"read_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.read_unix_ms))
	strings.write_string(builder, `,"delivery_failed_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.delivery_failed_unix_ms))
	strings.write_string(builder, `,"delivery_error":"`); json_write_string(builder, msg.delivery_error); strings.write_string(builder, `"`)
	strings.write_string(builder, `,"created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", msg.created_unix_ms))
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
