package main

// BR-2: bridge spawns/controls agents via ham-pty-host instead of tmux.
//
// This is the high-level runtime layer that sits on top of the wire client
// (pty_host_client.odin) and the pre-spawn materializer (BR-1,
// bootstrap_prespawn.odin). It:
//
//   * lazily starts the per-machine ham-pty-host daemon (one per bridge, keyed on
//     the bridge's local endpoint socket dir),
//   * builds a Spawn request from a provider profile (argv + cwd=run_dir + the
//     HEIMDALL_* env from BR-1 + the resolved startup-detection JSON),
//   * maps the bridge's lifecycle ops onto the daemon control plane:
//       launch/relaunch -> host.spawn (or host.restart when already registered)
//       stop            -> host.close
//   * is gated behind a runtime flag (bridge_config.pty_host_runtime) so the tmux
//     path stays the default until DEL-1 flips it — this is the A/B switch.
//
// Event subscription (ChildExited -> status, StartupReady/Blocked/ScreenChanged)
// is layered on in BR-3; BR-2 wires the control plane + a ChildExited-to-status
// mapping helper the subscriber will call.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

// Retry/backoff for a spawn that races daemon startup (AC-5 parity with the tmux
// launch path): the daemon may not be accepting connections the instant after we
// start it, so a spawn retries a few times with a short backoff.
PTY_HOST_SPAWN_MAX_ATTEMPTS :: 5
PTY_HOST_SPAWN_BASE_BACKOFF_MS :: 100

// Default VT geometry for a freshly spawned agent pane.
PTY_HOST_DEFAULT_ROWS :: 40
PTY_HOST_DEFAULT_COLS :: 120

// ---- runtime flag -------------------------------------------------------

// bridge_pty_host_runtime_enabled reports whether the bridge should drive agents
// through ham-pty-host instead of tmux. Sourced from config (pty_host_runtime) OR
// the HEIMDALL_BRIDGE_PTY_HOST env override (so it can be flipped for an A/B run
// without editing config.toml). Default: false (tmux path) until DEL-1.
bridge_pty_host_runtime_enabled :: proc() -> bool {
	if v := os.get_env_alloc("HEIMDALL_BRIDGE_PTY_HOST", context.allocator); strings.trim_space(v) != "" {
		defer delete(v)
		return bridge_pty_host_truthy(v)
	}
	return bridge_config.pty_host_runtime
}

bridge_pty_host_truthy :: proc(v: string) -> bool {
	switch strings.to_lower(strings.trim_space(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// ---- daemon lazy-start --------------------------------------------------

pty_host_daemon_started: bool
pty_host_daemon_lock: sync.Mutex

// bridge_pty_host_bin resolves the ham-pty-host binary: the HEIMDALL_HAM_PTY_HOST_BIN
// env override (set by the flake app to the matching build) wins, else PATH.
bridge_pty_host_bin :: proc() -> string {
	if v := os.get_env_alloc("HEIMDALL_HAM_PTY_HOST_BIN", context.allocator); strings.trim_space(v) != "" do return v
	if found := bridge_runtime_find_on_path("ham-pty-host"); found != "" do return found
	return "ham-pty-host"
}

// bridge_pty_host_ensure_daemon starts the daemon once (idempotent) and returns
// its socket path. The daemon is spawned detached (its own process) listening on
// pty_host_socket_path(); we then poll a Ping until it answers or the deadline
// passes. Safe to call on every launch.
//
// BR-2a: the socket path is BRIDGE-UNIQUE (see pty_host_socket_path). A daemon
// already answering on it therefore belongs to THIS bridge — a prior instance of
// the same bridge identity (e.g. across a bridge restart), never another bridge's
// daemon. Adopting it is correct-by-identity: we never cross-wire two bridges to
// one daemon, and each bridge owns exactly one daemon serving its own agent set.
bridge_pty_host_ensure_daemon :: proc() -> (string, bool) {
	socket := pty_host_socket_path()
	sync.mutex_lock(&pty_host_daemon_lock)
	defer sync.mutex_unlock(&pty_host_daemon_lock)

	// Already up on this bridge's own socket (this process started it, or a prior
	// instance of THIS bridge left it running across a restart)?
	if pty_host_daemon_started && bridge_pty_host_ping(socket) do return socket, true
	if bridge_pty_host_ping(socket) {
		pty_host_daemon_started = true
		return socket, true
	}

	// Ensure the socket's parent dir exists, then spawn the daemon detached.
	if slash := strings.last_index_byte(socket, '/'); slash > 0 do _ = os.make_directory_all(socket[:slash])
	bin := bridge_pty_host_bin()
	cmd := []string{bin, "daemon", "--socket", socket}
	// env = nil => the daemon inherits the bridge's environment. The per-agent
	// HEIMDALL_* env is delivered in each Spawn request, not the daemon's env.
	proc_handle, err := os.process_start(os.Process_Desc{command = cmd})
	if err != nil {
		fmt.eprintln("bridge pty-host: failed to start daemon:", bin, err)
		return "", false
	}
	// Detach — the daemon outlives this call and is reaped by the OS on exit.
	_ = proc_handle

	// Poll until the daemon accepts + answers Ping.
	deadline := time.time_add(time.now(), 5 * time.Second)
	for time.now()._nsec < deadline._nsec {
		if bridge_pty_host_ping(socket) {
			pty_host_daemon_started = true
			return socket, true
		}
		time.sleep(50 * time.Millisecond)
	}
	fmt.eprintln("bridge pty-host: daemon did not become ready on", socket)
	return "", false
}

// bridge_pty_host_ping sends a Ping and expects a Pong. Used both for readiness
// polling and liveness checks.
bridge_pty_host_ping :: proc(socket: string) -> bool {
	req := pty_host_encode_ping()
	defer delete(req)
	reply, ok := pty_host_request(socket, req)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	return reply.kind == .Pong
}

// ---- spawn-request assembly ---------------------------------------------

// bridge_pty_host_build_spawn assembles the daemon Spawn request for an instance:
// the provider argv, cwd=run_dir, the BR-1 HEIMDALL_* env (as (k,v) pairs), and
// the resolved provider startup-detection JSON (stored verbatim; HOST-2 parses).
// Returns ok=false when the provider has no runnable command. Caller owns the
// returned request's heap slices (free with bridge_pty_host_spawn_request_delete).
bridge_pty_host_build_spawn :: proc(instance_id, run_dir, provider, tier, agent_token: string, env: []string, display_name := "") -> (Pty_Host_Spawn_Request, bool) {
	profile, profile_ok := bridge_provider_by_name_or_default(provider)
	if !profile_ok || !profile.enabled || len(profile.command) == 0 do return {}, false
	agent_argv := bridge_runtime_agent_argv_for_profile(profile, tier, agent_token, instance_id)
	if len(agent_argv) == 0 do return {}, false

	detect_json := bridge_runtime_startup_detection_arg(profile.startup_detection)
	req := Pty_Host_Spawn_Request{
		instance         = strings.clone(instance_id),
		argv             = agent_argv, // owned by the request now
		cwd              = strings.clone(run_dir),
		has_cwd          = true,
		env              = bridge_pty_host_env_pairs(env),
		detect           = detect_json,
		has_detect       = strings.trim_space(detect_json) != "",
		display_name     = strings.clone(display_name),
		has_display_name = strings.trim_space(display_name) != "",
		rows             = PTY_HOST_DEFAULT_ROWS,
		cols             = PTY_HOST_DEFAULT_COLS,
	}
	return req, true
}

// bridge_pty_host_env_pairs converts BR-1's "KEY=VALUE" env slice into the
// (key,value) pairs the Spawn codec wants. Entries without '=' are skipped.
bridge_pty_host_env_pairs :: proc(env: []string) -> [][2]string {
	out := make([dynamic][2]string)
	for e in env {
		if eq := strings.index_byte(e, '='); eq > 0 {
			append(&out, [2]string{strings.clone(e[:eq]), strings.clone(e[eq + 1:])})
		}
	}
	return out[:]
}

bridge_pty_host_spawn_request_delete :: proc(req: Pty_Host_Spawn_Request) {
	if req.instance != "" do delete(req.instance)
	for a in req.argv do delete(a)
	if req.argv != nil do delete(req.argv)
	if req.cwd != "" do delete(req.cwd)
	for kv in req.env { delete(kv[0]); delete(kv[1]) }
	if req.env != nil do delete(req.env)
	if req.detect != "" do delete(req.detect)
	if req.display_name != "" do delete(req.display_name)
}

// ---- control-plane ops --------------------------------------------------

// bridge_pty_host_spawn spawns (or restarts) an instance on the daemon with
// AC-5-style retry/backoff. If the instance is already registered the daemon
// returns an Error; the caller should use bridge_pty_host_restart for a known
// relaunch. Returns (pid, true) on Spawned.
bridge_pty_host_spawn :: proc(socket: string, req: Pty_Host_Spawn_Request) -> (i32, bool) {
	frame := pty_host_encode_spawn(req)
	defer delete(frame)
	for attempt in 1..=PTY_HOST_SPAWN_MAX_ATTEMPTS {
		reply, ok := pty_host_request(socket, frame)
		if ok {
			defer pty_host_reply_delete(reply)
			if reply.kind == .Spawned do return reply.pid, true
			if reply.kind == .Error {
				fmt.eprintln("bridge pty-host spawn error:", reply.message)
				return 0, false
			}
		}
		if attempt < PTY_HOST_SPAWN_MAX_ATTEMPTS do bridge_pty_host_backoff(attempt)
	}
	return 0, false
}

// bridge_pty_host_restart re-spawns an instance from its remembered spec. Maps
// the bridge's relaunch/wake of an already-registered instance.
bridge_pty_host_restart :: proc(socket, instance: string) -> (i32, bool) {
	frame := pty_host_encode_restart(instance)
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return 0, false
	defer pty_host_reply_delete(reply)
	if reply.kind == .Restarted do return reply.pid, true
	if reply.kind == .Error do fmt.eprintln("bridge pty-host restart error:", reply.message)
	return 0, false
}

// bridge_pty_host_close SIGTERM->SIGKILL + unregisters an instance. Maps stop.
bridge_pty_host_close :: proc(socket, instance: string) -> bool {
	frame := pty_host_encode_close(instance)
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	return reply.kind == .Closed
}

// bridge_pty_host_list enumerates registered agents. Caller owns the reply.
bridge_pty_host_list :: proc(socket: string) -> (Pty_Host_Reply, bool) {
	frame := pty_host_encode_list()
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return {}, false
	if reply.kind != .Agent_List { pty_host_reply_delete(reply); return {}, false }
	return reply, true
}

// bridge_pty_host_is_registered reports whether instance appears in the daemon's
// current agent list (used to decide spawn vs restart on a relaunch).
bridge_pty_host_is_registered :: proc(socket, instance: string) -> bool {
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	for a in reply.agents do if a.instance_id == instance do return true
	return false
}

bridge_pty_host_backoff :: proc(attempt: int) {
	ms := PTY_HOST_SPAWN_BASE_BACKOFF_MS
	for _ in 1..<attempt do ms *= 2
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// ---- message/prompt/nudge delivery (BR-3) -------------------------------
//
// In the tmux/wrapper model the ham-wrapper received a hub push and injected a
// one-line notice into the pane via tmux.send_text(pane, msg, enter=true) (type
// the text, then press Enter). In the wrapper-free model the bridge does the same
// thing directly against the daemon: host.input(instance, text) followed by
// host.key(instance, Enter). bridge_pty_host_deliver_line is that primitive; the
// hub-push handlers translate each notification into a single notice line exactly
// as the wrapper did, then call it.

// bridge_pty_host_deliver_line types text into the instance then presses Enter,
// mirroring tmux.send_text(pane, text, enter=true). Returns false if either the
// input or the key send fails.
bridge_pty_host_deliver_line :: proc(socket, instance, text: string) -> bool {
	input := pty_host_encode_input(instance, transmute([]byte)text)
	defer delete(input)
	if !bridge_pty_host_send_oneway(socket, input) do return false
	// Small settle delay before Enter, matching the wrapper's 300ms pane pause so a
	// TUI input box registers the pasted text before the submit key.
	time.sleep(300 * time.Millisecond)
	key := pty_host_encode_key(instance, .Enter)
	defer delete(key)
	return bridge_pty_host_send_oneway(socket, key)
}

// bridge_pty_host_send_oneway writes a data-plane frame that expects no reply
// (Input/Key/Resize on an attached instance). Dials, sends, closes.
bridge_pty_host_send_oneway :: proc(socket: string, frame: []byte) -> bool {
	fd, ok := pty_host_dial(socket)
	if !ok do return false
	defer posix.close(fd)
	return pty_host_send_all(fd, frame)
}

// bridge_pty_host_message_notice renders the agent_message notice text (pure, so
// it is unit-testable). Mirrors the wrapper's wrapper_bridge_deliver_message_push.
bridge_pty_host_message_notice :: proc(sender: string) -> string {
	s := sender
	if strings.trim_space(s) == "" do s = "user"
	return strings.concatenate({"New message from ", s, " \u2014 run './.heimdall/bin/ham-ctl agent chat read' to view."})
}

// bridge_pty_host_task_nudge_notice renders the task-nudge notice text (pure).
bridge_pty_host_task_nudge_notice :: proc(task_id, target_role: string) -> string {
	tid := task_id
	if strings.trim_space(tid) == "" do tid = "unknown"
	role := target_role
	if strings.trim_space(role) == "" do role = "participant"
	return strings.concatenate({"Nudge: you have been nudged on ", tid, " (", role, "). Run './.heimdall/bin/ham-ctl tasks list' and complete your assignment."})
}

// bridge_pty_host_deliver_message renders the same notice the wrapper produced for
// an agent_message push and delivers it.
//
// User-initiated messages press ESC BEFORE typing the notice: this interrupts the
// agent's current turn (most CLI agents treat ESC as "cancel/stop") so it drops
// back to an input-ready prompt and picks up the just-arrived user message ASAP
// instead of finishing a long autonomous run first. The ESC is followed by a
// short settle so the pane returns to its input box before we paste the notice.
bridge_pty_host_deliver_message :: proc(socket, instance, sender: string) -> bool {
	esc := pty_host_encode_key(instance, .Esc)
	defer delete(esc)
	if !bridge_pty_host_send_oneway(socket, esc) do return false
	time.sleep(300 * time.Millisecond)
	msg := bridge_pty_host_message_notice(sender)
	defer delete(msg)
	return bridge_pty_host_deliver_line(socket, instance, msg)
}

// bridge_pty_host_deliver_task_nudge mirrors the wrapper task-nudge notice.
bridge_pty_host_deliver_task_nudge :: proc(socket, instance, task_id, target_role: string) -> bool {
	msg := bridge_pty_host_task_nudge_notice(task_id, target_role)
	defer delete(msg)
	return bridge_pty_host_deliver_line(socket, instance, msg)
}

// bridge_pty_host_deliver_notice delivers an arbitrary prefixed nudge/notice line
// (title-nudge, startup prompt) verbatim.
bridge_pty_host_deliver_notice :: proc(socket, instance, notice: string) -> bool {
	return bridge_pty_host_deliver_line(socket, instance, notice)
}

// bridge_pty_host_deliver_to_agent is the single entry the hub-push handlers call
// in the wrapper-free path: it ensures the daemon is up, then renders+delivers the
// notice for the given kind ("message" | "task_nudge"). Returns false if the daemon
// is unavailable or the delivery fails.
bridge_pty_host_deliver_to_agent :: proc(instance, kind, sender, task_id, target_role: string) -> bool {
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok do return false
	switch kind {
	case "message":
		return bridge_pty_host_deliver_message(socket, instance, sender)
	case "task_nudge":
		return bridge_pty_host_deliver_task_nudge(socket, instance, task_id, target_role)
	}
	return false
}

// ---- UI capture proxy (BR-4) --------------------------------------------

// bridge_pty_host_capture_result serves a UI pane_capture_request by proxying
// host.capture(instance): it ensures the daemon, requests one Screen snapshot,
// joins the rendered lines into pane text (honoring the request's line_limit),
// and builds the pane_capture_result JSON in the SAME shape the wrapper produced.
// On any failure it returns a failed result with a stable error_code so the UI
// surfaces a clean message instead of hanging on a pending capture.
bridge_pty_host_capture_result :: proc(pending: Bridge_Pane_Capture_Pending) -> string {
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok {
		return bridge_pane_capture_result_json(pending, false, "host_unavailable", "The ham-pty-host daemon is not available.", "", 0, false)
	}
	frame := pty_host_encode_capture(pending.agent_instance_id)
	defer delete(frame)
	reply, rok := pty_host_request(socket, frame)
	if !rok || reply.kind != .Screen {
		if rok do pty_host_reply_delete(reply)
		return bridge_pane_capture_result_json(pending, false, "capture_failed", "No screen snapshot was returned for this agent.", "", 0, false)
	}
	defer pty_host_reply_delete(reply)
	output, line_count, truncated := bridge_pty_host_screen_to_output(reply.screen.lines, pending.line_limit)
	defer delete(output)
	return bridge_pane_capture_result_json(pending, true, "", "", output, line_count, truncated)
}

// bridge_pty_host_screen_to_output joins a captured screen's rendered lines into
// pane text, keeping only the LAST line_limit lines (the tail, matching the tmux
// capture semantics) and reporting the emitted line count + whether the screen was
// truncated to the tail. Caller owns the returned string.
bridge_pty_host_screen_to_output :: proc(lines: []string, line_limit: int) -> (output: string, line_count: int, truncated: bool) {
	start := 0
	trunc := false
	if line_limit > 0 && len(lines) > line_limit {
		start = len(lines) - line_limit
		trunc = true
	}
	tail := lines[start:]
	return strings.join(tail, "\n"), len(tail), trunc
}

// ---- event->status mapping (consumed by the BR-3 subscriber) ------------

// bridge_pty_host_apply_child_exited maps a ChildExited event to the bridge's
// runtime status. The child is gone, so we drop the launch record and mark the
// instance stopped/idle; the stop-intent guard inside the status layer prevents a
// deliberately-stopped instance from being resurrected. Restart-reap (a superseded
// launch closing an older child) is handled at launch time via
// bridge_pty_host_reap_superseded, not here.
bridge_pty_host_apply_child_exited :: proc(instance: string, code: i32) {
	if strings.trim_space(instance) == "" do return
	fmt.println("bridge pty-host: child exited", instance, "code", code)
	bridge_runtime_remove_launch(instance)
	bridge_runtime_set_status(instance, "stopped", "idle")
}

// bridge_pty_host_apply_startup_ready maps a StartupReady event: the startup probe
// saw no blocked pattern. This proves the process launched but is NOT start-success
// (only the agent calling start-success flips to "running"), so we record a
// liveness signal exactly as the wrapper's "startup ready" did — keeping the
// instance "starting" until the agent acknowledges.
bridge_pty_host_apply_startup_ready :: proc(instance: string) {
	if strings.trim_space(instance) == "" do return
	bridge_runtime_note_wrapper_signal(instance, "idle")
}

// bridge_pty_host_apply_startup_blocked maps a StartupBlocked event to the distinct
// "blocked" runtime state (active-but-not-ready), mirroring the wrapper's
// wrapper.startup.report phase=startup_blocked path. reason_code/safe_diagnostic
// are logged for operators; the status layer projects "blocked" upstream.
bridge_pty_host_apply_startup_blocked :: proc(instance, reason_code, safe_diagnostic: string) {
	if strings.trim_space(instance) == "" do return
	fmt.println("bridge pty-host: startup blocked", instance, "reason=", reason_code, "detail=", safe_diagnostic)
	bridge_runtime_set_status(instance, "blocked", "idle")
}

// bridge_pty_host_apply_activity maps a classified burst to a hub activity report,
// tagged with the harness-agnostic "pane_diff" source (same rank the wrapper's pane
// detector used) so it ranks above a plain liveness ping but below a native agent
// extension. waiting_user is projected to idle by the hub.
bridge_pty_host_apply_activity :: proc(instance: string, sample: Bridge_Activity_Sample) {
	if strings.trim_space(instance) == "" do return
	bridge_runtime_note_agent_activity(instance, bridge_activity_status_string(sample.status), "pane_diff")
}

// bridge_pty_host_reap_superseded implements the restart-reap rule for the
// wrapper-free path: when a fresh launch supersedes a prior run of the same
// instance, close the old child on the daemon (SIGTERM->SIGKILL + unregister) so no
// orphaned agent lingers. This is the host analog of the wrapper's H7 token
// self-reap — with a real daemon we close directly instead of waiting for a
// liveness-ping timeout. Best-effort; safe if the instance is not registered.
bridge_pty_host_reap_superseded :: proc(socket, instance: string) {
	if strings.trim_space(instance) == "" do return
	if bridge_pty_host_is_registered(socket, instance) {
		if bridge_pty_host_close(socket, instance) do fmt.println("bridge pty-host: reaped superseded instance", instance)
	}
}
