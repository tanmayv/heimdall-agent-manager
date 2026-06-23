package main

chat_append_agent_to_user :: proc(user_id, agent_instance_id, body: string) -> (string, bool) {
	if user_id == "" || agent_instance_id == "" || body == "" do return "", false

	message_id, ok := chat_store_append_message(user_id, agent_instance_id, "agent_to_user", body, false)
	if !ok || message_id == "" {
		return "", false
	}

	sent := chat_event_fanout(user_id, agent_instance_id, message_id, "agent_to_user")
	if sent <= 0 && !user_client_has_ws(user_id) {
		if chat_store_append_event(Chat_Event{kind = .Delivery_Failed, user_id = user_id, agent_instance_id = agent_instance_id, message_id = message_id, direction = "agent_to_user", delivery_failed_unix_ms = router_now_unix_ms(), delivery_error = "no active user websocket recipients"}) {
			chat_event_fanout(user_id, agent_instance_id, message_id, "delivery_failed")
		}
	}

	return message_id, true
}
