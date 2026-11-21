package main

// Stale PTY host replacement.
//
// The PTY host daemon outlives bridge restarts by design, and an update used to
// leave it running: setup renames bin/ to bin.bak* under it (setup_cmd.odin, the
// Binaries step) and the restarted bridge adopted it on its socket through a plain
// Ping (bridge_pty_host_ensure_daemon). An adopted daemon from an older release
// does not answer Capabilities, so acp_runtime_v1 was never advertised and ACP
// stayed unavailable until someone killed the old process by hand.
//
// Two halves close that:
//   - update/setup stops the profile's daemon before swapping bin/ while it hosts
//     no agents (bridge_setup_stop_idle_pty_host), and
//   - a running bridge (this file) retires an ADOPTED daemon that is stale (its
//     Capabilities probe failed, or its executable is not the ham-pty-host this
//     bridge would start) once it hosts no agents, starts the current one and
//     re-probes. Updates run by an older binary still leave stale daemons behind,
//     so this half is what repairs installs that are already affected.
//
// A stale daemon that still hosts agents is never killed: it keeps serving them and
// is re-checked on the ACP probe's retry schedule until they have drained.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import local_socket "odin_test:lib/local_socket"

Pty_Host_Stale_Reason :: enum {
	None,
	Stale_Exe_Path,    // the daemon's executable is not the ham-pty-host this bridge starts
	No_Reply,          // no (decodable) Capabilities reply: a build older than the probe
	Bad_Reply,         // an unexpected reply kind
	Lacks_Piped_Spawn, // Capabilities without piped_spawn_v1
}

Pty_Host_Stale_Action :: enum {
	Healthy,            // not stale (or not adopted): nothing to do
	Replaced,           // the stale daemon was stopped; the caller starts the current one
	Kept_Agents_Hosted, // stale, but agents still run on it: re-checked later
	Kept_Unverified,    // stale, but its agents could not be listed or a launch was in flight
	Replace_Failed,     // stale and idle, but it could not be stopped
}

// Pty_Host_Stale_IO is the reconcile's seam to processes and the daemon, swapped
// by tests. Strings it returns are temp-allocated.
Pty_Host_Stale_IO :: struct {
	peer_pid:     proc(socket: string) -> (int, bool),
	exe_path:     proc(pid: int) -> (string, bool),
	expected_exe: proc() -> (string, bool),
	agents:       proc(socket: string) -> (int, bool), // RUNNING children (alive entries)
	reserve:      proc() -> bool, // close the spawn gate for the swap
	release:      proc(),
	stop:         proc(socket: string) -> (bool, string),
}

pty_host_stale_io := Pty_Host_Stale_IO{
	peer_pid     = pty_host_stale_peer_pid,
	exe_path     = pty_host_stale_exe_path,
	expected_exe = pty_host_stale_expected_exe,
	agents       = pty_host_stale_agent_count,
	reserve      = pty_host_spawn_gate_close,
	release      = pty_host_spawn_gate_open,
	stop         = bridge_update_stop_pty_host,
}

// A stale daemon is kept and re-checked (acp_runtime_probe.odin schedules the retry).
// Atomic.
pty_host_stale_pending: bool

// bridge_pty_host_stale_reason classifies a daemon from its Capabilities probe and
// its executable path. A failed probe wins: it is what keeps ACP off. A path is
// only compared when both sides are known, so an OS that cannot report another
// process's executable never retires a daemon on that ground.
bridge_pty_host_stale_reason :: proc(probe: Pty_Host_Pipe_Probe, exe: string, exe_ok: bool, expected: string, expected_ok: bool) -> Pty_Host_Stale_Reason {
	switch probe {
	case .No_Reply:          return .No_Reply
	case .Bad_Reply:         return .Bad_Reply
	case .Lacks_Piped_Spawn: return .Lacks_Piped_Spawn
	case .Supported:
	}
	if exe_ok && expected_ok && !pty_host_stale_same_exe(exe, expected) do return .Stale_Exe_Path
	return .None
}

// pty_host_stale_same_exe compares two executable paths. Linux reports a deleted
// image as "<path> (deleted)": that is an old binary replaced in place, so it never
// matches.
pty_host_stale_same_exe :: proc(exe, expected: string) -> bool {
	return strings.trim_right(exe, "/") == strings.trim_right(expected, "/")
}

PTY_HOST_STALE_REASON_SYMS := [Pty_Host_Stale_Reason]Blog_Sym{
	.None              = .other,
	.Stale_Exe_Path    = .stale_exe_path,
	.No_Reply          = .no_reply,
	.Bad_Reply         = .bad_reply,
	.Lacks_Piped_Spawn = .lacks_piped_spawn,
}

// bridge_pty_host_stale_reconcile decides what to do with the daemon answering on
// socket, given its Capabilities probe, and stops it when it is stale and idle.
// Only an ADOPTED daemon is ever retired: one this process started runs the
// current binary by construction, and retiring it for a failed probe would only
// loop. On .Replaced the caller starts the current daemon (ensure_daemon) and
// re-probes; the spawn gate (pty_host_runtime.odin) is held closed across the stop
// so no agent, shell or ACP child is spawned on the daemon being retired.
bridge_pty_host_stale_reconcile :: proc(socket: string, probe: Pty_Host_Pipe_Probe, io := pty_host_stale_io) -> (action: Pty_Host_Stale_Action, reason: Pty_Host_Stale_Reason) {
	pid, has_pid := io.peer_pid(socket)
	if has_pid && bridge_pty_host_is_own_daemon(pid) {
		sync.atomic_store(&pty_host_stale_pending, false)
		return .Healthy, .None
	}
	exe, exe_ok := "", false
	if has_pid do exe, exe_ok = io.exe_path(pid)
	expected, expected_ok := io.expected_exe()
	reason = bridge_pty_host_stale_reason(probe, exe, exe_ok, expected, expected_ok)
	if reason == .None {
		sync.atomic_store(&pty_host_stale_pending, false)
		return .Healthy, .None
	}
	defer sync.atomic_store(&pty_host_stale_pending, action != .Healthy && action != .Replaced)

	keep :: proc(action: Pty_Host_Stale_Action, decision: Blog_Sym, reason: Pty_Host_Stale_Reason, agents: int) -> Pty_Host_Stale_Action {
		blog_warn(.pty_host_stale, blog_sym(.stage, decision), blog_sym(.reason, PTY_HOST_STALE_REASON_SYMS[reason]), blog_int(.agents, i64(agents)))
		return action
	}
	fmt.eprintfln("bridge pty-host: adopted daemon (pid %d, exe %q) is stale: %v (this bridge starts %q)", pid, exe if exe_ok else "unknown", reason, expected if expected_ok else "unknown")

	agents, listed := io.agents(socket)
	if !listed do return keep(.Kept_Unverified, .list_failed, reason, 0), reason
	if agents > 0 {
		fmt.eprintfln("bridge pty-host: keeping the stale daemon while it hosts %d agents; it is replaced once they have exited", agents)
		return keep(.Kept_Agents_Hosted, .agents_still_hosted, reason, agents), reason
	}
	if !io.reserve() do return keep(.Kept_Unverified, .spawn_in_progress, reason, 0), reason
	defer io.release()
	// The gate is closed now: a spawn that raced the first listing shows up here.
	agents, listed = io.agents(socket)
	if !listed do return keep(.Kept_Unverified, .list_failed, reason, 0), reason
	if agents > 0 do return keep(.Kept_Agents_Hosted, .agents_still_hosted, reason, agents), reason
	if ok, detail := io.stop(socket); !ok {
		fmt.eprintfln("bridge pty-host: cannot retire the stale daemon: %s", detail)
		return keep(.Replace_Failed, .stop_failed, reason, 0), reason
	}
	blog_warn(.pty_host_stale, blog_sym(.stage, .retired), blog_sym(.reason, PTY_HOST_STALE_REASON_SYMS[reason]), blog_int(.agents, 0))
	fmt.eprintln("bridge pty-host: retired the stale daemon; starting the current ham-pty-host")
	return .Replaced, reason
}

// bridge_pty_host_is_own_daemon: pid is the daemon this process started and still
// holds (pty_host_daemon_process).
bridge_pty_host_is_own_daemon :: proc(pid: int) -> bool {
	sync.mutex_lock(&pty_host_daemon_lock)
	defer sync.mutex_unlock(&pty_host_daemon_lock)
	return pty_host_daemon_has_process && pty_host_daemon_process.pid == pid
}

pty_host_stale_peer_pid :: proc(socket: string) -> (int, bool) {
	s, dialed := pty_host_dial(socket)
	if !dialed do return 0, false
	defer local_socket.close(s)
	return local_socket.peer_pid(s)
}

// pty_host_stale_exe_path is the executable image pid runs: /proc/<pid>/exe on
// Linux, proc_pidpath on macOS. Both follow a rename of its directory (bin ->
// bin.bak*), which the command line does not.
pty_host_stale_exe_path :: proc(pid: int) -> (string, bool) {
	info, err := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator)
	if err != nil || .Executable_Path not_in info.fields || info.executable_path == "" do return "", false
	return info.executable_path, true
}

// pty_host_stale_expected_exe is the canonical path of the ham-pty-host this bridge
// would start (bridge_pty_host_bin). ok=false when it cannot be resolved, e.g. a
// bare "ham-pty-host" that is not on PATH.
pty_host_stale_expected_exe :: proc() -> (string, bool) {
	bin := bridge_pty_host_bin()
	defer delete(bin)
	return pty_host_stale_canonical(bin)
}

pty_host_stale_canonical :: proc(path: string) -> (string, bool) {
	if !strings.has_prefix(path, "/") do return "", false
	return bridge_os_realpath(path, context.temp_allocator)
}

// pty_host_stale_agent_count counts the RUNNING children (agents and shell runs)
// on the daemon. List also returns exited tombstones (alive=false), which the
// daemon keeps for up to an hour (tools/pty_host/src/daemon.rs TOMBSTONE_TTL) and
// prunes only on the next spawn or exit; counting them would keep a drained stale
// daemon forever. Dropping tombstones loses nothing: reconcile treats a
// not-alive entry exactly like a missing one (agent_reconcile.odin).
pty_host_stale_agent_count :: proc(socket: string) -> (int, bool) {
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return 0, false
	defer pty_host_reply_delete(reply)
	return pty_host_running_agent_count(reply.agents), true
}

pty_host_running_agent_count :: proc(agents: []Pty_Host_Agent_Info) -> int {
	n := 0
	for a in agents do if a.alive do n += 1
	return n
}
