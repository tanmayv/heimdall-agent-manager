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
	retired, kept, failed := 0, 0, 0
	for socket, i in sockets {
		if i > 0 && socket == sockets[i - 1] do continue
		agents, live := bridge_pty_host_agent_count(socket)
		if !live do continue
		if agents > 0 {
			kept += 1
			continue
		}
		if ok, _ := bridge_pty_host_shutdown_at(socket, BRIDGE_SETUP_PTY_STOP_WAIT); ok do retired += 1
		else do failed += 1
	}
	parts := make([dynamic]string, context.temp_allocator)
	if retired > 0 do append(&parts, fmt.tprintf("replaced %d idle PTY host(s)", retired))
	if kept > 0 do append(&parts, fmt.tprintf("kept %d PTY host(s) with live agents (replaced at the next idle update)", kept))
	if failed > 0 do append(&parts, fmt.tprintf("%d idle PTY host(s) did not stop", failed))
	return strings.join(parts[:], "; ", context.temp_allocator)
}

// bridge_pty_host_agent_count asks the daemon at socket how many agents it hosts.
// live=false when nothing answers there.
bridge_pty_host_agent_count :: proc(socket: string) -> (agents: int, live: bool) {
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return 0, bridge_pty_host_ping(socket)
	defer pty_host_reply_delete(reply)
	return len(reply.agents), true
}
