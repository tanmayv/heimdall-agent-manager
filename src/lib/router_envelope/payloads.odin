package router_envelope

import "core:encoding/json"

Message_Send_Payload :: struct {
	from_agent_instance_id:   string `json:"from_agent_instance_id"`,
	target_agent_instance_id: string `json:"target_agent_instance_id"`,
	body:                     string `json:"body"`,
}

Message_Read_Payload :: struct {
	conversation_id:           string `json:"conversation_id"`,
	message_id:                string `json:"message_id"`,
	read_by_agent_instance_id: string `json:"read_by_agent_instance_id"`,
	read_unix_ms:              i64    `json:"read_unix_ms"`,
}

parse_message_send_payload_json :: proc(payload_json: string) -> (Message_Send_Payload, bool) {
	payload: Message_Send_Payload
	if err := json.unmarshal_string(payload_json, &payload, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		return {}, false
	}
	return payload, payload.from_agent_instance_id != "" && payload.target_agent_instance_id != ""
}

parse_message_read_payload_json :: proc(payload_json: string) -> (Message_Read_Payload, bool) {
	payload: Message_Read_Payload
	if err := json.unmarshal_string(payload_json, &payload, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		return {}, false
	}
	return payload, payload.conversation_id != "" && payload.message_id != "" && payload.read_by_agent_instance_id != ""
}
