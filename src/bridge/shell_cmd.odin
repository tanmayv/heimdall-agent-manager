package main

// Bridge-local shell command execution (REQ-14).
//
// An agent calls `agent.shell_cmd.exec {cmd}`; the bridge runs the command
// LOCALLY (sh -c) on this host and races a 15s deadline:
//   <15s   -> returns synchronously with status="completed", the (tail-truncated)
//            output, exit_code and timing metadata.
//   >=15s  -> stores a job record, returns status="running" immediately, and a
//            background thread drains the process to completion (or a 30-minute
//            hard cap) before reporting job status back to the hub.
//
// Output is written ONLY to <data_dir>/shell_jobs/<exec_id>.out on this machine
// and is NEVER sent to the hub. The completion report to the hub carries status
// metadata only (exec_id, status, exit_code); the hub delivers it via the
// transient nudge path (REQ-15), not as a stored chat message.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// exec runs longer than this -> switch to the async (background job) path.
BRIDGE_SHELL_ASYNC_THRESHOLD :: 15 * time.Second
// Hard cap for a background job measured from spawn; exceeded -> SIGKILL + failed.
BRIDGE_SHELL_HARD_TIMEOUT :: 30 * time.Minute
// Output truncation: > THRESHOLD lines -> keep only the last KEEP lines.
BRIDGE_SHELL_TAIL_THRESHOLD :: 200
BRIDGE_SHELL_TAIL_KEEP :: 100

// Bridge_Shell_Job is the durable-for-process-lifetime record for one exec. All
// string fields are owned (cloned) so they outlive the request that created them.
Bridge_Shell_Job :: struct {
	exec_id:          string,
	cmd:              string,
	status:           string, // "running" | "completed" | "failed"
	start_time:       string, // RFC3339 UTC
	started_unix_ms:  i64,
	finished_unix_ms: i64,
	exit_code:        int,
	output_path:      string,
	instance_token:   string, // hub credential of the caller (for the async report)
	instance_id:      string,
}

// bridge_shell_jobs is keyed by exec_id and guarded by bridge_shell_jobs_mutex.
// Records are never removed (the store is small: one entry per exec).
bridge_shell_jobs: map[string]^Bridge_Shell_Job
bridge_shell_jobs_mutex: sync.Mutex
bridge_shell_exec_seq: i64

// Bridge_Shell_Async_Ctx is heap-allocated per background job and handed to the
// worker thread, which frees it on exit.
Bridge_Shell_Async_Ctx :: struct {
	process:         os.Process,
	exec_id:         string,
	cmd:             string,
	start_time:      string, // RFC3339 UTC
	output_path:     string,
	started_unix_ms: i64,
	instance_token:  string,
	instance_id:     string,
}

// ---- request handlers ----------------------------------------------------

bridge_shell_cmd_exec :: proc(request_id, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	cmd := strings.trim_space(bridge_local_extract_json_string(params, "cmd", ""))
	if cmd == "" do return bridge_local_response_error(request_id, "bad_request", "shell-cmd exec requires --cmd '<command>'")

	// Optional working directory (REQ-24). Empty -> inherit the bridge service's
	// cwd (historic behavior). A non-empty value is ~-expanded and must resolve to
	// an existing directory; an invalid --cwd is rejected before spawn rather than
	// silently ignored, so agents get a clear error instead of a command that ran
	// in the wrong place. working_dir is only heap-allocated when ~ was expanded
	// (bridge_expand_home aliases the input otherwise), hence the guarded delete.
	cwd := strings.trim_space(bridge_local_extract_json_string(params, "cwd", ""))
	working_dir := ""
	if cwd != "" do working_dir = bridge_expand_home(cwd)
	defer if working_dir != cwd && working_dir != "" do delete(working_dir)
	if cwd != "" {
		if !os.exists(working_dir) do return bridge_local_response_error(request_id, "bad_request", strings.concatenate({"shell-cmd exec --cwd does not exist: ", working_dir}))
		if !os.is_dir(working_dir) do return bridge_local_response_error(request_id, "bad_request", strings.concatenate({"shell-cmd exec --cwd is not a directory: ", working_dir}))
	}

	exec_id := bridge_shell_next_exec_id()
	output_path := bridge_shell_output_path(exec_id)
	if slash := strings.last_index_byte(output_path, '/'); slash > 0 do _ = os.make_directory_all(output_path[:slash])

	// The child writes stdout+stderr straight into the output file (2>&1). We keep
	// our own handle only long enough to hand its fd to the child; the child gets a
	// dup'd fd, so closing ours here does not affect the child's writes.
	out_file, oerr := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Read_All + {.Write_User})
	if oerr != nil do return bridge_local_response_error(request_id, "io_error", strings.concatenate({"failed to open shell output file: ", output_path}))

	started_ms := bridge_now_unix_ms()
	start_time := strings.clone(action_scheduler_format_rfc3339_utc(started_ms))

	command := []string{"sh", "-c", cmd}
	process, perr := os.process_start(os.Process_Desc{command = command, stdout = out_file, stderr = out_file, working_dir = working_dir})
	_ = os.close(out_file)
	if perr != nil {
		delete(start_time)
		return bridge_local_response_error(request_id, "spawn_failed", "failed to start shell subprocess")
	}

	state, werr := os.process_wait(process, BRIDGE_SHELL_ASYNC_THRESHOLD)
	if bridge_shell_err_is_timeout(werr) {
		// ---- async path: still running after the threshold --------------------
		job := new(Bridge_Shell_Job)
		job.exec_id = exec_id
		job.cmd = strings.clone(cmd)
		job.status = strings.clone("running")
		job.start_time = start_time
		job.started_unix_ms = started_ms
		job.output_path = strings.clone(output_path)
		job.instance_token = strings.clone(rec.instance_token)
		job.instance_id = strings.clone(rec.agent_instance_id)
		bridge_shell_jobs_put(job)

		ctx := new(Bridge_Shell_Async_Ctx)
		ctx.process = process
		ctx.exec_id = strings.clone(exec_id)
		ctx.cmd = strings.clone(cmd)
		ctx.start_time = strings.clone(start_time)
		ctx.output_path = strings.clone(output_path)
		ctx.started_unix_ms = started_ms
		ctx.instance_token = strings.clone(rec.instance_token)
		ctx.instance_id = strings.clone(rec.agent_instance_id)

		// Report the job to the hub as running BEFORE spawning the worker so the UI
		// can show it in-flight (REQ-14a). Status-only + metadata — never output.
		bridge_shell_cmd_notify_hub(exec_id, "running", 0, false, cmd, start_time, rec)

		thread.run_with_data(rawptr(ctx), bridge_shell_async_worker)

		b := strings.builder_make()
		strings.write_string(&b, "{\"exec_id\":\"")
		bridge_local_write_json_string(&b, exec_id)
		strings.write_string(&b, "\",\"status\":\"running\",\"start_time\":\"")
		bridge_local_write_json_string(&b, start_time)
		strings.write_string(&b, "\",\"raw_output_location\":\"")
		bridge_local_write_json_string(&b, output_path)
		strings.write_string(&b, "\",\"message\":\"Background job started; use shell-cmd read ")
		bridge_local_write_json_string(&b, exec_id)
		strings.write_string(&b, " for output\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}

	// ---- sync path: finished within the threshold ---------------------------
	finished_ms := bridge_now_unix_ms()
	status := "completed"
	exit_code := 0
	if werr == nil {
		exit_code = state.exit_code
	} else {
		// A non-timeout wait error means we lost track of the process; surface it
		// as a failed job rather than a bogus success.
		status = "failed"
		exit_code = -1
	}

	job := new(Bridge_Shell_Job)
	job.exec_id = exec_id
	job.cmd = strings.clone(cmd)
	job.status = strings.clone(status)
	job.start_time = start_time
	job.started_unix_ms = started_ms
	job.finished_unix_ms = finished_ms
	job.exit_code = exit_code
	job.output_path = strings.clone(output_path)
	job.instance_token = strings.clone(rec.instance_token)
	job.instance_id = strings.clone(rec.agent_instance_id)
	bridge_shell_jobs_put(job)

	raw, rerr := os.read_entire_file(output_path, context.allocator)
	defer if rerr == nil do delete(raw)
	output_str := ""
	output_size := 0
	if rerr == nil {
		output_str = string(raw)
		output_size = len(raw)
	}
	tail, truncated := bridge_shell_tail(output_str, BRIDGE_SHELL_TAIL_THRESHOLD, BRIDGE_SHELL_TAIL_KEEP)

	b := strings.builder_make()
	bridge_shell_write_job_json(&b, job, tail, truncated, output_size, true)
	return bridge_local_response_data(request_id, strings.to_string(b))
}

bridge_shell_cmd_read :: proc(request_id, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	exec_id := strings.trim_space(bridge_local_extract_json_string(params, "exec_id", ""))
	if exec_id == "" do return bridge_local_response_error(request_id, "bad_request", "shell-cmd read requires <exec-id>")

	// Optional paging over the on-disk output (REQ-25). The default triple
	// (offset 0, limit 100, no grep) reproduces the historic tail-100 behavior
	// exactly; any customization switches to explicit from-start paging so agents
	// can reach output earlier than the last 100 lines of a long build/test log.
	offset_lines := bridge_local_extract_json_int(params, "offset_lines", 0)
	limit_lines := bridge_local_extract_json_int(params, "limit_lines", BRIDGE_SHELL_TAIL_KEEP)
	grep_pattern := bridge_local_extract_json_string(params, "grep_pattern", "")

	// Snapshot the record under the lock. Only `status` is mutated after creation
	// (by the async worker), so we clone it; the other fields are set once and are
	// safe to share since job records are never removed.
	snap: Bridge_Shell_Job
	ok := false
	sync.mutex_lock(&bridge_shell_jobs_mutex)
	if job, found := bridge_shell_jobs[exec_id]; found {
		snap = job^
		snap.status = strings.clone(job.status)
		ok = true
	}
	sync.mutex_unlock(&bridge_shell_jobs_mutex)
	if !ok do return bridge_local_response_error(request_id, "not_found", strings.concatenate({"no shell job with exec_id ", exec_id}))
	defer delete(snap.status)

	raw, rerr := os.read_entire_file(snap.output_path, context.allocator)
	defer if rerr == nil do delete(raw)
	output_str := ""
	output_size := 0
	if rerr == nil {
		output_str = string(raw)
		output_size = len(raw)
	}
	tail: string
	truncated: bool
	tail_owned := false
	if offset_lines == 0 && limit_lines == BRIDGE_SHELL_TAIL_KEEP && grep_pattern == "" {
		// Back-compat default: last 100 lines only when the file exceeds 200 lines.
		tail, truncated = bridge_shell_tail(output_str, BRIDGE_SHELL_TAIL_THRESHOLD, BRIDGE_SHELL_TAIL_KEEP)
	} else {
		// Explicit paging: from-start offset + limit, optional grep filter. The
		// returned string is heap-allocated, so free it after the response is built.
		tail, truncated = bridge_shell_page(output_str, offset_lines, limit_lines, grep_pattern)
		tail_owned = true
	}
	defer if tail_owned do delete(tail)

	b := strings.builder_make()
	bridge_shell_write_job_json(&b, &snap, tail, truncated, output_size, true)
	return bridge_local_response_data(request_id, strings.to_string(b))
}

// ---- async worker --------------------------------------------------------

bridge_shell_async_worker :: proc(data: rawptr) {
	ctx := (^Bridge_Shell_Async_Ctx)(data)

	// Wait for the process, but no longer than the remaining 30-minute budget
	// measured from spawn (the 15s already-elapsed counts against the cap).
	elapsed := time.Duration(bridge_now_unix_ms() - ctx.started_unix_ms) * time.Millisecond
	remaining := BRIDGE_SHELL_HARD_TIMEOUT - elapsed
	if remaining <= 0 do remaining = time.Millisecond
	state, werr := os.process_wait(ctx.process, remaining)

	status := "completed"
	exit_code := 0
	if bridge_shell_err_is_timeout(werr) {
		// Exceeded the hard cap: force-kill, reap, and mark failed.
		_ = os.process_kill(ctx.process)
		_, _ = os.process_wait(ctx.process)
		bridge_shell_append_line(ctx.output_path, "[job killed: exceeded 30-minute timeout]")
		status = "failed"
		exit_code = -1
	} else if werr == nil {
		exit_code = state.exit_code
	} else {
		status = "failed"
		exit_code = -1
	}

	bridge_shell_jobs_finish(ctx.exec_id, status, exit_code, bridge_now_unix_ms())

	// Report status only to the hub (never any output). rec carries just the
	// caller's instance token, which is all bridge_local_relay_raw needs.
	rec := Bridge_Local_Agent_Token_Record{instance_token = ctx.instance_token, agent_instance_id = ctx.instance_id}
	bridge_shell_cmd_notify_hub(ctx.exec_id, status, exit_code, true, ctx.cmd, ctx.start_time, rec)

	delete(ctx.exec_id)
	delete(ctx.cmd)
	delete(ctx.start_time)
	delete(ctx.output_path)
	delete(ctx.instance_token)
	delete(ctx.instance_id)
	free(ctx)
}

// bridge_shell_cmd_notify_hub reports STATUS + metadata (never output) to the hub.
// exit_code is included only when exit_code_set (omitted for the initial running
// report); cmd + started_at are always included so the hub/UI can show the job
// (REQ-14a).
bridge_shell_cmd_notify_hub :: proc(exec_id, status: string, exit_code: int, exit_code_set: bool, cmd, started_at: string, rec: Bridge_Local_Agent_Token_Record) {
	if strings.trim_space(rec.instance_token) == "" do return
	b := strings.builder_make()
	strings.write_string(&b, "{\"exec_id\":\"")
	bridge_local_write_json_string(&b, exec_id)
	strings.write_string(&b, "\",\"status\":\"")
	bridge_local_write_json_string(&b, status)
	strings.write_byte(&b, '"')
	if exit_code_set {
		strings.write_string(&b, ",\"exit_code\":")
		strings.write_string(&b, bridge_agent_itoa(exit_code))
	}
	strings.write_string(&b, ",\"cmd\":\"")
	bridge_local_write_json_string(&b, cmd)
	strings.write_string(&b, "\",\"started_at\":\"")
	bridge_local_write_json_string(&b, started_at)
	strings.write_string(&b, "\"}")
	_ = bridge_local_relay_raw("POST", "/api/v1/agent-actions/shell-cmd/report", strings.to_string(b), rec)
}

// ---- job store -----------------------------------------------------------

bridge_shell_jobs_put :: proc(job: ^Bridge_Shell_Job) {
	sync.mutex_lock(&bridge_shell_jobs_mutex)
	defer sync.mutex_unlock(&bridge_shell_jobs_mutex)
	if bridge_shell_jobs == nil do bridge_shell_jobs = make(map[string]^Bridge_Shell_Job)
	bridge_shell_jobs[job.exec_id] = job
}

bridge_shell_jobs_finish :: proc(exec_id, status: string, exit_code: int, finished_ms: i64) {
	sync.mutex_lock(&bridge_shell_jobs_mutex)
	defer sync.mutex_unlock(&bridge_shell_jobs_mutex)
	if job, ok := bridge_shell_jobs[exec_id]; ok {
		delete(job.status)
		job.status = strings.clone(status)
		job.exit_code = exit_code
		job.finished_unix_ms = finished_ms
	}
}

// ---- helpers -------------------------------------------------------------

// bridge_shell_write_job_json writes the rich job snapshot object. exit_code and
// execution_time_ms are omitted while the job is still running; output/truncated
// are included only when include_output is set.
bridge_shell_write_job_json :: proc(b: ^strings.Builder, job: ^Bridge_Shell_Job, output_tail: string, truncated: bool, output_size: int, include_output: bool) {
	strings.write_string(b, "{\"exec_id\":\"")
	bridge_local_write_json_string(b, job.exec_id)
	strings.write_string(b, "\",\"status\":\"")
	bridge_local_write_json_string(b, job.status)
	strings.write_byte(b, '"')
	if job.status != "running" {
		strings.write_string(b, ",\"exit_code\":")
		strings.write_string(b, bridge_agent_itoa(job.exit_code))
		strings.write_string(b, ",\"execution_time_ms\":")
		strings.write_string(b, bridge_agent_itoa(int(job.finished_unix_ms - job.started_unix_ms)))
	}
	strings.write_string(b, ",\"start_time\":\"")
	bridge_local_write_json_string(b, job.start_time)
	strings.write_string(b, "\",\"output_size_bytes\":")
	strings.write_string(b, bridge_agent_itoa(output_size))
	strings.write_string(b, ",\"raw_output_location\":\"")
	bridge_local_write_json_string(b, job.output_path)
	strings.write_byte(b, '"')
	if include_output {
		strings.write_string(b, ",\"output\":\"")
		bridge_local_write_json_string(b, output_tail)
		strings.write_string(b, "\",\"truncated\":")
		if truncated {
			strings.write_string(b, "true")
		} else {
			strings.write_string(b, "false")
		}
	}
	strings.write_byte(b, '}')
}

// bridge_shell_tail returns the last `keep` lines of output when it exceeds
// `threshold` lines (truncated=true); otherwise it returns output unchanged
// (truncated=false). The returned string is a slice into `output` (no copy).
bridge_shell_tail :: proc(output: string, threshold, keep: int) -> (string, bool) {
	if keep <= 0 do return output, false
	total := 0
	for i in 0 ..< len(output) {
		if output[i] == '\n' do total += 1
	}
	if len(output) > 0 && output[len(output) - 1] != '\n' do total += 1
	if total <= threshold do return output, false

	// Walk backward, ignoring a single trailing newline, until we have passed
	// `keep` line boundaries; the content after that boundary is the last `keep`
	// lines.
	j := len(output) - 1
	if j >= 0 && output[j] == '\n' do j -= 1
	needed := keep
	for ; j >= 0; j -= 1 {
		if output[j] == '\n' {
			needed -= 1
			if needed == 0 do return output[j + 1:], true
		}
	}
	return output, true
}

// bridge_shell_page produces the output slice for `shell-cmd read` when any of the
// paging flags are set (REQ-25): it skips the first `offset` lines of the file,
// optionally keeps only lines containing `grep` (each prefixed with its original
// 1-based line number, grep -n style), and returns at most `limit` lines. A `limit`
// of <= 0 means "no cap". truncated is true when lines were skipped by the offset
// or candidate lines remain beyond the returned slice. The returned string is
// heap-allocated and owned by the caller. A single trailing newline is treated as a
// line terminator (not an extra empty line), matching bridge_shell_tail's counting.
bridge_shell_page :: proc(output: string, offset, limit: int, grep: string) -> (string, bool) {
	off := offset
	if off < 0 do off = 0
	no_limit := limit <= 0

	b := strings.builder_make()
	idx := 0 // index among candidate (post-grep) lines
	emitted := 0
	line_no := 0
	start := 0
	total := len(output)
	for i := 0; i <= total; i += 1 {
		at_end := i == total
		if !at_end && output[i] != '\n' do continue
		// A line spans [start, i). Skip the empty tail produced by a final newline.
		if !(at_end && start == i) {
			line := output[start:i]
			line_no += 1
			if grep == "" || strings.contains(line, grep) {
				if idx >= off && (no_limit || emitted < limit) {
					if grep != "" {
						strings.write_int(&b, line_no)
						strings.write_byte(&b, ':')
					}
					strings.write_string(&b, line)
					strings.write_byte(&b, '\n')
					emitted += 1
				}
				idx += 1
			}
		}
		start = i + 1
	}
	truncated := off > 0 || idx > off + emitted
	return strings.to_string(b), truncated
}

bridge_shell_next_exec_id :: proc() -> string {
	sync.mutex_lock(&bridge_shell_jobs_mutex)
	bridge_shell_exec_seq += 1
	seq := bridge_shell_exec_seq
	sync.mutex_unlock(&bridge_shell_jobs_mutex)
	return strings.clone(fmt.tprintf("sexc_%x_%d", time.to_unix_nanoseconds(time.now()), seq))
}

bridge_shell_jobs_dir :: proc() -> string {
	data_dir := bridge_expand_home(bridge_config.data_dir)
	if strings.trim_space(data_dir) == "" do data_dir = bridge_expand_home("~/.local/share/heimdall")
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/shell_jobs"})
}

bridge_shell_output_path :: proc(exec_id: string) -> string {
	return strings.concatenate({bridge_shell_jobs_dir(), "/", exec_id, ".out"})
}

bridge_shell_append_line :: proc(path, line: string) {
	f, err := os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREATE, os.Permissions_Read_All + {.Write_User})
	if err != nil do return
	defer os.close(f)
	_, _ = os.write(f, transmute([]byte)line)
	_, _ = os.write(f, []byte{'\n'})
}

bridge_shell_err_is_timeout :: proc(err: os.Error) -> bool {
	if g, ok := err.(os.General_Error); ok do return g == .Timeout
	return false
}
