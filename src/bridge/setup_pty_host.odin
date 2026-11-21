package main

// Setup's half of stale PTY host prevention (see pty_host_stale.odin for the
// running bridge's half). The PTY host daemon outlives the bridge service, so a
// bin/ swap with it still running leaves the old ham-pty-host executing from
// bin.bak* and the restarted bridge adopts it. Before the swap, setup stops the
// profile's daemon when it hosts no agents. A daemon that still hosts agents is
// kept, so an update never kills running agents; the new bridge replaces it once
// they have exited.
//
// Every update path reaches this step: `ham-bridge update` (user-run and
// --auto-worker) runs the NEW bundle's `setup` (bridgesvc.update_setup_argv), and
// a hub-driven update hands off to `update --detach` after stopping the daemon
// itself (bridge_runtime_apply_update).

import "core:fmt"
import bridgesvc "odin_test:lib/bridgesvc"

Bridge_Setup_Pty_Host_Outcome :: enum {
	None_Running, // nothing answers on the profile's socket (or it cannot be located)
	Stopped,      // idle daemon stopped
	Kept_Agents,  // agents still run on it
	Kept_Unknown, // it answers but its agents could not be listed
	Stop_Failed,
}

// Seams for tests; zero fields mean the real implementation.
Bridge_Setup_Pty_Host_IO :: struct {
	ping:   proc(socket: string) -> bool,
	agents: proc(socket: string) -> (int, bool),
	stop:   proc(socket: string) -> (bool, string),
}

// bridge_setup_stop_idle_pty_host stops the daemon on socket when it hosts no
// agents. message (temp-allocated) explains the outcome for setup's progress.
bridge_setup_stop_idle_pty_host :: proc(socket: string, io: Bridge_Setup_Pty_Host_IO = {}) -> (outcome: Bridge_Setup_Pty_Host_Outcome, message: string) {
	ping := io.ping if io.ping != nil else bridge_pty_host_ping
	agents_of := io.agents if io.agents != nil else pty_host_stale_agent_count
	stop := io.stop if io.stop != nil else bridge_update_stop_pty_host
	if !ping(socket) do return .None_Running, ""
	agents, listed := agents_of(socket)
	if !listed {
		return .Kept_Unknown, "PTY host kept: its agents could not be listed; the updated bridge replaces it once it is idle"
	}
	if agents > 0 {
		return .Kept_Agents, fmt.tprintf("PTY host kept: %d agents still run on it; the updated bridge replaces it once they have exited", agents)
	}
	if ok, detail := stop(socket); !ok {
		return .Stop_Failed, fmt.tprintf("PTY host not stopped (%s); the updated bridge replaces it once it is idle", detail)
	}
	return .Stopped, "stopped the idle PTY host so the new ham-pty-host starts with the bridge"
}

// bridge_setup_quiesce_pty_host runs before the Binaries step renames bin/. It
// covers every daemon socket in the profile's run dir (the service runs with
// --local-run-dir <data_dir>/run). It never fails the step: a daemon left running
// is retired by the new bridge.
bridge_setup_quiesce_pty_host :: proc(s: ^Bridge_Setup) {
	sockets := make([dynamic]string, context.temp_allocator)
	bridge_profile_pty_sockets(s.layout.data_dir, &sockets)
	for socket in sockets {
		defer delete(socket)
		outcome, message := bridge_setup_stop_idle_pty_host(socket)
		if outcome == .None_Running do continue
		// "progress" is the protocol's in-step information line
		// (docs/bridge-setup-progress.md); a kept daemon is not a step failure.
		bridge_setup_emit(s, bridgesvc.Event{step = "binaries", state = "progress", message = message})
	}
}
