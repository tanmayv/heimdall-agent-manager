package main

import contracts "odin_test:contracts"

Message_Event_Kind :: enum {
	New_Message_Requested,
	Message_Stored,
	Messages_Available,
	Message_Read,
	Remote_Route_Required,
	Message_Send_Failed,
}

Message_Event :: struct {
	kind: Message_Event_Kind,
	message_id: contracts.Message_ID,
	conversation_id: contracts.Conversation_ID,
	from_agent_instance_id: contracts.Agent_Instance_ID,
	target_agent_instance_id: contracts.Agent_Instance_ID,
	read_by_agent_instance_id: contracts.Agent_Instance_ID,
	pending_count: int,
	created_unix_ms: i64,
	read_unix_ms: i64,

	// Internal only. Never serialize this onto WS/hub plaintext.
	body: string,
}

message_bus_emit :: proc(event: Message_Event) -> bool {
	#partial switch event.kind {
	case .Remote_Route_Required:
		return false
	case:
		hub_adapter_append_event(event)
		return ws_events_handle_message_event(event)
	}
	return true
}
