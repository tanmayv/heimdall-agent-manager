package bridge_shell_cmd_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import bridge "odin_test:bridge"

test_config_mutex: sync.Mutex

extract_json_number :: proc(json, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":"})
	defer delete(needle)
	idx := strings.index(json, needle)
	if idx < 0 do return ""
	rest := json[idx + len(needle):]
	end := 0
	for end < len(rest) && (rest[end] == '-' || (rest[end] >= '0' && rest[end] <= '9')) do end += 1
	return rest[:end]
}

// -----------------------------------------------------------------------------
// 1. Synchronous Command Execution (REQ-MACOS-4)
// -----------------------------------------------------------------------------

@(test)
test_shell_cmd_exec_sync_echo :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_config_mutex)
	defer sync.mutex_unlock(&test_config_mutex)
	bridge.bridge_shell_test_reset()
	defer bridge.bridge_shell_test_reset()

	saved_dir := bridge.bridge_config.data_dir
	defer { bridge.bridge_config.data_dir = saved_dir }
	bridge.bridge_config.data_dir = "/tmp/ham-shell-test-sync-echo"

	rec := bridge.Bridge_Local_Agent_Token_Record{}
	resp := bridge.bridge_shell_cmd_exec("req_echo_1", "{\"cmd\":\"echo 'hello world'\"}", rec)
	defer delete(resp)

	testing.expect(t, strings.contains(resp, "\"ok\":true"), "exec response must indicate ok: true")
	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "sync command must complete within 15s")
	testing.expect(t, strings.contains(resp, "\"exit_code\":0"), "successful command has exit_code 0")
	testing.expect(t, strings.contains(resp, "\"truncated\":false"), "short echo output must not be truncated")
	testing.expect(t, strings.contains(resp, "hello world"), "output must contain printed text")

	exec_id := bridge.bridge_local_extract_json_string(resp, "exec_id", "")
	defer delete(exec_id)
	testing.expect(t, strings.has_prefix(exec_id, "sexc_"), "exec_id must start with sexc_ prefix")

	loc := bridge.bridge_local_extract_json_string(resp, "raw_output_location", "")
	defer delete(loc)
	testing.expect(t, strings.has_prefix(loc, "/tmp/ham-shell-test-sync-echo/shell_jobs/"), "raw_output_location under data_dir")
	testing.expect(t, os.exists(loc), "raw output file must exist on disk")
}

@(test)
test_shell_cmd_exec_sync_nonzero_exit :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_config_mutex)
	defer sync.mutex_unlock(&test_config_mutex)
	bridge.bridge_shell_test_reset()
	defer bridge.bridge_shell_test_reset()

	saved_dir := bridge.bridge_config.data_dir
	defer { bridge.bridge_config.data_dir = saved_dir }
	bridge.bridge_config.data_dir = "/tmp/ham-shell-test-sync-fail"

	rec := bridge.Bridge_Local_Agent_Token_Record{}
	resp := bridge.bridge_shell_cmd_exec("req_fail_1", "{\"cmd\":\"sh -c 'exit 42'\"}", rec)
	defer delete(resp)

	testing.expect(t, strings.contains(resp, "\"ok\":true"), "exec response ok envelope is true")
	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "completed with exit code")
	testing.expect(t, strings.contains(resp, "\"exit_code\":42"), "non-zero exit code 42 captured")
}

@(test)
test_shell_cmd_exec_requires_cmd :: proc(t: ^testing.T) {
	rec := bridge.Bridge_Local_Agent_Token_Record{}
	resp := bridge.bridge_shell_cmd_exec("req_missing_cmd", "{}", rec)
	defer delete(resp)

	testing.expect(t, strings.contains(resp, "\"ok\":false"), "missing cmd must fail")
	testing.expect(t, strings.contains(resp, "bad_request"), "missing cmd error must be bad_request")
}

// -----------------------------------------------------------------------------
// 2. Working Directory Support (cwd) (REQ-MACOS-4)
// -----------------------------------------------------------------------------

@(test)
test_shell_cmd_exec_cwd_valid :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_config_mutex)
	defer sync.mutex_unlock(&test_config_mutex)
	bridge.bridge_shell_test_reset()
	defer bridge.bridge_shell_test_reset()

	saved_dir := bridge.bridge_config.data_dir
	defer { bridge.bridge_config.data_dir = saved_dir }
	bridge.bridge_config.data_dir = "/tmp/ham-shell-test-cwd"

	rec := bridge.Bridge_Local_Agent_Token_Record{}
	resp := bridge.bridge_shell_cmd_exec("req_cwd_1", "{\"cmd\":\"pwd\",\"cwd\":\"/tmp\"}", rec)
	defer delete(resp)

	testing.expect(t, strings.contains(resp, "\"ok\":true"), "exec in cwd /tmp ok")
	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "completed")
	testing.expect(t, strings.contains(resp, "/tmp"), "pwd output contains /tmp")
}

@(test)
test_shell_cmd_exec_cwd_nonexistent :: proc(t: ^testing.T) {
	rec := bridge.Bridge_Local_Agent_Token_Record{}
	resp := bridge.bridge_shell_cmd_exec("req_cwd_invalid", "{\"cmd\":\"pwd\",\"cwd\":\"/tmp/nonexistent_dir_84729104\"}", rec)
	defer delete(resp)

	testing.expect(t, strings.contains(resp, "\"ok\":false"), "nonexistent cwd must fail")
	testing.expect(t, strings.contains(resp, "bad_request"), "error code bad_request")
	testing.expect(t, strings.contains(resp, "does not exist"), "error message mentions does not exist")
}

@(test)
test_shell_cmd_exec_cwd_not_a_directory :: proc(t: ^testing.T) {
	rec := bridge.Bridge_Local_Agent_Token_Record{}
	resp := bridge.bridge_shell_cmd_exec("req_cwd_file", "{\"cmd\":\"pwd\",\"cwd\":\"/etc/hosts\"}", rec)
	defer delete(resp)

	testing.expect(t, strings.contains(resp, "\"ok\":false"), "file as cwd must fail")
	testing.expect(t, strings.contains(resp, "bad_request"), "error code bad_request")
	testing.expect(t, strings.contains(resp, "is not a directory"), "error message mentions is not a directory")
}

// -----------------------------------------------------------------------------
// 3. Output Capture and Tail Truncation (REQ-MACOS-4)
// -----------------------------------------------------------------------------

@(test)
test_shell_tail_pure_helpers :: proc(t: ^testing.T) {
	// Under threshold -> not truncated
	out_short := "line 1\nline 2\nline 3\n"
	tail, trunc := bridge.bridge_shell_tail(out_short, 10, 5)
	testing.expect(t, !trunc, "under threshold must not truncate")
	testing.expect(t, tail == out_short, "under threshold output unchanged")

	// Exactly threshold -> not truncated
	out_exact := "a\nb\nc\n"
	tail_ex, trunc_ex := bridge.bridge_shell_tail(out_exact, 3, 2)
	testing.expect(t, !trunc_ex, "exact threshold must not truncate")
	testing.expect(t, tail_ex == out_exact, "exact threshold output unchanged")

	// Over threshold -> keep last N lines
	out_long := "a\nb\nc\nd\ne\n"
	tail_lg, trunc_lg := bridge.bridge_shell_tail(out_long, 3, 2)
	testing.expect(t, trunc_lg, "over threshold must truncate")
	testing.expect(t, tail_lg == "d\ne\n", "must keep last 2 lines")

	// Over threshold without trailing newline
	out_no_nl := "a\nb\nc\nd\ne"
	tail_nn, trunc_nn := bridge.bridge_shell_tail(out_no_nl, 3, 2)
	testing.expect(t, trunc_nn, "over threshold without trailing newline must truncate")
	testing.expect(t, tail_nn == "d\ne", "must keep last 2 lines without trailing newline")

	// Empty string
	tail_emp, trunc_emp := bridge.bridge_shell_tail("", 200, 100)
	testing.expect(t, !trunc_emp, "empty string not truncated")
	testing.expect(t, tail_emp == "", "empty string remains empty")
}

@(test)
test_shell_cmd_exec_truncates_over_200_lines :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_config_mutex)
	defer sync.mutex_unlock(&test_config_mutex)
	bridge.bridge_shell_test_reset()
	defer bridge.bridge_shell_test_reset()

	saved_dir := bridge.bridge_config.data_dir
	defer { bridge.bridge_config.data_dir = saved_dir }
	bridge.bridge_config.data_dir = "/tmp/ham-shell-test-trunc"

	rec := bridge.Bridge_Local_Agent_Token_Record{}
	// 250 lines (> 200 threshold)
	resp := bridge.bridge_shell_cmd_exec("req_trunc_1", "{\"cmd\":\"for i in $(seq 1 250); do echo line$i; done\"}", rec)
	defer delete(resp)

	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "completed")
	testing.expect(t, strings.contains(resp, "\"truncated\":true"), "over 200 lines marked truncated: true")

	output := bridge.bridge_local_extract_json_string(resp, "output", "")
	defer delete(output)
	kept_newlines := strings.count(output, "\n")
	testing.expect(t, kept_newlines <= 100, "tail keeps at most 100 lines")
	testing.expect(t, strings.contains(output, "line250"), "tail includes final lines")
	testing.expect(t, !strings.contains(output, "line1\n"), "tail drops early lines")

	size_str := extract_json_number(resp, "output_size_bytes")
	size, ok := strconv.parse_int(size_str)
	testing.expect(t, ok, "output_size_bytes is a valid integer")
	testing.expect(t, size > len(output), "full output size is larger than tail length")
}

// -----------------------------------------------------------------------------
// 4. Paging and Grep Filtering (bridge_shell_cmd_read) (REQ-MACOS-4)
// -----------------------------------------------------------------------------

@(test)
test_shell_page_pure_helpers :: proc(t: ^testing.T) {
	out := "alpha\nbravo error\ncharlie\ndelta error\necho\n"

	// Offset skips lines
	page_off, trunc_off := bridge.bridge_shell_page(out, 2, 10, "")
	defer delete(page_off)
	testing.expect(t, trunc_off, "offset > 0 marks truncated")
	testing.expect(t, page_off == "charlie\ndelta error\necho\n", "offset 2 keeps from line 3 onwards")

	// Limit caps lines
	page_lim, trunc_lim := bridge.bridge_shell_page(out, 0, 2, "")
	defer delete(page_lim)
	testing.expect(t, trunc_lim, "remaining lines mark truncated")
	testing.expect(t, page_lim == "alpha\nbravo error\n", "limit 2 keeps first 2 lines")

	// Grep filters lines and adds 1-based line numbers
	page_grep, trunc_grep := bridge.bridge_shell_page(out, 0, 10, "error")
	defer delete(page_grep)
	testing.expect(t, !trunc_grep, "all matches included -> not truncated")
	testing.expect(t, page_grep == "2:bravo error\n4:delta error\n", "grep output has 1-based line numbers")

	// Empty string
	page_emp, trunc_emp := bridge.bridge_shell_page("", 0, 10, "")
	defer delete(page_emp)
	testing.expect(t, !trunc_emp, "empty input not truncated")
	testing.expect(t, page_emp == "", "empty input output is empty")
}

@(test)
test_shell_cmd_read_e2e_and_paging :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_config_mutex)
	defer sync.mutex_unlock(&test_config_mutex)
	bridge.bridge_shell_test_reset()
	defer bridge.bridge_shell_test_reset()

	saved_dir := bridge.bridge_config.data_dir
	defer { bridge.bridge_config.data_dir = saved_dir }
	bridge.bridge_config.data_dir = "/tmp/ham-shell-test-read-page"

	rec := bridge.Bridge_Local_Agent_Token_Record{}
	resp := bridge.bridge_shell_cmd_exec("req_read_init", "{\"cmd\":\"for i in $(seq 1 50); do echo item$i; done\"}", rec)
	defer delete(resp)

	exec_id := bridge.bridge_local_extract_json_string(resp, "exec_id", "")
	defer delete(exec_id)
	testing.expect(t, strings.has_prefix(exec_id, "sexc_"), "valid exec_id")

	// Standard read
	read_params := fmt.tprintf("{{\"exec_id\":\"%s\"}}", exec_id)
	rresp := bridge.bridge_shell_cmd_read("req_r1", read_params, rec)
	defer delete(rresp)
	testing.expect(t, strings.contains(rresp, "\"ok\":true"), "read response ok")
	testing.expect(t, strings.contains(rresp, "\"status\":\"completed\""), "read status completed")
	testing.expect(t, strings.contains(rresp, "item1"), "contains item1")
	testing.expect(t, strings.contains(rresp, "item50"), "contains item50")

	// Grep read
	grep_params := fmt.tprintf("{{\"exec_id\":\"%s\",\"grep_pattern\":\"item25\"}}", exec_id)
	gresp := bridge.bridge_shell_cmd_read("req_r2", grep_params, rec)
	defer delete(gresp)
	testing.expect(t, strings.contains(gresp, "25:item25"), "grep matches line 25 with number")
	testing.expect(t, !strings.contains(gresp, "item24"), "grep filters out non-matching item24")

	// Offset and limit paging
	page_params := fmt.tprintf("{{\"exec_id\":\"%s\",\"offset_lines\":5,\"limit_lines\":3}}", exec_id)
	presp := bridge.bridge_shell_cmd_read("req_r3", page_params, rec)
	defer delete(presp)
	testing.expect(t, strings.contains(presp, "item6"), "offset 5 begins at item6")
	testing.expect(t, strings.contains(presp, "item8"), "limit 3 includes item8")
	testing.expect(t, !strings.contains(presp, "item9"), "limit stops before item9")

	// Unknown exec_id returns not_found
	unknown_resp := bridge.bridge_shell_cmd_read("req_r4", "{\"exec_id\":\"sexc_unknown_123\"}", rec)
	defer delete(unknown_resp)
	testing.expect(t, strings.contains(unknown_resp, "\"ok\":false"), "unknown exec_id fails")
	testing.expect(t, strings.contains(unknown_resp, "not_found"), "error is not_found")

	// Missing exec_id returns bad_request
	missing_resp := bridge.bridge_shell_cmd_read("req_r5", "{}", rec)
	defer delete(missing_resp)
	testing.expect(t, strings.contains(missing_resp, "\"ok\":false"), "missing exec_id fails")
	testing.expect(t, strings.contains(missing_resp, "bad_request"), "error is bad_request")
}

// -----------------------------------------------------------------------------
// 5. Cross-Platform Process Termination & Timeout Handling (REQ-MACOS-1, 2, 4)
// -----------------------------------------------------------------------------

@(test)
test_shell_timeout_detection_helper :: proc(t: ^testing.T) {
	// os.General_Error.Timeout must be recognized as timeout
	timeout_err: os.Error = os.General_Error.Timeout
	testing.expect(t, bridge.bridge_shell_err_is_timeout(timeout_err), "General_Error.Timeout is timeout")

	none_err: os.Error = os.General_Error.None
	testing.expect(t, !bridge.bridge_shell_err_is_timeout(none_err), "General_Error.None is not timeout")

	not_exist_err: os.Error = os.General_Error.Not_Exist
	testing.expect(t, !bridge.bridge_shell_err_is_timeout(not_exist_err), "General_Error.Not_Exist is not timeout")

	nil_err: os.Error = nil
	testing.expect(t, !bridge.bridge_shell_err_is_timeout(nil_err), "nil error is not timeout")
}

@(test)
test_shell_append_line_helper :: proc(t: ^testing.T) {
	test_file := "/tmp/ham-shell-append-test.txt"
	_ = os.remove(test_file)
	defer _ = os.remove(test_file)

	bridge.bridge_shell_append_line(test_file, "[line one]")
	bridge.bridge_shell_append_line(test_file, "[line two]")

	data, err := os.read_entire_file(test_file, context.allocator)
	testing.expect(t, err == nil, "file readable")
	defer delete(data)

	content := string(data)
	testing.expect(t, strings.contains(content, "[line one]\n"), "first appended line with newline")
	testing.expect(t, strings.contains(content, "[line two]\n"), "second appended line with newline")
}

@(test)
test_cross_platform_process_spawn_and_kill :: proc(t: ^testing.T) {
	// Verify that os.process_start and posix.kill work cross-platform as implemented
	// in src/bridge/shell_cmd.odin (REQ-MACOS-1, REQ-MACOS-2).
	command: []string
	when ODIN_OS == .Darwin {
		command = []string{"sh", "-c", "sleep 30"}
	} else {
		command = []string{"setsid", "sh", "-c", "sleep 30"}
	}

	process, perr := os.process_start(os.Process_Desc{command = command})
	testing.expect(t, perr == nil, "process start succeeds")

	if perr == nil {
		// Give spawned process a moment to initialize session
		time.sleep(50 * time.Millisecond)

		// Terminate process cross-platform using posix.kill
		when ODIN_OS == .Darwin {
			_ = posix.kill(posix.pid_t(-i32(process.pid)), .SIGKILL)
			_ = posix.kill(posix.pid_t(process.pid), .SIGKILL)
		} else {
			_ = posix.kill(posix.pid_t(-i32(process.pid)), .SIGKILL)
			_ = posix.kill(posix.pid_t(process.pid), .SIGKILL)
		}

		state, werr := os.process_wait(process, 3 * time.Second)
		testing.expect(t, werr == nil, "killed process successfully waited on")
		testing.expect(t, state.exited, "process marked exited")
	}
}
