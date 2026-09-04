package main

import "core:os"
import "core:strings"
import "core:testing"

// BR-2 runtime-layer tests: the flag gate, env-pair conversion, and spawn-request
// assembly. These exercise the mapping logic without a live daemon (control-plane
// round-trips against a real ham-pty-host are covered by the daemon's own HOST-1
// integration tests + the codec tests here).

@(test)
pty_host_flag_truthy_parsing :: proc(t: ^testing.T) {
	testing.expect(t, bridge_pty_host_truthy("1"), "1 is truthy")
	testing.expect(t, bridge_pty_host_truthy("true"), "true is truthy")
	testing.expect(t, bridge_pty_host_truthy("TRUE"), "TRUE is truthy")
	testing.expect(t, bridge_pty_host_truthy(" on "), "on (padded) is truthy")
	testing.expect(t, bridge_pty_host_truthy("yes"), "yes is truthy")
	testing.expect(t, !bridge_pty_host_truthy("0"), "0 is falsey")
	testing.expect(t, !bridge_pty_host_truthy("false"), "false is falsey")
	testing.expect(t, !bridge_pty_host_truthy(""), "empty is falsey")
	testing.expect(t, !bridge_pty_host_truthy("nope"), "garbage is falsey")
}

@(test)
pty_host_flag_env_override_wins :: proc(t: ^testing.T) {
	// Default (no env, config false) => tmux path.
	old := os.get_env_alloc("HEIMDALL_BRIDGE_PTY_HOST", context.allocator)
	defer {
		if strings.trim_space(old) != "" { _ = os.set_env("HEIMDALL_BRIDGE_PTY_HOST", old) } else { _ = os.unset_env("HEIMDALL_BRIDGE_PTY_HOST") }
	}
	_ = os.unset_env("HEIMDALL_BRIDGE_PTY_HOST")
	bridge_config.pty_host_runtime = false
	testing.expect(t, !bridge_pty_host_runtime_enabled(), "off by default")

	// Config on => enabled.
	bridge_config.pty_host_runtime = true
	testing.expect(t, bridge_pty_host_runtime_enabled(), "config flag enables")

	// Env override to 0 beats config true.
	_ = os.set_env("HEIMDALL_BRIDGE_PTY_HOST", "0")
	testing.expect(t, !bridge_pty_host_runtime_enabled(), "env 0 overrides config true")

	// Env override to 1 with config false.
	bridge_config.pty_host_runtime = false
	_ = os.set_env("HEIMDALL_BRIDGE_PTY_HOST", "1")
	testing.expect(t, bridge_pty_host_runtime_enabled(), "env 1 overrides config false")

	bridge_config.pty_host_runtime = false
}

@(test)
pty_host_env_pairs_splits_on_first_eq :: proc(t: ^testing.T) {
	env := []string{
		"HEIMDALL_BRIDGE_ENDPOINT=unix:/tmp/b.sock",
		"HEIMDALL_AGENT_TOKEN=hlat_a=b=c", // value contains '='
		"NO_EQUALS_SKIPPED",
		"=leading-eq-skipped",
		"HEIMDALL_CTL_BIN=/run/.heimdall/bin/ham-ctl",
	}
	pairs := bridge_pty_host_env_pairs(env)
	defer { for kv in pairs { delete(kv[0]); delete(kv[1]) }; delete(pairs) }

	testing.expect_value(t, len(pairs), 3)
	testing.expect_value(t, pairs[0][0], "HEIMDALL_BRIDGE_ENDPOINT")
	testing.expect_value(t, pairs[0][1], "unix:/tmp/b.sock")
	// split on FIRST '=' only => value keeps the remaining '='s
	testing.expect_value(t, pairs[1][0], "HEIMDALL_AGENT_TOKEN")
	testing.expect_value(t, pairs[1][1], "hlat_a=b=c")
	testing.expect_value(t, pairs[2][0], "HEIMDALL_CTL_BIN")
	testing.expect_value(t, pairs[2][1], "/run/.heimdall/bin/ham-ctl")
}

@(test)
pty_host_socket_path_under_run_dir :: proc(t: ^testing.T) {
	old := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = old }

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-x"
	p := pty_host_socket_path()
	defer delete(p)
	testing.expect_value(t, p, "/tmp/heimdall-bridge-x/pty-host.sock")

	// Trailing slash must not double up.
	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-x/"
	p2 := pty_host_socket_path()
	defer delete(p2)
	testing.expect_value(t, p2, "/tmp/heimdall-bridge-x/pty-host.sock")
}

@(test)
pty_host_message_notice_rendering :: proc(t: ^testing.T) {
	m := bridge_pty_host_message_notice("inst_sender")
	defer delete(m)
	testing.expect_value(t, m, "New message from inst_sender \u2014 run './.heimdall/bin/ham-ctl agent chat read' to view.")
	// blank sender defaults to "user"
	m2 := bridge_pty_host_message_notice("  ")
	defer delete(m2)
	testing.expect(t, strings.contains(m2, "New message from user "), "blank sender => user")
}

@(test)
pty_host_task_nudge_notice_rendering :: proc(t: ^testing.T) {
	n := bridge_pty_host_task_nudge_notice("task_123", "assignee")
	defer delete(n)
	testing.expect_value(t, n, "Nudge: you have been nudged on task_123 (assignee). Run './.heimdall/bin/ham-ctl tasks list' and complete your assignment.")
	// blank defaults
	n2 := bridge_pty_host_task_nudge_notice("", "")
	defer delete(n2)
	testing.expect(t, strings.contains(n2, "nudged on unknown (participant)"), "blank task/role defaults")
}

// pty_host_delivery_maps_push_to_input_enter proves the delivery primitive's wire
// shape: a notice becomes Input(instance, text) followed by Key(instance, Enter) —
// the host analog of tmux.send_text(pane, text, enter=true).
@(test)
pty_host_delivery_maps_push_to_input_enter :: proc(t: ^testing.T) {
	notice := bridge_pty_host_message_notice("user")
	defer delete(notice)

	input := pty_host_encode_input("inst_a", transmute([]byte)notice)
	defer delete(input)
	ip := pty_host_test_reframe(t, input)
	testing.expect_value(t, ip[0], u8(PTY_HOST_T_INPUT))
	// tag + u32 len(6) + "inst_a" + raw notice bytes
	testing.expect_value(t, len(ip), 1 + 4 + 6 + len(notice))

	key := pty_host_encode_key("inst_a", .Enter)
	defer delete(key)
	kp := pty_host_test_reframe(t, key)
	want := []byte{PTY_HOST_T_KEY, 0, 0, 0, 6, 'i', 'n', 's', 't', '_', 'a', 1}
	testing.expect_value(t, len(kp), len(want))
	for i in 0..<len(want) do testing.expect_value(t, kp[i], want[i])
}

@(test)
pty_host_build_spawn_from_profile :: proc(t: ^testing.T) {
	// Requires a runnable provider profile. Use the resolved default provider; if
	// none is runnable in this build/test env, skip (the assembly logic is still
	// covered by the codec's Spawn tests).
	bridge_provider_store_init()
	env := []string{"HEIMDALL_AGENT_TOKEN=hlat_x", "HEIMDALL_CTL_BIN=/run/.heimdall/bin/ham-ctl"}
	req, ok := bridge_pty_host_build_spawn("inst_test", "/tmp/run/inst_test", "", "", "hlat_x", env)
	if !ok do return // no runnable provider in this environment; nothing to assert
	defer bridge_pty_host_spawn_request_delete(req)

	testing.expect_value(t, req.instance, "inst_test")
	testing.expect_value(t, req.cwd, "/tmp/run/inst_test")
	testing.expect(t, req.has_cwd, "cwd present")
	testing.expect(t, len(req.argv) > 0, "argv non-empty")
	testing.expect_value(t, len(req.env), 2)
	testing.expect_value(t, req.rows, u16(PTY_HOST_DEFAULT_ROWS))
	testing.expect_value(t, req.cols, u16(PTY_HOST_DEFAULT_COLS))
}
