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
		write_response(client, 200, "OK", memory_service_list_json(body, from_agent_instance_id))
	} else if action == "memory_show" {
		write_response(client, 200, "OK", memory_service_show_json(body))
	} else if action == "memory_history" {
		write_response(client, 200, "OK", memory_service_history_json(body))
	} else if action == "start_success" {
		handle_start_success(client, agent_token)
	} else {
		fmt.println("agent_rpc failure unsupported_action", action, "from", from_agent_instance_id)
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported agent-rpc action"}`)
	}
}

handle_agent_rpc_send_to_user :: proc(client: net.TCP_Socket, body, from_agent_instance_id: string) {
	user_id := extract_json_string(body, "user_id", "")
	payload := extract_json_string(body, "payload", "")
	if payload == "" do payload = extract_json_string(body, "body", "")
	if !valid_user_id(user_id) || payload == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"send_to_user requires valid user_id and body"}`)
		return
	}
	if !user_client_user_exists(user_id) {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown user_id"}`)
		return
	}
	message_id, ok := agent_chat_send_to_user(from_agent_instance_id, user_id, payload)
	if !ok || message_id == "" {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"send_to_user did not create a message"}`)
		return
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"message_id":"`); json_write_string(&builder, message_id)
	strings.write_string(&builder, `"}`)
	write_response(client, 200, "OK", strings.to_string(builder))
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

	if chat_has_unread_direction(user_id, from_agent_instance_id, "user_to_agent") {
		// Mark read only up to the latest unread message, not current time
		// This prevents filtering out agent responses sent around the same time
		read_time := message_db_get_max_unread_timestamp(user_id, from_agent_instance_id, "user_to_agent")
		if read_time > 0 {
			if !chat_store_append_event(Chat_Event{kind = .Read_Marked, user_id = user_id, agent_instance_id = from_agent_instance_id, direction = "user_to_agent", read_unix_ms = read_time}) {
				write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"fetch_user_chat mark read failed"}`)
				return
			}
			chat_event_fanout(user_id, from_agent_instance_id, "", "read")
		}
	}
	write_response(client, 200, "OK", chat_fetch_json(user_id, from_agent_instance_id, unread_only, "user_to_agent", limit, cursor))
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
