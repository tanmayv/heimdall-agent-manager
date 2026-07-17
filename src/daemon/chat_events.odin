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

chat_event_metadata_json :: proc(user_id, agent_instance_id, message_id, direction, chain_id: string, fetch_required: bool = false, delivered_unix_ms: i64 = 0, read_unix_ms: i64 = 0, delivery_failed_unix_ms: i64 = 0, delivery_error: string = "") -> string {
	builder := strings.builder_make()
	chat_event_write_base(&builder, user_id, agent_instance_id, message_id, direction, chain_id)
	if delivered_unix_ms > 0 {
		strings.write_string(&builder, `,"delivered_unix_ms":`)
		strings.write_string(&builder, fmt.tprintf("%d", delivered_unix_ms))
	}
	if read_unix_ms > 0 {
		strings.write_string(&builder, `,"read_unix_ms":`)
		strings.write_string(&builder, fmt.tprintf("%d", read_unix_ms))
	}
	if delivery_failed_unix_ms > 0 {
		strings.write_string(&builder, `,"delivery_failed_unix_ms":`)
		strings.write_string(&builder, fmt.tprintf("%d", delivery_failed_unix_ms))
	}
	if delivery_error != "" {
		strings.write_string(&builder, `,"delivery_error":"`)
		json_write_string(&builder, delivery_error)
		strings.write_string(&builder, `"`)
	}
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

chat_event_fanout :: proc(user_id, agent_instance_id, message_id, direction: string, chain_id: string = "", delivered_unix_ms: i64 = 0, read_unix_ms: i64 = 0, delivery_failed_unix_ms: i64 = 0, delivery_error: string = "") -> int {
	if chat_event_should_inline_message(direction, message_id) {
		if payload, ok := chat_event_inline_message_json(user_id, agent_instance_id, message_id, direction, chain_id); ok {
			return user_client_fanout_ws_text(user_id, payload)
		}
		return user_client_fanout_ws_text(user_id, chat_event_metadata_json(user_id, agent_instance_id, message_id, direction, chain_id, true, delivered_unix_ms, read_unix_ms, delivery_failed_unix_ms, delivery_error))
	}
	return user_client_fanout_ws_text(user_id, chat_event_metadata_json(user_id, agent_instance_id, message_id, direction, chain_id, false, delivered_unix_ms, read_unix_ms, delivery_failed_unix_ms, delivery_error))
}

chat_mark_delivered_and_fanout :: proc(user_id, agent_instance_id, message_id, direction: string, chain_id: string = "") -> i64 {
	if user_id == "" || agent_instance_id == "" || message_id == "" || direction == "" do return 0
	delivered_unix_ms := router_now_unix_ms()
	if !chat_store_append_event(Chat_Event{kind = .Delivered_Marked, user_id = user_id, agent_instance_id = agent_instance_id, message_id = message_id, direction = direction, delivered_unix_ms = delivered_unix_ms}) do return 0
	chat_event_fanout(user_id, agent_instance_id, message_id, "delivered", chain_id, delivered_unix_ms)
	return delivered_unix_ms
}

chat_mark_read_and_fanout :: proc(user_id, agent_instance_id, direction, message_id, chain_id: string, read_unix_ms: i64) -> bool {
	if user_id == "" || agent_instance_id == "" || direction == "" || read_unix_ms <= 0 do return false
	if !chat_store_append_event(Chat_Event{kind = .Read_Marked, user_id = user_id, agent_instance_id = agent_instance_id, direction = direction, message_id = message_id, read_unix_ms = read_unix_ms}) do return false
	chat_event_fanout(user_id, agent_instance_id, message_id, "read", chain_id, 0, read_unix_ms)
	return true
}
