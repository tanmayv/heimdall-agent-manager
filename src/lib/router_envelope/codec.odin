package router_envelope

import "core:fmt"
import "core:strconv"
import "core:strings"

router_envelope_to_json :: proc(envelope: Router_Envelope) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"protocol_version\":")
	strings.write_string(&builder, fmt.tprintf("%d", envelope.protocol_version))
	strings.write_string(&builder, ",\"envelope_id\":\"")
	write_json_string(&builder, envelope.envelope_id)
	strings.write_string(&builder, "\",\"logical_message_id\":\"")
	write_json_string(&builder, envelope.logical_message_id)
	strings.write_string(&builder, "\",\"nonce\":\"")
	write_json_string(&builder, envelope.nonce)
	strings.write_string(&builder, "\",\"user_id\":\"")
	write_json_string(&builder, envelope.user_id)
	strings.write_string(&builder, "\",\"namespace\":\"")
	write_json_string(&builder, envelope.namespace)
	strings.write_string(&builder, "\",\"source_daemon_id\":\"")
	write_json_string(&builder, envelope.source_daemon_id)
	strings.write_string(&builder, "\",\"target_daemon_id\":\"")
	write_json_string(&builder, envelope.target_daemon_id)
	strings.write_string(&builder, "\",\"target_agent_instance_id\":\"")
	write_json_string(&builder, envelope.target_agent_instance_id)
	strings.write_string(&builder, "\",\"payload_type\":\"")
	write_json_string(&builder, envelope.payload_type)
	strings.write_string(&builder, "\",\"payload_version\":")
	strings.write_string(&builder, fmt.tprintf("%d", envelope.payload_version))
	strings.write_string(&builder, ",\"encrypted_payload_json\":\"")
	write_json_string(&builder, envelope.encrypted_payload_json)
	strings.write_string(&builder, "\"}")
	return strings.to_string(builder)
}

router_envelope_from_json :: proc(body: string) -> (Router_Envelope, bool) {
	envelope := Router_Envelope {
		protocol_version = extract_json_int(body, "protocol_version", 0),
		envelope_id = extract_json_string(body, "envelope_id", ""),
		logical_message_id = extract_json_string(body, "logical_message_id", ""),
		nonce = extract_json_string(body, "nonce", ""),
		user_id = extract_json_string(body, "user_id", ""),
		namespace = extract_json_string(body, "namespace", ""),
		source_daemon_id = extract_json_string(body, "source_daemon_id", ""),
		target_daemon_id = extract_json_string(body, "target_daemon_id", ""),
		target_agent_instance_id = extract_json_string(body, "target_agent_instance_id", ""),
		payload_type = extract_json_string(body, "payload_type", ""),
		payload_version = extract_json_int(body, "payload_version", 0),
		encrypted_payload_json = extract_json_string(body, "encrypted_payload_json", ""),
	}
	return envelope, validate_router_envelope_metadata(envelope)
}

message_send_payload_json :: proc(from_agent_instance_id, target_agent_instance_id, body: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"from_agent_instance_id\":\"")
	write_json_string(&builder, from_agent_instance_id)
	strings.write_string(&builder, "\",\"target_agent_instance_id\":\"")
	write_json_string(&builder, target_agent_instance_id)
	strings.write_string(&builder, "\",\"body\":\"")
	write_json_string(&builder, body)
	strings.write_string(&builder, "\"}")
	return strings.to_string(builder)
}

message_read_payload_json :: proc(conversation_id, message_id, read_by_agent_instance_id: string, read_unix_ms: i64) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"conversation_id\":\"")
	write_json_string(&builder, conversation_id)
	strings.write_string(&builder, "\",\"message_id\":\"")
	write_json_string(&builder, message_id)
	strings.write_string(&builder, "\",\"read_by_agent_instance_id\":\"")
	write_json_string(&builder, read_by_agent_instance_id)
	strings.write_string(&builder, "\",\"read_unix_ms\":")
	strings.write_string(&builder, fmt.tprintf("%d", read_unix_ms))
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

write_json_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case: strings.write_rune(builder, ch)
		}
	}
}

extract_json_string :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := start
	escaped := false
	for end < len(body) {
		ch := body[end]
		if escaped {
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			return json_unescape(body[start:end])
		}
		end += 1
	}
	return fallback
}

extract_json_int :: proc(body, key: string, fallback: int) -> int {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := start
	for end < len(body) {
		ch := body[end]
		if ch < '0' || ch > '9' do break
		end += 1
	}
	if end == start do return fallback
	if value, ok := strconv.parse_int(body[start:end]); ok {
		return int(value)
	}
	return fallback
}

json_unescape :: proc(value: string) -> string {
	builder := strings.builder_make()
	escaped := false
	for ch in value {
		if escaped {
			switch ch {
			case 'n': strings.write_rune(&builder, '\n')
			case 'r': strings.write_rune(&builder, '\r')
			case 't': strings.write_rune(&builder, '\t')
			case '"': strings.write_rune(&builder, '"')
			case '\\': strings.write_rune(&builder, '\\')
			case: strings.write_rune(&builder, ch)
			}
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	if escaped do strings.write_rune(&builder, '\\')
	return strings.to_string(builder)
}
