package main

import "core:fmt"
import "core:strings"

ws_events_handle_message_event :: proc(event: Message_Event) -> bool {
	#partial switch event.kind {
	case .Messages_Available:
		notification := messages_available_event_json(event)
		return registry_send_ws_text(string(event.target_agent_instance_id), notification)
	case .Message_Read:
		notification := message_read_event_json(event)
		return registry_send_ws_text(string(event.from_agent_instance_id), notification)
	case:
		return true
	}
}

messages_available_event_json :: proc(event: Message_Event) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"type\":\"message_event\",\"event\":\"messages_available\",\"conversation_id\":\"")
	json_write_string(&builder, string(event.conversation_id))
	strings.write_string(&builder, "\",\"from_agent_instance_id\":\"")
	json_write_string(&builder, string(event.from_agent_instance_id))
	strings.write_string(&builder, "\",\"pending_count\":")
	strings.write_string(&builder, fmt.tprintf("%d", event.pending_count))
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

message_read_event_json :: proc(event: Message_Event) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"type\":\"message_event\",\"event\":\"messages_read\",\"conversation_id\":\"")
	json_write_string(&builder, string(event.conversation_id))
	strings.write_string(&builder, "\",\"message_id\":\"")
	json_write_string(&builder, string(event.message_id))
	strings.write_string(&builder, "\",\"read_by_agent_instance_id\":\"")
	json_write_string(&builder, string(event.read_by_agent_instance_id))
	strings.write_string(&builder, "\",\"read_unix_ms\":")
	strings.write_string(&builder, fmt.tprintf("%d", event.read_unix_ms))
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}
