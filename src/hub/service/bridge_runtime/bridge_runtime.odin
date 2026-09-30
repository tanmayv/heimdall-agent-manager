package bridge_runtime

import "core:net"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"
import "odin_test:contracts"

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
	wrote := write_ws_command(socket, command.body_json)
	project_service.bridge_runtime_registry_command_unlock(registry)
	if wrote != .Ok do return false, command_write_error(wrote)
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
	wrote := write_ws_command(socket, command.body_json)
	project_service.bridge_runtime_registry_command_unlock(registry)
	if wrote != .Ok do return "", false, command_write_error(wrote)
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
	// lock/unlock are bare sync calls, time.now is arithmetic, and the whole write
	// path is heap-only. (Trace established by reviewer #46 under REQ-ALLOC-2;
	// deliberately cited by procedure name rather than line number, which rots.)
	//
	// RE-ESTABLISHED FOR THE CHUNKED WRITE PATH (REQ-SHELL-36). The write is no longer
	// one procedure: write_ws_command may now fan out into hub_command_chunk_frames ->
	// base64.encode + hub_command_chunk_json + hub_chunk_next_id, and every one of
	// those had to be checked, not assumed. They allocate via make([]byte, ...),
	// base64.encode, strings.builder_make/to_string and strings.concatenate — all on
	// context.allocator (HEAP). Integers go through strconv.write_int into STACK
	// buffers SPECIFICALLY so that this argument survives; hub_command_chunk.odin's
	// header says so, because fmt.tprintf is the obvious way to write that code and it
	// would break this silently.
	//
	// That makes the argument CONDITIONAL, which is why it is written down: if any
	// procedure on the write path is ever switched to the temp allocator, a wrap could
	// occur BEFORE this line and we would faithfully clone already-corrupted bytes. The
	// clone would still be here, still read as correct, and protect nothing — and no
	// test would fail, because nothing at this site would have changed. The chunked
	// path widened the surface this depends on from one procedure to five.
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
	if ok {
		// REQ-SHELL-36 AC4 audit: CONDITIONALLY owned, which is why this is four lines
		// and not one. runtime_command_result_idempotent stores result_json in the
		// registry ring and returns already_cached=false; on already_cached=true it
		// returns the FIRST result for this id and never takes ours — so the string we
		// just built is ours to free, and previously was not freed at all.
		//
		// Do NOT "simplify" this to an unconditional delete: on the false branch the
		// registry now holds the only reference and callers read it back out of the ring
		// (runtime_command_cached -> send_runtime_command_wait), so freeing it there
		// would be a use-after-free rather than a leak.
		result_json := validation_result_json(result)
		if _, already_cached := runtime_command_result_idempotent(registry, command.bridge_id, command.command_id, result_json); already_cached {
			delete(result_json)
		}
	}
	return result, ok, err
}

send_validate_project_path_command :: proc(ws_url: string, command: project_service.Validate_Project_Path_Command) -> (project_service.Project_Path_Validation_Result, bool, domain.Domain_Error) {
	conn, conn_ok := ws.connect(ws_url)
	if !conn_ok do return project_service.Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge websocket command connect failed")
	defer ws.close(&conn)
	// REQ-SHELL-36 AC4 audit: `body` leaked on every path validation — built here,
	// handed to ws.send_text (which only borrows it) and never freed. Same class as the
	// frame leak below: a persistent/background path with no per-request arena behind it.
	body := strings.concatenate({"{\"type\":\"validate_project_path\",\"command_id\":\"", command.command_id, "\",\"project_id\":\"", string(command.project_id), "\",\"bridge_id\":\"", command.bridge_id, "\",\"path\":\"", command.path, "\",\"vcs_kind\":\"", command.vcs_kind, "\",\"repo_url\":\"", command.repo_url, "\"}"})
	defer delete(body)
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

// Command_Write_Result says WHICH failure happened, because "this frame cannot be
// encoded" and "this socket is gone" are different conditions with different recovery
// and a bool cannot tell them apart. REQ-SHELL-36: collapsing them is exactly what made
// an oversized command surface as .Bridge_Offline — an operator chasing "bridge offline"
// looks at the bridge, the network and the token long before they look at a frame size.
Command_Write_Result :: enum {
	Ok,
	// The payload cannot be carried even chunked: it exceeds the reassembly caps the
	// bridge enforces. A statement about THIS COMMAND, never about the connection.
	Too_Large,
	// The socket write failed or could not complete. The bridge really has stopped
	// taking bytes, so .Bridge_Offline is the honest mapping for this one.
	Send_Failed,
}

// write_ws_command writes one hub->bridge command, CHUNKING it when it does not fit in
// a single 16-bit-length WS frame. This is the hub->bridge half of the protocol whose
// bridge->hub half has existed since REQ-SHELL-32; see hub_command_chunk.odin for why
// chunking rather than a 64-bit length arm, and for the frame shape.
//
// >>> THE CALLER MUST HOLD THE REGISTRY COMMAND LOCK ACROSS THIS CALL. <<<
// Both call sites do, and for a reason that got stricter when chunking landed. The lock
// used to buy only BYTE-level serialisation: the runtime loop's ack writes must not
// interleave bytes inside one frame. It now also buys SEQUENCE-level serialisation:
// the bridge reassembles by chunk_id, so another command's CHUNKS must not appear
// between this sequence's chunks. Whole non-chunk frames landing between two chunks are
// fine and always were — the bridge passes those straight through while a reassembly is
// in flight — but a second interleaved SEQUENCE would have both streams open at once and
// is what the lock now prevents. This is the same pairing the bridge side documents on
// _bridge_hub_send_mu, reached from the other direction.
//
// ACK-LESS, deliberately, matching the other direction: this channel has no chunk_ack
// path, and a single ordered connection with the lock held means the bridge sees the
// chunks in order anyway, so per-chunk acks would be pure latency.
write_ws_command :: proc(socket: net.TCP_Socket, text: string) -> Command_Write_Result {
	payload := contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES
	// Fits whole. Nothing to reassemble, so the bridge never sees a chunk frame for the
	// overwhelming majority of commands. Same condition hub_command_chunk_frames uses to
	// return nil, tested here so the two branches below are explicit.
	if len(text) <= payload {
		if !write_ws_text_frame(socket, text) do return .Send_Failed
		return .Ok
	}
	// REFUSED BEFORE THE FRAMES ARE BUILT, and the order is the point: an over-cap
	// command is rejected without allocating anything. Checking after the split would
	// have built and immediately discarded thousands of frames for a payload that was
	// never deliverable (at 6000 bytes a chunk, the 16 MB byte cap is ~2731 frames and
	// the 4096-chunk cap is ~24.5 MB) — wasteful on the exact path where the payload is
	// already known to be enormous. Placed after the fits-whole test above so the caps
	// bound what must actually be REASSEMBLED rather than every command.
	if !hub_command_is_chunkable(text, payload) do return .Too_Large
	frames := hub_command_chunk_frames(text, payload)
	if frames == nil do return .Send_Failed // unreachable: len(text) > payload > 0
	defer {
		for f in frames do delete(f)
		delete(frames)
	}
	// Stop on the first failed write but keep freeing (the defer above owns that).
	// A half-sent sequence is a dropped command, not a corrupted one: the bridge holds
	// an incomplete reassembly that never dispatches and expires on its own.
	for f in frames {
		if !write_ws_text_frame(socket, f) do return .Send_Failed
	}
	return .Ok
}

// write_ws_text_frame writes ONE unmasked FIN+text frame, 16-bit length only.
//
// The >65535 refusal is NOT a missing protocol case to be fixed here — see
// hub_command_chunk.odin. Callers must route through write_ws_command, which keeps
// every frame reaching this procedure under the cap.
write_ws_text_frame :: proc(socket: net.TCP_Socket, text: string) -> bool {
	n := len(text)
	if n > 65535 do return false
	header_len := 2
	if n > 125 do header_len = 4
	frame := make([]byte, header_len + n)
	// REQ-SHELL-36 AC4: `frame` used to leak on EVERY hub->bridge command. This path is
	// not an HTTP request thread — it has no per-request virtual arena to reclaim it —
	// so a persistent-path allocation must be freed explicitly. One defer covers both
	// leaking exits (the err return and the final return); the >65535 refusal above sits
	// ABOVE the make and never leaked, so it needs nothing.
	defer delete(frame)
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

// command_write_error maps a write result onto the domain error the API returns.
//
// AC1 LIVES HERE. .Too_Large becomes .Validation_Failed, which is HTTP 400 with code
// string "validation_failed"; .Send_Failed keeps .Bridge_Offline, which is HTTP 409 with
// "bridge_offline". Different status AND different code string, so the two are
// distinguishable in a log line rather than only in prose — which is the whole point,
// since the defect was an operator being pointed at a healthy bridge.
command_write_error :: proc(result: Command_Write_Result) -> domain.Domain_Error {
	switch result {
	case .Ok:
		return domain.Domain_Error{}
	case .Too_Large:
		return domain.domain_error(.Validation_Failed, "bridge command payload exceeds the chunked-delivery limit for the hub->bridge channel; the bridge is NOT offline")
	case .Send_Failed:
		return domain.domain_error(.Bridge_Offline, "bridge websocket command send failed")
	}
	return domain.domain_error(.Internal_Error, "unknown bridge command write result")
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
