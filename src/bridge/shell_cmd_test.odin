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
	sync.mutex_lock(&bridge_token_store_test_mutex)
	defer sync.mutex_unlock(&bridge_token_store_test_mutex)
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
	testing.expect(t, strings.has_prefix(exec_id, "sexc_"), "exec_id has sexc_ prefix")
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
	sync.mutex_lock(&bridge_token_store_test_mutex)
	defer sync.mutex_unlock(&bridge_token_store_test_mutex)
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
