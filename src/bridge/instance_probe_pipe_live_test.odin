#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Runs the real ACP process transport without a provider account or model.
// Use a test-owned daemon with pipe support via HEIMDALL_HAM_PTY_HOST_BIN.
when #config(HEIMDALL_PTY_LIVENESS_LIVE_TEST, false) {
	@(test)
	test_instance_probe_observes_real_pipe_child_and_exit :: proc(t: ^testing.T) {
		sync.mutex_lock(&bridge_test_config_mutex)
		defer sync.mutex_unlock(&bridge_test_config_mutex)
		bin := os.get_env("HEIMDALL_HAM_PTY_HOST_BIN", context.temp_allocator)
		if !testing.expect(t, strings.has_prefix(bin, "/") && os.exists(bin), "set the absolute fixture daemon binary") do return
		dir := fmt.tprintf("/tmp/ham-liveness-%d-%d", os.get_pid(), time.tick_now()._nsec)
		if !testing.expect(t, os.make_directory(dir, {.Read_User, .Write_User, .Execute_User}) == nil) do return
		defer _ = os.remove_all(dir)
		prev_run_dir, prev_bridge := bridge_config.local_endpoint_run_dir, bridge_config.daemon_id
		bridge_config.local_endpoint_run_dir, bridge_config.daemon_id = dir, "pipe-fixture"
		defer { bridge_config.local_endpoint_run_dir, bridge_config.daemon_id = prev_run_dir, prev_bridge }
		socket := pty_host_socket_path()
		defer delete(socket)
		swap := pty_host_test_install_socket(socket)
		defer pty_host_test_restore_socket(swap)
		daemon, spawn_err := os.process_start({command = {bin, "daemon", "--socket", socket}, env = {fmt.tprintf("HOME=%s", dir), "PATH=/usr/bin:/bin"}})
		if !testing.expect(t, spawn_err == nil, "could not start fixture daemon") do return
		defer {
			_ = os.process_kill(daemon)
			_, _ = os.process_wait(daemon)
		}
		ready := false
		for deadline := time.tick_now()._nsec + i64(5 * time.Second); time.tick_now()._nsec < deadline; {
			if bridge_pty_host_ping(socket) { ready = true; break }
			time.sleep(10 * time.Millisecond)
		}
		if !testing.expect(t, ready, "private daemon failed to answer") do return

		id :: "inst_pipe_liveness_fixture"
		launch, spawned := pty_host_spawn_pipe(socket, {
			mode = .Pipe, instance = id, argv = {"/bin/sh", "-c", "read -r line; exit 7"},
			env = {{"PATH", "/usr/bin:/bin"}, {"HOME", dir}, {"HEIMDALL_STARTUP_KEY", "pipe-fixture-key"}},
			cwd = dir, has_cwd = true,
		})
		defer pty_host_reply_delete(launch)
		if !testing.expect(t, spawned && launch.kind == .Spawned && launch.pid > 0 && launch.generation != "", "spawn real pipe process") do return
		defer _ = bridge_pty_host_close(socket, id)
		pid, queried := bridge_pty_host_startup_launch(socket, id, "pipe-fixture-key")
		testing.expect(t, queried && pid == launch.pid, "the live pipe is bound to its startup generation")
		live := bridge_instance_probe(id)
		testing.expect(t, live.state == "alive" && live.pid == launch.pid, "same liveness provider as PTY")
		// The terminal-input protocol is invalid for pipe children. Its
		// rejection must not change which child the daemon reports alive.
		invalid := pty_host_encode_input(id, transmute([]byte)string("not ACP input"))
		defer delete(invalid)
		rejected, replied := pty_host_request_deadline(socket, invalid, 1500)
		defer pty_host_reply_delete(rejected)
		testing.expect(t, replied && rejected.kind == .Error, "the daemon explicitly rejected terminal input")
		after_input := bridge_instance_probe(id)
		testing.expect(t, after_input.state == "alive" && after_input.pid == launch.pid)
		client := Pty_Host_Client{socket = socket}
		signal, _ := bridge_pty_host_signal_detailed(&client, id, 15)
		if !testing.expect(t, signal != .Refused, "fixture child did not accept SIGTERM") do return
		exited: Bridge_Instance_Probe_Result
		for deadline := time.tick_now()._nsec + i64(5 * time.Second); time.tick_now()._nsec < deadline; {
			exited = bridge_instance_probe(id)
			if exited.state == "exited" do break
			time.sleep(10 * time.Millisecond)
		}
		bridge_instance_probe_bind(&exited, pid, 4, "pipe-fixture-epoch")
		code, has_code := exited.exit_code.?
		testing.expect(t, exited.state == "exited" && exited.pid == launch.pid && has_code && code != 0 && exited.run_count == 4,
			"confirmed terminal observation must match the real child PID and carry its exit code")
	}
}
