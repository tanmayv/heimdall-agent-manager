package main

import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:strings"
import "core:time"

// In-memory runtime/session state for a live agent wrapper. NEVER persisted.
// Reconstructed from wrapper heartbeats on daemon restart. Identity/configuration
// fields live in Agent_Instance_Record (agent_store.odin) and are the source of
// truth — fields below that mirror them (display_name, provider_profile, etc.)
// are a cached view that the heartbeat refreshes for fast lookups; they must
// not be the place anything writes back to disk.
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
	activity_status: string,
	activity_checked_unix_ms: i64,
	activity_source: string,
	provider_profile: string,
	provider_tier: string,
	project_id: string,
	run_dir: string,
	tmux_pane: string,
	pid: int,
	exec_state: string,
	exec_state_since_unix_ms: i64,
	blocked_reason: string,
	stop_timeout_seconds: int,
	stop_requested_unix_ms: i64,
	has_ws: bool,
	ws_socket: net.TCP_Socket,
}

Heartbeat_Snapshot :: struct {
	agent_instance_id: string,
	agent_token: string,
	display_name: string,
	provider_profile: string,
	provider_tier: string,
	project_id: string,
	tmux_pane: string,
	pid: int,
	exec_state: string,
	exec_state_since_unix_ms: i64,
	blocked_reason: string,
	run_dir: string,
	startup_status: string,
	startup_reason_code: string,
	startup_safe_diagnostic: string,
	activity_status: string,
	activity_checked_unix_ms: i64,
	activity_source: string,
}

startup_status_rank :: proc(status: string) -> int {
	switch status {
	case "stopping", "stopped": return 3
	case "ready", "startup_failed": return 2
	case "startup_blocked", "startup_unknown": return 1
	case "starting", "": return 0
	case: return -1
	}
}

// registry_apply_heartbeat_snapshot updates only the runtime/session fields on
// an existing registry entry. Returns true when any runtime field changed
// (caller fans out agent.runtime_changed on true).
registry_apply_heartbeat_snapshot :: proc(snap: Heartbeat_Snapshot) -> (runtime_changed: bool, lifecycle_changed: bool) {
	idx := registry_find_agent(snap.agent_instance_id)
	if idx < 0 do return false, false
	a := &agents[idx]
	a.connected = true
	a.last_seen_unix_ms = now_unix_ms()
	if snap.tmux_pane != "" && snap.tmux_pane != a.tmux_pane {
		a.tmux_pane = strings.clone(snap.tmux_pane)
		runtime_changed = true
	}
	if snap.pid != 0 && snap.pid != a.pid {
		a.pid = snap.pid
		runtime_changed = true
	}
	if snap.run_dir != "" && snap.run_dir != a.run_dir {
		a.run_dir = strings.clone(snap.run_dir)
		runtime_changed = true
	}
	if snap.exec_state != "" && snap.exec_state != a.exec_state {
		a.exec_state = strings.clone(snap.exec_state)
		a.exec_state_since_unix_ms = snap.exec_state_since_unix_ms
		if a.exec_state_since_unix_ms == 0 do a.exec_state_since_unix_ms = a.last_seen_unix_ms
		runtime_changed = true
	}
	if snap.blocked_reason != a.blocked_reason {
		a.blocked_reason = strings.clone(snap.blocked_reason)
		runtime_changed = true
	}
	if snap.activity_status != "" && snap.activity_status != a.activity_status {
		a.activity_status = strings.clone(snap.activity_status)
		runtime_changed = true
	}
	if snap.activity_checked_unix_ms != 0 && snap.activity_checked_unix_ms != a.activity_checked_unix_ms {
		a.activity_checked_unix_ms = snap.activity_checked_unix_ms
		runtime_changed = true
	}
	if snap.activity_source != a.activity_source {
		a.activity_source = strings.clone(snap.activity_source)
		runtime_changed = true
	}

	// Declarative startup status synchronization via state rankings
	if snap.startup_status != "" {
		snap_rank := startup_status_rank(snap.startup_status)
		current_rank := startup_status_rank(a.startup_status)

		if snap_rank > current_rank {
			a.startup_status = strings.clone(snap.startup_status)
			a.startup_reason_code = strings.clone(snap.startup_reason_code)
			a.startup_safe_diagnostic = strings.clone(snap.startup_safe_diagnostic)
			a.startup_updated_unix_ms = a.last_seen_unix_ms
			lifecycle_changed = true
		}
	}

	return runtime_changed, lifecycle_changed
}

// registry_refresh_identity_cache mirrors a few identity/config fields into the
// in-memory registry so list views can render without joining against the
// agent_store. Does NOT persist. Caller must have already validated the values
// against the store (they should equal the store's values or be the corrections
// the daemon is about to send back).
registry_refresh_identity_cache :: proc(agent_instance_id, display_name, provider_profile, provider_tier, project_id: string) {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 do return
	a := &agents[idx]
	if display_name != "" do a.display_name = strings.clone(display_name)
	if provider_profile != "" do a.provider_profile = strings.clone(provider_profile)
	if provider_tier != "" do a.provider_tier = strings.clone(provider_tier)
	a.project_id = strings.clone(project_id)
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
	if agent_token == "" {
		// Try to recover token from persistent storage
		agent_token = auth_db_get_token("agent", instance)
		if agent_token == "" {
			// No stored token found, generate new one
			agent_token = generate_agent_token()
		}
	}
	// Always store the token (insert or replace) so it persists across daemon restarts
	if !auth_db_store_token(agent_token, "agent", instance, now_unix_ms()) {
		fmt.println("WARNING: failed to store agent token for", instance)
	}

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
			fmt.printfln("WARNING: Active duplicate detected for agent %s. Force-closing old socket to prefer new connection.", agent_instance_id)
			net.shutdown(agents[idx].ws_socket, .Both)
			net.close(agents[idx].ws_socket)
			agents[idx].has_ws = false
			agents[idx].connected = false
			return false
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

// registry_agent_instance_for_token_lenient attempts to find agent by token,
// and if not found in runtime registry, reconstructs entry from agent_store.
// This allows operations to proceed even after daemon restart or agent disconnect.
registry_agent_instance_for_token_lenient :: proc(agent_token: string) -> string {
	// First try runtime registry (fast path)
	if result := registry_agent_instance_for_token(agent_token); result != "" {
		return result
	}

	// Token not in runtime registry. This is OK if the agent exists in store.
	// For now, return empty. Callers can implement fallback logic.
	return ""
}

registry_agent_instance_for_token :: proc(agent_token: string) -> string {
	for i in 0..<agent_count {
		// Token is valid even if agent is offline/not running.
		// Tokens are issued at registration and remain valid until agent is destroyed.
		// Agent connection status should not affect token validity for operations.
		if agents[i].has_agent_token && agents[i].agent_token == agent_token {
			return agents[i].agent_instance_id
		}
	}

	// Token not found in runtime registry. Check if it's a valid pending token.
	// This handles the case where daemon restarted and lost in-memory registry,
	// but the token is still valid because it was issued recently and hasn't expired.
	for i in 0..<pending_agent_token_count {
		pending := &pending_agent_tokens[i]
		if pending.used do continue
		now := now_unix_ms()
		if now - pending.created_unix_ms > PENDING_AGENT_TOKEN_TTL_MS {
			pending.used = true
			continue
		}
		if pending.agent_token == agent_token {
			// Valid pending token found. Auto-register agent in registry.
			// This allows operations to proceed after daemon restart.
			_ = registry_register("", pending.agent_instance_id, "", agent_token)
			pending.used = true
			return pending.agent_instance_id
		}
	}

	// Check persistent database for token recovery after daemon restart
	itype, iid := auth_db_get_identity(agent_token)
	if itype == "agent" && iid != "" {
		fmt.println("TOKEN RECOVERY: Found persisted agent token, recovering agent", iid)
		// Auto-register agent in runtime registry using persisted token
		_ = registry_register("", iid, "", agent_token)
		return iid
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
		registry_clear_ws_index(idx)
	}
}

registry_clear_ws_if_socket :: proc(agent_instance_id: string, socket: net.TCP_Socket) -> bool {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		if agents[idx].has_ws && agents[idx].ws_socket == socket {
			registry_clear_ws_index(idx)
			return true
		}
		fmt.printf("WARNING: ignoring stale WebSocket close for agent '%s'; socket is no longer current\n", agent_instance_id)
	}
	return false
}

registry_clear_ws_index :: proc(idx: int) {
	if agents[idx].has_ws {
		net.shutdown(agents[idx].ws_socket, .Both)
		net.close(agents[idx].ws_socket)
	}
	agents[idx].has_ws = false
	agents[idx].connected = false
	agents[idx].last_seen_unix_ms = now_unix_ms()
	if agents[idx].startup_status == "starting" {
		agents[idx].startup_status = "startup_failed"
		agents[idx].startup_reason_code = "ws_disconnected"
		agents[idx].startup_safe_diagnostic = "Agent disconnected before reporting startup status"
		agents[idx].startup_updated_unix_ms = agents[idx].last_seen_unix_ms
	}
}

registry_mark_ws_stale :: proc(agent_instance_id, reason: string) {
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		if agents[idx].has_ws {
			net.shutdown(agents[idx].ws_socket, .Both)
			net.close(agents[idx].ws_socket)
		}
		agents[idx].has_ws = false
		// Keep heartbeat/process liveness separate from notification WS liveness:
		// a wrapper can still be heartbeating while its stored WS handle is stale.
		agents[idx].last_seen_unix_ms = now_unix_ms()
		fmt.printf("WARNING: cleared stale WebSocket for agent '%s' after failed send (%s)\n", agent_instance_id, reason)
	}
}

registry_send_ws_text :: proc(agent_instance_id, text: string) -> bool {
	idx := registry_find_agent(agent_instance_id)
	if idx < 0 {
		fmt.printf("WARNING: registry_send_ws_text failed: agent '%s' not found in registry\n", agent_instance_id)
		return false
	}
	agent := agents[idx]
	if !agent.has_ws {
		fmt.printf("WARNING: registry_send_ws_text failed: agent '%s' has no active WebSocket connection (connected=%t)\n", agent_instance_id, agent.connected)
		return false
	}
	if len(text) > 4090 {
		fmt.printf("ERROR: registry_send_ws_text failed: payload too large for agent '%s' WebSocket (bytes=%d limit=4090)\n", agent_instance_id, len(text))
		return false
	}
	ok := ws_send_text(agent.ws_socket, text)
	if !ok {
		fmt.printf("ERROR: registry_send_ws_text failed: socket write error to agent '%s' WebSocket\n", agent_instance_id)
		registry_mark_ws_stale(agent_instance_id, "socket_write_failed")
		agent_lifecycle_emit(agent_instance_id, "ws_stale", "socket_write_failed")
	}
	return ok
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
		// Update last_seen in persistent storage
		if agents[idx].agent_token != "" {
			auth_db_update_last_seen(agents[idx].agent_token, agents[idx].last_seen_unix_ms)
		}
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

// teams-v2: identity is decoupled from project. Role/class is NOT derived by
// splitting on '@' anymore; role comes from the agent's template role_hint.
// This helper is retained only as a last-resort fallback label when no template
// is known (e.g. reserved identities). It returns the whole id, minus any
// cosmetic '@'-suffix used by reserved ids like operator@local.
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

// teams-v2: an agent_instance_id is a project-free slug of [a-zA-Z0-9-].
// Reserved identities (operator@local, user_proxy) are the ONLY ids permitted to
// contain '@'; they are accepted here but must not be creatable via /agents/create
// (see agent_instance_id_is_reserved).
agent_instance_id_is_reserved :: proc(agent_instance_id: string) -> bool {
	return agent_instance_id == "operator@local" || agent_instance_id == "user_proxy"
}

valid_agent_instance_id :: proc(agent_instance_id: string) -> bool {
	if agent_instance_id_is_reserved(agent_instance_id) do return true
	return valid_agent_id_part(agent_instance_id)
}

// teams-v2: conversation id stays PER-INSTANCE. A running instance intentionally
// serves multiple task chains concurrently, so its conversation is the instance's
// single stream (not per-chain). This preserves existing message-provider behavior.
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
	return agents[idx].connected && agents[idx].has_ws && agents[idx].startup_status == "ready" && now - agents[idx].last_seen_unix_ms < DUPLICATE_HEARTBEAT_FRESH_MS
}


registry_list_json :: proc() -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agents":[`)
	for i in 0..<agent_count {
		if i > 0 do strings.write_byte(&builder, ',')
		a := agents[i]
		strings.write_string(&builder, `{"agent_instance_id":"`); json_write_string(&builder, a.agent_instance_id)
		strings.write_string(&builder, `","agent_class":"`); json_write_string(&builder, a.agent_class)
		strings.write_string(&builder, `","conversation_id":"`); json_write_string(&builder, a.conversation_id)
		strings.write_string(&builder, `","display_name":"`); json_write_string(&builder, a.display_name)
		strings.write_string(&builder, fmt.tprintf(`","connected":%v,"has_ws":%v,"last_seen_unix_ms":%d`, a.connected, a.has_ws, a.last_seen_unix_ms))
		strings.write_string(&builder, `,"startup_status":"`); json_write_string(&builder, a.startup_status)
		strings.write_string(&builder, `","activity_status":"`); json_write_string(&builder, a.activity_status)
		strings.write_string(&builder, `","activity_source":"`); json_write_string(&builder, a.activity_source)
		strings.write_string(&builder, `","activity_checked_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", a.activity_checked_unix_ms))
		strings.write_string(&builder, `,"provider_profile":"`); json_write_string(&builder, a.provider_profile)
		strings.write_string(&builder, `","provider_tier":"`); json_write_string(&builder, a.provider_tier)
		strings.write_string(&builder, `","project_id":"`); json_write_string(&builder, a.project_id)
		strings.write_string(&builder, `"}`)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}
