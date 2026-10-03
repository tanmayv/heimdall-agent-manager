package router_envelope

import "core:encoding/json"

router_envelope_to_json :: proc(envelope: Router_Envelope) -> string {
	bytes, err := json.marshal(envelope, allocator = context.temp_allocator)
	if err != nil do return ""
	return string(bytes)
}

router_envelope_from_json :: proc(body: string) -> (Router_Envelope, bool) {
	envelope: Router_Envelope
	if err := json.unmarshal_string(body, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		return {}, false
	}
	return envelope, validate_router_envelope_metadata(envelope)
}

message_send_payload_json :: proc(from_agent_instance_id, target_agent_instance_id, body: string) -> string {
	payload := Message_Send_Payload {
		from_agent_instance_id = from_agent_instance_id,
		target_agent_instance_id = target_agent_instance_id,
		body = body,
	}
	bytes, err := json.marshal(payload, allocator = context.temp_allocator)
	if err != nil do return ""
	return string(bytes)
}

message_read_payload_json :: proc(conversation_id, message_id, read_by_agent_instance_id: string, read_unix_ms: i64) -> string {
	payload := Message_Read_Payload {
		conversation_id = conversation_id,
		message_id = message_id,
		read_by_agent_instance_id = read_by_agent_instance_id,
		read_unix_ms = read_unix_ms,
	}
	bytes, err := json.marshal(payload, allocator = context.temp_allocator)
	if err != nil do return ""
	return string(bytes)
}
