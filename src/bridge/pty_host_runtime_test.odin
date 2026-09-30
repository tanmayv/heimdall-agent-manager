package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:net"
import "core:testing"
import ws "odin_test:lib/ws"

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
	// sender_display_name preferred when provided
	m_dn := bridge_pty_host_message_notice("inst_sender", "Alice")
	defer delete(m_dn)
	testing.expect_value(t, m_dn, "New message from Alice \u2014 run './.heimdall/bin/ham-ctl agent chat read' to view.")
	// blank sender defaults to "user"
	m2 := bridge_pty_host_message_notice("  ")
	defer delete(m2)
	testing.expect(t, strings.contains(m2, "New message from user "), "blank sender => user")
}

@(test)
pty_host_task_nudge_notice_rendering :: proc(t: ^testing.T) {
	n := bridge_pty_host_task_nudge_notice("task_123", "assignee")
	defer delete(n)
	testing.expect_value(t, n, "Nudge: you have been nudged on task_123 (assignee). Run './.heimdall/bin/ham-ctl task list' and complete your assignment.")
	// with task title
	n_title := bridge_pty_host_task_nudge_notice("task_123", "assignee", "Fix the bug")
	defer delete(n_title)
	testing.expect_value(t, n_title, "Nudge: you have been nudged on \"Fix the bug\" (task_123) (assignee). Run './.heimdall/bin/ham-ctl task list' and complete your assignment.")
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

@(test)
shell_stream_attach_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Cached command returns early
	bridge_runtime_cache_command("cmd_stream_attach_1", `{"command_id":"cmd_stream_attach_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_stream_attach(nil, `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_1","session_id":"sh_test"}`)
	cached, ok := bridge_runtime_cached_command("cmd_stream_attach_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Missing session_id fails gracefully
	cmd_empty := `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_2","session_id":""}`
	bridge_hub_handle_shell_stream_attach(nil, cmd_empty)
	res2, res2_ok := bridge_runtime_cached_command("cmd_stream_attach_2")
	testing.expect(t, res2_ok, "command executed and cached")
	testing.expect(t, strings.contains(res2, "failed"), "missing session_id fails gracefully")

	// 3. Nested payload with missing session_id fails gracefully
	cmd_nested_empty := `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_3","payload":{"session_id":""}}`
	bridge_hub_handle_shell_stream_attach(nil, cmd_nested_empty)
	res3, res3_ok := bridge_runtime_cached_command("cmd_stream_attach_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "failed"), "nested empty session_id fails gracefully")

	// 4. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_4","session_id":""}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_stream_attach_4")
	testing.expect(t, res4_ok, "shell_stream_attach dispatched through bridge_hub_handle_command")
	testing.expect(t, strings.contains(res4, "failed"), "empty session_id fails gracefully")
}

@(test)
shell_stream_detach_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Cached command returns early
	bridge_runtime_cache_command("cmd_stream_detach_1", `{"command_id":"cmd_stream_detach_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_stream_detach(nil, `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_1","session_id":"sh_test"}`)
	cached, ok := bridge_runtime_cached_command("cmd_stream_detach_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Missing session_id fails gracefully
	cmd_empty := `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_2","session_id":""}`
	bridge_hub_handle_shell_stream_detach(nil, cmd_empty)
	res2, res2_ok := bridge_runtime_cached_command("cmd_stream_detach_2")
	testing.expect(t, res2_ok, "command executed and cached")
	testing.expect(t, strings.contains(res2, "failed"), "missing session_id fails gracefully")

	// 3. Detaching non-active session succeeds cleanly (idempotent)
	cmd_nonactive := `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_3","session_id":"sh_nonexistent"}`
	bridge_hub_handle_shell_stream_detach(nil, cmd_nonactive)
	res3, res3_ok := bridge_runtime_cached_command("cmd_stream_detach_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "succeeded"), "idempotent detach succeeds")

	// 4. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_4","session_id":""}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_stream_detach_4")
	testing.expect(t, res4_ok, "shell_stream_detach dispatched through bridge_hub_handle_command")
	testing.expect(t, strings.contains(res4, "failed"), "empty session_id fails gracefully")
}

@(private = "file")
bridge_test_stream_mutex: sync.Mutex

@(test)
pty_stream_worker_emit_frame_encodes_base64_and_queues :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_stream_mutex)
	defer sync.mutex_unlock(&bridge_test_stream_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	test_data := "echo streaming test\n"
	bridge_pty_stream_emit_frame(nil, "sh_stream_1", transmute([]byte)test_data)

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for f in frames do delete(f)
		delete(frames)
	}

	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 {
		frame := frames[0]
		testing.expect(t, strings.contains(frame, `"type":"shell_pty_output"`), "frame type is shell_pty_output")
		testing.expect(t, strings.contains(frame, `"session_id":"sh_stream_1"`), "frame has session_id")
		testing.expect(t, strings.contains(frame, `"data_b64":"ZWNobyBzdHJlYW1pbmcgdGVzdAo="`), "frame data_b64 matches encoded test string")
	}
}

@(test)
pty_stream_worker_detach_deregisters_immediately :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_stream_mutex)
	defer sync.mutex_unlock(&bridge_test_stream_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	heap := runtime.heap_allocator()
	worker := new(Bridge_PTY_Stream_Worker, heap)
	worker.session_id = strings.clone("sh_detach_imm", heap)
	worker.shell_id = strings.clone("sh_detach_imm", heap)
	worker.fd = fds[0]
	worker.active = true

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	if bridge_pty_stream_map.workers == nil {
		bridge_pty_stream_map.workers = make(map[string]^Bridge_PTY_Stream_Worker, allocator = heap)
	}
	bridge_pty_stream_map.workers[strings.clone("sh_detach_imm", heap)] = worker
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	testing.expect(t, bridge_pty_stream_worker_is_active("sh_detach_imm"), "worker is initially active")

	// Detach must immediately deregister from map
	bridge_pty_stream_worker_detach("sh_detach_imm")

	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_detach_imm"), "worker is no longer active after detach")

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	_, found := bridge_pty_stream_map.workers["sh_detach_imm"]
	testing.expect(t, !found, "session key immediately purged from bridge_pty_stream_map")
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	// Clean up worker memory
	delete(worker.session_id, heap)
	delete(worker.shell_id, heap)
	free(worker, heap)
}



// REQ-SHELL-5 §1: the line an agent sees when one of its BACKGROUND runs ends.
//
// The assertions worth having here are the two the requirement actually constrains:
// the SESSION ID is present (it is the handle the agent was handed when the run was
// backgrounded, and what `shell log` takes), and NO OUTPUT travels with the status.
@(test)
bridge_shell_run_notice_rendering :: proc(t: ^testing.T) {
	n := bridge_shell_run_notice("sh_123", "exited", "0")
	defer delete(n)
	testing.expect_value(t, n, "Shell run sh_123 exited (exit 0). Run './.heimdall/bin/ham-ctl shell log sh_123' to read its output.")

	// A kill reports as killed, and an unknown exit code is simply omitted rather than
	// fabricated as 0 — the agent must be able to tell "no code" from "exit 0".
	killed := bridge_shell_run_notice("sh_456", "killed", "")
	defer delete(killed)
	testing.expect_value(t, killed, "Shell run sh_456 killed. Run './.heimdall/bin/ham-ctl shell log sh_456' to read its output.")

	// Blank defaults, matching the task-nudge notice's behaviour above: render
	// something truthful rather than an empty sentence.
	blank := bridge_shell_run_notice("", "", "")
	defer delete(blank)
	testing.expect(t, strings.contains(blank, "Shell run unknown exited"), "blank session/status defaults")
}

// =============================================================================
// REQ-SHELL-40 — the BRIDGE half: no stream worker outlives the hub connection it was
// created for, and a re-attach for a live worker never creates a second one.
//
// NO PTY AND NO DAEMON (AC6). Workers are fabricated over a socketpair and registered
// directly, exactly as pty_stream_worker_detach_deregisters_immediately does — so these
// exercise the registry and teardown logic without ham-pty-host running and cannot hang
// on a dial. The reader thread is deliberately never started, so the tests free the
// worker structs themselves, which is otherwise the reader's teardown job.
// =============================================================================

// t40_fake_worker registers an active worker for `sid` over one end of a socketpair.
// Returns the worker so the caller can free it; the fds are the caller's to close.
@(private = "file")
t40_fake_worker :: proc(sid: string, fd: posix.FD) -> ^Bridge_PTY_Stream_Worker {
	heap := runtime.heap_allocator()
	worker := new(Bridge_PTY_Stream_Worker, heap)
	worker.session_id = strings.clone(sid, heap)
	worker.shell_id = strings.clone(sid, heap)
	worker.fd = fd
	worker.active = true

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	if bridge_pty_stream_map.workers == nil {
		bridge_pty_stream_map.workers = make(map[string]^Bridge_PTY_Stream_Worker, allocator = heap)
	}
	bridge_pty_stream_map.workers[strings.clone(sid, heap)] = worker
	sync.mutex_unlock(&bridge_pty_stream_map.mu)
	return worker
}

@(test)
t40_stop_all_for_reconnect_detaches_every_worker :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_stream_mutex)
	defer sync.mutex_unlock(&bridge_test_stream_mutex)

	// THE 128B THIS TEST REPORTS AS LEAKED IS THE DYNAMIC ARRAY'S BACKING, AND IT IS
	// DELIBERATELY NOT FREED. Read this before "fixing" it.
	//
	// stop_all frees each queued frame's json — `dropped_bytes` in its log line is the
	// evidence — but nothing frees the backing of `bridge_pty_stream_outgoing` itself,
	// because clear() does not and production never needs to: that queue is a global that
	// lives for the process's lifetime. So the allocation is correct in production and
	// merely *reported* here.
	//
	// I DID free it (delete + re-make under the queue mutex) and then took it back out,
	// because it is not safe while REQ-SHELL-44 stands. bridge_test_stream_mutex serialises
	// this test against every other TEST that touches the queue, but it cannot serialise it
	// against a stray real reader thread: the suite reaches
	// bridge_pty_host_ensure_daemon and can dial the REAL ham-pty-host, and a worker thread
	// spawned that way outlives the test that created it and appends to this very array
	// without holding that mutex. Freeing the backing under it would be a use-after-free,
	// where merely leaving it allocated is 128 reported bytes. A reported leak I can explain
	// beats a use-after-free I cannot rule out — pre-existing tests only clear() this array,
	// which does not free the backing, so freeing it would make this test strictly more
	// dangerous than its neighbours rather than equally safe.
	//
	// Revisit once REQ-SHELL-44 isolates the suite from the live daemon; then the free is
	// safe and this comment should go with it.

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds_a: [2]posix.FD
	fds_b: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds_a) != .OK {
		testing.expect(t, false, "socketpair a failed")
		return
	}
	defer posix.close(fds_a[0]); defer posix.close(fds_a[1])
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds_b) != .OK {
		testing.expect(t, false, "socketpair b failed")
		return
	}
	defer posix.close(fds_b[0]); defer posix.close(fds_b[1])

	// TWO workers, because the defect is that the hub re-attaches PER SESSION while the
	// teardown is per CONNECTION: one connection drop must take every session's worker
	// with it, not just the first one found.
	w_a := t40_fake_worker("sh_recon_a", fds_a[0])
	w_b := t40_fake_worker("sh_recon_b", fds_b[0])
	heap := runtime.heap_allocator()
	defer {
		delete(w_a.session_id, heap); delete(w_a.shell_id, heap); free(w_a, heap)
		delete(w_b.session_id, heap); delete(w_b.shell_id, heap); free(w_b, heap)
	}

	// A frame queued by a worker that is about to be torn down. After the teardown it can
	// never be delivered to anyone — the deliberate, logged drop.
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	append(&bridge_pty_stream_outgoing, Bridge_PTY_Stream_Outgoing{json = strings.clone(`{"type":"shell_pty_output","session_id":"sh_recon_a","data_b64":"QQ=="}`, heap)})
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)

	testing.expect(t, bridge_pty_stream_worker_is_active("sh_recon_a"), "worker a starts active")
	testing.expect(t, bridge_pty_stream_worker_is_active("sh_recon_b"), "worker b starts active")

	stopped := bridge_pty_stream_stop_all_for_reconnect()

	testing.expect_value(t, stopped, 2)
	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_recon_a"), "worker a must not survive the connection it belonged to")
	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_recon_b"), "worker b must not survive the connection it belonged to")

	// The registry must be EMPTY, not merely marked inactive. An entry left behind would
	// make the next worker_start for that session take the not-active fall-through branch
	// rather than a clean dial.
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	testing.expect_value(t, len(bridge_pty_stream_map.workers), 0)
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	// And the queue is drained, so the reconnect cannot paint pre-outage bytes over the
	// fresh catch-up snapshot the re-attach earns.
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	testing.expect_value(t, len(bridge_pty_stream_outgoing), 0)
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
}

@(test)
t40_stop_all_for_reconnect_is_a_noop_with_no_workers :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_stream_mutex)
	defer sync.mutex_unlock(&bridge_test_stream_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	// The overwhelmingly common reconnect: nobody had a pane open. This must cost nothing
	// and must not log, because a line on every reconnect of every idle bridge is how a
	// useful log becomes one nobody reads.
	testing.expect_value(t, bridge_pty_stream_stop_all_for_reconnect(), 0)
	testing.expect_value(t, bridge_pty_stream_stop_all_for_reconnect(), 0)
}

@(test)
t40_reattach_of_a_live_worker_creates_no_second_worker :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_stream_mutex)
	defer sync.mutex_unlock(&bridge_test_stream_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	// fds[0] is handed to the worker and is closed by bridge_pty_stream_reset below; only
	// the other end is ours to close.
	defer posix.close(fds[1])

	// NOT FREED HERE, unlike the two-worker test above. This worker is still REGISTERED
	// when the test ends — that is the whole point of the assertion — so the deferred
	// bridge_pty_stream_reset owns it: reset frees session_id, shell_id, the worker and
	// its map key, and closes its fd. Freeing it here too would be a use-after-free and a
	// double free, because defers run LIFO and ours would run BEFORE reset walked the map.
	worker := t40_fake_worker("sh_dup", fds[0])

	// THE LOAD-BEARING IDEMPOTENCE GUARD FOR AC4. The hub sends an attach per reconnect
	// and cannot know whether the bridge already has a worker, so a reconnect storm — or a
	// reconnect racing a genuine 0->1 viewer attach — puts several attaches on the wire
	// for one session. This early return is what makes that cost N no-ops instead of N
	// workers and N pty-host sockets.
	//
	// THIS TEST CANNOT DIAL, AND THAT IS THE ASSERTION, not a limitation. There is no
	// ham-pty-host running here, so bridge_pty_host_ensure_daemon would fail and
	// worker_start would return FALSE if it ever reached it. Getting `true` back is
	// therefore positive proof that the early return fired ahead of the dial — a weaker
	// test that merely counted map entries would also pass if the dedup were removed and
	// the dial simply failed.
	conn: ws.Connection
	ok := bridge_pty_stream_worker_start("sh_dup", "sh_dup", &conn)
	testing.expect(t, ok, "a re-attach for a live worker must succeed without dialing the pty-host")

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	testing.expect_value(t, len(bridge_pty_stream_map.workers), 1)
	still_there, found := bridge_pty_stream_map.workers["sh_dup"]
	sync.mutex_unlock(&bridge_pty_stream_map.mu)
	testing.expect(t, found, "the original worker must still be registered")
	testing.expect(t, still_there == worker, "the registered worker must be the SAME one, not a replacement")

	// And it was rebound to the connection the re-attach arrived on, which is what makes a
	// re-attach meaningful rather than merely harmless.
	testing.expect(t, worker.conn == &conn, "the live worker must be rebound to the new connection")
}

@(test)
t40_connection_teardown_retires_workers_then_closes :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_stream_mutex)
	defer sync.mutex_unlock(&bridge_test_stream_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	// THIS IS THE CALL-SITE TEST, and it exists because the other bridge tests cannot be
	// it. They assert what the teardown DOES; none of them can assert that it is CALLED on
	// the way to closing a connection, so before bridge_hub_connection_teardown existed an
	// edit that dropped or reordered the call kept every test green. Routing both closes
	// through one procedure is what made that testable without a live WS: the wrapper takes
	// a Connection, so a fake one is enough.
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	// fds[0] is the worker's; worker_detach only shuts it down, and the reader thread that
	// would normally close it is never started here, so it is ours to close. fds[1] is the
	// connection's and ws.close owns it — a REAL fd rather than a zero value, because
	// ws.close on a non-secure Connection calls net.close(conn.socket) and socket 0 would
	// close this process's stdin.
	defer posix.close(fds[0])

	worker := t40_fake_worker("sh_teardown", fds[0])
	heap := runtime.heap_allocator()
	defer { delete(worker.session_id, heap); delete(worker.shell_id, heap); free(worker, heap) }

	conn := ws.Connection{connected = true, socket = net.TCP_Socket(fds[1])}
	testing.expect(t, bridge_pty_stream_worker_is_active("sh_teardown"), "worker starts active")

	bridge_hub_connection_teardown(&conn)

	// BOTH effects from ONE call is the assertion. Either one missing means a connection
	// was closed with a worker still holding a pointer to it, or a worker was retired
	// without the connection being closed.
	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_teardown"), "teardown must retire the worker")
	testing.expect(t, !conn.connected, "teardown must close the connection")
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	testing.expect_value(t, len(bridge_pty_stream_map.workers), 0)
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	// Idempotent, because the hello-failure path and the shared path both route through
	// this and a future edit may well call it twice.
	bridge_hub_connection_teardown(&conn)
	testing.expect(t, !conn.connected, "a second teardown is harmless")
}
