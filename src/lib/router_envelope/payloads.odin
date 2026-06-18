package router_envelope

Message_Send_Payload :: struct {
	from_agent_instance_id: string,
	target_agent_instance_id: string,
	body: string,
}

Message_Read_Payload :: struct {
	conversation_id: string,
	message_id: string,
	read_by_agent_instance_id: string,
	read_unix_ms: i64,
}

parse_message_send_payload_json :: proc(payload_json: string) -> (Message_Send_Payload, bool) {
	payload := Message_Send_Payload {
		from_agent_instance_id = extract_json_string(payload_json, "from_agent_instance_id", ""),
		target_agent_instance_id = extract_json_string(payload_json, "target_agent_instance_id", ""),
		body = extract_json_string(payload_json, "body", ""),
	}
	return payload, payload.from_agent_instance_id != "" && payload.target_agent_instance_id != ""
}

parse_message_read_payload_json :: proc(payload_json: string) -> (Message_Read_Payload, bool) {
	payload := Message_Read_Payload {
		conversation_id = extract_json_string(payload_json, "conversation_id", ""),
		message_id = extract_json_string(payload_json, "message_id", ""),
		read_by_agent_instance_id = extract_json_string(payload_json, "read_by_agent_instance_id", ""),
		read_unix_ms = i64(extract_json_int(payload_json, "read_unix_ms", 0)),
	}
	return payload, payload.conversation_id != "" && payload.message_id != "" && payload.read_by_agent_instance_id != ""
}
