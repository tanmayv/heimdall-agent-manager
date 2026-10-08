package main

import "core:strings"
import "core:testing"

// ===========================================================================
// ADVERSARIAL STRESS TEST SUITE: BRIDGE MILESTONE M1
// ===========================================================================

@(test)
test_adv_bridge_trim_variations :: proc(t: ^testing.T) {
	// 1. All empty lines
	all_empty := []string{"", "", "", ""}
	got1 := bridge_pty_stream_screen_payload(all_empty, -1, -1)
	defer delete(got1)
	testing.expect_value(t, got1, "")

	// 2. Whitespace lines only
	whitespace_only := []string{"   ", "\t\t", " \t \t", ""}
	got2 := bridge_pty_stream_screen_payload(whitespace_only, -1, -1)
	defer delete(got2)
	testing.expect_value(t, got2, "")

	// 3. Prompt line with trailing spaces, followed by 100 empty lines
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "admin@box:~#   ")
	for _ in 0 ..< 100 {
		append(&lines, "")
	}
	got3 := bridge_pty_stream_screen_payload(lines[:], -1, -1)
	defer delete(got3)
	testing.expect_value(t, got3, "admin@box:~#   ")
	testing.expect(t, strings.has_suffix(got3, "   "), "trailing spaces preserved")

	// 4. Interior blank lines preserved with CRLF
	lines4 := []string{"First", "", "Second", "   ", "Third", "", ""}
	got4 := bridge_pty_stream_screen_payload(lines4, -1, -1)
	defer delete(got4)
	testing.expect_value(t, got4, "First\r\n\r\nSecond\r\n   \r\nThird")

	// 5. Existing CR preserved without doubling
	lines5 := []string{"already\r", "carriage\r"}
	got5 := bridge_pty_stream_screen_payload(lines5, -1, -1)
	defer delete(got5)
	testing.expect(t, !strings.contains(got5, "\r\r"), "no doubled CR")
}

@(test)
test_adv_bridge_get_agent_pane_result_json_extremes :: proc(t: ^testing.T) {
	// 1. Extreme coordinates (65535, 65535)
	json1 := bridge_get_agent_pane_result_json("cmd_large", true, false, "h1", "out", 1, false, 65535, 65535)
	defer delete(json1)
	testing.expect(t, strings.contains(json1, "\"cursor_row\":65535"), "large cursor_row formatted")
	testing.expect(t, strings.contains(json1, "\"cursor_col\":65535"), "large cursor_col formatted")

	// 2. Origin (0, 0)
	json2 := bridge_get_agent_pane_result_json("cmd_origin", true, false, "h2", "out", 1, false, 0, 0)
	defer delete(json2)
	testing.expect(t, strings.contains(json2, "\"cursor_row\":0"), "cursor_row 0")
	testing.expect(t, strings.contains(json2, "\"cursor_col\":0"), "cursor_col 0")

	// 3. Unchanged state: output and cursor coordinates MUST be omitted to minimize payload
	json3 := bridge_get_agent_pane_result_json("cmd_unchanged", true, true, "h3", "", 0, false, 5, 10)
	defer delete(json3)
	testing.expect(t, strings.contains(json3, "\"unchanged\":true"), "unchanged true")
	testing.expect(t, !strings.contains(json3, "cursor_row"), "cursor_row omitted when unchanged")
	testing.expect(t, !strings.contains(json3, "cursor_col"), "cursor_col omitted when unchanged")
	testing.expect(t, !strings.contains(json3, "output"), "output omitted when unchanged")

	// 4. Failure state: cursor coordinates omitted
	json4 := bridge_get_agent_pane_result_json("cmd_fail", false, false, "", "", 0, false, 5, 10, "error detail")
	defer delete(json4)
	testing.expect(t, strings.contains(json4, "\"ok\":false"), "ok false")
	testing.expect(t, !strings.contains(json4, "cursor_row"), "cursor_row omitted on failure")
	testing.expect(t, !strings.contains(json4, "cursor_col"), "cursor_col omitted on failure")
}
