package main

import "core:strings"
import "core:testing"

// BR-4 tests: the UI capture proxy's screen->pane-text conversion (tail + limit +
// truncation) and the capture-result JSON shape. The live host.capture round-trip
// is covered by the client codec tests + the daemon's own HOST-1 tests; here we
// lock in the proxy's pure conversion + result assembly.

@(test)
pty_host_screen_to_output_joins_all_when_under_limit :: proc(t: ^testing.T) {
	lines := []string{"a", "b", "c"}
	out, count, trunc := bridge_pty_host_screen_to_output(lines, 120)
	defer delete(out)
	testing.expect_value(t, out, "a\nb\nc")
	testing.expect_value(t, count, 3)
	testing.expect_value(t, trunc, false)
}

@(test)
pty_host_screen_to_output_keeps_tail_when_over_limit :: proc(t: ^testing.T) {
	lines := []string{"l1", "l2", "l3", "l4", "l5"}
	out, count, trunc := bridge_pty_host_screen_to_output(lines, 2)
	defer delete(out)
	// keeps the LAST 2 lines (the tail), matching tmux capture semantics
	testing.expect_value(t, out, "l4\nl5")
	testing.expect_value(t, count, 2)
	testing.expect_value(t, trunc, true)
}

@(test)
pty_host_screen_to_output_zero_limit_keeps_all :: proc(t: ^testing.T) {
	lines := []string{"x", "y"}
	out, count, trunc := bridge_pty_host_screen_to_output(lines, 0)
	defer delete(out)
	testing.expect_value(t, out, "x\ny")
	testing.expect_value(t, count, 2)
	testing.expect_value(t, trunc, false)
}

@(test)
pty_host_capture_result_json_shape_ok :: proc(t: ^testing.T) {
	pending := Bridge_Pane_Capture_Pending{
		command_id              = "cmd_1",
		pane_capture_request_id = "pcr_1",
		agent_instance_id       = "inst_a",
		width                   = 80,
	}
	// Success shape carries output + line_count + ok:true.
	ok_json := bridge_pane_capture_result_json(pending, true, "", "", "hello\nworld", 2, false)
	defer delete(ok_json)
	testing.expect(t, strings.contains(ok_json, "\"type\":\"pane_capture_result\""), "type present")
	testing.expect(t, strings.contains(ok_json, "\"ok\":true"), "ok true")
	testing.expect(t, strings.contains(ok_json, "\"command_id\":\"cmd_1\""), "command id")
	testing.expect(t, strings.contains(ok_json, "\"pane_capture_request_id\":\"pcr_1\""), "request id")
	testing.expect(t, strings.contains(ok_json, "\"output\":\"hello\\nworld\""), "output escaped + present")
	testing.expect(t, strings.contains(ok_json, "\"line_count\":2"), "line count")

	// Failure shape carries error_code + message, no output.
	fail_json := bridge_pane_capture_result_json(pending, false, "host_unavailable", "The ham-pty-host daemon is not available.", "", 0, false)
	defer delete(fail_json)
	testing.expect(t, strings.contains(fail_json, "\"ok\":false"), "ok false")
	testing.expect(t, strings.contains(fail_json, "\"error_code\":\"host_unavailable\""), "error code")
	testing.expect(t, !strings.contains(fail_json, "\"output\":"), "no output on failure")
}
