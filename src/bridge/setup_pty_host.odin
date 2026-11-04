package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

BRIDGE_SETUP_PTY_STOP_WAIT :: 10 * time.Second

// bridge_setup_retire_idle_pty_hosts runs inside an update's setup transaction
// (the NEW binary), after the old bridge stopped and before bin/ is replaced.
// ham-pty-host outlives bridge restarts by design, so an update that never stops
// it leaves the old daemon serving forever: `ham-bridge update`, the auto-update
// worker and install.sh all did (only the hub-initiated update stopped it).
// A daemon that hosts NO agents is shut down here, so the restarted bridge spawns
// the new binary. A daemon with live agents is kept, so their sessions survive the
// update as before; the next idle update replaces it.
bridge_setup_retire_idle_pty_hosts :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> (summary: string) {
	sockets := make([dynamic]string, context.temp_allocator)
	if rt, ok := bridgesvc.read_runtime_status(l.state_dir); ok && strings.trim_space(rt.bridge_id) != "" {
		u := Bridge_Uninstall{host = host, layout = l, pty_sockets = make([dynamic]string, context.temp_allocator)}
		bridge_uninstall_add_pty_identity(&u, rt.bridge_id)
		append(&sockets, ..u.pty_sockets[:])
	}
	bridge_profile_scan_pty_sockets(l, &sockets)
	when ODIN_OS == .Windows {
		u := Bridge_Uninstall{host = host, layout = l, pty_sockets = make([dynamic]string, context.temp_allocator)}
		if ok, _ := bridge_uninstall_discover_pty_hosts(&u); ok do append(&sockets, ..u.pty_sockets[:])
	}
	slice.sort(sockets[:])
	unique := make([dynamic]string, context.temp_allocator)
	for socket, i in sockets do if i == 0 || socket != sockets[i - 1] do append(&unique, socket)
	return bridge_setup_retire_summary(bridge_setup_retire_idle_with(unique[:]))
}

Bridge_Pty_Retire_Ops :: struct {
	list:     proc(socket: string) -> (Pty_Host_Reply, bool),
	ping:     proc(socket: string) -> bool,
	shutdown: proc(socket: string, wait: time.Duration) -> (bool, string),
}

Bridge_Pty_Retire_Result :: struct {
	retired: int, // listed with no live agents, then shut down
	kept:    int, // listed with live agents: their sessions survive the update
	unknown: int, // answers but its agent list could not be read: kept (fail safe)
	failed:  int, // idle, but did not stop in time
}

// bridge_setup_retire_idle_with decides per socket. Only a SUCCESSFUL list with
// zero alive agents authorizes a shutdown: a daemon that answers but whose list
// fails (an old daemon's reply the new decoder cannot read, too many async frames,
// a transient read error) may still host live agents, so it is kept, the same rule
// as bridge_auto_update_quiet_with_host ("unavailable live state cannot authorize
// a restart"). A socket nobody answers is skipped.
bridge_setup_retire_idle_with :: proc(sockets: []string, ops := Bridge_Pty_Retire_Ops{list = bridge_pty_host_list, ping = bridge_pty_host_ping, shutdown = bridge_pty_host_shutdown_at}) -> (r: Bridge_Pty_Retire_Result) {
	for socket in sockets {
		reply, listed := ops.list(socket)
		if !listed {
			if ops.ping(socket) do r.unknown += 1
			continue
		}
		alive := bridge_pty_host_live_agents(reply.agents)
		pty_host_reply_delete(reply)
		if alive > 0 {
			r.kept += 1
			continue
		}
		if ok, _ := ops.shutdown(socket, BRIDGE_SETUP_PTY_STOP_WAIT); ok do r.retired += 1
		else do r.failed += 1
	}
	return
}

bridge_setup_retire_summary :: proc(r: Bridge_Pty_Retire_Result) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if r.retired > 0 do append(&parts, fmt.tprintf("replaced %d idle PTY host(s)", r.retired))
	if r.kept > 0 do append(&parts, fmt.tprintf("kept %d PTY host(s) with live agents (replaced at the next idle update)", r.kept))
	if r.unknown > 0 do append(&parts, fmt.tprintf("kept %d PTY host(s) whose agent list could not be read", r.unknown))
	if r.failed > 0 do append(&parts, fmt.tprintf("%d idle PTY host(s) did not stop", r.failed))
	return strings.join(parts[:], "; ", context.temp_allocator)
}

bridge_pty_host_live_agents :: proc(agents: []Pty_Host_Agent_Info) -> int {
	n := 0
	for a in agents do if a.alive do n += 1
	return n
}
