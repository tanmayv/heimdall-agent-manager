package shell_session

// Hub-side shell session service: WS fan-out registry (T7) + CRUD operations,
// bridge command dispatch, preview token store (T5).

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// Preview_Tunnel_Stream is an in-flight hub-side tunnel stream.
// Chunks are signalled via cond as they arrive; the proxy handler wakes and relays them.
Preview_Tunnel_Stream :: struct {
	mu:     sync.Mutex,
	cond:   sync.Cond,
	chunks: [dynamic][]byte,
	closed: bool,
}

Shell_Session_Service :: struct {
	// WS fan-out registry (T7) — protected by mu.
	mu:      sync.Mutex,
	viewers: map[string][dynamic]net.TCP_Socket, // session_id → attached WS client sockets
	// CRUD layer (T5) — session_owners also protected by mu.
	repo:                ^iface.Shell_Session_Repository,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	events:              ^events.User_Event_Bus,
	ids:                 ^platform.ID_Generator,
	clock:               ^platform.Clock,
	session_owners:      map[string]string, // session_id → owner_user_id (heap strings)
	// Tunnel stream registry (T8) — protected by tunnel_mu.
	tunnel_streams: map[string]^Preview_Tunnel_Stream, // stream_id → live stream
	tunnel_mu:      sync.Mutex,
}

new_shell_session_service :: proc(
	repo:                ^iface.Shell_Session_Repository = nil,
	bridge_command_sink: project_service.Bridge_Command_Sink = {},
	event_bus:           ^events.User_Event_Bus = nil,
	ids:                 ^platform.ID_Generator = nil,
	clock:               ^platform.Clock = nil,
) -> Shell_Session_Service {
	heap := runtime.heap_allocator()
	return Shell_Session_Service{
		viewers        = make(map[string][dynamic]net.TCP_Socket, heap),
		repo            = repo,
		bridge_command_sink = bridge_command_sink,
		events          = event_bus,
		ids             = ids,
		clock           = clock,
		session_owners  = make(map[string]string, heap),
		tunnel_streams  = make(map[string]^Preview_Tunnel_Stream, heap),
	}
}

shell_session_service_free :: proc(svc: ^Shell_Session_Service) {
	if svc == nil do return
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	for _, viewers in svc.viewers do delete(viewers)
	delete(svc.viewers)
	for k, v in svc.session_owners { delete(k); delete(v) }
	delete(svc.session_owners)
	sync.mutex_lock(&svc.tunnel_mu)
	defer sync.mutex_unlock(&svc.tunnel_mu)
	for k, stream in svc.tunnel_streams {
		delete(k)
		for chunk in stream.chunks do delete(chunk)
		delete(stream.chunks)
		free(stream)
	}
	delete(svc.tunnel_streams)
}

// --- WS attach/detach (T7, unchanged) ---

shell_session_attach :: proc(svc: ^Shell_Session_Service, session_id: string, socket: net.TCP_Socket) {
	if svc == nil || session_id == "" do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	if _, ok := svc.viewers[session_id]; !ok {
		svc.viewers[strings.clone(session_id, heap)] = make([dynamic]net.TCP_Socket, heap)
	}
	append(&svc.viewers[session_id], socket)
}

shell_session_detach :: proc(svc: ^Shell_Session_Service, session_id: string, socket: net.TCP_Socket) {
	if svc == nil || session_id == "" do return
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	viewers, ok := &svc.viewers[session_id]
	if !ok do return
	for i := 0; i < len(viewers); i += 1 {
		if viewers[i] == socket {
			ordered_remove(viewers, i)
			break
		}
	}
}

// shell_session_broadcast_output fans PTY output (already base64-encoded by the bridge)
// to all WS clients attached to session_id.
shell_session_broadcast_output :: proc(svc: ^Shell_Session_Service, session_id, data_b64: string) {
	if svc == nil || session_id == "" do return
	sockets := _copy_viewers(svc, session_id)
	defer delete(sockets)
	if len(sockets) == 0 do return
	frame := _output_frame_json(data_b64)
	defer delete(frame)
	for sock in sockets do _write_ws_text(sock, frame)
}

// shell_session_broadcast_status fans a status-change event to all attached clients.
shell_session_broadcast_status :: proc(svc: ^Shell_Session_Service, session_id, status: string, exit_code: int, exit_code_set: bool) {
	if svc == nil || session_id == "" do return
	sockets := _copy_viewers(svc, session_id)
	defer delete(sockets)
	if len(sockets) == 0 do return
	frame := _status_frame_json(status, exit_code, exit_code_set)
	defer delete(frame)
	for sock in sockets do _write_ws_text(sock, frame)
}

// --- CRUD service procs (T5) ---

Shell_Session_Create_Input :: struct {
	bridge_id:         string,
	kind:              string, // "agent" | "interactive" | "server" | "command"
	cmd:               string,
	cwd:               string,
	label:             string,
	project_id:        string,
	chain_id:          string,
	agent_instance_id: string,
	server_port:       int,
}

// shell_session_create creates a hub row with status=starting, sends shell_start to
// the bridge, and updates the row to running/failed based on the bridge reply.
shell_session_create :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, input: Shell_Session_Create_Input) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	if input.bridge_id == "" do return {}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")

	kind := input.kind
	if kind == "" do kind = "command"
	// Interactive sessions may omit cmd; the bridge falls back to $SHELL.
	if input.cmd == "" && kind != "interactive" do return {}, false, domain.domain_error(.Validation_Failed, "cmd is required")

	now := platform.clock_now(svc.clock)
	session_id := platform.generate_id(svc.ids, "sh_")

	session := domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = string(owner),
		bridge_id         = input.bridge_id,
		project_id        = input.project_id,
		chain_id          = input.chain_id,
		agent_instance_id = input.agent_instance_id,
		kind              = kind,
		label             = input.label,
		cmd               = input.cmd,
		cwd               = input.cwd,
		status            = domain.Shell_Session_Status_Starting,
		server_port       = input.server_port,
		started_at        = now,
		created_at        = now,
		last_activity_at  = now,
	}

	_, upsert_err := iface.shell_session_upsert(svc.repo, session)
	if upsert_err.code != .None do return {}, false, upsert_err

	// Track owner for handle_exited (heap-allocated key + value).
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	svc.session_owners[strings.clone(session_id, heap)] = strings.clone(string(owner), heap)
	sync.mutex_unlock(&svc.mu)

	// Send shell_start to bridge and wait for reply.
	cmd_id := platform.generate_id(svc.ids, "cmd_sh_start_")
	cmd_json := _shell_start_command_json(cmd_id, session_id, kind, input.cmd, input.cwd, input.label, input.project_id, input.chain_id, input.agent_instance_id, string(owner), input.server_port)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{
			bridge_id  = input.bridge_id,
			command_id = cmd_id,
			body_json  = cmd_json,
		},
		30_000,
	)
	delete(cmd_id)

	if !reply_ok {
		session.status = domain.Shell_Session_Status_Failed
		_, _ = iface.shell_session_upsert(svc.repo, session)
		return session, false, reply_err
	}
	defer delete(reply)

	if !_json_bool(reply, "ok") {
		session.status = domain.Shell_Session_Status_Failed
		_, _ = iface.shell_session_upsert(svc.repo, session)
		return session, false, domain.domain_error(.Internal_Error, "bridge failed to start shell session")
	}

	session.status          = domain.Shell_Session_Status_Running
	session.pid             = _json_int(reply, "pid", 0)
	session.last_activity_at = platform.clock_now(svc.clock)
	_, _ = iface.shell_session_upsert(svc.repo, session)
	return session, true, domain.Domain_Error{}
}

// shell_session_kill sends shell_kill to the bridge (fire-and-forget).
shell_session_kill :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return false, repo_err
	if !found do return false, domain.domain_error(.Not_Found, "session not found")
	if domain.shell_session_is_terminal(session) do return false, domain.domain_error(.Conflict, "session has already terminated")

	cmd_json := _shell_kill_command_json(session_id)
	defer delete(cmd_json)
	sent, send_err := project_service.bridge_command_send_runtime(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

// shell_session_signal sends shell_signal to the bridge (fire-and-forget).
shell_session_signal :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string, signal: int) -> (bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return false, repo_err
	if !found do return false, domain.domain_error(.Not_Found, "session not found")

	cmd_json := _shell_signal_command_json(session_id, signal)
	defer delete(cmd_json)
	sent, send_err := project_service.bridge_command_send_runtime(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

// shell_session_restart sends shell_restart to the bridge and updates the row.
shell_session_restart :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return {}, false, repo_err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_restart_")
	cmd_json := _shell_restart_command_json(cmd_id, session_id)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		30_000,
	)
	delete(cmd_id)

	if !reply_ok do return session, false, reply_err
	defer delete(reply)

	if !_json_bool(reply, "ok") do return session, false, domain.domain_error(.Internal_Error, "bridge failed to restart shell session")

	session.status           = domain.Shell_Session_Status_Running
	session.pid              = _json_int(reply, "pid", session.pid)
	session.finished_at      = ""
	session.last_activity_at = platform.clock_now(svc.clock)
	_, _ = iface.shell_session_upsert(svc.repo, session)
	return session, true, domain.Domain_Error{}
}

// Shell_Session_Max_Port is the highest TCP port a session may declare.
Shell_Session_Max_Port :: 65535

// Shell_Session_Set_Port_Timeout_Ms bounds the bridge round trip shell_session_set_port
// blocks an HTTP handler on. See the call site for why it is shorter than the 30s the
// spawn paths use.
Shell_Session_Set_Port_Timeout_Ms :: 10_000

// shell_session_set_port declares (or, with port 0, clears) the server port of a
// session that is ALREADY RUNNING — the XM-9 case where you open a terminal and
// only then decide to run a server in it.
//
// It updates the bridge BEFORE the hub row, and persists only on a successful
// bridge reply. That ordering is the point of the whole change: the bridge
// re-validates server_port against its own copy of the session when a tunnel is
// opened (bridge_hub_handle_tunnel_open), so a hub row updated on its own would
// advertise a port the bridge then refused. Going bridge-first also means a
// success returned here is "reachable now", not "reachable once something
// catches up" — which is what makes changing an already-set port take effect
// immediately rather than racing a stale copy.
//
// The port is still never read from a dial-time request; this changes only how
// the session RECORD gets its value.
shell_session_set_port :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	if server_port < 0 || server_port > Shell_Session_Max_Port {
		return {}, false, domain.domain_error(.Validation_Failed, "server_port must be between 1 and 65535, or 0 to clear it")
	}

	// Owner-scoped lookup: a session belonging to someone else is Not_Found
	// rather than Forbidden, so this does not disclose that it exists.
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return {}, false, repo_err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")
	if domain.shell_session_is_terminal(session) {
		return session, false, domain.domain_error(.Conflict, "session has already terminated")
	}

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_set_port_")
	cmd_json := _shell_set_port_command_json(cmd_id, session_id, server_port)
	defer delete(cmd_json)

	// 10s, not the 30s the spawn/restart paths use. A bridge is offline as an
	// ordinary matter, and this call blocks an HTTP handler, so the wait has to be
	// bounded tightly: setting a field on a live in-memory record is a round trip,
	// not a process spawn, so anything near 10s already means the bridge is gone.
	// The wait is bounded by the sink itself and an unreachable bridge fails
	// IMMEDIATELY (Bridge_Offline, before the wait starts) rather than burning the
	// full timeout — see send_runtime_command_wait.
	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		Shell_Session_Set_Port_Timeout_Ms,
	)
	delete(cmd_id)

	if !reply_ok {
		// Offline and timed-out both arrive as Bridge_Offline; keep that code — it is
		// the vocabulary the rest of the shell surface already uses — but say plainly
		// that NOTHING changed, which is the fact the caller needs in order to act.
		// Nothing has been written at this point: the hub row still holds whatever it
		// held, so a retry is safe and the session's reachability is unaltered.
		return session, false, domain.domain_error(reply_err.code, _set_port_unreachable_message(reply_err))
	}
	defer delete(reply)

	if !_json_bool(reply, "ok") {
		// The bridge answers with the shared refusal vocabulary
		// (session_not_found / session_not_running); surface it rather than a
		// generic failure, so the reason is the same word end to end.
		reason := _json_str(reply, "error")
		defer delete(reason)
		if reason == "session_not_running" {
			return session, false, domain.domain_error(.Conflict, "session has already terminated")
		}
		if reason == "session_not_found" {
			return session, false, domain.domain_error(.Not_Found, "session not found")
		}
		return session, false, domain.domain_error(.Internal_Error, "bridge failed to set the shell session port")
	}

	// Not an upsert: it keeps the existing port when the new one is 0, so
	// clearing would silently do nothing. See Shell_Session_Set_Server_Port_Proc.
	written, write_err := iface.shell_session_set_server_port(svc.repo, string(owner), session_id, server_port)
	if write_err.code != .None do return session, false, write_err
	if !written do return session, false, domain.domain_error(.Not_Found, "session not found")

	session.server_port = server_port
	return session, true, domain.Domain_Error{}
}

// shell_session_get returns a session owned by the authenticated user.
shell_session_get :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return {}, false, repo_err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")
	return session, true, domain.Domain_Error{}
}

// shell_session_list_by_bridge lists sessions on a specific bridge owned by the caller.
shell_session_list_by_bridge :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, bridge_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, "", err
	return iface.shell_session_list_by_bridge(svc.repo, string(owner), bridge_id, status_filter, cursor, limit)
}

// shell_session_list_by_project lists sessions for a specific project owned by the caller.
shell_session_list_by_project :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, project_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, "", err
	return iface.shell_session_list_by_project(svc.repo, string(owner), project_id, status_filter, cursor, limit)
}

// shell_session_list_by_chain lists sessions for a specific task chain owned by the caller.
shell_session_list_by_chain :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, "", err
	return iface.shell_session_list_by_chain(svc.repo, string(owner), chain_id, status_filter, cursor, limit)
}

Shell_Session_Log_Result :: struct {
	lines_raw:   string, // raw JSON array (caller must delete)
	truncated:   bool,
	total_lines: int,
}

// shell_session_get_log fetches log lines from the bridge for the session.
shell_session_get_log :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string, offset, limit_val: int, grep: string) -> (Shell_Session_Log_Result, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	session, found, err := shell_session_get(svc, auth, session_id)
	if err.code != .None do return {}, false, err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")

	lim := limit_val
	if lim <= 0 do lim = 100

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_logs_")
	cmd_json := _shell_logs_command_json(cmd_id, session_id, offset, lim, grep)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		30_000,
	)
	delete(cmd_id)

	if !reply_ok do return {}, false, reply_err
	defer delete(reply)

	if !_json_bool(reply, "ok") do return {}, false, domain.domain_error(.Internal_Error, "bridge failed to retrieve shell logs")

	lines_raw   := _json_array_raw(reply, "lines")
	truncated   := _json_bool(reply, "truncated")
	total_lines := _json_int(reply, "total_lines", 0)
	return Shell_Session_Log_Result{lines_raw = lines_raw, truncated = truncated, total_lines = total_lines}, true, domain.Domain_Error{}
}

Shell_Session_Capture_Result :: struct {
	content: string, // caller must delete
	rows:    int,
	cols:    int,
}

// shell_session_capture requests a PTY screen snapshot from the bridge.
shell_session_capture :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (Shell_Session_Capture_Result, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	session, found, err := shell_session_get(svc, auth, session_id)
	if err.code != .None do return {}, false, err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_capture_")
	cmd_json := _shell_capture_command_json(cmd_id, session_id)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		30_000,
	)
	delete(cmd_id)

	if !reply_ok do return {}, false, reply_err
	defer delete(reply)

	if !_json_bool(reply, "ok") do return {}, false, domain.domain_error(.Internal_Error, "bridge failed to capture shell session")

	content := _json_str(reply, "content")
	rows    := _json_int(reply, "rows", 24)
	cols    := _json_int(reply, "cols", 80)
	return Shell_Session_Capture_Result{content = content, rows = rows, cols = cols}, true, domain.Domain_Error{}
}

// shell_session_pane_terminal_status reports whether a session has reached a terminal
// state, in which case there is nothing live to capture and the pane must not cost a
// bridge round trip. Mirrors the agent pane's stopped/failed short-circuit
// (agent_service.get_instance_pane).
shell_session_pane_terminal_status :: proc(status: string) -> bool {
	return status == "exited" || status == "killed" || status == "failed"
}

// shell_session_get_pane returns a polled screen snapshot for an interactive shell
// session (REQ-PTY-STREAM-1), diffed against since_hash by the bridge so an idle screen
// costs an empty reply. This is the shell twin of agent_service.get_instance_pane and
// returns the identical payload shape {ok,unchanged,hash,output,line_count,truncated}.
//
// Owner scoping runs through shell_session_get (owner_from_auth + owner-keyed repo
// lookup), the same auth-scoped getter every other shell endpoint uses.
//
// The 5s bridge timeout is deliberate and differs from shell_session_capture's 30s: this
// command is polled twice a second while a pane is open, so a long timeout would let
// pending commands pile up under bridge slowness.
shell_session_get_pane :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id, since_hash: string, width, line_limit: int) -> (string, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return "", false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	session, found, err := shell_session_get(svc, auth, session_id)
	if err.code != .None do return "", false, err
	if !found do return "", false, domain.domain_error(.Not_Found, "session not found")

	// Terminal session: answer locally, never touch the bridge.
	if shell_session_pane_terminal_status(session.status) {
		b := strings.builder_make()
		strings.write_string(&b, "{\"ok\":true,\"status\":\"")
		contracts.write_json_string(&b, session.status)
		strings.write_string(&b, "\",\"unchanged\":true,\"hash\":\"\",\"output\":\"\"}")
		return strings.to_string(b), true, domain.Domain_Error{}
	}

	if strings.trim_space(session.bridge_id) == "" {
		return "", false, domain.domain_error(.Bridge_Offline, "shell session has no bridge")
	}

	w := width
	if w <= 0 do w = 80
	limit := line_limit
	if limit <= 0 do limit = 120

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_pane_")
	cmd_json := _shell_get_pane_command_json(cmd_id, session_id, since_hash, w, limit)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		5_000,
	)
	delete(cmd_id)

	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

// shell_session_handle_exited is called by bridge_handlers when a shell_exited event
// arrives from the bridge. It updates the hub DB row and publishes a push event.
//
// bridge_id is the authenticated id of the bridge the event arrived on. It is
// required: the row is only touched when it belongs to that same bridge, so a
// bridge cannot terminate the record of a session running on another bridge
// (and so, in practice, of another user). See the check below the lookup.
shell_session_handle_exited :: proc(svc: ^Shell_Session_Service, session_id, bridge_id, status: string, exit_code: int, exit_code_set: bool) {
	if svc == nil || svc.repo == nil || session_id == "" || bridge_id == "" do return

	// Remove the entry from session_owners under the lock, capturing the heap strings.
	sync.mutex_lock(&svc.mu)
	map_key: string
	map_val: string
	found_entry := false
	for k in svc.session_owners {
		if k == session_id {
			map_key = k
			map_val = svc.session_owners[k]
			delete_key(&svc.session_owners, k)
			found_entry = true
			break
		}
	}
	sync.mutex_unlock(&svc.mu)

	// Fast path frees remain exactly as before; they only apply when the map hit.
	defer if found_entry do delete(map_key)
	defer if found_entry do delete(map_val) // map_val is the owner_user_id

	owner:    string
	session:  domain.Shell_Session
	found:    bool
	repo_err: domain.Domain_Error

	if found_entry {
		owner = map_val
		session, found, repo_err = iface.shell_session_get(svc.repo, owner, session_id)
	} else {
		// session_owners is in-memory only and is never rehydrated from the DB,
		// so it is empty for every session created before the current hub
		// process. Dropping the event here left those rows stuck at "running"
		// forever — an unkillable ghost in the UI (REQ-RECON-5). Fall back to an
		// unscoped lookup to recover the owner from the row itself.
		//
		// Safe here and only here: the caller is a trusted bridge event with no
		// authenticated user to scope by. User-facing handlers keep using the
		// owner-scoped shell_session_get.
		session, found, repo_err = iface.shell_session_get_by_id(svc.repo, session_id)
		if found do owner = session.owner_user_id
	}
	if !found || repo_err.code != .None || owner == "" do return

	// Bridge scoping. Losing the owner check on the by-id path would otherwise let
	// ANY connected bridge terminate ANY user's session record by emitting
	// shell_exited with that session_id — session_owners used to make that
	// unreachable by accident, and the fallback above removes that accident. The
	// row names the bridge it runs on, so require the event to come from it.
	// Applied to both paths: a bridge has no business reporting an exit for a
	// session that is not its own either way.
	if session.bridge_id != bridge_id do return

	now := platform.clock_now(svc.clock)
	effective_status := status
	if effective_status == "" do effective_status = domain.Shell_Session_Status_Exited

	session.status           = effective_status
	session.finished_at      = now
	session.last_activity_at = now
	if exit_code_set {
		session.exit_code     = exit_code
		session.exit_code_set = true
	}

	_, _ = iface.shell_session_upsert(svc.repo, session)

	if svc.events != nil {
		evt := _shell_exited_event_json(session_id, effective_status, exit_code, exit_code_set)
		events.publish_owned(svc.events, owner, evt)
	}
}

// --- Tunnel stream registry (T8) ---

// shell_session_tunnel_register creates and registers a new in-flight tunnel stream.
// The returned pointer is valid until shell_session_tunnel_unregister is called.
shell_session_tunnel_register :: proc(svc: ^Shell_Session_Service, stream_id: string) -> ^Preview_Tunnel_Stream {
	heap := runtime.heap_allocator()
	stream := new(Preview_Tunnel_Stream, heap)
	stream.chunks = make([dynamic][]byte, heap)
	stream.closed = false
	sync.mutex_lock(&svc.tunnel_mu)
	svc.tunnel_streams[strings.clone(stream_id, heap)] = stream
	sync.mutex_unlock(&svc.tunnel_mu)
	return stream
}

// shell_session_tunnel_deliver appends a data chunk to a live tunnel stream.
// No-op if the stream is already closed or not found.
// tunnel_mu is held through the stream.mu section so that tunnel_unregister cannot
// free the stream between the map lookup and the stream.mu lock (UAF guard).
shell_session_tunnel_deliver :: proc(svc: ^Shell_Session_Service, stream_id: string, data: []byte) {
	if svc == nil || len(data) == 0 do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.tunnel_mu)
	stream, ok := svc.tunnel_streams[stream_id]
	if ok {
		chunk := make([]byte, len(data), heap)
		copy(chunk, data)
		sync.mutex_lock(&stream.mu)
		if !stream.closed {
			append(&stream.chunks, chunk)
			sync.cond_signal(&stream.cond)
		} else {
			delete(chunk, heap)
		}
		sync.mutex_unlock(&stream.mu)
	}
	sync.mutex_unlock(&svc.tunnel_mu)
}

// shell_session_tunnel_close_stream marks a tunnel stream as closed (all data delivered).
// tunnel_mu is held through stream.mu for the same UAF-safety reason as deliver.
shell_session_tunnel_close_stream :: proc(svc: ^Shell_Session_Service, stream_id: string) {
	if svc == nil do return
	sync.mutex_lock(&svc.tunnel_mu)
	stream, ok := svc.tunnel_streams[stream_id]
	if ok {
		sync.mutex_lock(&stream.mu)
		stream.closed = true
		sync.cond_signal(&stream.cond)
		sync.mutex_unlock(&stream.mu)
	}
	sync.mutex_unlock(&svc.tunnel_mu)
}

// shell_session_tunnel_unregister removes a tunnel stream and frees its resources.
// Must be called after the proxy handler has finished reading all chunks.
shell_session_tunnel_unregister :: proc(svc: ^Shell_Session_Service, stream_id: string) {
	if svc == nil do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.tunnel_mu)
	stream: ^Preview_Tunnel_Stream
	found := false
	for k in svc.tunnel_streams {
		if k == stream_id {
			stream = svc.tunnel_streams[k]
			delete_key(&svc.tunnel_streams, k)
			delete(k, heap)
			found = true
			break
		}
	}
	sync.mutex_unlock(&svc.tunnel_mu)
	if !found do return
	for chunk in stream.chunks do delete(chunk, heap)
	delete(stream.chunks)
	free(stream, heap)
}

// --- private helpers ---

_copy_viewers :: proc(svc: ^Shell_Session_Service, session_id: string) -> []net.TCP_Socket {
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	viewers, ok := svc.viewers[session_id]
	if !ok || len(viewers) == 0 do return nil
	out := make([]net.TCP_Socket, len(viewers))
	copy(out, viewers[:])
	return out
}

_output_frame_json :: proc(data_b64: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"output\",\"data_b64\":\"")
	contracts.write_json_string(&b, data_b64)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_status_frame_json :: proc(status: string, exit_code: int, exit_code_set: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"status\",\"status\":\"")
	contracts.write_json_string(&b, status)
	strings.write_string(&b, "\"")
	if exit_code_set {
		strings.write_string(&b, fmt.tprintf(",\"exit_code\":%d", exit_code))
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_write_ws_text :: proc(socket: net.TCP_Socket, text: string) -> bool {
	n := len(text)
	if n > 65535 do return false
	header_len := 2
	if n > 125 do header_len = 4
	frame := make([]byte, header_len + n)
	defer delete(frame)
	frame[0] = 0x81
	if n <= 125 {
		frame[1] = byte(n)
	} else {
		frame[1] = 126
		frame[2] = byte((n >> 8) & 0xff)
		frame[3] = byte(n & 0xff)
	}
	copy(frame[header_len:], transmute([]byte)text)
	_, err := net.send_tcp(socket, frame)
	return err == nil
}

// --- bridge command JSON builders ---

_shell_start_command_json :: proc(cmd_id, session_id, kind, cmd, cwd, label, project_id, chain_id, agent_instance_id, owner_user_id: string, server_port: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_start\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"kind\":\"")
	contracts.write_json_string(&b, kind)
	strings.write_string(&b, "\",\"cmd\":\"")
	contracts.write_json_string(&b, cmd)
	strings.write_string(&b, "\",\"cwd\":\"")
	contracts.write_json_string(&b, cwd)
	strings.write_string(&b, "\",\"label\":\"")
	contracts.write_json_string(&b, label)
	strings.write_string(&b, "\",\"project_id\":\"")
	contracts.write_json_string(&b, project_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	contracts.write_json_string(&b, chain_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	contracts.write_json_string(&b, agent_instance_id)
	strings.write_string(&b, "\",\"owner_user_id\":\"")
	contracts.write_json_string(&b, owner_user_id)
	strings.write_string(&b, "\",\"server_port\":")
	strings.write_int(&b, server_port)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_kill_command_json :: proc(session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_kill\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_shell_signal_command_json :: proc(session_id: string, signal: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_signal\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"signal\":")
	strings.write_int(&b, signal)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_restart_command_json :: proc(cmd_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_restart\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// _set_port_unreachable_message turns the sink's own wording into one sentence the
// caller can act on, keeping the original cause visible. Deliberately not a new error
// code: Bridge_Offline already means "the bridge could not be reached", and inventing
// a second code for the same condition is how two vocabularies start.
_set_port_unreachable_message :: proc(err: domain.Domain_Error) -> string {
	cause := err.message
	if cause == "" do cause = "bridge unreachable"
	return fmt.tprintf("the bridge did not apply the port, so nothing changed (%s)", cause)
}

_shell_set_port_command_json :: proc(cmd_id, session_id: string, server_port: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_set_port\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"server_port\":")
	strings.write_int(&b, server_port)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_logs_command_json :: proc(cmd_id, session_id: string, offset, limit_val: int, grep: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_logs\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"offset\":")
	strings.write_int(&b, offset)
	strings.write_string(&b, ",\"limit\":")
	strings.write_int(&b, limit_val)
	strings.write_string(&b, ",\"grep\":\"")
	contracts.write_json_string(&b, grep)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_shell_get_pane_command_json :: proc(cmd_id, session_id, since_hash: string, width, line_limit: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_get_pane\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"since_hash\":\"")
	contracts.write_json_string(&b, since_hash)
	strings.write_string(&b, "\",\"width\":")
	strings.write_int(&b, width)
	strings.write_string(&b, ",\"line_limit\":")
	strings.write_int(&b, line_limit)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_capture_command_json :: proc(cmd_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_capture\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// --- bridge reply JSON parsers ---

_json_str :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	b := strings.builder_make()
	escaped := false
	for i := 1; i < len(rest); i += 1 {
		ch := rest[i]
		if escaped {
			switch ch {
			case 'n': strings.write_byte(&b, '\n')
			case 'r': strings.write_byte(&b, '\r')
			case 't': strings.write_byte(&b, '\t')
			case '"': strings.write_byte(&b, '"')
			case '\\': strings.write_byte(&b, '\\')
			case: strings.write_byte(&b, ch)
			}
			escaped = false
			continue
		}
		if ch == '\\' { escaped = true; continue }
		if ch == '"' do return strings.to_string(b)
		strings.write_byte(&b, ch)
	}
	return ""
}

_json_int :: proc(body, key: string, default_value: int) -> int {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return default_value
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return default_value
	rest = strings.trim_space(rest[colon + 1:])
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
	if end == 0 do return default_value
	v, ok := strconv.parse_int(rest[:end])
	if !ok do return default_value
	return int(v)
}

_json_bool :: proc(body, key: string) -> bool {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return false
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return false
	rest = strings.trim_space(rest[colon + 1:])
	return strings.has_prefix(rest, "true")
}

// _json_array_raw returns the raw JSON array value for a key as a heap-allocated string
// (e.g., ["line1","line2"]). Caller must delete the returned string.
_json_array_raw :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return strings.clone("[]")
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return strings.clone("[]")
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '[' do return strings.clone("[]")
	depth := 0
	for i := 0; i < len(rest); i += 1 {
		if rest[i] == '[' do depth += 1
		else if rest[i] == ']' {
			depth -= 1
			if depth == 0 do return strings.clone(rest[:i + 1])
		}
	}
	return strings.clone("[]")
}

_shell_exited_event_json :: proc(session_id, status: string, exit_code: int, exit_code_set: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_session_exited\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"status\":\"")
	contracts.write_json_string(&b, status)
	strings.write_string(&b, "\"")
	if exit_code_set {
		strings.write_string(&b, ",\"exit_code\":")
		strings.write_int(&b, exit_code)
	}
	strings.write_string(&b, ",\"ts\":")
	strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now()) / 1_000_000))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}
