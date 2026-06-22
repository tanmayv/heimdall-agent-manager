package main

import "core:fmt"
import "core:strings"

agent_chat_send_to_user :: proc(agent_instance_id, user_id, body: string) -> (string, bool) {
	if !valid_user_id(user_id) || body == "" do return "", false
	message_id, ok := chat_append_agent_to_user(user_id, agent_instance_id, body)
	if !ok || message_id == "" do return "", false
	return message_id, true
}

agent_chat_notify_user_message :: proc(agent_instance_id, user_id, message_id: string) -> bool {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"user_chat_event","event":"user_message_available","user_id":"`)
	json_write_string(&builder, user_id)
	strings.write_string(&builder, `","message_id":"`)
	json_write_string(&builder, message_id)
	strings.write_string(&builder, `","pending_count":`)
	strings.write_string(&builder, fmt.tprintf("%d", chat_unread_for_agent(user_id, agent_instance_id)))
	strings.write_string(&builder, `}`)
	return registry_send_ws_text(agent_instance_id, strings.to_string(builder))
}

chat_unread_for_agent :: proc(user_id, agent_instance_id: string) -> int {
	count := 0
	for i in 0..<chat_message_count {
		msg := chat_messages[i]
		if msg.user_id == user_id && msg.agent_instance_id == agent_instance_id && msg.direction == "user_to_agent" && msg.read_unix_ms == 0 do count += 1
	}
	if count <= 0 do count = 1
	return count
}
