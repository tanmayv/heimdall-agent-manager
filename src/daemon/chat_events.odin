package main

import "core:fmt"
import "core:strings"

WS_INLINE_PAYLOAD_LIMIT :: 3900

chat_event_write_base :: proc(builder: ^strings.Builder, user_id, agent_instance_id, message_id, direction, chain_id: string) {
	strings.write_string(builder, `{"type":"chat_event","event":"chat_updated","user_id":"`)
	json_write_string(builder, user_id)
	strings.write_string(builder, `","agent_instance_id":"`)
	json_write_string(builder, agent_instance_id)
	strings.write_string(builder, `","message_id":"`)
	json_write_string(builder, message_id)
	strings.write_string(builder, `","direction":"`)
	json_write_string(builder, direction)
	strings.write_string(builder, `","unread_count":`)
	strings.write_string(builder, fmt.tprintf("%d", chat_unread_count(user_id, agent_instance_id)))
	if chain_id != "" {
		strings.write_string(builder, `,"chain_id":"`)
		json_write_string(builder, chain_id)
		strings.write_string(builder, `"`)
	}
}

chat_event_metadata_json :: proc(user_id, agent_instance_id, message_id, direction, chain_id: string, fetch_required: bool = false) -> string {
	builder := strings.builder_make()
	chat_event_write_base(&builder, user_id, agent_instance_id, message_id, direction, chain_id)
	if fetch_required && message_id != "" {
		strings.write_string(&builder, `,"fetch_required":true,"fetch_kind":"chat_message","fetch_id":"`)
		json_write_string(&builder, message_id)
		strings.write_string(&builder, `"`)
	}
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

chat_event_inline_message_json :: proc(user_id, agent_instance_id, message_id, direction, chain_id: string) -> (string, bool) {
	msg, found := message_db_get_message(message_id)
	if !found do return "", false
	defer free_chat_message(msg)

	builder := strings.builder_make()
	chat_event_write_base(&builder, user_id, agent_instance_id, message_id, direction, chain_id)
	strings.write_string(&builder, `,"message":`)
	chat_write_message_json(&builder, msg)
	strings.write_string(&builder, `}`)
	payload := strings.to_string(builder)
	if len(payload) > WS_INLINE_PAYLOAD_LIMIT {
		delete(payload)
		return "", false
	}
	return payload, true
}

chat_event_should_inline_message :: proc(direction, message_id: string) -> bool {
	if message_id == "" do return false
	switch direction {
	case "user_to_agent", "agent_to_user":
		return true
	}
	return false
}

chat_event_fanout :: proc(user_id, agent_instance_id, message_id, direction: string, chain_id: string = "") -> int {
	if chat_event_should_inline_message(direction, message_id) {
		if payload, ok := chat_event_inline_message_json(user_id, agent_instance_id, message_id, direction, chain_id); ok {
			return user_client_fanout_ws_text(user_id, payload)
		}
		return user_client_fanout_ws_text(user_id, chat_event_metadata_json(user_id, agent_instance_id, message_id, direction, chain_id, true))
	}
	return user_client_fanout_ws_text(user_id, chat_event_metadata_json(user_id, agent_instance_id, message_id, direction, chain_id, false))
}
