package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
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

// ---- routing + allowlist -------------------------------------------------

@(test)
bridge_shell_cmd_routes_local :: proc(t: ^testing.T) {
	rx := bridge_agent_route("agent.shell_cmd.exec", "{}")
	testing.expect(t, rx.kind == .Local, "exec routes .Local")
	testing.expect(t, rx.local_op == "shell_cmd.exec", "exec local_op")
	rr := bridge_agent_route("agent.shell_cmd.read", "{}")
	testing.expect(t, rr.kind == .Local, "read routes .Local")
	testing.expect(t, rr.local_op == "shell_cmd.read", "read local_op")
}

@(test)
bridge_shell_cmd_methods_allowed :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_method_allowed("agent.shell_cmd.exec"), "exec allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.shell_cmd.read"), "read allowed")
}

// ---- exec (sync) + read end-to-end ---------------------------------------

@(test)
bridge_shell_cmd_exec_sync_completed :: proc(t: ^testing.T) {
	// data_dir is a shared global; serialize with the token-store tests that also
	// mutate it (see agent_token_store_test.odin).
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	bridge_config.data_dir = "/tmp/ham-shell-sync-test"

	rec := Bridge_Local_Agent_Token_Record{}
	resp := bridge_shell_cmd_exec("req1", "{\"cmd\":\"printf 'hello\\\\nworld\\\\n'\"}", rec)

	testing.expect(t, strings.contains(resp, "\"ok\":true"), "exec ok")
	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "sync status completed")
	testing.expect(t, strings.contains(resp, "\"exit_code\":0"), "exit_code 0")
	testing.expect(t, strings.contains(resp, "\"truncated\":false"), "small output not truncated")
	testing.expect(t, strings.contains(resp, "hello"), "output contains hello")

	exec_id := bridge_local_extract_json_string(resp, "exec_id", "")
	testing.expect(t, strings.has_prefix(exec_id, "shl_"), "exec_id has shl_ prefix")
	loc := bridge_local_extract_json_string(resp, "raw_output_location", "")
	testing.expect(t, strings.has_prefix(loc, "/tmp/ham-shell-sync-test/shell_jobs/"), "raw_output_location under data_dir/shell_jobs")
	testing.expect(t, os.exists(loc), "output file written to disk")

	// read back the same job -> same completed shape from the local file.
	read_params := strings.concatenate({"{\"exec_id\":\"", exec_id, "\"}"})
	rresp := bridge_shell_cmd_read("req2", read_params, rec)
	testing.expect(t, strings.contains(rresp, "\"status\":\"completed\""), "read status completed")
	testing.expect(t, strings.contains(rresp, "hello"), "read output contains hello")
	testing.expect(t, strings.contains(rresp, "\"exit_code\":0"), "read exit_code 0")
}

@(test)
bridge_shell_cmd_exec_truncates_large_output :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	bridge_config.data_dir = "/tmp/ham-shell-trunc-test"

	rec := Bridge_Local_Agent_Token_Record{}
	// 300 lines > 200 threshold -> keep last 100.
	resp := bridge_shell_cmd_exec("req3", "{\"cmd\":\"for i in $(seq 1 300); do echo line$i; done\"}", rec)
	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "completed")
	testing.expect(t, strings.contains(resp, "\"truncated\":true"), "large output truncated")

	output := bridge_local_extract_json_string(resp, "output", "")
	kept := strings.count(output, "\n")
	testing.expectf(t, kept <= 100, "tail keeps at most 100 lines, got %d", kept)
	testing.expect(t, strings.contains(output, "line300"), "tail includes the last line")
	testing.expect(t, !strings.contains(output, "line1\n"), "tail drops the earliest lines")

	// output_size_bytes reflects the FULL file, not the truncated tail.
	size_str := bridge_shell_extract_json_number(resp, "output_size_bytes")
	size, ok := strconv.parse_int(size_str)
	testing.expect(t, ok, "output_size_bytes present")
	testing.expect(t, size > len(output), "output_size_bytes is the full raw size (> tail)")
}

@(test)
bridge_shell_cmd_exec_requires_cmd :: proc(t: ^testing.T) {
	rec := Bridge_Local_Agent_Token_Record{}
	resp := bridge_shell_cmd_exec("req4", "{}", rec)
	testing.expect(t, strings.contains(resp, "\"ok\":false"), "missing cmd -> error")
	testing.expect(t, strings.contains(resp, "bad_request"), "missing cmd -> bad_request")
}

@(test)
bridge_shell_cmd_read_unknown :: proc(t: ^testing.T) {
	rec := Bridge_Local_Agent_Token_Record{}
	resp := bridge_shell_cmd_read("req5", "{\"exec_id\":\"sexc_does_not_exist\"}", rec)
	testing.expect(t, strings.contains(resp, "\"ok\":false"), "unknown exec_id -> error")
	testing.expect(t, strings.contains(resp, "not_found"), "unknown exec_id -> not_found")
}

@(test)
bridge_shell_cmd_read_paging_reaches_early_lines :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	bridge_config.data_dir = "/tmp/ham-shell-page-e2e-test"

	rec := Bridge_Local_Agent_Token_Record{}
	// 300 lines: the default tail-100 read only exposes line201..line300.
	resp := bridge_shell_cmd_exec("rp1", "{\"cmd\":\"for i in $(seq 1 300); do echo line$i; done\"}", rec)
	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "exec completed")
	exec_id := bridge_local_extract_json_string(resp, "exec_id", "")
	testing.expect(t, strings.has_prefix(exec_id, "shl_"), "got exec id")

	// grep reaches an early line the default tail would hide, tagged with its number.
	gp := strings.concatenate({"{\"exec_id\":\"", exec_id, "\",\"grep_pattern\":\"line150\"}"})
	gr := bridge_shell_cmd_read("rp2", gp, rec)
	testing.expect(t, strings.contains(gr, "150:line150"), "grep returns line150 with its 1-based line number")
	testing.expect(t, !strings.contains(gr, "line151"), "grep returns only the matching line")

	// offset+limit page an explicit window from the start.
	op := strings.concatenate({"{\"exec_id\":\"", exec_id, "\",\"offset_lines\":10,\"limit_lines\":3}"})
	or := bridge_shell_cmd_read("rp3", op, rec)
	testing.expect(t, strings.contains(or, "line11"), "offset 10 starts at line11")
	testing.expect(t, strings.contains(or, "line13"), "limit 3 ends at line13")
	testing.expect(t, !strings.contains(or, "line14"), "limit stops before line14")
	testing.expect(t, strings.contains(or, "\"truncated\":true"), "more lines remain -> truncated")

	// Default read (no paging flags) is still the tail-100 window.
	dp := strings.concatenate({"{\"exec_id\":\"", exec_id, "\"}"})
	dr := bridge_shell_cmd_read("rp4", dp, rec)
	testing.expect(t, strings.contains(dr, "line300"), "default read keeps the last line")
	testing.expect(t, !strings.contains(dr, "line150\\n"), "default tail-100 does not reach line150")
	testing.expect(t, strings.contains(dr, "\"truncated\":true"), "default tail still marks truncated for >200 lines")
}

// bridge_shell_extract_json_number returns the raw numeric token for `key`
// (handles negative values, which bridge_local_extract_json_int does not).
bridge_shell_extract_json_number :: proc(json, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":"})
	idx := strings.index(json, needle)
	if idx < 0 do return ""
	rest := json[idx + len(needle):]
	end := 0
	for end < len(rest) && (rest[end] == '-' || (rest[end] >= '0' && rest[end] <= '9')) do end += 1
	return rest[:end]
}
