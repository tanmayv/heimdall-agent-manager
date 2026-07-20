package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

json_has_key :: proc(body, key: string) -> bool {
	return json_value_start(body, key) >= 0
}

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
	search_start := 0
	for search_start < len(body) {
		idx_rel := strings.index(body[search_start:], pattern)
		if idx_rel < 0 do return -1
		idx := search_start + idx_rel
		pos := idx + len(pattern)
		for pos < len(body) && (body[pos] == ' ' || body[pos] == '\t' || body[pos] == '\n' || body[pos] == '\r') do pos += 1
		if pos < len(body) && body[pos] == ':' {
			pos += 1
			for pos < len(body) && (body[pos] == ' ' || body[pos] == '\t' || body[pos] == '\n' || body[pos] == '\r') do pos += 1
			return pos
		}
		search_start = idx + len(pattern)
	}
	return -1
}

json_unescape :: proc(value: string) -> string {
	builder := strings.builder_make()
	i := 0
	for i < len(value) {
		ch := value[i]
		if ch == '\\' {
			if i + 1 < len(value) {
				next_ch := value[i + 1]
				switch next_ch {
				case 'n': strings.write_byte(&builder, '\n')
				case 'r': strings.write_byte(&builder, '\r')
				case 't': strings.write_byte(&builder, '\t')
				case '"': strings.write_byte(&builder, '"')
				case '\\': strings.write_byte(&builder, '\\')
				case 'u':
					if i + 5 < len(value) {
						hex_str := value[i + 2 : i + 6]
						val, ok := strconv.parse_int(hex_str, 16)
						if ok {
							strings.write_rune(&builder, rune(val))
							i += 6
							continue
						}
					}
					strings.write_byte(&builder, 'u')
				case:
					strings.write_byte(&builder, next_ch)
				}
				i += 2
			} else {
				strings.write_byte(&builder, '\\')
				i += 1
			}
		} else {
			strings.write_byte(&builder, ch)
			i += 1
		}
	}
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

register_response_json :: proc(record: Agent_Record, template_persona, template_instructions, prefs_json: string) -> string {
	builder := strings.builder_make()
	ws_host := server_bind_host
	if server_config.daemon.advertise_host != "" do ws_host = server_config.daemon.advertise_host
	strings.write_string(&builder, "{\"agent_instance_id\":\"")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"agent_class\":\"")
	strings.write_string(&builder, record.agent_class)
	strings.write_string(&builder, "\",\"conversation_id\":\"")
	strings.write_string(&builder, record.conversation_id)
	strings.write_string(&builder, "\",\"reconnect_token\":\"rt_")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"ws_url\":\"ws://")
	strings.write_string(&builder, ws_host)
	strings.write_string(&builder, ":")
	strings.write_string(&builder, fmt.tprintf("%d", server_port))
	strings.write_string(&builder, "/ws/")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"ws_token\":\"ws_")
	strings.write_string(&builder, record.agent_instance_id)
	strings.write_string(&builder, "\",\"agent_token\":\"")
	json_write_string(&builder, record.agent_token)
	strings.write_string(&builder, "\"")
	if template_persona != "" {
		strings.write_string(&builder, ",\"template_persona\":\"")
		json_write_string(&builder, template_persona)
		strings.write_string(&builder, "\"")
	}
	if template_instructions != "" {
		strings.write_string(&builder, ",\"template_instructions\":\"")
		json_write_string(&builder, template_instructions)
		strings.write_string(&builder, "\"")
	}
	if prefs_json != "" {
		strings.write_string(&builder, ",\"preferences\":")
		strings.write_string(&builder, prefs_json)
	}
	strings.write_string(&builder, "}")
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
			if ch < 32 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_rune(builder, ch)
			}
		}
	}
}

extract_json_string_array :: proc(body, key: string) -> [dynamic]string {
	arr := make([dynamic]string)
	start := json_value_start(body, key)
	if start < 0 || start >= len(body) || body[start] != '[' do return arr
	idx := start + 1
	for idx < len(body) {
		for idx < len(body) && (body[idx] == ' ' || body[idx] == '\t' || body[idx] == '\n' || body[idx] == '\r') {
			idx += 1
		}
		if idx >= len(body) do break
		if body[idx] == ']' {
			break
		}
		if body[idx] == '"' {
			idx += 1
			str_start := idx
			escaped := false
			for idx < len(body) {
				ch := body[idx]
				if escaped {
					escaped = false
				} else if ch == '\\' {
					escaped = true
				} else if ch == '"' {
					append(&arr, json_unescape(body[str_start:idx]))
					idx += 1
					break
				}
				idx += 1
			}
		} else if body[idx] == ',' {
			idx += 1
		} else {
			idx += 1
		}
	}
	return arr
}
