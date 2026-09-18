package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
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
pty_host_always_enabled :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old_pty := bridge_config.pty_host_runtime
	defer { bridge_config.pty_host_runtime = old_pty }

	// DEL-1: ham-pty-host is the only agent-launch runtime; the tmux path was
	// removed, so bridge_pty_host_runtime_enabled() is always true regardless of
	// the (now no-op) config flag / env override.
	old := os.get_env_alloc("HEIMDALL_BRIDGE_PTY_HOST", context.allocator)
	defer {
		if strings.trim_space(old) != "" { _ = os.set_env("HEIMDALL_BRIDGE_PTY_HOST", old) } else { _ = os.unset_env("HEIMDALL_BRIDGE_PTY_HOST") }
	}
	_ = os.unset_env("HEIMDALL_BRIDGE_PTY_HOST")
	bridge_config.pty_host_runtime = false
	testing.expect(t, bridge_pty_host_runtime_enabled(), "always enabled even with config false + no env")

	_ = os.set_env("HEIMDALL_BRIDGE_PTY_HOST", "0")
	testing.expect(t, bridge_pty_host_runtime_enabled(), "env 0 no longer re-enables the removed tmux path")

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
	// Shares the global bridge_config with the BR-2a socket tests; serialize on the
	// same mutex and snapshot/restore. BR-2a made the socket name bridge-unique, so
	// pin a known identity and assert the new <run_dir>/pty-host-<id>.sock shape.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old_dir := bridge_config.local_endpoint_run_dir
	old_id := bridge_config.daemon_id
	old_port := bridge_config.local_endpoint_port
	defer { bridge_config.local_endpoint_run_dir = old_dir; bridge_config.daemon_id = old_id; bridge_config.local_endpoint_port = old_port }
	bridge_config.daemon_id = "brg_z"
	bridge_config.local_endpoint_port = 0

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-x"
	p := pty_host_socket_path()
	defer delete(p)
	testing.expect_value(t, p, "/tmp/heimdall-bridge-x/pty-host-brg_z.sock")

	// Trailing slash must not double up.
	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-x/"
	p2 := pty_host_socket_path()
	defer delete(p2)
	testing.expect_value(t, p2, "/tmp/heimdall-bridge-x/pty-host-brg_z.sock")
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

// MEM-6: the delivered line prefers the hub's human_message verbatim, falling back
// to the legacy generated notice when it is absent/blank.
@(test)
pty_host_task_nudge_line_prefers_human_message :: proc(t: ^testing.T) {
	hm := bridge_pty_host_task_nudge_line("task_9", "assignee", `[Review Requested] @coder #1 submitted for review "Fix bug" (task_9)`)
	defer delete(hm)
	testing.expect_value(t, hm, `[Review Requested] @coder #1 submitted for review "Fix bug" (task_9)`)

	lg := bridge_pty_host_task_nudge_line("task_9", "assignee", "")
	defer delete(lg)
	testing.expect(t, strings.contains(lg, "you have been nudged on task_9 (assignee)"), "empty human_message falls back to legacy notice")

	blank := bridge_pty_host_task_nudge_line("task_9", "reviewer", "   ")
	defer delete(blank)
	testing.expect(t, strings.contains(blank, "nudged on task_9 (reviewer)"), "whitespace human_message falls back to legacy notice")
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

// pty_host_user_message_interrupts_with_esc pins the wire shape of the ESC key
// that bridge_pty_host_deliver_message sends BEFORE typing a user-message notice.
// Pressing ESC first interrupts the agent's current turn so it drops to an
// input-ready prompt and picks up the just-arrived user message ASAP. The key
// tag byte is the Esc discriminant (2), which must stay in sync with proto.rs.
@(test)
pty_host_user_message_interrupts_with_esc :: proc(t: ^testing.T) {
	esc := pty_host_encode_key("inst_a", .Esc)
	defer delete(esc)
	ep := pty_host_test_reframe(t, esc)
	want := []byte{PTY_HOST_T_KEY, 0, 0, 0, 6, 'i', 'n', 's', 't', '_', 'a', 2}
	testing.expect_value(t, len(ep), len(want))
	for i in 0..<len(want) do testing.expect_value(t, ep[i], want[i])
}

@(test)
pty_host_build_spawn_from_profile :: proc(t: ^testing.T) {
	// Requires a runnable provider profile. Use the resolved default provider; if
	// none is runnable in this build/test env, skip (the assembly logic is still
	// covered by the codec's Spawn tests).
	bridge_provider_store_init()
	env := []string{"HEIMDALL_AGENT_TOKEN=hlat_x", "HEIMDALL_CTL_BIN=/run/.heimdall/bin/ham-ctl"}
	req, ok := bridge_pty_host_build_spawn("inst_test", "/tmp/run/inst_test", "", "", "hlat_x", env, "test-agent #1")
	if !ok do return // no runnable provider in this environment; nothing to assert
	defer bridge_pty_host_spawn_request_delete(req)

	testing.expect_value(t, req.instance, "inst_test")
	testing.expect_value(t, req.display_name, "test-agent #1")
	testing.expect(t, req.has_display_name, "display_name present")
	testing.expect_value(t, req.cwd, "/tmp/run/inst_test")
	testing.expect(t, req.has_cwd, "cwd present")
	testing.expect(t, len(req.argv) > 0, "argv non-empty")
	testing.expect_value(t, len(req.env), 2)
	testing.expect_value(t, req.rows, u16(25))
	testing.expect_value(t, req.cols, u16(80))
	testing.expect_value(t, req.rows, u16(PTY_HOST_DEFAULT_ROWS))
	testing.expect_value(t, req.cols, u16(PTY_HOST_DEFAULT_COLS))
}

@(test)
pty_host_raw_input_framing :: proc(t: ^testing.T) {
	data := "echo hello\n"
	frame := pty_host_encode_input("inst_a", transmute([]byte)data)
	defer delete(frame)
	ip := pty_host_test_reframe(t, frame)
	testing.expect_value(t, ip[0], u8(PTY_HOST_T_INPUT))
	// tag + u32 len(6) + "inst_a" + raw data bytes
	testing.expect_value(t, len(ip), 1 + 4 + 6 + len(data))
	// Verify raw data bytes match exactly
	testing.expect_value(t, string(ip[11:]), data)
}

@(test)
pty_host_deliver_raw_input_rejects_empty :: proc(t: ^testing.T) {
	data := "test input"
	testing.expect(t, !bridge_pty_host_deliver_raw_input("", data), "empty instance fails")
	testing.expect(t, !bridge_pty_host_deliver_raw_input("", "inst_a", data), "empty socket fails")
	testing.expect(t, !bridge_pty_host_deliver_raw_input("/nonexistent.sock", "", data), "empty instance with socket fails")
}

@(test)
agent_pty_input_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields
	cmd_top := `{"type":"agent_pty_input","command_id":"cmd_input_1","agent_instance_id":"inst_test","data":"cmd1"}`
	bridge_runtime_cache_command("cmd_input_1", `{"command_id":"cmd_input_1","status":"cached_ok"}`)
	bridge_hub_handle_agent_pty_input(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_input_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Nested payload fields
	cmd_nested := `{"type":"agent_pty_input","command_id":"cmd_input_2","payload":{"agent_instance_id":"","data":""}}`
	bridge_hub_handle_agent_pty_input(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_input_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expect(t, strings.contains(res, "failed"), "empty instance fails gracefully")
}

@(test)
pty_host_resize_framing :: proc(t: ^testing.T) {
	frame := pty_host_encode_resize("inst_a", 24, 100)
	defer delete(frame)
	pl := pty_host_test_reframe(t, frame)
	// Resize: tag(PTY_HOST_T_RESIZE) + u32 len(6) + "inst_a" + u16 rows(24) + u16 cols(100)
	want := []byte{PTY_HOST_T_RESIZE, 0, 0, 0, 6, 'i', 'n', 's', 't', '_', 'a', 0, 24, 0, 100}
	testing.expect_value(t, len(pl), len(want))
	for i in 0..<len(want) do testing.expect_value(t, pl[i], want[i])
}

@(test)
pty_host_deliver_resize_rejects_invalid :: proc(t: ^testing.T) {
	testing.expect(t, !bridge_pty_host_deliver_resize("", 24, 100), "empty instance fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("inst_a", 0, 100), "zero rows fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("inst_a", 24, 0), "zero cols fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("", "inst_a", 24, 100), "empty socket fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("/nonexistent.sock", "", 24, 100), "empty instance with socket fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("/nonexistent.sock", "inst_a", 0, 100), "zero rows with socket fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("/nonexistent.sock", "inst_a", 24, 0), "zero cols with socket fails")
}

@(test)
agent_pty_resize_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields
	cmd_top := `{"type":"agent_pty_resize","command_id":"cmd_resize_1","agent_instance_id":"inst_test","rows":24,"cols":100}`
	bridge_runtime_cache_command("cmd_resize_1", `{"command_id":"cmd_resize_1","status":"cached_ok"}`)
	bridge_hub_handle_agent_pty_resize(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_resize_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Nested payload fields
	cmd_nested := `{"type":"agent_pty_resize","command_id":"cmd_resize_2","payload":{"agent_instance_id":"","rows":24,"cols":100}}`
	bridge_hub_handle_agent_pty_resize(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_resize_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expect(t, strings.contains(res, "failed"), "empty instance fails gracefully")

	// 3. Nested payload with zero dimensions
	cmd_zero := `{"type":"agent_pty_resize","command_id":"cmd_resize_3","payload":{"agent_instance_id":"inst_test","rows":0,"cols":100}}`
	bridge_hub_handle_agent_pty_resize(nil, cmd_zero)
	res3, res3_ok := bridge_runtime_cached_command("cmd_resize_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "failed"), "zero rows fails gracefully")

	// 4. Also verify dispatch through bridge_hub_handle_command
	cmd_dispatch := `{"type":"agent_pty_resize","command_id":"cmd_resize_4","agent_instance_id":"","rows":24,"cols":100}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_resize_4")
	testing.expect(t, res4_ok, "command dispatched through bridge_hub_handle_command and cached")
	testing.expect(t, strings.contains(res4, "failed"), "empty instance fails gracefully")
}

@(test)
shell_pty_input_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields with shell_id
	cmd_top := `{"type":"shell_pty_input","command_id":"cmd_shell_input_1","shell_id":"sh_test","data":"echo hello"}`
	bridge_runtime_cache_command("cmd_shell_input_1", `{"command_id":"cmd_shell_input_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_pty_input(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_shell_input_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Nested payload fields with shell_id
	cmd_nested := `{"type":"shell_pty_input","command_id":"cmd_shell_input_2","payload":{"shell_id":"","data":""}}`
	bridge_hub_handle_shell_pty_input(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_shell_input_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expectf(t, strings.contains(res, "failed"), "empty shell_id fails gracefully, got: %s", res)

	// 3. Fallback to agent_instance_id when shell_id is omitted
	cmd_fallback := `{"type":"shell_pty_input","command_id":"cmd_shell_input_3","payload":{"agent_instance_id":"","data":""}}`
	bridge_hub_handle_shell_pty_input(nil, cmd_fallback)
	res3, res3_ok := bridge_runtime_cached_command("cmd_shell_input_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expectf(t, strings.contains(res3, "failed"), "empty fallback agent_instance_id fails gracefully, got: %s", res3)

	// 4. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_pty_input","command_id":"cmd_shell_input_4","shell_id":"","data":"test"}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_shell_input_4")
	testing.expect(t, res4_ok, "shell_pty_input dispatched through bridge_hub_handle_command")
	testing.expectf(t, strings.contains(res4, "failed"), "empty shell_id fails gracefully, got: %s", res4)
}

@(test)
shell_pty_resize_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields with shell_id
	cmd_top := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_1","shell_id":"sh_test","rows":30,"cols":120}`
	bridge_runtime_cache_command("cmd_shell_resize_1", `{"command_id":"cmd_shell_resize_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_pty_resize(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_shell_resize_1")
	testing.expect(t, ok, "cached command found")
	testing.expectf(t, strings.contains(cached, "cached_ok"), "cached result matched, got: %s", cached)

	// 2. Nested payload fields with shell_id
	cmd_nested := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_2","payload":{"shell_id":"","rows":30,"cols":120}}`
	bridge_hub_handle_shell_pty_resize(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_shell_resize_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expectf(t, strings.contains(res, "failed"), "empty shell_id fails gracefully, got: %s", res)

	// 3. Fallback to agent_instance_id when shell_id is omitted
	cmd_fallback := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_3","payload":{"agent_instance_id":"","rows":30,"cols":120}}`
	bridge_hub_handle_shell_pty_resize(nil, cmd_fallback)
	res3, res3_ok := bridge_runtime_cached_command("cmd_shell_resize_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "failed"), "empty fallback agent_instance_id fails gracefully")

	// 4. Nested payload with zero dimensions
	cmd_zero := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_4","payload":{"shell_id":"sh_test","rows":0,"cols":120}}`
	bridge_hub_handle_shell_pty_resize(nil, cmd_zero)
	res4, res4_ok := bridge_runtime_cached_command("cmd_shell_resize_4")
	testing.expect(t, res4_ok, "command executed and cached")
	testing.expect(t, strings.contains(res4, "failed"), "zero rows fails gracefully")

	// 5. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_5","shell_id":"","rows":30,"cols":120}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res5, res5_ok := bridge_runtime_cached_command("cmd_shell_resize_5")
	testing.expect(t, res5_ok, "shell_pty_resize dispatched through bridge_hub_handle_command")
	testing.expect(t, strings.contains(res5, "failed"), "empty shell_id fails gracefully")
}

@(test)
pty_host_deliver_shell_input_and_resize_validation :: proc(t: ^testing.T) {
	testing.expect(t, !bridge_pty_host_deliver_shell_input("", "data"), "empty shell_id fails for input")
	testing.expect(t, !bridge_pty_host_deliver_shell_resize("", 24, 100), "empty shell_id fails for resize")
	testing.expect(t, !bridge_pty_host_deliver_shell_resize("sh_a", 0, 100), "zero rows fails for resize")
	testing.expect(t, !bridge_pty_host_deliver_shell_resize("sh_a", 24, 0), "zero cols fails for resize")
}

