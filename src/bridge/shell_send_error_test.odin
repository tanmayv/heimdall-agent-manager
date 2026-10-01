package main

// REQ-SHELL-16 D1a. Two things are pinned here.
//
// 1. THE WIRE SHAPE IS UNCHANGED. The fix collapsed three hand-written, byte-identical
//    `send_error` builders (shell_start / shell_logs / shell_capture) into one shared
//    proc. Those three replies are a contract the hub parses, and the three differ in
//    fields the hub reads on the failure path (`lines`, `truncated`, `total_lines` for
//    logs; `content`, `rows`, `cols` for capture). A refactor that silently dropped one
//    would turn a diagnosable refusal into a parse failure — the opposite of this task's
//    purpose — so each type's exact body is asserted rather than eyeballed.
//
// 2. THE REASON IS IN THE BODY. The `error` field carrying the actual reason is the
//    payload the hub now propagates (D1b). If it ever stops being emitted here, the hub
//    silently falls back to its generic constant and the defect returns invisibly.

import "core:strings"
import "core:testing"

@(test)
test_req16_shell_start_error_body_is_unchanged :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json("shell_start_result", "sh_1", "cmd_1", "daemon unavailable", "")
	defer delete(got)
	testing.expect_value(
		t,
		got,
		`{"type":"shell_start_result","session_id":"sh_1","command_id":"cmd_1","ok":false,"error":"daemon unavailable"}`,
	)
}

@(test)
test_req16_shell_logs_error_body_keeps_its_padding_fields :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json(
		"shell_logs_result", "sh_2", "cmd_2", "session not found",
		`"lines":[],"truncated":false,"total_lines":0,`,
	)
	defer delete(got)
	testing.expect_value(
		t,
		got,
		`{"type":"shell_logs_result","session_id":"sh_2","command_id":"cmd_2","ok":false,"lines":[],"truncated":false,"total_lines":0,"error":"session not found"}`,
	)
}

@(test)
test_req16_shell_capture_error_body_keeps_its_padding_fields :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json(
		"shell_capture_result", "sh_3", "cmd_3", "capture failed",
		`"content":"","rows":0,"cols":0,`,
	)
	defer delete(got)
	testing.expect_value(
		t,
		got,
		`{"type":"shell_capture_result","session_id":"sh_3","command_id":"cmd_3","ok":false,"content":"","rows":0,"cols":0,"error":"capture failed"}`,
	)
}

// A reason is operator-facing text, not a controlled vocabulary, so it can contain the
// characters that break a hand-built JSON string. The shared builder escapes it; a
// future "simplification" to plain concatenation would produce an unparseable reply
// exactly when something has already gone wrong.
@(test)
test_req16_error_reason_is_json_escaped :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json(
		"shell_start_result", "sh_4", "cmd_4", `spawn failed: "/bin/sh" \ exited`, "",
	)
	defer delete(got)
	testing.expect(
		t,
		strings.contains(got, `\"/bin/sh\"`),
		"an embedded quote in the reason must be escaped, not emitted raw",
	)
	testing.expect(
		t,
		!strings.contains(got, `: "/bin/sh"`),
		"the raw unescaped form must not appear",
	)
}

// ---- REQ-SHELL-16 AC1: the log line, and the REAL handler reaching it ----

// The log line is the host-side diagnostic contract this task exists to create. Asserting
// it exactly is the point: a refusal you can see happened but cannot tie to a session or
// a command is the original defect, and dropping either id from this format would restore
// it with every other test still green.
@(test)
test_req16_error_log_line_names_the_reason_and_both_ids :: proc(t: ^testing.T) {
	got := bridge_shell_error_log_line("shell_start_result", "sh_5", "cmd_5", "daemon unavailable")
	defer delete(got)
	testing.expect_value(
		t,
		got,
		"bridge shell: rejected shell_start_result session_id=sh_5 command_id=cmd_5 reason=daemon unavailable",
	)
}

// These two drive the PRODUCTION handler, not a helper, for the two rejection reasons
// reachable without a daemon — so the evidence is that `bridge_hub_handle_shell_start`
// itself now reaches a logging call, rather than that a helper would log if something
// called it. Passing conn=nil is what makes it safe offline: bridge_shell_send_error
// logs unconditionally and only the SEND is conditional on a connection, which is
// itself the property being demonstrated. Both guards return before any daemon or
// spawn interaction, so nothing is started and nothing needs tearing down.
//
// Each emits its line to the test runner's stdout; that captured output is the AC1
// journal evidence.
@(test)
test_req16_handler_rejects_a_missing_session_id :: proc(t: ^testing.T) {
	bridge_hub_handle_shell_start(nil, `{"type":"shell_start","command_id":"cmd_ac1a","kind":"run","cmd":"echo hi"}`)
	testing.expect(t, true, "handler returned without a connection or a daemon")
}

@(test)
test_req16_handler_rejects_a_missing_cmd :: proc(t: ^testing.T) {
	bridge_hub_handle_shell_start(nil, `{"type":"shell_start","session_id":"sh_ac1b","command_id":"cmd_ac1b","kind":"run"}`)
	testing.expect(t, true, "handler returned without a connection or a daemon")
}
