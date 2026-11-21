package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
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

STALE_TEST_EXPECTED :: "/opt/heimdall/bin/ham-pty-host"
STALE_TEST_BACKUP :: "/opt/heimdall/bin.bak-1-2/ham-pty-host"

stale_test_io := Pty_Host_Stale_IO{
	peer_pid     = proc(socket: string) -> (int, bool) { return stale_test_pid, stale_test_pid != 0 },
	exe_path     = proc(pid: int) -> (string, bool) { return stale_test_exe, stale_test_exe != "" },
	expected_exe = proc() -> (string, bool) { return STALE_TEST_EXPECTED, true },
	agents       = proc(socket: string) -> (int, bool) {
		stale_test_lists += 1
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
		// The current daemon replaces it: from now on it is healthy and idle.
		stale_test_exe = STALE_TEST_EXPECTED
		stale_test_agents = 0
		return true, ""
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

// Stale retirement shares launch admission with auto-update without clobbering it.
@(test)
test_stale_reserve_respects_update_admission :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	defer {
		sync.mutex_lock(&bridge_auto_update_mutex)
		bridge_auto_update_reserved_until = 0
		pty_host_stale_reserved_until = 0
		sync.mutex_unlock(&bridge_auto_update_mutex)
	}

	testing.expect(t, bridge_auto_update_launch_enter())
	testing.expect(t, !pty_host_stale_reserve(), "a launch in preparation keeps the daemon")
	bridge_auto_update_launch_leave()

	testing.expect(t, pty_host_stale_reserve())
	testing.expect(t, !bridge_auto_update_launch_enter(), "no launch while the daemon is swapped")
	pty_host_stale_release()
	testing.expect(t, bridge_auto_update_launch_enter(), "admission reopened")
	bridge_auto_update_launch_leave()

	// An update's reservation is neither taken over nor released.
	testing.expect(t, bridge_auto_update_reserve_forced())
	testing.expect(t, !pty_host_stale_reserve(), "an update in progress owns the daemon")
	pty_host_stale_release()
	testing.expect(t, !bridge_auto_update_launch_enter(), "the update's reservation stands")
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
