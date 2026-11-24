package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

// Scripted processes for the stale-daemon seam (pty_host_stale.odin).
stale_test_pid: int
stale_test_exe: string
stale_test_agents: int
stale_test_agents_after_reserve: int // agents the post-reservation re-check sees (-1 = same)
stale_test_list_ok: bool
stale_test_reserve_ok: bool
stale_test_stop_ok: bool
stale_test_stops: int
stale_test_reserves: int
stale_test_releases: int
stale_test_lists: int
stale_test_reserved: bool
stale_test_tombstones: bool
stale_test_daemon_up: bool  // the scripted socket has a daemon behind it
stale_test_starts: int
stale_test_waiter: ^thread.Thread
stale_test_waiter_saw_daemon: bool // agents(): count a List reply with two exited entries via the real counter

STALE_TEST_EXPECTED :: "/opt/heimdall/bin/ham-pty-host"
STALE_TEST_BACKUP :: "/opt/heimdall/bin.bak-1-2/ham-pty-host"

stale_test_io := Pty_Host_Stale_IO{
	peer_pid     = proc(socket: string) -> (int, bool) { return stale_test_pid, stale_test_pid != 0 },
	exe_path     = proc(pid: int) -> (string, bool) { return stale_test_exe, stale_test_exe != "" },
	expected_exe = proc() -> (string, bool) { return STALE_TEST_EXPECTED, true },
	agents       = proc(socket: string) -> (int, bool) {
		stale_test_lists += 1
		if stale_test_tombstones {
			list := make([]Pty_Host_Agent_Info, 2 + stale_test_agents, context.temp_allocator)
			for i in 2 ..< len(list) do list[i].alive = true
			return pty_host_running_agent_count(list), stale_test_list_ok
		}
		if stale_test_reserved && stale_test_agents_after_reserve >= 0 do return stale_test_agents_after_reserve, stale_test_list_ok
		return stale_test_agents, stale_test_list_ok
	},
	reserve      = proc() -> bool {
		stale_test_reserves += 1
		stale_test_reserved = stale_test_reserve_ok
		return stale_test_reserve_ok
	},
	release      = proc() { stale_test_releases += 1; stale_test_reserved = false },
	stop         = proc(socket: string) -> (bool, string) {
		stale_test_stops += 1
		if !stale_test_stop_ok do return false, "pid survived SIGKILL"
		stale_test_daemon_up = false
		return true, ""
	},
	start        = proc() -> (string, bool) {
		stale_test_starts += 1
		// The current daemon replaces it: from now on it is healthy and idle.
		stale_test_exe = STALE_TEST_EXPECTED
		stale_test_agents = 0
		stale_test_daemon_up = true
		return "/tmp/acp-probe-test.sock", true
	},
}

stale_test_reconcile :: proc(socket: string, probe: Pty_Host_Pipe_Probe) -> (Pty_Host_Stale_Action, Pty_Host_Stale_Reason) {
	return bridge_pty_host_stale_reconcile(socket, probe, stale_test_io)
}

// stale_test_begin: an adopted daemon (pid 4242, not ours) running the old
// ham-pty-host from bin.bak*, idle, every operation succeeding.
stale_test_begin :: proc(steps: []ACP_Probe_Test_Step) -> ACP_Probe_IO {
	saved := acp_probe_test_begin(steps)
	acp_probe_io.reconcile = stale_test_reconcile
	stale_test_pid = 4242
	stale_test_exe = STALE_TEST_BACKUP
	stale_test_agents = 0
	stale_test_agents_after_reserve = -1
	stale_test_list_ok, stale_test_reserve_ok, stale_test_stop_ok = true, true, true
	stale_test_stops, stale_test_reserves, stale_test_releases, stale_test_lists = 0, 0, 0, 0
	stale_test_reserved = false
	stale_test_tombstones = false
	stale_test_daemon_up, stale_test_starts = true, 0
	sync.atomic_store(&pty_host_stale_pending, false)
	return saved
}

stale_test_end :: proc(saved: ACP_Probe_IO) {
	sync.atomic_store(&pty_host_stale_pending, false)
	acp_probe_test_end(saved)
}

// Acceptance: an adopted stale daemon (an older build: no Capabilities reply) that
// hosts no agents is retired at hub connect, the current one is started and
// probed, and acp_runtime_v1 is advertised in the very hello.
@(test)
test_stale_idle_daemon_replaced_then_acp_advertised :: proc(t: ^testing.T) {
	saved := stale_test_begin([]ACP_Probe_Test_Step{.Silent, .Pipes})
	defer stale_test_end(saved)

	bridge_acp_runtime_probe_on_connect()
	testing.expect_value(t, stale_test_stops, 1)
	testing.expect_value(t, stale_test_starts, 1)
	testing.expect_value(t, stale_test_reserves, 1)
	testing.expect_value(t, stale_test_releases, 1)
	testing.expect(t, acp_features_advertised(), "the replacement daemon supports piped spawn: acp_runtime_v1 is advertised")
	testing.expect(t, !sync.atomic_load(&pty_host_stale_pending), "nothing left to re-check")
	testing.expect_value(t, sync.atomic_load(&acp_probe_next_retry_ns), i64(0))
	testing.expect_value(t, acp_probe_test_requests, 2) // old daemon, then the replacement
}

// Acceptance: the same replacement mid-connection re-advertises the change.
@(test)
test_stale_daemon_replaced_mid_connection_is_readvertised :: proc(t: ^testing.T) {
	saved := stale_test_begin([]ACP_Probe_Test_Step{.Silent, .Pipes})
	defer stale_test_end(saved)

	outcome, changed := bridge_acp_runtime_probe(.Daemon_Restart)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Supported)
	testing.expect(t, changed, "the latch flipped")
	testing.expect(t, sync.atomic_load(&bridge_acp_features_dirty), "queued for bridge_features_update")
}

// Acceptance: a stale daemon that still hosts agents is not killed. It is
// re-checked on the retry schedule and replaced once they have drained.
@(test)
test_stale_daemon_with_agents_kept_until_drained :: proc(t: ^testing.T) {
	saved := stale_test_begin([]ACP_Probe_Test_Step{.Silent, .Silent, .Pipes})
	defer stale_test_end(saved)
	stale_test_agents = 2

	bridge_acp_runtime_probe_on_connect()
	testing.expect_value(t, stale_test_stops, 0)
	testing.expect_value(t, stale_test_reserves, 0)
	testing.expect(t, !acp_features_advertised(), "the old daemon cannot host ACP")
	testing.expect(t, sync.atomic_load(&pty_host_stale_pending), "kept daemon is pending replacement")
	testing.expect(t, sync.atomic_load(&acp_probe_next_retry_ns) != 0, "a re-check is scheduled")

	// Agents drained.
	stale_test_agents = 0
	outcome, changed := bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, stale_test_stops, 1)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Supported)
	testing.expect(t, changed && acp_features_advertised(), "re-probed after the replacement and advertised")
	testing.expect(t, !sync.atomic_load(&pty_host_stale_pending), "no longer pending")
}

// A daemon from bin.bak* of a recent release supports piped spawn, but it still
// runs the previous binary: it is replaced too, and while it hosts agents the
// re-check stays scheduled even though ACP is already supported.
@(test)
test_stale_exe_path_with_pipes_is_replaced_and_rechecked :: proc(t: ^testing.T) {
	saved := stale_test_begin([]ACP_Probe_Test_Step{.Pipes})
	defer stale_test_end(saved)
	stale_test_agents = 1

	outcome, _ := bridge_acp_runtime_probe(.Hub_Connect)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Supported)
	testing.expect_value(t, stale_test_stops, 0)
	testing.expect(t, sync.atomic_load(&acp_probe_next_retry_ns) != 0, "kept stale daemon is re-checked although ACP works")

	stale_test_agents = 0
	_, _ = bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, stale_test_stops, 1)
	testing.expect_value(t, sync.atomic_load(&acp_probe_next_retry_ns), i64(0))
}

// A launch that raced the first listing is seen after admission is closed; a
// launch already in flight keeps admission open and the daemon alive; a daemon
// that cannot be stopped or listed is kept and re-checked.
@(test)
test_stale_reconcile_guards :: proc(t: ^testing.T) {
	saved := stale_test_begin([]ACP_Probe_Test_Step{.Silent})
	defer stale_test_end(saved)

	stale_test_agents_after_reserve = 1
	action, reason := bridge_pty_host_stale_reconcile("/tmp/x.sock", .No_Reply, stale_test_io)
	testing.expect_value(t, action, Pty_Host_Stale_Action.Kept_Agents_Hosted)
	testing.expect_value(t, reason, Pty_Host_Stale_Reason.No_Reply)
	testing.expect_value(t, stale_test_stops, 0)
	testing.expect_value(t, stale_test_releases, 1)

	stale_test_agents_after_reserve = -1
	stale_test_reserve_ok = false
	action, _ = bridge_pty_host_stale_reconcile("/tmp/x.sock", .No_Reply, stale_test_io)
	testing.expect_value(t, action, Pty_Host_Stale_Action.Kept_Unverified)
	testing.expect_value(t, stale_test_stops, 0)

	stale_test_reserve_ok = true
	stale_test_list_ok = false
	action, _ = bridge_pty_host_stale_reconcile("/tmp/x.sock", .No_Reply, stale_test_io)
	testing.expect_value(t, action, Pty_Host_Stale_Action.Kept_Unverified)

	stale_test_list_ok = true
	stale_test_stop_ok = false
	action, _ = bridge_pty_host_stale_reconcile("/tmp/x.sock", .No_Reply, stale_test_io)
	testing.expect_value(t, action, Pty_Host_Stale_Action.Replace_Failed)
	testing.expect(t, sync.atomic_load(&pty_host_stale_pending), "a failed retire is retried")

	// A current, healthy daemon is left alone.
	stale_test_exe = STALE_TEST_EXPECTED
	action, reason = bridge_pty_host_stale_reconcile("/tmp/x.sock", .Supported, stale_test_io)
	testing.expect_value(t, action, Pty_Host_Stale_Action.Healthy)
	testing.expect_value(t, reason, Pty_Host_Stale_Reason.None)
	testing.expect(t, !sync.atomic_load(&pty_host_stale_pending), "healthy clears pending")
}

// A spawn arriving during a retire waits on the real spawn gate and is released
// only once the replacement daemon is up: never into the gap between the stop
// and the start.
@(test)
test_spawn_waiting_on_retire_lands_on_replacement :: proc(t: ^testing.T) {
	saved := stale_test_begin([]ACP_Probe_Test_Step{.Silent, .Pipes})
	defer stale_test_end(saved)
	defer pty_host_spawn_gate_open()
	io := stale_test_io
	io.reserve = pty_host_spawn_gate_close
	io.release = pty_host_spawn_gate_open
	io.stop = proc(socket: string) -> (bool, string) {
		stale_test_stops += 1
		stale_test_daemon_up = false
		// A shell/agent spawn arrives while the old daemon is being retired.
		stale_test_waiter_saw_daemon = false
		stale_test_waiter = thread.create_and_start(proc() {
			if pty_host_spawn_enter(5 * time.Second) {
				stale_test_waiter_saw_daemon = stale_test_daemon_up
				pty_host_spawn_leave()
			}
		})
		time.sleep(50 * time.Millisecond) // let it block on the gate
		return true, ""
	}
	action, _ := bridge_pty_host_stale_reconcile("/tmp/x.sock", .No_Reply, io)
	thread.join(stale_test_waiter)
	thread.destroy(stale_test_waiter)
	testing.expect_value(t, action, Pty_Host_Stale_Action.Replaced)
	testing.expect_value(t, stale_test_starts, 1)
	testing.expect(t, stale_test_waiter_saw_daemon, "the waiting spawn proceeded only after the replacement daemon was up")
	testing.expect(t, !pty_host_spawn_gate_closed, "the gate is open again")
}

// Exited tombstones (alive=false) the daemon keeps for an hour are not running
// agents: a daemon holding only tombstones is idle and is replaced.
@(test)
test_stale_daemon_with_only_tombstones_is_replaced :: proc(t: ^testing.T) {
	agents := []Pty_Host_Agent_Info{{instance_id = "a", alive = false}, {instance_id = "b", alive = false, has_exit_code = true}}
	testing.expect_value(t, pty_host_running_agent_count(agents), 0)
	agents[1].alive = true
	testing.expect_value(t, pty_host_running_agent_count(agents), 1)

	saved := stale_test_begin([]ACP_Probe_Test_Step{.Silent, .Pipes})
	defer stale_test_end(saved)
	stale_test_tombstones = true
	stale_test_agents = 0 // running children; the scripted List also carries two tombstones
	outcome, _ := bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, stale_test_stops, 1)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Supported)
}

// The daemon this process started is never retired, even if its probe failed:
// it runs the current binary, and retiring it would only loop.
@(test)
test_stale_reconcile_never_retires_own_daemon :: proc(t: ^testing.T) {
	saved := stale_test_begin([]ACP_Probe_Test_Step{.Silent})
	defer stale_test_end(saved)
	sync.mutex_lock(&pty_host_daemon_lock)
	saved_process, saved_has := pty_host_daemon_process, pty_host_daemon_has_process
	pty_host_daemon_process = os.Process{pid = stale_test_pid}
	pty_host_daemon_has_process = true
	sync.mutex_unlock(&pty_host_daemon_lock)
	defer {
		sync.mutex_lock(&pty_host_daemon_lock)
		pty_host_daemon_process, pty_host_daemon_has_process = saved_process, saved_has
		sync.mutex_unlock(&pty_host_daemon_lock)
	}

	action, _ := bridge_pty_host_stale_reconcile("/tmp/x.sock", .No_Reply, stale_test_io)
	testing.expect_value(t, action, Pty_Host_Stale_Action.Healthy)
	testing.expect_value(t, stale_test_stops, 0)
	testing.expect_value(t, stale_test_lists, 0)
}

@(test)
test_stale_reason_classification :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_pty_host_stale_reason(.Supported, STALE_TEST_EXPECTED, true, STALE_TEST_EXPECTED, true), Pty_Host_Stale_Reason.None)
	testing.expect_value(t, bridge_pty_host_stale_reason(.Supported, STALE_TEST_BACKUP, true, STALE_TEST_EXPECTED, true), Pty_Host_Stale_Reason.Stale_Exe_Path)
	testing.expect_value(t, bridge_pty_host_stale_reason(.Supported, STALE_TEST_EXPECTED + " (deleted)", true, STALE_TEST_EXPECTED, true), Pty_Host_Stale_Reason.Stale_Exe_Path)
	// Unknown paths never retire a daemon that answers correctly.
	testing.expect_value(t, bridge_pty_host_stale_reason(.Supported, "", false, STALE_TEST_EXPECTED, true), Pty_Host_Stale_Reason.None)
	testing.expect_value(t, bridge_pty_host_stale_reason(.Supported, STALE_TEST_BACKUP, true, "", false), Pty_Host_Stale_Reason.None)
	// A failed probe is stale whatever the path says.
	testing.expect_value(t, bridge_pty_host_stale_reason(.No_Reply, "", false, "", false), Pty_Host_Stale_Reason.No_Reply)
	testing.expect_value(t, bridge_pty_host_stale_reason(.Bad_Reply, STALE_TEST_EXPECTED, true, STALE_TEST_EXPECTED, true), Pty_Host_Stale_Reason.Bad_Reply)
	testing.expect_value(t, bridge_pty_host_stale_reason(.Lacks_Piped_Spawn, STALE_TEST_EXPECTED, true, STALE_TEST_EXPECTED, true), Pty_Host_Stale_Reason.Lacks_Piped_Spawn)
}

// The real executable lookup follows the image, not argv: it must agree with the
// canonical path of this test binary.
@(test)
test_stale_exe_path_reports_own_image :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		self, err := os.get_executable_path(context.temp_allocator)
		testing.expect(t, err == nil, "own executable path")
		expected, ok := pty_host_stale_canonical(self)
		testing.expect(t, ok, "canonical own path")
		got, got_ok := pty_host_stale_exe_path(os.get_pid())
		testing.expect(t, got_ok, "exe path of a live pid")
		testing.expect_value(t, got, expected)
		_, missing_ok := pty_host_stale_exe_path(0x7ffffff0)
		testing.expect(t, !missing_ok, "no such pid")
	}
}

// The spawn gate: a swap is refused while a spawn is in flight; a spawn arriving
// during a swap waits for the replacement (and gives up after its wait).
@(test)
test_pty_host_spawn_gate :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	defer pty_host_spawn_gate_open()

	testing.expect(t, pty_host_spawn_enter(0))
	testing.expect(t, !pty_host_spawn_gate_close(), "a spawn in flight keeps the daemon")
	pty_host_spawn_leave()

	testing.expect(t, pty_host_spawn_gate_close())
	testing.expect(t, !pty_host_spawn_gate_close(), "one swap at a time")
	testing.expect(t, !pty_host_spawn_enter(20 * time.Millisecond), "no spawn while the daemon is swapped")

	// A waiting spawn proceeds as soon as the swap ends.
	entered: bool
	th := thread.create_and_start_with_poly_data(&entered, proc(entered: ^bool) {
		entered^ = pty_host_spawn_enter(5 * time.Second)
		if entered^ do pty_host_spawn_leave()
	})
	time.sleep(50 * time.Millisecond)
	pty_host_spawn_gate_open()
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, entered, "the waiting spawn went through after the gate reopened")
}

// The real spawn paths honour the gate: refused before any request is sent.
@(test)
test_pty_host_spawn_refused_while_gate_closed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_wait := pty_host_spawn_gate_wait
	pty_host_spawn_gate_wait = 10 * time.Millisecond
	defer pty_host_spawn_gate_wait = saved_wait
	testing.expect(t, pty_host_spawn_gate_close())
	defer pty_host_spawn_gate_open()

	req := Pty_Host_Spawn_Request{instance = "gate-test"}
	_, ok, msg := bridge_pty_host_spawn_detailed("/tmp/no-such-pty-host.sock", req)
	defer delete(msg)
	testing.expect(t, !ok, "shell/agent Spawn refused during the swap")
	testing.expect_value(t, msg, PTY_HOST_SPAWN_GATE_REFUSAL)
	_, restarted := bridge_pty_host_restart("/tmp/no-such-pty-host.sock", "gate-test")
	testing.expect(t, !restarted, "Restart refused during the swap")
	reply, received := pty_host_spawn_pipe("/tmp/no-such-pty-host.sock", req)
	defer pty_host_reply_delete(reply)
	testing.expect(t, received && reply.kind == .Error && reply.message == PTY_HOST_SPAWN_GATE_REFUSAL, "ACP pipe Spawn refused during the swap")
}

// ---- setup (update) path ------------------------------------------------

setup_pty_test_running: bool
setup_pty_test_agents: int
setup_pty_test_list_ok: bool
setup_pty_test_stop_ok: bool
setup_pty_test_stops: int

setup_pty_test_io := Bridge_Setup_Pty_Host_IO{
	ping   = proc(socket: string) -> bool { return setup_pty_test_running },
	agents = proc(socket: string) -> (int, bool) { return setup_pty_test_agents, setup_pty_test_list_ok },
	stop   = proc(socket: string) -> (bool, string) {
		setup_pty_test_stops += 1
		return setup_pty_test_stop_ok, "" if setup_pty_test_stop_ok else "pid survived SIGKILL"
	},
}

// Acceptance: the update/setup path stops the profile's PTY host before the bin
// swap when it hosts no agents, and keeps one that still hosts agents.
@(test)
test_setup_stops_idle_pty_host_before_bin_swap :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	reset :: proc() {
		setup_pty_test_running, setup_pty_test_agents = true, 0
		setup_pty_test_list_ok, setup_pty_test_stop_ok = true, true
		setup_pty_test_stops = 0
	}

	reset()
	setup_pty_test_running = false
	outcome, _ := bridge_setup_stop_idle_pty_host("/tmp/x.sock", setup_pty_test_io)
	testing.expect_value(t, outcome, Bridge_Setup_Pty_Host_Outcome.None_Running)
	testing.expect_value(t, setup_pty_test_stops, 0)

	reset()
	outcome, _ = bridge_setup_stop_idle_pty_host("/tmp/x.sock", setup_pty_test_io)
	testing.expect_value(t, outcome, Bridge_Setup_Pty_Host_Outcome.Stopped)
	testing.expect_value(t, setup_pty_test_stops, 1)

	reset()
	setup_pty_test_agents = 3
	message: string
	outcome, message = bridge_setup_stop_idle_pty_host("/tmp/x.sock", setup_pty_test_io)
	testing.expect_value(t, outcome, Bridge_Setup_Pty_Host_Outcome.Kept_Agents)
	testing.expect_value(t, setup_pty_test_stops, 0)
	testing.expect(t, strings.contains(message, "3 agents"), "the kept daemon's agents are reported")

	reset()
	setup_pty_test_list_ok = false
	outcome, _ = bridge_setup_stop_idle_pty_host("/tmp/x.sock", setup_pty_test_io)
	testing.expect_value(t, outcome, Bridge_Setup_Pty_Host_Outcome.Kept_Unknown)
	testing.expect_value(t, setup_pty_test_stops, 0)

	reset()
	setup_pty_test_stop_ok = false
	outcome, _ = bridge_setup_stop_idle_pty_host("/tmp/x.sock", setup_pty_test_io)
	testing.expect_value(t, outcome, Bridge_Setup_Pty_Host_Outcome.Stop_Failed)
}

// Setup finds the profile's daemons in its run dir (<data_dir>/run), whatever
// identity named the socket, and nothing else there.
@(test)
test_setup_finds_profile_pty_host_sockets :: proc(t: ^testing.T) {
	root := strings.concatenate({bridge_scratch_root(context.temp_allocator), "/setup-pty-host-sockets"}, context.temp_allocator)
	_ = os.remove_all(root)
	defer _ = os.remove_all(root)
	run := bridgesvc.pjoin(root, "run")
	_ = os.make_directory_all(run)
	for name in ([]string{"pty-host-brg_a.sock", "pty-host.sock", "local.sock", "pty-host-x.log"}) {
		_ = os.write_entire_file(bridgesvc.pjoin(run, name), []u8{})
	}
	sockets := make([dynamic]string, context.temp_allocator)
	bridge_profile_pty_sockets(root, &sockets)
	defer for socket in sockets do delete(socket)
	testing.expect_value(t, len(sockets), 2)
	found_scoped, found_plain := false, false
	for socket in sockets {
		if strings.has_suffix(socket, "pty-host-brg_a.sock") do found_scoped = true
		if strings.has_suffix(socket, "/pty-host.sock") do found_plain = true
	}
	testing.expect(t, found_scoped && found_plain, "both socket names are found")

	missing := make([dynamic]string, context.temp_allocator)
	bridge_profile_pty_sockets(bridgesvc.pjoin(root, "absent"), &missing)
	testing.expect_value(t, len(missing), 0)
}

// Step level: the Binaries step stops the idle PTY host while bin/ still holds the
// old binaries, i.e. BEFORE the bin/ -> bin.bak rename, and then swaps. This is
// the step every update path reaches (ham-bridge update and --auto-worker run the
// new bundle's setup; the hub-driven update hands off to `update --detach`).
setup_step_test_bin_dir: string
setup_step_test_stopped_before_swap: bool
setup_step_test_stops: int

@(test)
test_setup_binaries_step_stops_idle_pty_host_before_rename :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	root := strings.concatenate({bridge_scratch_root(context.temp_allocator), "/setup-binaries-pty-host"}, context.temp_allocator)
	_ = os.remove_all(root)
	defer _ = os.remove_all(root)
	l := bridgesvc.Layout{data_dir = root, bin_dir = bridgesvc.pjoin(root, "bin"), state_dir = bridgesvc.pjoin(root, "state")}
	staging := bridgesvc.pjoin(root, ".staging")
	for dir in ([]string{l.bin_dir, staging, bridgesvc.pjoin(root, "run")}) do _ = os.make_directory_all(dir)
	_ = os.write_entire_file(bridgesvc.pjoin(l.bin_dir, "OLD"), []u8{})
	_ = os.write_entire_file(bridgesvc.pjoin(staging, "NEW"), []u8{})
	_ = os.write_entire_file(bridgesvc.pjoin(root, "run", "pty-host-brg_step.sock"), []u8{})

	saved_io := bridge_setup_pty_host_io
	defer bridge_setup_pty_host_io = saved_io
	setup_step_test_bin_dir = l.bin_dir
	setup_step_test_stopped_before_swap, setup_step_test_stops = false, 0
	bridge_setup_pty_host_io = Bridge_Setup_Pty_Host_IO{
		ping   = proc(socket: string) -> bool { return true },
		agents = proc(socket: string) -> (int, bool) { return 0, true },
		stop   = proc(socket: string) -> (bool, string) {
			setup_step_test_stops += 1
			setup_step_test_stopped_before_swap = os.exists(bridgesvc.pjoin(setup_step_test_bin_dir, "OLD"))
			return true, ""
		},
	}

	s := Bridge_Setup{host = bridge_service_host(), layout = l, staging = staging, copy_binaries = true, pid = 1, json_progress = true, plan = {replace_binaries = true}}
	result := bridge_setup_run(&s, .Binaries)
	testing.expect(t, result.ok, result.message)
	testing.expect_value(t, setup_step_test_stops, 1)
	testing.expect(t, setup_step_test_stopped_before_swap, "the daemon is stopped before bin/ is renamed")
	testing.expect(t, os.exists(bridgesvc.pjoin(l.bin_dir, "NEW")), "then the new binaries are installed")

	// A daemon with running agents is kept and the swap still happens.
	_ = os.remove_all(l.bin_dir); _ = os.remove_all(bridgesvc.pjoin(root, "bin.bak"))
	_ = os.make_directory_all(l.bin_dir); _ = os.make_directory_all(staging)
	_ = os.write_entire_file(bridgesvc.pjoin(staging, "NEW"), []u8{})
	bridge_setup_pty_host_io.agents = proc(socket: string) -> (int, bool) { return 2, true }
	setup_step_test_stops = 0
	result = bridge_setup_run(&s, .Binaries)
	testing.expect(t, result.ok, result.message)
	testing.expect_value(t, setup_step_test_stops, 0)
}
