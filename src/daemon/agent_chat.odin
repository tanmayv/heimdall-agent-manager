package main

import "core:fmt"
import "core:strings"

agent_chat_send_to_user :: proc(agent_instance_id, user_id, body: string, chain_id: string = "") -> (string, bool) {
	if !valid_user_id(user_id) || body == "" do return "", false
	if message_id, routed, ok := federation_user_chat_reply_to_origin(agent_instance_id, user_id, body, chain_id); routed {
		return message_id, ok
	}
	message_id, ok := chat_append_agent_to_user_with_chain(user_id, agent_instance_id, body, chain_id)
	if !ok || message_id == "" do return "", false
	return message_id, true
}

agent_chat_notify_user_message :: proc(agent_instance_id, user_id, message_id: string) -> bool {
	msg, ok := message_db_get_message(message_id)
	send_escape := false
	if ok {
		send_escape = msg.interrupt
		delete(msg.message_id)
		delete(msg.user_id)
		delete(msg.agent_instance_id)
		delete(msg.direction)
		delete(msg.body)
		delete(msg.delivery_error)
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"user_chat_event","event":"user_message_available","user_id":"`)
	json_write_string(&builder, user_id)
	strings.write_string(&builder, `","message_id":"`)
	json_write_string(&builder, message_id)
	strings.write_string(&builder, `","pending_count":`)
	strings.write_string(&builder, fmt.tprintf("%d", chat_unread_for_agent(user_id, agent_instance_id)))
	strings.write_string(&builder, `,"interrupt":`)
	strings.write_string(&builder, send_escape ? "true" : "false")
	strings.write_string(&builder, `,"send_escape_prefix":`)
	strings.write_string(&builder, send_escape ? "true" : "false")
	strings.write_string(&builder, `}`)
	return registry_send_ws_text(agent_instance_id, strings.to_string(builder))
}

agent_chat_notify_user_read :: proc(agent_instance_id, user_id, message_id: string) -> bool {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 || !agents[idx].has_ws do return false
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"user_chat_event","event":"user_messages_read","user_id":"`)
	json_write_string(&builder, user_id)
	strings.write_string(&builder, `","message_id":"`)
	json_write_string(&builder, message_id)
	strings.write_string(&builder, `"}`)
	return registry_send_ws_text(agent_instance_id, strings.to_string(builder))
}

chat_unread_for_agent :: proc(user_id, agent_instance_id: string) -> int {
	count := message_db_count_unread_for_agent(user_id, agent_instance_id)
	if count <= 0 do count = 1
	return count
}
