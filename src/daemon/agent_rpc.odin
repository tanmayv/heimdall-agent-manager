package main

import "core:fmt"
import "core:net"
import "core:strings"
import contracts "odin_test:contracts"

handle_agent_rpc :: proc(client: net.TCP_Socket, body: string) {
	agent_token := extract_json_string(body, "agent_token", "")
	action := extract_json_string(body, "action", "")
	from_agent_instance_id := registry_agent_instance_for_token(agent_token)
	if from_agent_instance_id == "" {
		fmt.println("agent_rpc failure invalid_token action", action)
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`)
	} else if action == "send_message" {
		command := agent_rpc_parse_send_message_command(body, from_agent_instance_id)
		result := message_service_execute(command)
		write_agent_rpc_service_result(client, result)
	} else if action == "fetch_messages" {
		command := agent_rpc_parse_fetch_messages_command(body, from_agent_instance_id)
		result := message_service_execute(command)
		write_agent_rpc_service_result(client, result)
	} else if action == "send_to_user" {
		handle_agent_rpc_send_to_user(client, body, from_agent_instance_id)
	} else if action == "fetch_user_chat" {
		handle_agent_rpc_fetch_user_chat(client, body, from_agent_instance_id)
	} else if action == "user_presence" {
		write_response(client, 200, "OK", user_presence_json())
	} else if action == "memory_propose_new" {
		write_memory_service_response(client, memory_service_propose("new", body, from_agent_instance_id))
	} else if action == "memory_propose_edit" {
		write_memory_service_response(client, memory_service_propose("edit", body, from_agent_instance_id))
	} else if action == "memory_propose_archive" {
		write_memory_service_response(client, memory_service_propose("archive", body, from_agent_instance_id))
	} else if action == "memory_propose_rollback" {
		write_memory_service_response(client, memory_service_propose("rollback", body, from_agent_instance_id))
	} else if action == "memory_decide" {
		write_memory_service_response(client, memory_service_decide(extract_json_string(body, "decision", extract_json_string(body, "result", "")), body, from_agent_instance_id))
	} else if action == "memory_list" {
		out := memory_service_list_json(body, from_agent_instance_id)
		if !extract_json_bool(out, "ok", false) { write_response(client, 400, "Bad Request", out) } else { write_response(client, 200, "OK", out) }
	} else if action == "memory_show" {
		write_response(client, 200, "OK", memory_service_show_json(body))
	} else if action == "memory_history" {
		write_response(client, 200, "OK", memory_service_history_json(body))
	} else if action == "start_success" {
		handle_start_success(client, agent_token)
	} else if guide_rpc_try_handle(client, action, body, from_agent_instance_id) {
		return
	} else {
		fmt.println("agent_rpc failure unsupported_action", action, "from", from_agent_instance_id)
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported agent-rpc action"}`)
	}
}

handle_agent_rpc_send_to_user :: proc(client: net.TCP_Socket, body, from_agent_instance_id: string) {
	user_id := extract_json_string(body, "user_id", "")
	payload := extract_json_string(body, "payload", "")
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
	if payload == "" do payload = extract_json_string(body, "body", "")
	if !valid_user_id(user_id) || payload == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"send_to_user requires valid user_id and body"}`)
		return
	}
	if !user_client_user_exists(user_id) && user_id != server_config.daemon.user_id {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown user_id"}`)
		return
	}
	chain_id_explicit := chain_id != ""
	if chain_id == "" {
		inferred_chain_id, inferred, ambiguous := agent_rpc_infer_reply_chain_id(from_agent_instance_id)
		if ambiguous {
			write_response(client, 409, "Conflict", `{"ok":false,"message":"send_to_user has multiple possible active chains; pass chain_id explicitly"}`)
			return
		}
		if inferred do chain_id = inferred_chain_id
	}

	if chain_id != "" {
		chain, found := store_get_chain(chain_id)
		if !found {
			write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown chain_id"}`)
			return
		}
		if chain.coordinator_agent_instance_id != from_agent_instance_id {
			agent_rpc_redirect_non_coordinator_send_to_user(client, user_id, from_agent_instance_id, payload, chain_id, chain_id_explicit)
			return
		}
	}
	// Detect approval-shaped payloads (smart_answer / questions / approval_request).
	// Approvals must be bound to a chain so operator inbox items can be listed
	// and expired without stranding the agent. Reject known invalid spellings
	// instead of silently rendering raw JSON.
	if invalid_approval := chat_approval_invalid_type_error(payload); invalid_approval != "" {
		write_response(client, 400, "Bad Request", invalid_approval)
		return
	}
	approval_det := chat_approval_detect_payload(payload)
	if approval_det.matched && chain_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"chain_id required for approval-shaped send_to_user","error":"chain_id_required_for_approval"}`)
		return
	}
	message_id, ok := agent_chat_send_to_user(from_agent_instance_id, user_id, payload, chain_id)
	if !ok || message_id == "" {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"send_to_user did not create a message"}`)
		return
	}
	approval_id := ""
	if approval_det.matched {
		if recorded, insert_ok := chat_approval_service_record(approval_det, message_id, chain_id, user_id, from_agent_instance_id); insert_ok {
			approval_id = recorded
		}
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"message_id":"`); json_write_string(&builder, message_id)
	if chain_id != "" {
		strings.write_string(&builder, `","chain_id":"`)
		json_write_string(&builder, chain_id)
	}
	if approval_id != "" {
		strings.write_string(&builder, `","approval_id":"`)
		json_write_string(&builder, approval_id)
	}
	strings.write_string(&builder, `"}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

agent_rpc_redirect_non_coordinator_send_to_user :: proc(client: net.TCP_Socket, user_id, from_agent_instance_id, payload, chain_id: string, chain_id_explicit: bool) {
	chain, found := store_get_chain(chain_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown chain_id"}`)
		return
	}
	coordinator := chain.coordinator_agent_instance_id
	if coordinator == "" {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"chain has no coordinator"}`)
		return
	}
	body := fmt.tprintf("Agent %s attempted to send this message directly to user %s. Free-form user contact is coordinator-owned; please answer/resolve if you can, or forward/ask the user if clarification is needed.\n\nOriginal message:\n%s", from_agent_instance_id, user_id, payload)
	boot_requested := task_autoscaler_ensure_chain_coordinator(chain_id, "agent_send_to_user_redirect", "high")
	message_id, ok := chat_store_append_message_with_chain(user_id, coordinator, "user_to_agent", body, false, chain_id)
	if !ok || message_id == "" {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"redirect to coordinator did not create a message"}`)
		return
	}
	chat_event_fanout(user_id, coordinator, message_id, "user_to_agent", chain_id)
	_ = agent_chat_notify_user_message(coordinator, user_id, message_id)

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"redirected_to_coordinator":true,"message_id":"`); json_write_string(&builder, message_id)
	strings.write_string(&builder, `","chain_id":"`); json_write_string(&builder, chain_id)
	strings.write_string(&builder, `","coordinator_agent_instance_id":"`); json_write_string(&builder, coordinator)
	strings.write_string(&builder, `","original_agent_instance_id":"`); json_write_string(&builder, from_agent_instance_id)
	strings.write_string(&builder, `","delivered_to_user":false,"chain_id_explicit":`); strings.write_string(&builder, "true" if chain_id_explicit else "false")
	strings.write_string(&builder, `,"coordinator_boot_requested":`); strings.write_string(&builder, "true" if boot_requested else "false")
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

agent_rpc_infer_reply_chain_id :: proc(agent_instance_id: string) -> (chain_id: string, inferred: bool, ambiguous: bool) {
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		current_task_id := agent_instance_records[idx].current_task_id
		if current_task_id != "" {
			if task, found := store_get_task_in_chain(current_task_id, ""); found && task.chain_id != "" {
				return task.chain_id, true, false
			}
		}
	}

	candidate := ""
	count := 0
	for chain in store_all_chains() {
		if !agent_rpc_chain_is_reply_candidate_for_agent(chain, agent_instance_id) do continue
		if candidate != chain.chain_id {
			candidate = chain.chain_id
			count += 1
		}
		if count > 1 do return "", false, true
	}
	if count == 1 do return candidate, true, false
	return "", false, false
}

agent_rpc_chain_is_reply_candidate_for_agent :: proc(chain: Task_Chain_State, agent_instance_id: string) -> bool {
	if chain.chain_id == "" || chain.archived do return false
	if chain.status == "completed" || chain.status == "abandoned" || chain.status == "cancelled" do return false
	if chain.coordinator_agent_instance_id == agent_instance_id do return true
	for state in store_tasks_in_chain(chain.chain_id) {
		if task_status_terminal(state.status) do continue
		if state.assignee_agent_instance_id == agent_instance_id do return true
		if task_actor_has_role(state, agent_instance_id, "lgtm_required") || task_actor_has_role(state, agent_instance_id, "lgtm_optional") || task_actor_has_role(state, agent_instance_id, "subscriber") do return true
	}
	return false
}

handle_agent_rpc_fetch_user_chat :: proc(client: net.TCP_Socket, body, from_agent_instance_id: string) {
	user_id := extract_json_string(body, "user_id", "")
	if !valid_user_id(user_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"fetch_user_chat requires valid user_id"}`)
		return
	}
	unread_only := extract_json_bool(body, "unread_only", true)
	limit := extract_json_int(body, "limit", 3)
	cursor := extract_json_i64(body, "cursor", 0)

	// 1. Fetch messages first while they are still unread
	response_json := chat_fetch_json(user_id, from_agent_instance_id, unread_only, "user_to_agent", limit, cursor)

	// 2. Mark them as read afterwards
	if unread_only && chat_has_unread_direction(user_id, from_agent_instance_id, "user_to_agent") {
		read_time := message_db_get_max_unread_timestamp(user_id, from_agent_instance_id, "user_to_agent")
		if read_time > 0 {
			if !chat_store_append_event(Chat_Event{kind = .Read_Marked, user_id = user_id, agent_instance_id = from_agent_instance_id, direction = "user_to_agent", read_unix_ms = read_time}) {
				fmt.println("WARNING: fetch_user_chat mark read failed")
			} else {
				chat_event_fanout(user_id, from_agent_instance_id, "", "read")
			}
		}
	}

	// 3. Return the fetched messages
	write_response(client, 200, "OK", response_json)
}

agent_rpc_parse_send_message_command :: proc(body, from_agent_instance_id: string) -> Command {
	target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
	payload := extract_json_string(body, "payload", "")
	if payload == "" do payload = extract_json_string(body, "body", "")
	return Command {
		source = .Local_Agent_RPC,
		kind = .Send_Message,
		send_message = Send_Message_Command {
			from_agent_instance_id = contracts.Agent_Instance_ID(from_agent_instance_id),
			target_agent_instance_id = contracts.Agent_Instance_ID(target_agent_instance_id),
			payload = payload,
		},
	}
}

agent_rpc_parse_fetch_messages_command :: proc(body, from_agent_instance_id: string) -> Command {
	conversation_id := extract_json_string(body, "conversation_id", "")
	limit := extract_json_int(body, "limit", 100)
	include_read := extract_json_bool(body, "include_read", false)
	return Command {
		source = .Local_Agent_RPC,
		kind = .Fetch_Messages,
		fetch_messages = Fetch_Messages_Command {
			agent_instance_id = contracts.Agent_Instance_ID(from_agent_instance_id),
			conversation_id = contracts.Conversation_ID(conversation_id),
			limit = limit,
			include_read = include_read,
		},
	}
}

write_agent_rpc_service_result :: proc(client: net.TCP_Socket, result: Service_Result) {
	if !result.ok {
		write_response(client, result.status_code, result.status_text, result.message)
		return
	}
	if result.send_response.ok {
		write_response(client, result.status_code, result.status_text, send_message_response_json(result.send_response, result.pending_count))
		return
	}
	write_response(client, result.status_code, result.status_text, fetch_messages_response_json(result.fetch_response))
}
