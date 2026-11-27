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
		prev_config := bridge_config
		bridge_config.local_endpoint_run_dir, bridge_config.daemon_id, bridge_config.data_dir = dir, "pipe-fixture", dir
		defer bridge_config = prev_config
		prev_tokens := bridge_local_token_records
		bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
		defer {
			for rec in bridge_local_token_records { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
			delete(bridge_local_token_records)
			bridge_local_token_records = prev_tokens
		}
		socket := pty_host_socket_path()
		defer delete(socket)
		swap := pty_host_test_install_socket(socket)
		defer pty_host_test_restore_socket(swap)
		daemon, spawn_err := os.process_start({command = {bin, "daemon", "--socket", socket}, env = {fmt.tprintf("HOME=%s", dir), "PATH=/usr/bin:/bin"}})
		if !testing.expect(t, spawn_err == nil, "could not start fixture daemon") do return
		daemon_waited := false
		defer if !daemon_waited {
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
		when ODIN_OS == .Linux {
			// Both children are independent of pipe EOF. The first should die
			// with the daemon, and the second deliberately ignores SIGTERM.
			normal, normal_ok := pty_host_spawn_pipe(socket, {
				mode = .Pipe, instance = "inst_parent_signal", argv = {"/bin/sleep", "300"},
				env = {{"PATH", "/usr/bin:/bin"}, {"HOME", dir}}, cwd = dir, has_cwd = true,
			})
			defer pty_host_reply_delete(normal)
			if !testing.expect(t, normal_ok && normal.kind == .Spawned) do return
			normal_token := bridge_agent_token_issue("inst_parent_signal", "fixture~normal_epoch", .Agent, 3)
			normal_rec, _ := bridge_agent_token_verify(normal_token.plaintext_token)
			bridge_agent_remember_process("inst_parent_signal", normal_rec.token_hash, normal.pid)
			normal_identity := bridge_agent_previous_process("inst_parent_signal", 3)
			defer if bridge_agent_process_match(normal_identity, bridge_agent_process_os_read(normal.pid)) == .Alive {
				_ = bridge_agent_process_kill_orphan(normal_identity)
			}
			ready_path := fmt.tprintf("%s/orphan-ready", dir)
			orphan, orphan_ok := pty_host_spawn_pipe(socket, {
				mode = .Pipe, instance = "inst_orphan_signal",
				argv = {"/bin/sh", "-c", "trap '' TERM; : > \"$1\"; exec /bin/sleep 300", "fixture", ready_path},
				env = {{"PATH", "/usr/bin:/bin"}, {"HOME", dir}}, cwd = dir, has_cwd = true,
			})
			defer pty_host_reply_delete(orphan)
			if !testing.expect(t, orphan_ok && orphan.kind == .Spawned) do return
			orphan_token := bridge_agent_token_issue("inst_orphan_signal", "fixture~orphan_epoch", .Agent, 4)
			orphan_rec, _ := bridge_agent_token_verify(orphan_token.plaintext_token)
			bridge_agent_remember_process("inst_orphan_signal", orphan_rec.token_hash, orphan.pid)
			orphan_identity := bridge_agent_previous_process("inst_orphan_signal", 4)
			defer if bridge_agent_process_match(orphan_identity, bridge_agent_process_os_read(orphan.pid)) == .Alive {
				_ = bridge_agent_process_kill_orphan(orphan_identity)
			}
			for deadline := time.tick_now()._nsec + i64(2 * time.Second); !os.exists(ready_path) && time.tick_now()._nsec < deadline; {
				time.sleep(10 * time.Millisecond)
			}
			if !testing.expect(t, os.exists(ready_path) && orphan_identity.start > 0 && normal_identity.start > 0) do return
			testing.expect(t, bridge_instance_probe("inst_parent_signal").state == "alive", "one-shot spawn socket may close without causing parent death")
			testing.expect(t, os.process_kill(daemon) == nil)
			_, _ = os.process_wait(daemon)
			daemon_waited = true
			for deadline := time.tick_now()._nsec + i64(2 * time.Second); time.tick_now()._nsec < deadline; {
				if bridge_agent_process_match(normal_identity, bridge_agent_process_os_read(normal.pid)) == .Gone do break
				time.sleep(10 * time.Millisecond)
			}
			testing.expect_value(t, bridge_agent_process_match(normal_identity, bridge_agent_process_os_read(normal.pid)), Bridge_Agent_Process_State.Gone)
			testing.expect_value(t, bridge_agent_process_match(orphan_identity, bridge_agent_process_os_read(orphan.pid)), Bridge_Agent_Process_State.Alive)
			wrong := orphan_identity
			wrong.start += 1
			testing.expect(t, !bridge_agent_process_kill_orphan(wrong), "a different start time must never signal the process")
			offline := bridge_instance_probe_for_hub("inst_orphan_signal")
			defer delete(offline.launch_epoch)
			testing.expect_value(t, offline.state, "unknown")
			_ = os.remove(socket)
			next_daemon, next_err := os.process_start({command = {bin, "daemon", "--socket", socket}, env = {fmt.tprintf("HOME=%s", dir), "PATH=/usr/bin:/bin"}})
			if !testing.expect(t, next_err == nil, "start isolated replacement daemon") do return
			defer { _ = os.process_kill(next_daemon); _, _ = os.process_wait(next_daemon) }
			next_ready := false
			for deadline := time.tick_now()._nsec + i64(3 * time.Second); time.tick_now()._nsec < deadline; {
				if bridge_pty_host_ping(socket) { next_ready = true; break }
				time.sleep(10 * time.Millisecond)
			}
			if !testing.expect(t, next_ready) do return
			absent := bridge_instance_probe_for_hub("inst_parent_signal")
			defer delete(absent.launch_epoch)
			testing.expect(t, absent.state == "absent" && absent.source == "os_identity_gone" &&
				absent.run_count == 3 && absent.launch_epoch == "normal_epoch" && absent.exit_code == nil, "bound absence must not invent an exit code")
			reaped := bridge_instance_probe_for_hub("inst_orphan_signal")
			defer delete(reaped.launch_epoch)
			testing.expect(t, reaped.state == "exited" && reaped.source == "orphan_reaped" &&
				reaped.run_count == 4 && reaped.launch_epoch == "orphan_epoch" && reaped.pid == orphan.pid && reaped.exit_code == nil)
			testing.expect_value(t, bridge_agent_process_match(orphan_identity, bridge_agent_process_os_read(orphan.pid)), Bridge_Agent_Process_State.Gone)
		}
	}
}
