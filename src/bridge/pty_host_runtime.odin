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
bridge_pty_host_ensure_daemon :: proc() -> (string, bool) {
	socket := pty_host_socket_path()
	sync.mutex_lock(&pty_host_daemon_lock)
	defer sync.mutex_unlock(&pty_host_daemon_lock)

	// Already up (this bridge started it, or a prior bridge left it running)?
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
bridge_pty_host_build_spawn :: proc(instance_id, run_dir, provider, tier, agent_token: string, env: []string) -> (Pty_Host_Spawn_Request, bool) {
	profile, profile_ok := bridge_provider_by_name_or_default(provider)
	if !profile_ok || !profile.enabled || len(profile.command) == 0 do return {}, false
	agent_argv := bridge_runtime_agent_argv_for_profile(profile, tier, agent_token, instance_id)
	if len(agent_argv) == 0 do return {}, false

	detect_json := bridge_runtime_startup_detection_arg(profile.startup_detection)
	req := Pty_Host_Spawn_Request{
		instance   = strings.clone(instance_id),
		argv       = agent_argv, // owned by the request now
		cwd        = strings.clone(run_dir),
		has_cwd    = true,
		env        = bridge_pty_host_env_pairs(env),
		detect     = detect_json,
		has_detect = strings.trim_space(detect_json) != "",
		rows       = PTY_HOST_DEFAULT_ROWS,
		cols       = PTY_HOST_DEFAULT_COLS,
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

// ---- event->status mapping (consumed by the BR-3 subscriber) ------------

// bridge_pty_host_apply_child_exited maps a ChildExited event to the bridge's
// runtime status. A clean stop-intent exit stays "stopped"; an unexpected exit
// surfaces as "stopped" with idle activity so the UI reflects the dead child.
// (Restart-on-crash policy lands in BR-3; BR-2 just wires the status transition.)
bridge_pty_host_apply_child_exited :: proc(instance: string, code: i32) {
	if strings.trim_space(instance) == "" do return
	fmt.println("bridge pty-host: child exited", instance, "code", code)
	bridge_runtime_remove_launch(instance)
	bridge_runtime_set_status(instance, "stopped", "idle")
}
