package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

extract_json_string :: proc(body, key, fallback: string) -> string {
	start := json_value_start(body, key)
	if start < 0 || start >= len(body) || body[start] != '"' do return fallback
	start += 1
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

json_value_start :: proc(body, key: string) -> int {
	pattern := fmt.tprintf("\"%s\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return -1
	pos := idx + len(pattern)
	for pos < len(body) && (body[pos] == ' ' || body[pos] == '\t' || body[pos] == '\n' || body[pos] == '\r') do pos += 1
	if pos >= len(body) || body[pos] != ':' do return -1
	pos += 1
	for pos < len(body) && (body[pos] == ' ' || body[pos] == '\t' || body[pos] == '\n' || body[pos] == '\r') do pos += 1
	return pos
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

extract_json_int :: proc(body, key: string, fallback: int) -> int {
	start := json_value_start(body, key)
	if start < 0 do return fallback
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

extract_json_i64 :: proc(body, key: string, fallback: i64) -> i64 {
	start := json_value_start(body, key)
	if start < 0 do return fallback
	end := start
	for end < len(body) {
		ch := body[end]
		if ch < '0' || ch > '9' do break
		end += 1
	}
	if end == start do return fallback
	if value, ok := strconv.parse_i64(body[start:end]); ok {
		return value
	}
	return fallback
}

extract_json_bool :: proc(body, key: string, fallback: bool) -> bool {
	start := json_value_start(body, key)
	if start < 0 do return fallback
	if strings.has_prefix(body[start:], "true") do return true
	if strings.has_prefix(body[start:], "false") do return false
	return fallback
}

register_response_json :: proc(record: Agent_Record, template_instructions: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"agent_instance_id\":\"")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"agent_class\":\"")
	strings.write_string(&builder, record.agent_class)
	strings.write_string(&builder, "\",\"conversation_id\":\"")
	strings.write_string(&builder, record.conversation_id)
	strings.write_string(&builder, "\",\"reconnect_token\":\"rt_")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"ws_url\":\"ws://")
	strings.write_string(&builder, server_bind_host)
	strings.write_string(&builder, ":")
	strings.write_string(&builder, fmt.tprintf("%d", server_port))
	strings.write_string(&builder, "/ws/")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"ws_token\":\"ws_")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"agent_token\":\"")
	json_write_string(&builder, record.agent_token)
	if template_instructions != "" {
		strings.write_string(&builder, "\",\"template_instructions\":\"")
		json_write_string(&builder, template_instructions)
	}
	strings.write_string(&builder, "\"}")
	return strings.to_string(builder)
}

send_message_response_json :: proc(response: contracts.Send_Message_Response, pending_count: int) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"ok\":true,\"message\":\"send_message accepted\",\"message_id\":\"")
	json_write_string(&builder, string(response.message_id))
	strings.write_string(&builder, "\",\"conversation_id\":\"")
	json_write_string(&builder, string(response.conversation_id))
	strings.write_string(&builder, "\",\"pending_count\":")
	strings.write_string(&builder, fmt.tprintf("%d", pending_count))
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

fetch_messages_response_json :: proc(response: contracts.Fetch_Messages_Response) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"ok\":")
	strings.write_string(&builder, "true" if response.ok else "false")
	strings.write_string(&builder, ",\"messages\":[")
	for i in 0..<len(response.messages) {
		if i > 0 do strings.write_string(&builder, ",")
		msg := response.messages[i]
		strings.write_string(&builder, "{\"id\":\"")
		json_write_string(&builder, string(msg.id))
		strings.write_string(&builder, "\",\"conversation_id\":\"")
		json_write_string(&builder, string(msg.conversation_id))
		strings.write_string(&builder, "\",\"from_agent_instance_id\":\"")
		json_write_string(&builder, string(msg.from_agent_instance_id))
		strings.write_string(&builder, "\",\"target_agent_instance_id\":\"")
		json_write_string(&builder, string(msg.target_agent_instance_id))
		strings.write_string(&builder, "\",\"body\":\"")
		json_write_string(&builder, msg.body)
		strings.write_string(&builder, "\",\"created_unix_ms\":")
		strings.write_string(&builder, fmt.tprintf("%d", msg.created_unix_ms))
		strings.write_string(&builder, ",\"read\":")
		strings.write_string(&builder, "true" if msg.read_unix_ms > 0 else "false")
		strings.write_string(&builder, "}")
	}
	strings.write_string(&builder, "],\"has_more\":")
	strings.write_string(&builder, "true" if response.has_more else "false")
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\':
			strings.write_string(builder, "\\\\")
		case '"':
			strings.write_string(builder, "\\\"")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			strings.write_rune(builder, ch)
		}
	}
}
