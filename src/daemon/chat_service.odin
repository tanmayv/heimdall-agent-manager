package main

chat_append_agent_to_user :: proc(user_id, agent_instance_id, body: string) -> (string, bool) {
	if user_id == "" || agent_instance_id == "" || body == "" do return "", false
	event := Chat_Event{kind = .Message_Appended, user_id = user_id, agent_instance_id = agent_instance_id, direction = "agent_to_user", body = body}
	if !chat_store_append_event(event) do return "", false
	stored := chat_events[chat_event_count - 1]
	chat_event_fanout(user_id, agent_instance_id, stored.message_id, stored.direction)
	return stored.message_id, true
}
