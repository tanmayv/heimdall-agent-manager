package main

import "base:runtime"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// REQ-SHELL-31: the BRIDGE's catch-up snapshot joined rows with a bare LF — the SECOND
// staircase producer. REQ-SHELL-30 fixed the hub's snapshot builder, the terminal still
// staircased, and this emit site (pty_host_stream_worker.odin, the .Screen case) was why:
// it writes the joined screen into a `shell_pty_output` data_b64 frame, which lands in
// xterm as RAW BYTES. LF without CR drops a row and keeps the column.
//
// WHAT THESE TESTS PROVE, STATED EXACTLY: that bridge_pty_stream_screen_payload — the join plus
// the conversion, the SAME composition the .Screen emit site uses — emits exactly one "\r\n" per
// row boundary, never "\r\n\r\n", and never a trailing separator after the last row.
//
// WHAT THEY DO NOT PROVE: xterm.js's deferred-wrap cancellation — that writing
// the cols-th character sets a pending wrap which a following CR cancels, so CRLF after a
// genuinely full-width row yields one newline rather than two. That is terminal-emulator
// behaviour, it cannot be executed from an Odin unit test, and it is the USER'S re-check.
// It is not measured here and must not be reported as if it were.
//
// Nor do they prove anything about xterm's `convertEol`, which is what makes the SAME bare-LF
// text correct on the polled panes (ShellTerminalPane.tsx:229/:349). These tests cover the
// streaming path only, where convertEol is off — which is precisely the path that was broken.

@(test)
test_req31_rows_are_joined_with_crlf_not_bare_lf :: proc(t: ^testing.T) {
	// Three rows exactly as bridge_pty_host_screen_to_output delivers them.
	got := bridge_pty_stream_screen_payload([]string{"row one", "row two", "row three"})
	defer delete(got)

	testing.expect_value(t, got, "row one\r\nrow two\r\nrow three")

	// Three rows means exactly two boundaries. Counting catches both failure directions at
	// once: a missed CR staircases, an extra one double-spaces.
	testing.expect_value(t, strings.count(got, "\r\n"), 2)
	testing.expect_value(t, strings.count(got, "\n"), 2) // every LF is part of a CRLF
	testing.expect(t, !strings.contains(got, "\r\n\r\n"), "no blank line between rows")
	testing.expect(
		t,
		!strings.has_suffix(got, "\r\n"),
		"no trailing separator after the last row — that would push a blank line on every attach",
	)
}

// FULL-WIDTH ROWS ARE COMMON, NOT EXOTIC: vt.rs trims trailing blanks, so any horizontal
// rule, box border or progress bar produces one. This is the case where a staircase fix
// turns into a double-spacing bug.
//
// The rule is 80 box-drawing characters — 80 display columns but 240 BYTES, because U+2500
// is three bytes in UTF-8. That is deliberate: it proves the conversion adds exactly one
// separator regardless of byte length, so nothing in it can be computing a width.
@(test)
test_req31_full_width_row_does_not_double_space :: proc(t: ^testing.T) {
	rule := strings.repeat("─", 80)
	defer delete(rule)
	testing.expect_value(t, len(rule), 240) // 80 columns, 240 bytes — width is NOT length

	got := bridge_pty_stream_screen_payload([]string{"header", rule, "footer"})
	defer delete(got)

	expected := strings.concatenate({"header\r\n", rule, "\r\nfooter"})
	defer delete(expected)
	testing.expect_value(t, got, expected)

	testing.expect_value(t, strings.count(got, "\r\n"), 2)
	testing.expect(
		t,
		!strings.contains(got, "\r\n\r\n"),
		"a full-width row must not produce a blank line between rows",
	)
	testing.expect(t, !strings.has_suffix(got, "\r\n"), "no trailing separator after the last row")
}

// vt.rs capture() writes SGR runs INLINE into each row, so a row's byte length exceeds its
// display width. Nothing may derive a separator decision from length.
@(test)
test_req31_inline_sgr_row_gets_exactly_one_separator :: proc(t: ^testing.T) {
	sgr_row := "\x1b[1m\x1b[31mERROR\x1b[0m failed to connect"
	got := bridge_pty_stream_screen_payload([]string{"before", sgr_row, "after"})
	defer delete(got)

	testing.expect_value(t, strings.count(got, "\r\n"), 2)
	testing.expect(t, strings.contains(got, sgr_row), "SGR runs pass through untouched")
	testing.expect(
		t,
		!strings.contains(got, "\r\n\r\n"),
		"an SGR-bearing row is still ONE row however many bytes it carries",
	)
}

// Defensive: if the pty-host ever starts sending CRLF itself, this must not become "\r\r\n".
@(test)
test_req31_an_existing_cr_is_not_doubled :: proc(t: ^testing.T) {
	got := _bridge_pty_stream_lf_to_crlf("already\r\ncrlf")
	defer delete(got)

	testing.expect_value(t, got, "already\r\ncrlf")
	testing.expect(t, !strings.contains(got, "\r\r"), "a CR already present must not be doubled")
}

// A lone LF at index 0 must still gain its CR: the i == 0 branch of the scan is a real case
// (a screen whose first row is empty), not a defensive flourish.
@(test)
test_req31_leading_lf_gains_a_cr :: proc(t: ^testing.T) {
	// The joiner's bare-LF shape, recorded so the test states what it is converting FROM.
	joined, _, _ := bridge_pty_host_screen_to_output([]string{"", "second"}, 0)
	defer delete(joined)
	testing.expect_value(t, joined, "\nsecond")

	got := bridge_pty_stream_screen_payload([]string{"", "second"})
	defer delete(got)
	testing.expect_value(t, got, "\r\nsecond")
}

// An empty screen must stay empty: the emit site guards on len(content) > 0, but the
// conversion must not invent a separator if that guard ever moves.
@(test)
test_req31_empty_screen_adds_no_separator :: proc(t: ^testing.T) {
	got := _bridge_pty_stream_lf_to_crlf("")
	defer delete(got)
	testing.expect_value(t, got, "")
}

// A single row has NO boundary and must gain nothing at all. This is the test that would
// catch a conversion that appended a separator per row rather than per LF.
@(test)
test_req31_single_row_gains_nothing :: proc(t: ^testing.T) {
	got := bridge_pty_stream_screen_payload([]string{"only row"})
	defer delete(got)

	testing.expect_value(t, got, "only row")
	testing.expect_value(t, strings.count(got, "\r"), 0)
	testing.expect_value(t, strings.count(got, "\n"), 0)
}

// ---------------------------------------------------------------------------
// REQ-STREAM-EVENT-2: stream_ready and stream_closed WebSocket lifecycle events.

@(test)
test_stream_ready_lifecycle_event_formatting :: proc(t: ^testing.T) {
	json_str := bridge_pty_stream_format_lifecycle_event(
		"shell_pty_stream_ready",
		"sh_sess_ready_1",
		"shell_inst_ready_1",
	)
	defer delete(json_str)

	testing.expect(t, strings.contains(json_str, `"type":"shell_pty_stream_ready"`), "frame type is shell_pty_stream_ready")
	testing.expect(t, strings.contains(json_str, `"session_id":"sh_sess_ready_1"`), "frame has correct session_id")
	testing.expect(t, strings.contains(json_str, `"shell_id":"shell_inst_ready_1"`), "frame has correct shell_id")
	testing.expect(t, !strings.contains(json_str, `"exit_code"`), "ready event has no exit_code")
}

@(test)
test_stream_closed_lifecycle_event_formatting :: proc(t: ^testing.T) {
	// 1. With exit code
	json_str1 := bridge_pty_stream_format_lifecycle_event(
		"shell_pty_stream_closed",
		"sh_sess_closed_1",
		"shell_inst_closed_1",
		true,
		42,
	)
	defer delete(json_str1)

	testing.expect(t, strings.contains(json_str1, `"type":"shell_pty_stream_closed"`), "frame type is shell_pty_stream_closed")
	testing.expect(t, strings.contains(json_str1, `"session_id":"sh_sess_closed_1"`), "frame has correct session_id")
	testing.expect(t, strings.contains(json_str1, `"shell_id":"shell_inst_closed_1"`), "frame has correct shell_id")
	testing.expect(t, strings.contains(json_str1, `"exit_code":42`), "frame has exit_code:42")

	// 2. Without exit code (e.g. session teardown / close)
	json_str2 := bridge_pty_stream_format_lifecycle_event(
		"shell_pty_stream_closed",
		"sh_sess_closed_2",
		"shell_inst_closed_2",
		false,
		0,
	)
	defer delete(json_str2)

	testing.expect(t, strings.contains(json_str2, `"type":"shell_pty_stream_closed"`), "frame type is shell_pty_stream_closed")
	testing.expect(t, strings.contains(json_str2, `"session_id":"sh_sess_closed_2"`), "frame has correct session_id")
	testing.expect(t, strings.contains(json_str2, `"shell_id":"shell_inst_closed_2"`), "frame has correct shell_id")
	testing.expect(t, !strings.contains(json_str2, `"exit_code"`), "frame does not contain exit_code when has_exit_code is false")
}
