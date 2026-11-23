package main

// Runtime half of the supervisor's agent gate (docs/specs/bridge-supervisor-engine.md §12,
// §12.2; T14). The supervisor (src/supervisor/runtimectl) asks the running runtime, over
// the local endpoint, to:
//
//   supervisor.gate.count       count what an update would interrupt
//   supervisor.admission.close  refuse new agent launches (in memory; a new runtime starts open)
//   supervisor.admission.open   accept launches again
//   supervisor.sessions.end     soft-stop every live PTY session; reply with each one's
//                               (pid, start_time) so the supervisor can stop survivors
//
// The count:
//   pty_sessions  live entries of this bridge's PTY-host roster that are agents
//   helpers       live roster entries that are shell sessions (`sh_*`: ham-ctl shell
//                 run/serve and user terminals, also spawned by the PTY host)
//   launches      launches in preparation (admitted, not yet in the roster)
// No PTY-host socket = no daemon = no sessions. A daemon that does not answer the list is
// "not counted", which the engine treats as busy (fail closed).
//
// Admission shares bridge_auto_update_mutex with the launch counter
// (bridge_auto_update_launch_enter, the single admission point of
// bridge_runtime_launch_agent), so a close and a launch cannot interleave: after a close
// returns, every launch either was counted in `launches` or is refused.
//
// Auth: a control token separate from agent tokens, minted at endpoint start and written
// with the endpoint descriptor to <run_dir>/supervisor-control.json (0600). The loopback
// TCP fallback is reachable by other local users; without the token they cannot close
// admission or end sessions. Agents of the same OS user can read the file, as they can
// signal the bridge itself; the boundary is the OS user (Q8).

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import procs "odin_test:supervisor/procs"

SUPERVISOR_CONTROL_FILE :: "supervisor-control.json"
SUPERVISOR_CONTROL_TOKEN_BYTES :: 32
// Signal sent by sessions.end: SIGTERM (the PTY host signals the session's group).
SUPERVISOR_END_SIGNAL :: 15

// Guarded by bridge_auto_update_mutex (auto_update.odin).
bridge_gate_admission_closed: bool

// Minted once before the local endpoint's listeners start; read-only afterwards.
bridge_supervisor_control_token: string

Bridge_Gate_Count :: struct {
	counted:      bool,
	pty_sessions: int,
	launches:     int,
	helpers:      int,
	closed:       bool,
}

Bridge_Gate_Session :: struct {
	instance_id: string,
	pid:         int,
	helper:      bool,
}

// Roster seam: the real PTY host, or a fake in tests. ok = false: the daemon runs (or its
// socket exists) but did not answer, so the count is unavailable.
Bridge_Gate_Roster :: proc(allocator := context.allocator) -> (sessions: []Bridge_Gate_Session, ok: bool)

// Session-signal seam: deliver SIGTERM to one roster entry. true = delivered or already gone.
Bridge_Gate_Signal :: proc(instance_id: string) -> bool

bridge_gate_admission_close :: proc() -> (launches: int) {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	bridge_gate_admission_closed = true
	return bridge_auto_update_launches
}

bridge_gate_admission_open :: proc() {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	bridge_gate_admission_closed = false
}

bridge_gate_admission_is_closed :: proc() -> bool {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	return bridge_gate_admission_closed
}

bridge_gate_count :: proc(roster: Bridge_Gate_Roster = bridge_gate_pty_roster) -> (c: Bridge_Gate_Count) {
	sync.mutex_lock(&bridge_auto_update_mutex)
	c.launches = bridge_auto_update_launches
	c.closed = bridge_gate_admission_closed
	sync.mutex_unlock(&bridge_auto_update_mutex)
	sessions, ok := roster(context.temp_allocator)
	if !ok do return
	c.counted = true
	for s in sessions {
		if s.helper do c.helpers += 1
		else do c.pty_sessions += 1
	}
	return
}

// bridge_gate_end_sessions: capture every live session's identity, then ask each to end.
// The identities are taken before any signal, so a session whose leader exits at once
// still names a group whose survivors the supervisor can stop.
bridge_gate_end_sessions :: proc(
	roster: Bridge_Gate_Roster = bridge_gate_pty_roster,
	signal: Bridge_Gate_Signal = bridge_gate_pty_signal,
	allocator := context.allocator,
) -> (targets: []procs.Target, signalled: int, ok: bool) {
	sessions, listed := roster(context.temp_allocator)
	if !listed do return nil, 0, false
	out := make([dynamic]procs.Target, 0, len(sessions), allocator)
	for s in sessions {
		// Each PTY session leads its own session and group (setsid): a group target.
		if id, live := procs.identify(s.pid); live do append(&out, procs.Target{id = id, group = true})
	}
	for s in sessions {
		if signal(s.instance_id) do signalled += 1
	}
	if signalled > 0 do fmt.println("bridge supervisor gate: asked", signalled, "sessions to end for an update")
	return out[:], signalled, true
}

bridge_gate_pty_roster :: proc(allocator := context.allocator) -> ([]Bridge_Gate_Session, bool) {
	socket := pty_host_socket_path()
	defer delete(socket)
	// No socket: no daemon, nothing runs. Never start one just to count.
	if !os.exists(socket) do return nil, true
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return nil, false
	defer pty_host_reply_delete(reply)
	out := make([dynamic]Bridge_Gate_Session, 0, len(reply.agents), allocator)
	for a in reply.agents {
		if !a.alive do continue
		append(&out, Bridge_Gate_Session {
			instance_id = strings.clone(a.instance_id, allocator),
			pid = int(a.pid),
			helper = strings.has_prefix(a.instance_id, "sh_"),
		})
	}
	return out[:], true
}

bridge_gate_pty_signal :: proc(instance_id: string) -> bool {
	socket := pty_host_socket_path()
	defer delete(socket)
	client := Pty_Host_Client{socket = socket}
	result, _ := bridge_pty_host_signal_detailed(&client, instance_id, SUPERVISOR_END_SIGNAL)
	return result != .Refused
}

// ---- control token and file ----

// bridge_supervisor_control_mint: once per process, before the endpoint's listener threads
// start (they read the token without a lock).
bridge_supervisor_control_mint :: proc() {
	if bridge_supervisor_control_token != "" do return
	raw: [SUPERVISOR_CONTROL_TOKEN_BYTES]byte
	crypto.rand_bytes(raw[:])
	bridge_supervisor_control_token = string(hex.encode(raw[:]))
}

// bridge_supervisor_control_publish mints the control token (once per process) and writes
// {v, endpoint, token, pid} to <run_dir>/supervisor-control.json, owner-only.
bridge_supervisor_control_publish :: proc(run_dir, endpoint: string) -> bool {
	bridge_supervisor_control_mint()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"v":1,"endpoint":"`)
	bridge_local_write_json_string(&b, endpoint)
	strings.write_string(&b, `","token":"`)
	strings.write_string(&b, bridge_supervisor_control_token)
	fmt.sbprintf(&b, `","pid":%d}`, os.get_pid())
	strings.write_byte(&b, '\n')
	path := bridge_supervisor_control_path(run_dir)
	return bridge_supervisor_write_private(path, transmute([]byte)strings.to_string(b))
}

// bridge_supervisor_write_private: write-new 0600 + fsync + rename. Unlike
// bridge_retry_atomic_write it leaves the run dir's mode alone (the run dir also holds the
// agents' instance dirs and the endpoint socket; its mode is the endpoint's business).
bridge_supervisor_write_private :: proc(path: string, data: []byte) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	_ = os.remove(tmp)
	f, err := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, {.Read_User, .Write_User})
	if err != nil do return false
	n, werr := os.write(f, data)
	serr := os.sync(f)
	_ = os.close(f)
	if werr != nil || n != len(data) || serr != nil || os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

bridge_supervisor_control_path :: proc(run_dir: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({strings.trim_right(run_dir, "/\\"), "/", SUPERVISOR_CONTROL_FILE}, allocator)
}

bridge_supervisor_token_ok :: proc(token: string) -> bool {
	want := bridge_supervisor_control_token
	if want == "" || len(token) != len(want) do return false
	return crypto.compare_constant_time(transmute([]byte)token, transmute([]byte)want) == 1
}

// ---- local endpoint methods ----

// bridge_supervisor_control_handle answers one supervisor.* JSONL request. The response is
// heap-allocated like every local endpoint response (the caller deletes it).
bridge_supervisor_control_handle :: proc(
	request_id, method, token: string,
	roster: Bridge_Gate_Roster = bridge_gate_pty_roster,
	signal: Bridge_Gate_Signal = bridge_gate_pty_signal,
) -> string {
	if !bridge_supervisor_token_ok(token) {
		return bridge_local_response_error(request_id, "unauthenticated", "supervisor control token is invalid")
	}
	switch method {
	case "supervisor.gate.count":
		c := bridge_gate_count(roster)
		return bridge_local_response_data(request_id, bridge_gate_count_json(c))
	case "supervisor.admission.close":
		n := bridge_gate_admission_close()
		return bridge_local_response_data(request_id, fmt.tprintf(`{{"admission":"closed","launches":%d}}`, n))
	case "supervisor.admission.open":
		bridge_gate_admission_open()
		return bridge_local_response_data(request_id, `{"admission":"open"}`)
	case "supervisor.sessions.end":
		targets, signalled, ok := bridge_gate_end_sessions(roster, signal, context.temp_allocator)
		if !ok do return bridge_local_response_error(request_id, "unavailable", "PTY host did not list its sessions")
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"signalled":%d,"targets":[`, signalled)
		for t, i in targets {
			if i > 0 do strings.write_byte(&b, ',')
			fmt.sbprintf(&b, `{{"pid":%d,"start_time":%d}}`, t.id.pid, t.id.start_time)
		}
		strings.write_string(&b, "]}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}
	return bridge_local_response_error(request_id, "forbidden", "unknown supervisor method")
}

bridge_gate_count_json :: proc(c: Bridge_Gate_Count) -> string {
	admission := "closed" if c.closed else "open"
	if !c.counted {
		return fmt.tprintf(`{{"counted":false,"admission":"%s","launches":%d}}`, admission, c.launches)
	}
	return fmt.tprintf(
		`{{"counted":true,"admission":"%s","pty_sessions":%d,"launches":%d,"helpers":%d}}`,
		admission, c.pty_sessions, c.launches, c.helpers,
	)
}
