package main

// Unit tests for the shared shell output helpers in shell_common.odin.
//
// This file was src/bridge/shell_cmd_test.odin. REQ-SHELL-7 deleted the bridge-local
// exec/read RPC surface it also covered — the routing/allowlist assertions for those
// two methods, and their exec+read end-to-end cases — because the methods no longer
// exist. What is KEPT is everything covering bridge_shell_tail and bridge_shell_page,
// which survive as the truncation and paging behind `ham-ctl shell log` and a finished
// run's inline result.

import "core:strings"
import "core:testing"

// ---- pure helpers: tail truncation ---------------------------------------

@(test)
bridge_shell_tail_no_truncation_under_threshold :: proc(t: ^testing.T) {
	out := "a\nb\nc\n"
	tail, truncated := bridge_shell_tail(out, 200, 100)
	testing.expect(t, !truncated, "under threshold must not truncate")
	testing.expect(t, tail == out, "under threshold returns output unchanged")
}

@(test)
bridge_shell_tail_at_threshold_not_truncated :: proc(t: ^testing.T) {
	// exactly `threshold` lines -> not truncated (only > threshold truncates).
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 5 {
		strings.write_string(&b, "line\n")
	}
	out := strings.to_string(b)
	tail, truncated := bridge_shell_tail(out, 5, 2)
	testing.expect(t, !truncated, "exactly threshold lines must not truncate")
	testing.expect(t, tail == out, "output unchanged at threshold")
}

@(test)
bridge_shell_tail_keeps_last_lines :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne\n"
	tail, truncated := bridge_shell_tail(out, 3, 2)
	testing.expect(t, truncated, "over threshold must truncate")
	testing.expect(t, tail == "d\ne\n", "must keep exactly the last 2 lines")
}

@(test)
bridge_shell_tail_keeps_last_lines_no_trailing_newline :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne"
	tail, truncated := bridge_shell_tail(out, 3, 2)
	testing.expect(t, truncated, "over threshold must truncate")
	testing.expect(t, tail == "d\ne", "must keep last 2 lines when no trailing newline")
}

@(test)
bridge_shell_tail_empty :: proc(t: ^testing.T) {
	tail, truncated := bridge_shell_tail("", 200, 100)
	testing.expect(t, !truncated, "empty output not truncated")
	testing.expect(t, tail == "", "empty output unchanged")
}

// ---- pure helpers: paging (REQ-25) ---------------------------------------

@(test)
bridge_shell_page_offset_skips_from_start :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne\n"
	page, truncated := bridge_shell_page(out, 2, 100, "")
	defer delete(page)
	testing.expect(t, page == "c\nd\ne\n", "offset 2 keeps lines 3..5")
	testing.expect(t, truncated, "offset > 0 marks truncated")
}

@(test)
bridge_shell_page_limit_caps_lines :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne\n"
	page, truncated := bridge_shell_page(out, 0, 2, "")
	defer delete(page)
	testing.expect(t, page == "a\nb\n", "limit 2 keeps the first 2 lines from offset 0")
	testing.expect(t, truncated, "more lines remain -> truncated")
}

@(test)
bridge_shell_page_limit_within_bounds_not_truncated :: proc(t: ^testing.T) {
	out := "a\nb\nc\n"
	page, truncated := bridge_shell_page(out, 0, 10, "")
	defer delete(page)
	testing.expect(t, page == "a\nb\nc\n", "limit above line count returns all")
	testing.expect(t, !truncated, "nothing skipped or dropped -> not truncated")
}

@(test)
bridge_shell_page_grep_filters_with_line_numbers :: proc(t: ^testing.T) {
	out := "alpha\nerror one\nbeta\nerror two\ngamma\n"
	page, truncated := bridge_shell_page(out, 0, 100, "error")
	defer delete(page)
	testing.expect(t, page == "2:error one\n4:error two\n", "grep keeps matches with original 1-based line numbers")
	testing.expect(t, !truncated, "all matches returned -> not truncated")
}

@(test)
bridge_shell_page_grep_with_offset_and_limit :: proc(t: ^testing.T) {
	out := "e1\nx\ne2\ne3\ny\ne4\n"
	// matches are lines 1,3,4,6 -> skip 1 match, keep 2.
	page, truncated := bridge_shell_page(out, 1, 2, "e")
	defer delete(page)
	testing.expect(t, page == "3:e2\n4:e3\n", "offset+limit page the grep matches")
	testing.expect(t, truncated, "offset skipped a match -> truncated")
}

@(test)
bridge_shell_page_no_trailing_newline :: proc(t: ^testing.T) {
	out := "a\nb\nc"
	page, truncated := bridge_shell_page(out, 0, 10, "")
	defer delete(page)
	testing.expect(t, page == "a\nb\nc\n", "final line without newline is still emitted")
	testing.expect(t, !truncated, "all lines returned -> not truncated")
}

@(test)
bridge_shell_page_empty_output :: proc(t: ^testing.T) {
	page, truncated := bridge_shell_page("", 0, 100, "")
	defer delete(page)
	testing.expect(t, page == "", "empty output pages to empty")
	testing.expect(t, !truncated, "empty output not truncated")
}
