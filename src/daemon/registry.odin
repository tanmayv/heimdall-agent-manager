package main

import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:strings"
import "core:time"

Agent_Record :: struct {
	agent_instance_id: string,
	agent_class: string,
	conversation_id: string,
	display_name: string,
	access_mode: string,
	connected: bool,
	has_agent_token: bool,
	agent_token: string,
	last_seen_unix_ms: i64,
	startup_status: string,
	startup_reason_code: string,
	startup_safe_diagnostic: string,
	startup_updated_unix_ms: i64,
	provider_profile: string,
	run_dir: string,
	tmux_pane: string,
	has_ws: bool,
	ws_socket: net.TCP_Socket,
}

// TODO: Registry is process-global and not thread-safe yet; daemon request handlers run in threads.
MAX_AGENTS :: 1024
MAX_PENDING_AGENT_TOKENS :: 1024
DUPLICATE_HEARTBEAT_FRESH_MS :: i64(15_000)
PENDING_AGENT_TOKEN_TTL_MS :: i64(60_000)

Pending_Agent_Token :: struct {
	agent_instance_id: string,
	agent_token: string,
	created_unix_ms: i64,
	used: bool,
}

agents: [MAX_AGENTS]Agent_Record
agent_count: int
pending_agent_tokens: [MAX_PENDING_AGENT_TOKENS]Pending_Agent_Token
pending_agent_token_count: int

registry_init :: proc() {
	agent_count = 0
	pending_agent_token_count = 0
}

registry_register :: proc(agent_class, agent_instance_id, display_name: string, requested_agent_token := "") -> Agent_Record {
	class := agent_class
	instance := agent_instance_id
	display := display_name

	if instance == "" do instance = "unknown"
	if class == "" do class = derive_agent_class(instance)
	if display == "" do display = instance

	agent_token := requested_agent_token
	if agent_token == "" do agent_token = generate_agent_token()

	if idx := registry_find_agent(instance); idx >= 0 {
		agents[idx].agent_class = strings.clone(class)
		agents[idx].display_name = strings.clone(display)
		agents[idx].connected = true
		agents[idx].has_ws = false
		agents[idx].has_agent_token = true
		agents[idx].agent_token = strings.clone(agent_token)
		agents[idx].last_seen_unix_ms = now_unix_ms()
		if agents[idx].startup_status == "" {
			agents[idx].startup_status = "starting"
			agents[idx].startup_updated_unix_ms = agents[idx].last_seen_unix_ms
		}
		return agents[idx]
	}

	record := Agent_Record {
		agent_instance_id = strings.clone(instance),
		agent_class = strings.clone(class),
		conversation_id = conversation_id_for_instance(instance),
		display_name = strings.clone(display),
		access_mode = "main",
		connected = true,
		has_agent_token = true,
		agent_token = strings.clone(agent_token),
		last_seen_unix_ms = now_unix_ms(),
		startup_status = "starting",
		startup_updated_unix_ms = now_unix_ms(),
	}

	if agent_count < MAX_AGENTS {
		agents[agent_count] = record
		agent_count += 1
	}

	return record
}

registry_find_agent :: proc(agent_instance_id: string) -> int {
	for i in 0..<agent_count {
		if agents[i].agent_instance_id == agent_instance_id {
			return i
		}
	}
	return -1
}

registry_agent_exists :: proc(agent_instance_id: string) -> bool {
	return registry_find_agent(agent_instance_id) >= 0
}

registry_add_pending_agent_token :: proc(agent_instance_id, agent_token: string) {
	now := now_unix_ms()
	for i in 0..<pending_agent_token_count {
		if pending_agent_tokens[i].agent_instance_id == agent_instance_id && !pending_agent_tokens[i].used {
			pending_agent_tokens[i].agent_token = strings.clone(agent_token)
			pending_agent_tokens[i].created_unix_ms = now
			return
		}
	}
	if pending_agent_token_count < MAX_PENDING_AGENT_TOKENS {
		pending_agent_tokens[pending_agent_token_count] = Pending_Agent_Token {
			agent_instance_id = strings.clone(agent_instance_id),
			agent_token = strings.clone(agent_token),
			created_unix_ms = now,
		}
		pending_agent_token_count += 1
	}
}

registry_consume_pending_agent_token :: proc(agent_instance_id, agent_token: string) -> bool {
	now := now_unix_ms()
	for i in 0..<pending_agent_token_count {
		pending := &pending_agent_tokens[i]
		if pending.used do continue
		if pending.agent_instance_id != agent_instance_id do continue
		if now - pending.created_unix_ms > PENDING_AGENT_TOKEN_TTL_MS {
			pending.used = true
			continue
		}
		if pending.agent_token == agent_token {
			pending.used = true
			return true
		}
	}
	return false
}

registry_agent_active_for_duplicate :: proc(agent_instance_id: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 && agents[idx].has_ws {
		now := now_unix_ms()
		heartbeat_recent := now - agents[idx].last_seen_unix_ms < DUPLICATE_HEARTBEAT_FRESH_MS
		ws_send_ok := ws_send_text(agents[idx].ws_socket, `{"type":"duplicate_check"}`)
		if ws_send_ok && heartbeat_recent {
			agents[idx].connected = true
			return true
		}
		agents[idx].has_ws = false
		agents[idx].connected = false
		return false
	}
	return false
}

registry_conversation_id :: proc(agent_instance_id: string) -> string {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		return agents[idx].conversation_id
	}
	return ""
}

registry_agent_token_valid :: proc(agent_token: string) -> bool {
	return registry_agent_instance_for_token(agent_token) != ""
}

registry_agent_instance_for_token :: proc(agent_token: string) -> string {
	for i in 0..<agent_count {
		if agents[i].has_agent_token && agents[i].agent_token == agent_token {
			return agents[i].agent_instance_id
		}
	}
	return ""
}

registry_set_ws :: proc(agent_instance_id: string, socket: net.TCP_Socket) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		agents[idx].has_ws = true
		agents[idx].ws_socket = socket
		return true
	}
	return false
}

registry_clear_ws :: proc(agent_instance_id: string) {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		agents[idx].has_ws = false
		agents[idx].connected = false
		agents[idx].last_seen_unix_ms = now_unix_ms()
	}
}

registry_send_ws_text :: proc(agent_instance_id, text: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 && agents[idx].has_ws {
		return ws_send_text(agents[idx].ws_socket, text)
	}
	return false
}

registry_update_startup :: proc(agent_instance_id, status, reason_code, safe_diagnostic, provider_profile, run_dir, tmux_pane: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		agents[idx].startup_status = strings.clone(status)
		agents[idx].startup_reason_code = strings.clone(reason_code)
		agents[idx].startup_safe_diagnostic = strings.clone(safe_diagnostic)
		if provider_profile != "" do agents[idx].provider_profile = strings.clone(provider_profile)
		if run_dir != "" do agents[idx].run_dir = strings.clone(run_dir)
		if tmux_pane != "" do agents[idx].tmux_pane = strings.clone(tmux_pane)
		agents[idx].startup_updated_unix_ms = now_unix_ms()
		return true
	}
	return false
}

registry_heartbeat :: proc(agent_instance_id: string) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		agents[idx].connected = true
		agents[idx].last_seen_unix_ms = now_unix_ms()
		return true
	}
	return false
}

now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

generate_agent_token :: proc() -> string {
	bytes: [32]byte
	if rand.read(bytes[:]) != len(bytes) {
		now := u64(now_unix_ms())
		for i in 0..<len(bytes) {
			bytes[i] = byte((now >> uint((i % 8) * 8)) & 0xff)
		}
	}
	builder := strings.builder_make()
	strings.write_string(&builder, "agt_")
	for b in bytes {
		hex_write_byte(&builder, b)
	}
	return strings.to_string(builder)
}

hex_write_byte :: proc(builder: ^strings.Builder, b: byte) {
	digits := "0123456789abcdef"
	strings.write_byte(builder, digits[int(b >> 4)])
	strings.write_byte(builder, digits[int(b & 0x0f)])
}

derive_agent_class :: proc(agent_instance_id: string) -> string {
	if at := strings.index_byte(agent_instance_id, '@'); at >= 0 {
		return strings.clone(agent_instance_id[:at])
	}
	return strings.clone(agent_instance_id)
}

valid_agent_id_part :: proc(id: string) -> bool {
	if len(id) == 0 do return false
	for ch in id {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-':
			continue
		case:
			return false
		}
	}
	return true
}

valid_agent_instance_id :: proc(agent_instance_id: string) -> bool {
	at := strings.index_byte(agent_instance_id, '@')
	if at <= 0 do return false
	if at >= len(agent_instance_id) - 1 do return false
	if strings.index_byte(agent_instance_id[at + 1:], '@') >= 0 do return false
	return valid_agent_id_part(agent_instance_id[:at]) && valid_agent_id_part(agent_instance_id[at + 1:])
}

conversation_id_for_instance :: proc(agent_instance_id: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "conv_")
	for ch in agent_instance_id {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-':
			strings.write_rune(&builder, ch)
		case:
			strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

registry_agent_live :: proc(agent_instance_id: string) -> bool {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return false
	now := now_unix_ms()
	return agents[idx].connected && now - agents[idx].last_seen_unix_ms < DUPLICATE_HEARTBEAT_FRESH_MS
}

registry_list_json :: proc() -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"agents\":[")
	for i in 0..<agent_count {
		if i > 0 do strings.write_string(&builder, ",")
		agent := agents[i]
		strings.write_string(&builder, "{\"agent_instance_id\":\"")
		strings.write_string(&builder, agent.agent_instance_id)
		strings.write_string(&builder, "\",\"agent_class\":\"")
		strings.write_string(&builder, agent.agent_class)
		strings.write_string(&builder, "\",\"conversation_id\":\"")
		strings.write_string(&builder, agent.conversation_id)
		strings.write_string(&builder, "\",\"display_name\":\"")
		strings.write_string(&builder, agent.display_name)
		strings.write_string(&builder, "\",\"access_mode\":\"")
		strings.write_string(&builder, agent.access_mode)
		strings.write_string(&builder, "\",\"connected\":")
		strings.write_string(&builder, "true" if agent.connected else "false")
		strings.write_string(&builder, ",\"has_agent_token\":")
		strings.write_string(&builder, "true" if agent.has_agent_token else "false")
		strings.write_string(&builder, ",\"last_seen_unix_ms\":")
		strings.write_string(&builder, fmt.tprintf("%d", agent.last_seen_unix_ms))
		strings.write_string(&builder, `,"startup_status":"`); json_write_string(&builder, agent.startup_status)
		strings.write_string(&builder, `","startup_reason_code":"`); json_write_string(&builder, agent.startup_reason_code)
		strings.write_string(&builder, `","safe_diagnostic":"`); json_write_string(&builder, agent.startup_safe_diagnostic)
		strings.write_string(&builder, `","provider_profile":"`); json_write_string(&builder, agent.provider_profile)
		strings.write_string(&builder, `","run_dir":"`); json_write_string(&builder, agent.run_dir)
		strings.write_string(&builder, `","tmux_pane":"`); json_write_string(&builder, agent.tmux_pane)
		strings.write_string(&builder, `","startup_updated_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", agent.startup_updated_unix_ms))
		strings.write_string(&builder, "}")
	}
	strings.write_string(&builder, "]}")
	return strings.to_string(builder)
}
