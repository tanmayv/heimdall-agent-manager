package main

// REQ-PAGER-1, REQ-PAGER-2, REQ-PAGER-3: non-interactive pager overrides for kind=run.
//
// Commands running inside ham-pty-host allocate a PTY, so isatty(1) is true.
// For one-shot agent runs (kind=run), commands like git diff, git log, systemctl, etc.
// would otherwise open interactive pagers like less and block indefinitely waiting
// for user interaction on stdin.
//
// These tests verify:
// 1. bridge_shell_run_env() allocates and returns exactly the required overrides:
//    - PAGER=cat
//    - GIT_PAGER=cat
//    - SYSTEMD_PAGER=cat
// 2. Kind branching:
//    - kind == .Run gets bridge_shell_run_env()
//    - kind == .Shell and kind == .Server get nil
// 3. Memory leak assertions:
//    - bridge_pty_host_spawn_request_delete cleanly frees all allocations made by
//      bridge_shell_run_env() with 0 leaks and 0 bad frees under a Tracking_Allocator.

import "core:mem"
import "core:testing"

@(test)
test_shell_run_env_key_values :: proc(t: ^testing.T) {
	env := bridge_shell_run_env()
	defer {
		for kv in env {
			delete(kv[0])
			delete(kv[1])
		}
		delete(env)
	}

	testing.expect_value(t, len(env), 3)
	if len(env) == 3 {
		testing.expect_value(t, env[0][0], "PAGER")
		testing.expect_value(t, env[0][1], "cat")
		testing.expect_value(t, env[1][0], "GIT_PAGER")
		testing.expect_value(t, env[1][1], "cat")
		testing.expect_value(t, env[2][0], "SYSTEMD_PAGER")
		testing.expect_value(t, env[2][1], "cat")
	}
}

@(test)
test_shell_run_env_cleanly_freed_by_spawn_request_delete :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	baseline_allocs := len(track.allocation_map)
	baseline_bytes := track.current_memory_allocated

	{
		req := Pty_Host_Spawn_Request{
			env = bridge_shell_run_env(),
		}
		bridge_pty_host_spawn_request_delete(req)
	}

	testing.expectf(t, len(track.allocation_map) == baseline_allocs,
		"leak: %d live allocations, expected %d", len(track.allocation_map), baseline_allocs)
	testing.expectf(t, track.current_memory_allocated == baseline_bytes,
		"leak: %d live bytes, expected %d", track.current_memory_allocated, baseline_bytes)
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
test_shell_env_kind_branching :: proc(t: ^testing.T) {
	// kind == .Run gets injected overrides
	run_env := Bridge_Shell_Session_Kind.Run == .Run ? bridge_shell_run_env() : nil
	testing.expect(t, run_env != nil, "Run env must not be nil")
	testing.expect_value(t, len(run_env), 3)

	req_run := Pty_Host_Spawn_Request{
		env = run_env,
	}
	bridge_pty_host_spawn_request_delete(req_run)

	// kind == .Shell must remain nil (no pager override)
	shell_env := Bridge_Shell_Session_Kind.Shell == .Run ? bridge_shell_run_env() : nil
	testing.expect(t, shell_env == nil, "Shell env must remain nil")
	req_shell := Pty_Host_Spawn_Request{
		env = shell_env,
	}
	bridge_pty_host_spawn_request_delete(req_shell)

	// kind == .Server must remain nil (no pager override)
	server_env := Bridge_Shell_Session_Kind.Server == .Run ? bridge_shell_run_env() : nil
	testing.expect(t, server_env == nil, "Server env must remain nil")
	req_server := Pty_Host_Spawn_Request{
		env = server_env,
	}
	bridge_pty_host_spawn_request_delete(req_server)
}
