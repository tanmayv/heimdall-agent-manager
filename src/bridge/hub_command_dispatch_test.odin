package main

import "core:strings"
import "core:testing"

@(test)
bridge_dispatch_classifies_blocking_incident_paths :: proc(t: ^testing.T) {
	lifecycle, lifecycle_ok := bridge_command_dispatch_class("launch_agent")
	background, background_ok := bridge_command_dispatch_class("provider_discover")
	interactive, interactive_ok := bridge_command_dispatch_class("notify_task_nudge")
	exclusive, exclusive_ok := bridge_command_dispatch_class("bridge_update")
	general_io, general_io_ok := bridge_command_dispatch_class("vcs_status")
	shell, shell_ok := bridge_command_dispatch_class("shell_start")
	_, heartbeat_async := bridge_command_dispatch_class("bridge_heartbeat_ack")
	_, tunnel_async := bridge_command_dispatch_class("tunnel_data")
	testing.expect(t, lifecycle_ok && lifecycle == .Lifecycle, "agent launch must use the isolated lifecycle lane")
	testing.expect(t, background_ok && background == .Background, "provider discovery must use the shed-first background lane")
	testing.expect(t, interactive_ok && interactive == .Interactive, "notifications must not share the background lane")
	testing.expect(t, exclusive_ok && exclusive == .Exclusive, "Bridge update must never execute on the reader or lifecycle lane")
	testing.expect(t, general_io_ok && general_io == .General_IO, "filesystem and VCS work must use a bounded IO lane")
	testing.expect(t, shell_ok && shell == .Shell, "shell control must preserve its own FIFO lane")
	testing.expect(t, !heartbeat_async, "heartbeat acknowledgement must remain reader-local control traffic")
	testing.expect(t, !tunnel_async, "stream data remains on its specialized data plane")
	testing.expect(t, bridge_command_inline_type("bridge_heartbeat_ack"), "heartbeat acknowledgement is an explicit inline control type")
	testing.expect(t, bridge_command_inline_type("tunnel_data"), "tunnel data is an explicit specialized data-plane type")
	testing.expect(t, !bridge_command_inline_type("made_up_command"), "unknown commands must not fall through to inline execution")
}

@(test)
bridge_dispatch_admission_is_bounded_and_reserves_control_path :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Background, 0, 0, 0, 0, 128), "")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Background, 0, BRIDGE_DISPATCH_BACKGROUND_LIMIT, 0, 0, 128), "background")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, BRIDGE_DISPATCH_TOTAL_LIMIT, 0, 0, 0, 128), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Interactive, 0, 0, BRIDGE_DISPATCH_OWNED_BYTES_LIMIT, 0, 1), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Interactive, 0, 0, 0, BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT, 1), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, BRIDGE_DISPATCH_TOTAL_LIMIT - BRIDGE_DISPATCH_RECOVERY_RESERVE, 0, 0, 0, 128), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, BRIDGE_DISPATCH_TOTAL_LIMIT - BRIDGE_DISPATCH_RECOVERY_RESERVE, 0, 0, 0, 128, true), "")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, 0, 0, BRIDGE_DISPATCH_OWNED_BYTES_LIMIT - BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE, 0, 1), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, 0, 0, BRIDGE_DISPATCH_OWNED_BYTES_LIMIT - BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE, 0, 1, true), "")
	testing.expect(t, bridge_command_is_recovery("stop_agent"), "agent stop must retain reserved recovery admission")
	testing.expect(t, bridge_command_is_recovery("shell_kill"), "shell kill must retain reserved recovery admission")
	testing.expect(t, !bridge_command_is_recovery("launch_agent"), "new work must not consume recovery reserve")
}

@(test)
bridge_dispatch_overload_result_has_retry_contract :: proc(t: ^testing.T) {
	result := bridge_command_dispatch_busy_json("cmd_busy", "background", 1250)
	defer delete(result)
	testing.expect(t, strings.contains(result, `"status":"failed"`), "overload is terminal for this attempt")
	testing.expect(t, strings.contains(result, `"error_code":"bridge_busy"`), "overload has a stable error code")
	testing.expect(t, strings.contains(result, `"retryable":true`), "overload declares retry safety")
	testing.expect(t, strings.contains(result, `"retry_after_ms":1250`), "overload supplies bounded retry guidance")
	testing.expect(t, strings.contains(result, `"overload_scope":"background"`), "overload identifies only a bounded scope")
}

@(test)
bridge_dispatch_protocol_errors_are_terminal_and_not_retryable :: proc(t: ^testing.T) {
	result := bridge_command_dispatch_protocol_error_json("cmd_bad", "command_too_large")
	defer delete(result)
	testing.expect(t, strings.contains(result, `"command_id":"cmd_bad"`), "protocol error retains command correlation")
	testing.expect(t, strings.contains(result, `"status":"failed"`), "protocol error is terminal")
	testing.expect(t, strings.contains(result, `"error_code":"command_too_large"`), "protocol error has a stable reason")
	testing.expect(t, strings.contains(result, `"retryable":false`), "malformed work must not be retried")
}

@(test)
bridge_dispatch_ordering_keys_serialize_conflicting_mutations :: proc(t: ^testing.T) {
	a1 := bridge_command_ordering_key("launch_agent", `{"agent_instance_id":"inst_a"}`)
	a2 := bridge_command_ordering_key("agent_pty_input", `{"agent_instance_id":"inst_a"}`)
	b := bridge_command_ordering_key("launch_agent", `{"agent_instance_id":"inst_b"}`)
	s1 := bridge_command_ordering_key("shell_start", `{"session_id":"sh_1"}`)
	s2 := bridge_command_ordering_key("shell_kill", `{"session_id":"sh_1"}`)
	fs1 := bridge_command_ordering_key("fs_write_file", `{"path":"/a"}`)
	fs2 := bridge_command_ordering_key("fs_delete", `{"path":"/b"}`)
	defer { delete(a1); delete(a2); delete(b); delete(s1); delete(s2); delete(fs1); delete(fs2) }
	testing.expect_value(t, a1, a2)
	testing.expect(t, a1 != b, "independent agents may execute in parallel")
	testing.expect_value(t, s1, s2)
	testing.expect_value(t, fs1, fs2)
}
