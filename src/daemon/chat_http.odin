package main

import "core:fmt"
import "core:net"
import "core:strings"

handle_chat_request :: proc(client: net.TCP_Socket, request: string) -> bool {
	method, target := http_method_target(request)
	path := path_without_query(target)
	if method == "POST" && (path == "/chat/send-to-coordinator" || path == "/chat/send-to-coordinator/") {
		handle_chat_send_to_coordinator(client, request_body(request))
		return true
	}
	if method == "GET" && (path == "/chat/inbox" || path == "/chat/inbox/") {
		handle_chat_inbox(client, target)
		return true
	}
	return false
}

handle_chat_send_to_coordinator :: proc(client: net.TCP_Socket, body: string) {
	token := extract_json_string(body, "agent_token", extract_json_string(body, "token", ""))
	itype, sender := auth_db_get_identity(token)
	if itype == "" || sender == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid token"}`)
		return
	}
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
	message_body := extract_json_string(body, "body", extract_json_string(body, "payload", ""))
	if chain_id == "" || strings.trim_space(message_body) == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"send-to-coordinator requires chain_id and body"}`)
		return
	}
	idx, found := task_existing_chain_index(chain_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"chain not found"}`)
		return
	}
	coordinator := task_chains[idx].coordinator_agent_instance_id
	if coordinator == "" {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"chain has no coordinator"}`)
		return
	}
	user_id := sender
	if itype != "user" do user_id = HUMAN_RECIPIENT_ID
	message_id, ok := chat_store_append_message_with_chain(user_id, coordinator, "user_to_agent", message_body, false, chain_id)
	if !ok {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"append chat failed"}`)
		return
	}
	chat_event_fanout(user_id, coordinator, message_id, "user_to_agent", chain_id)
	_ = agent_chat_notify_user_message(coordinator, user_id, message_id)
	superseded := chat_approval_supersede_for_chain(chain_id, message_body, message_id, user_id)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"message_id":"`); json_write_string(&b, message_id)
	strings.write_string(&b, `","chain_id":"`); json_write_string(&b, chain_id)
	strings.write_string(&b, `","superseded_approvals":`); strings.write_string(&b, fmt.tprintf("%d", superseded))
	strings.write_string(&b, `,"agent_instance_id":"`); json_write_string(&b, coordinator)
	strings.write_string(&b, `","coordinator_boot_requested":false`)
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_chat_inbox :: proc(client: net.TCP_Socket, target: string) {
	token := query_value(target, "agent_token")
	if token == "" do token = query_value(target, "token")
	agent_instance_id := registry_agent_instance_for_token(token)
	if agent_instance_id == "" {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"invalid agent token"}`)
		return
	}
	limit := extract_int(query_value(target, "limit"))
	if limit <= 0 do limit = 50
	include_read := query_value(target, "include_read") == "true" || query_value(target, "include_read") == "1"
	chain_id := query_value(target, "chain_id")
	write_response(client, 200, "OK", chat_fetch_json(HUMAN_RECIPIENT_ID, agent_instance_id, !include_read, "user_to_agent", limit, 0, chain_id))
}

