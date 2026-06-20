package main

chat_append_agent_to_user :: proc(user_id, agent_instance_id, body: string) -> (string, bool) {
	if user_id == "" || agent_instance_id == "" || body == "" do return "", false
	event := Chat_Event{kind = .Message_Appended, user_id = user_id, agent_instance_id = agent_instance_id, direction = "agent_to_user", body = body}
	if !chat_store_append_event(event) do return "", false
	stored := chat_events[chat_event_count - 1]
	sent := chat_event_fanout(user_id, agent_instance_id, stored.message_id, stored.direction)
	if sent <= 0 && !user_client_has_ws(user_id) {
		if chat_store_append_event(Chat_Event{kind = .Delivery_Failed, user_id = user_id, agent_instance_id = agent_instance_id, message_id = stored.message_id, direction = "agent_to_user", delivery_failed_unix_ms = router_now_unix_ms(), delivery_error = "no active user websocket recipients"}) {
			chat_event_fanout(user_id, agent_instance_id, stored.message_id, "delivery_failed")
		}
	}
	return stored.message_id, true
}
