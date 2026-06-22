package main

import "core:fmt"
import "core:strings"

chat_event_fanout :: proc(user_id, agent_instance_id, message_id, direction: string) -> int {
	// Try to fetch the message payload
	msg, found := message_db_get_message(message_id)

	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"chat_event","event":"chat_updated","user_id":"`)
	json_write_string(&builder, user_id)
	strings.write_string(&builder, `","agent_instance_id":"`)
	json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `","message_id":"`)
	json_write_string(&builder, message_id)
	strings.write_string(&builder, `","direction":"`)
	json_write_string(&builder, direction)
	strings.write_string(&builder, `","unread_count":`)
	strings.write_string(&builder, fmt.tprintf("%d", chat_unread_count(user_id, agent_instance_id)))
	
	if found {
		strings.write_string(&builder, `,"message":`)
		chat_write_message_json(&builder, msg)
		
		// Free message cloned strings
		delete(msg.message_id)
		delete(msg.user_id)
		delete(msg.agent_instance_id)
		delete(msg.direction)
		delete(msg.body)
		delete(msg.delivery_error)
	}

	strings.write_string(&builder, `}`)
	return user_client_fanout_ws_text(user_id, strings.to_string(builder))
}
