package bridge_runtime

import "core:net"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"

new_bridge_command_sink :: proc(registry: ^project_service.Bridge_Runtime_Registry) -> project_service.Bridge_Command_Sink {
	return project_service.Bridge_Command_Sink{ctx = rawptr(registry), validate_project_path = validate_project_path, send_runtime_command = send_runtime_command, send_runtime_command_wait = send_runtime_command_wait}
}

send_runtime_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	registry := (^project_service.Bridge_Runtime_Registry)(ctx)
	if !project_service.bridge_runtime_registry_has_live(registry, command.bridge_id) do return false, domain.domain_error(.Bridge_Offline, "bridge is not connected")
	socket, socket_ok := project_service.bridge_runtime_registry_command_socket(registry, command.bridge_id)
	if !socket_ok do return false, domain.domain_error(.Bridge_Offline, "bridge websocket command path is not connected")
	// Serialize with the runtime loop's ack writes so the frame isn't interleaved.
	project_service.bridge_runtime_registry_command_lock(registry)
	wrote := write_ws_text_frame(socket, command.body_json)
	project_service.bridge_runtime_registry_command_unlock(registry)
	if !wrote do return false, domain.domain_error(.Bridge_Offline, "bridge websocket command send failed")
	return true, domain.Domain_Error{}
}

send_runtime_command_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	registry := cast(^project_service.Bridge_Runtime_Registry)ctx
	if !project_service.bridge_runtime_registry_has_live(registry, command.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, "bridge is not connected")
	socket, socket_ok := project_service.bridge_runtime_registry_command_socket(registry, command.bridge_id)
	if !socket_ok do return "", false, domain.domain_error(.Bridge_Offline, "bridge websocket command path is not connected")
	// Serialize ONLY the frame write with the runtime loop's ack writes (so bytes
	// can't interleave on the shared socket). The lock is released before the poll
	// below — holding it across the wait would stall the loop's heartbeat/state acks
	// and could deadlock command delivery.
	project_service.bridge_runtime_registry_command_lock(registry)
	wrote := write_ws_text_frame(socket, command.body_json)
	project_service.bridge_runtime_registry_command_unlock(registry)
	if !wrote do return "", false, domain.domain_error(.Bridge_Offline, "bridge websocket command send failed")
	deadline := time.to_unix_nanoseconds(time.now()) + i64(time.Duration(timeout_ms) * time.Millisecond)
	// wait_id is a HEAP COPY of command.command_id, and it is load-bearing. Do not
	// "simplify" it back to comparing command.command_id directly.
	//
	// command.command_id is almost always platform.generate_id output, which is
	// fmt.tprintf memory: the PER-THREAD TEMP ALLOCATOR. The loop below re-reads that
	// string on every iteration for up to timeout_ms (10s at most call sites). The temp
	// allocator is a ring — once it wraps it hands back the same bytes and reuses them
	// IN PLACE — so any allocation occurring inside this loop could rewrite the id while
	// we were still comparing against it. The failure would not be a crash or a failing
	// test: the compare would silently stop matching, the command's reply would never be
	// recognised, and the call would time out after 10s, intermittently and only under
	// enough load to wrap the ring.
	//
	// Comparing a heap copy makes that impossible rather than merely prevented, which is
	// why this is a clone and not a comment telling you to avoid allocating in the loop.
	// The loop is now free to allocate; no future edit here can reintroduce the defect.
	//
	// WHY THE CLONE SITS HERE AND NOT AT PROCEDURE ENTRY: it is placed after the
	// socket lookup, the locked frame write and the deadline computation so the
	// bridge-offline and send-failure paths — which never reach the loop — neither
	// allocate nor free. That placement is SAFE ONLY BECAUSE nothing between
	// procedure entry and this line advances the per-thread temp ring: registry
	// has_live/command_socket do string compares over a fixed array, the command
	// lock/unlock are bare sync calls, time.now is arithmetic, and
	// write_ws_text_frame (below in this file) allocates its frame with a bare
	// make([]byte, ...) — i.e. on context.allocator (HEAP), not
	// context.temp_allocator. (Trace established by reviewer #46 under REQ-ALLOC-2;
	// deliberately cited by procedure name rather than line number, which rots.)
	//
	// That makes the argument CONDITIONAL, which is why it is written down: if
	// write_ws_text_frame is ever switched to the temp allocator, a wrap could occur
	// BEFORE this line and we would faithfully clone already-corrupted bytes. The
	// clone would still be here, still read as correct, and protect nothing — and no
	// test would fail, because nothing at this site would have changed.
	wait_id := strings.clone(command.command_id)
	defer delete(wait_id)
	for time.to_unix_nanoseconds(time.now()) < deadline {
		// runtime_command_cached takes the command lock internally (brief), then we
		// sleep OUTSIDE the lock.
		if cached, ok := runtime_command_cached(registry, wait_id); ok do return cached, true, domain.Domain_Error{}
		time.sleep(25 * time.Millisecond)
	}
	return "", false, domain.domain_error(.Bridge_Offline, "bridge websocket command timed out")
}

validate_project_path :: proc(ctx: rawptr, command: project_service.Validate_Project_Path_Command) -> (project_service.Project_Path_Validation_Result, bool, domain.Domain_Error) {
	registry := (^project_service.Bridge_Runtime_Registry)(ctx)
	if !project_service.bridge_runtime_registry_has_live(registry, command.bridge_id) do return project_service.Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge is not connected")
	ws_url := project_service.bridge_runtime_registry_path_validation_url(registry, command.bridge_id)
	if ws_url == "" do return project_service.Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge websocket command path is not connected")
	if command.type != "validate_project_path" do return project_service.Project_Path_Validation_Result{}, false, domain.domain_error(.Internal_Error, "unexpected bridge command type")
	if cached, cached_ok := runtime_command_cached(registry, command.command_id); cached_ok do return parse_validation_result(command, cached), true, domain.Domain_Error{}
	result, ok, err := send_validate_project_path_command(ws_url, command)
	if ok { _, _ = runtime_command_result_idempotent(registry, command.bridge_id, command.command_id, validation_result_json(result)) }
	return result, ok, err
}

send_validate_project_path_command :: proc(ws_url: string, command: project_service.Validate_Project_Path_Command) -> (project_service.Project_Path_Validation_Result, bool, domain.Domain_Error) {
	conn, conn_ok := ws.connect(ws_url)
	if !conn_ok do return project_service.Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge websocket command connect failed")
	defer ws.close(&conn)
	body := strings.concatenate({"{\"type\":\"validate_project_path\",\"command_id\":\"", command.command_id, "\",\"project_id\":\"", string(command.project_id), "\",\"bridge_id\":\"", command.bridge_id, "\",\"path\":\"", command.path, "\",\"vcs_kind\":\"", command.vcs_kind, "\",\"repo_url\":\"", command.repo_url, "\"}"})
	if !ws.send_text(&conn, body) do return project_service.Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge websocket command send failed")
	deadline := time.to_unix_nanoseconds(time.now()) + i64(3 * time.Second)
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if text, ok := ws.poll_text(&conn); ok {
			if json_string(text, "type") == "project_path_validation_result" && json_string(text, "command_id") == command.command_id {
				return parse_validation_result(command, text), true, domain.Domain_Error{}
			}
		}
		time.sleep(25 * time.Millisecond)
	}
	return project_service.Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge websocket validation timed out")
}

validation_result_json :: proc(result: project_service.Project_Path_Validation_Result) -> string {
	return strings.concatenate({"{\"type\":\"project_path_validation_result\",\"command_id\":\"", result.command_id, "\",\"ok\":", "true" if result.ok else "false", ",\"validation_error\":\"", result.validation_error, "\",\"details\":", result.details_json, "}"})
}

parse_validation_result :: proc(command: project_service.Validate_Project_Path_Command, text: string) -> project_service.Project_Path_Validation_Result {
	ok := json_bool(text, "ok")
	message := json_string(text, "validation_error")
	error_code := json_string(text, "code")
	if !ok && message == "" do message = json_string(text, "message")
	if !ok && error_code == "" do error_code = "validation_failed"
	return validation_result(command, ok, error_code, message)
}

validation_result :: proc(command: project_service.Validate_Project_Path_Command, ok: bool, error_code, message: string) -> project_service.Project_Path_Validation_Result {
	details: string
	validation_error := ""
	if ok {
		details = strings.concatenate({"{\"transport\":\"bridge_ws\",\"command\":\"validate_project_path\",\"bridge_id\":\"", command.bridge_id, "\",\"vcs_kind\":\"", command.vcs_kind, "\",\"command_id\":\"", command.command_id, "\"}"})
	} else {
		validation_error = message
		details = strings.concatenate({"{\"transport\":\"bridge_ws\",\"command\":\"validate_project_path\",\"bridge_id\":\"", command.bridge_id, "\",\"command_id\":\"", command.command_id, "\",\"error\":{\"code\":\"", error_code, "\",\"message\":\"", message, "\"}}"})
	}
	return project_service.Project_Path_Validation_Result{type = "project_path_validation_result", command_id = command.command_id, project_id = command.project_id, path = command.path, ok = ok, validation_error = validation_error, details_json = details}
}

write_ws_text_frame :: proc(socket: net.TCP_Socket, text: string) -> bool {
	n := len(text)
	if n > 65535 do return false
	header_len := 2
	if n > 125 do header_len = 4
	frame := make([]byte, header_len + n)
	frame[0] = 0x81
	if n <= 125 { frame[1] = byte(n) } else { frame[1] = 126; frame[2] = byte((n >> 8) & 0xff); frame[3] = byte(n & 0xff) }
	copy(frame[header_len:], transmute([]byte)text)
	sent_bytes := 0
	for sent_bytes < len(frame) {
		n_written, err := net.send_tcp(socket, frame[sent_bytes:])
		if err != nil do return false
		if n_written == 0 do break
		sent_bytes += n_written
	}
	return sent_bytes == len(frame)
}

json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:]); if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

json_bool :: proc(body, key: string) -> bool {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return false
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return false
	rest = strings.trim_space(rest[colon + 1:])
	return strings.has_prefix(rest, "true")
}
