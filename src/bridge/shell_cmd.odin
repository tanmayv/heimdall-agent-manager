package main

// Bridge-local shell command execution.
//
// An agent calls `agent.shell_cmd.exec {cmd}` and the bridge runs it LOCALLY
// (sh -c) on this host as a direct child process, capturing stdout+stderr into
// <data_dir>/shell_jobs/<session_id>.out. Output is NEVER sent to the hub; it is
// read on demand from this machine.
//
// REQ-SHELL-2 DELETED THE 15s AUTO-BACKGROUND RULE. This file used to race a
// BRIDGE_SHELL_ASYNC_THRESHOLD deadline: a command finishing inside 15s returned
// synchronously, and one that did not was silently converted into a background job
// that reported back over the hub. That implicit rule is GONE, along with the dual
// sync/async code paths it required, and it is not coming back — an agent could
// not tell which shape it was going to get without knowing in advance how long its
// own command would take, and "how long did it happen to run" is not an intent.
//
// BACKGROUNDING IS NOW EXPLICIT, and it is the CALLER that says so:
//
//   default (foreground)  the call blocks until the run reaches a terminal status
//                         and returns the result INLINE. No notification is sent —
//                         the caller is holding the answer already, so a message
//                         about it would be noise. There is no duration at which
//                         this silently becomes something else.
//
//   background:true       the call returns IMMEDIATELY with the session id. The
//                         completion (or kill) notification arrives later
//                         referencing that id, delivered by REQ-SHELL-5.
//
// The block itself lives in shell_run_wait.odin — see that file for why it is
// bridge-local rather than a long hub request, and for the W1-W4 constraints it
// satisfies. What matters here is that the wait is a CONVENIENCE: this proc
// registers the run in the session map and on disk BEFORE it blocks, so a caller
// that dies, is Ctrl-C'd or times out leaves a run that is still live, still
// tracked, still killable by id and still reapable.
//
// The 30-minute hard cap (BRIDGE_SHELL_HARD_TIMEOUT) survives, because it bounds
// the PROCESS and always did. It is enforced by the reaper thread below for every
// run regardless of foreground/background, and it is NOT applied to kind=server
// sessions, which are long-running by definition and never come through here.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Hard cap for a run measured from spawn; exceeded -> SIGKILL the process group +
// status failed/killed. It bounds the PROCESS, not any call waiting on it, so a
// dropped waiter neither extends nor shortens it, and it applies equally to a
// foreground and a background run.
//
// It does NOT apply to kind=server sessions. A server is long-running by
// definition — capping it at 30 minutes would kill every dev server half an hour
// in — and servers are spawned through the pty-host path in hub_runtime_client.odin,
// which never reaches this reaper. That is not an accident of layering: see
// bridge_shell_run_reaper_applies for the assertion that keeps it true.
BRIDGE_SHELL_HARD_TIMEOUT :: 30 * time.Minute
// Output truncation: > THRESHOLD lines -> keep only the last KEEP lines.
BRIDGE_SHELL_TAIL_THRESHOLD :: 200
BRIDGE_SHELL_TAIL_KEEP :: 100

// Package-level session map (replaces the old bridge_shell_jobs map).
// All exec sessions (kind=Run) are registered here.
bridge_shell_session_map: Bridge_Shell_Session_Map

// Bridge_Shell_Async_Ctx is heap-allocated per background job and handed to the
// worker thread, which frees it on exit.
Bridge_Shell_Async_Ctx :: struct {
	process:         os.Process,
	exec_id:         string, // == session_id
	cmd:             string,
	start_time:      string, // RFC3339 UTC
	output_path:     string,
	started_unix_ms: i64,
	instance_token:  string,
	instance_id:     string,
	// background decides ONLY whether the hub is notified when this run ends. The
	// reaper's process ownership, the 30-minute cap, the status write and the spec
	// deletion are identical either way — a foreground run needs an owner just as
	// much, because its caller may vanish at any moment (W2).
	background:      bool,
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

	session_id := bridge_shell_session_next_id()
	defer delete(session_id)
	output_path := bridge_shell_output_path(session_id)
	defer delete(output_path)
	if slash := strings.last_index_byte(output_path, '/'); slash > 0 do _ = os.make_directory_all(output_path[:slash])

	// The child writes stdout+stderr straight into the output file (2>&1). We keep
	// our own handle only long enough to hand its fd to the child; the child gets a
	// dup'd fd, so closing ours here does not affect the child's writes.
	out_file, oerr := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Read_All + {.Write_User})
	if oerr != nil do return bridge_local_response_error(request_id, "io_error", strings.concatenate({"failed to open shell output file: ", output_path}))

	started_ms := bridge_now_unix_ms()
	start_time := strings.clone(action_scheduler_format_rfc3339_utc(started_ms))
	defer delete(start_time)

	// setsid creates a new session so the spawned sh becomes the session/group
	// leader (PGID == PID). On timeout we kill the entire group with kill(-pgid)
	// so child processes the shell spawns are also terminated (REQ-27).
	command: []string
	when ODIN_OS == .Darwin {
		command = []string{"sh", "-c", cmd}
	} else {
		command = []string{"setsid", "sh", "-c", cmd}
	}
	process, perr := os.process_start(os.Process_Desc{command = command, stdout = out_file, stderr = out_file, working_dir = working_dir})
	_ = os.close(out_file)
	if perr != nil {
		return bridge_local_response_error(request_id, "spawn_failed", "failed to start shell subprocess")
	}

	// Register and PERSIST before doing anything else. This ordering is what makes
	// the wait a convenience rather than the source of truth (W2): from here on the
	// run is in the map and on disk, so a caller that dies, is Ctrl-C'd or times out
	// leaves a run that is still live, still tracked, still killable by id and still
	// reapable by reconcile.
	//
	// SAVED AFTER THE PID IS KNOWN, deliberately. reconcile proves a direct child's
	// liveness with bridge_shell_session_pid_is_plausible, which needs the pid, the
	// cmd and started_at together — a spec written before the spawn would carry pid 0
	// and be unreapable, which defeats the only reason the file exists.
	//
	// KNOWN WINDOW, RECORDED AS DELIBERATE: between os.process_start above and this
	// save, a bridge crash leaves a running process with no spec and therefore no
	// tracker. It cannot be closed from here — the pid does not exist before the
	// spawn and the crash can land on either side of any single write — so it is left
	// to the convergence inventory (REQ-SHELL-10), which is the net for exactly this
	// class of gap. Do not try to close it locally with a pre-spawn placeholder: that
	// trades a rare untracked process for a routine spec that names no process.
	background := bridge_local_extract_json_bool(params, "background", false)

	// THE MAP'S ALLOCATOR, explicitly. register takes ownership of every string
	// below, and the map is what frees them — when this entry is superseded by
	// reconcile on a background thread, or removed. context.allocator differs per
	// thread (a per-test tracking allocator under `odin test`), so cloning through it
	// here would free through a different allocator than it allocated from. Same rule
	// as the ctx below, and as lsp_session.odin's lsp_heap.
	map_heap := bridge_shell_session_map_allocator(&bridge_shell_session_map)
	sess := Bridge_Shell_Session{
		session_id      = strings.clone(session_id, map_heap),
		kind            = .Run,
		cmd             = strings.clone(cmd, map_heap),
		cwd             = strings.clone(cwd, map_heap),
		bridge_id       = strings.clone(bridge_config.daemon_id, map_heap),
		agent_instance_id = strings.clone(rec.agent_instance_id, map_heap),
		pid             = process.pid,
		status          = .Running,
		started_at      = strings.clone(start_time, map_heap),
		started_unix_ms = started_ms,
		shell_id        = strings.clone(session_id, map_heap),
		background      = background,
		// Direct os.process_start child, NOT a pty-host session: it will never appear
		// in the daemon roster, and reconcile must resolve its liveness with ps
		// instead of reaping it as missing. See bridge_shell_session_reconcile.
		pty_host        = false,
		pty_host_provenance_known = true,
	}
	// SPEC FIRST, THEN REGISTER — see the same reordering in
	// bridge_hub_handle_shell_start for the full reasoning. save_spec reads every
	// string of `sess`; after register the map owns them and a concurrent re-register
	// could free them mid-read, with bridge_shell_data_dir() sitting in the window.
	data_dir := bridge_shell_data_dir()
	defer delete(data_dir)
	bridge_shell_session_save_spec(data_dir, sess)

	// CONSUMES sess: it is zeroed here and must not be read below.
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	// The reaper owns the process from here: it waits for the child, enforces the
	// 30-minute cap, records the terminal status, clears the spec, signals any
	// foreground waiter and — for a BACKGROUND run only — notifies the hub. It runs
	// for foreground and background alike, because the process needs an owner either
	// way and the foreground caller may vanish at any moment (W2/W4).
	// The ctx crosses a THREAD BOUNDARY: it is built here and freed by the worker.
	// Every field is therefore allocated from runtime.default_allocator() and freed
	// from the same, never from context.allocator — which differs per thread (it is
	// a per-thread tracking allocator under the test runner) and would make the
	// worker's frees invalid frees against memory this thread allocated. Same
	// discipline as bridge_shell_session_register's map.
	//
	// This used to be reachable only on the async side of the deleted 15s threshold,
	// so the mismatch existed but was rarely hit; every run takes this path now.
	heap := runtime.default_allocator()
	ctx := new(Bridge_Shell_Async_Ctx, heap)
	ctx.process         = process
	ctx.exec_id         = strings.clone(session_id, heap)
	ctx.cmd             = strings.clone(cmd, heap)
	ctx.start_time      = strings.clone(start_time, heap)
	ctx.output_path     = strings.clone(output_path, heap)
	ctx.started_unix_ms = started_ms
	ctx.instance_token  = strings.clone(rec.instance_token, heap)
	ctx.instance_id     = strings.clone(rec.agent_instance_id, heap)
	ctx.background      = background

	if background {
		// Report it to the hub as running before the worker starts, so the UI can show
		// it in flight. Status + metadata only, never output.
		bridge_shell_cmd_notify_hub(session_id, "running", 0, false, cmd, start_time, rec)
	}
	thread.run_with_data(rawptr(ctx), bridge_shell_async_worker)

	if background {
		// ---- explicit background: return the session id immediately --------------
		b := strings.builder_make()
		strings.write_string(&b, "{\"exec_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"session_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"status\":\"running\",\"background\":true,\"start_time\":\"")
		bridge_local_write_json_string(&b, start_time)
		strings.write_string(&b, "\",\"raw_output_location\":\"")
		bridge_local_write_json_string(&b, output_path)
		strings.write_string(&b, "\",\"message\":\"Background run started; you will be notified when it finishes. Read output with shell-cmd read ")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}

	// ---- foreground: block until terminal, then return the result inline -------
	// No threshold, no conversion: however long this takes, it comes back here.
	return bridge_shell_run_wait_response(request_id, session_id, output_path)
}

// bridge_shell_run_wait_response blocks on a live run and renders the result the
// FOREGROUND caller gets back. Shared by shell_cmd exec and the agent.shell.wait
// local RPC (which is how `ham-ctl shell run` blocks on a hub-created run), so the
// two surfaces cannot drift in what "the run finished" looks like.
//
// Three shapes come out of it, and they are distinguishable by the caller:
//   finished      -> the full session result with exit_code and output, as an
//                    inline `shell-cmd exec` always returned.
//   backgrounded  -> {background:true, session_id}, byte-identical to what a
//                    background start returns, because that is exactly what the
//                    run now is.
//   timeout       -> the wait call's own ceiling elapsed. THE RUN IS UNAFFECTED
//                    (W2/W4): it keeps running, and the id in the response is how
//                    the caller re-reads or kills it.
bridge_shell_run_wait_response :: proc(request_id, session_id, output_path: string, timeout_ms := BRIDGE_SHELL_WAIT_DEFAULT_MS) -> string {
	w := bridge_shell_wait_register(session_id)
	// Unregistered on EVERY exit path by the waiting thread itself, which is what
	// leaves nothing behind when a caller walks away.
	defer bridge_shell_wait_unregister(session_id, w)

	outcome, _, _, _ := bridge_shell_wait_block(w, timeout_ms)

	if outcome == .Backgrounded {
		b := strings.builder_make()
		strings.write_string(&b, "{\"exec_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"session_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"status\":\"running\",\"background\":true,\"message\":\"Run was moved to the background; you will be notified when it finishes.\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}

	if outcome == .Timed_Out {
		b := strings.builder_make()
		strings.write_string(&b, "{\"exec_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"session_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"status\":\"running\",\"timed_out\":true,\"message\":\"Still running; the wait timed out but the run was not affected.\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}

	// Terminal. Read the final record back from the map rather than trusting the
	// values carried on the signal, so the response reflects what was actually
	// recorded (the reaper writes status/exit_code/timing under the map lock).
	snap, ok := bridge_shell_session_snapshot(&bridge_shell_session_map, session_id)
	if !ok do return bridge_local_response_error(request_id, "not_found", strings.concatenate({"no shell session with id ", session_id}))
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, snap)

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
	bridge_shell_write_session_json(&b, &snap, tail, truncated, output_size, true)
	return bridge_local_response_data(request_id, strings.to_string(b))
}

// bridge_shell_data_dir resolves the expanded data dir, defaulting as everywhere
// else in the bridge. The returned string is always owned by the caller (unlike
// bridge_expand_home, which aliases its input when there is no "~" to expand) so
// callers get one unconditional delete instead of a guarded one.
bridge_shell_data_dir :: proc() -> string {
	raw_dir := strings.trim_space(bridge_config.data_dir)
	if raw_dir == "" do raw_dir = "~/.local/share/heimdall"
	expanded := bridge_expand_home(raw_dir)
	if raw_data(expanded) != raw_data(raw_dir) do return expanded
	return strings.clone(expanded)
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

	// A deep-clone snapshot under the lock: every string field below is serialized
	// into the response, and the record may be superseded by reconcile meanwhile.
	snap, ok := bridge_shell_session_snapshot(&bridge_shell_session_map, exec_id)
	if !ok do return bridge_local_response_error(request_id, "not_found", strings.concatenate({"no shell job with exec_id ", exec_id}))
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, snap)

	output_path := bridge_shell_output_path(exec_id)
	defer delete(output_path)

	raw, rerr := os.read_entire_file(output_path, context.allocator)
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
	bridge_shell_write_session_json(&b, &snap, tail, truncated, output_size, true)
	return bridge_local_response_data(request_id, strings.to_string(b))
}

// ---- async worker --------------------------------------------------------

// bridge_shell_async_worker OWNS the spawned process for its whole life. It is
// started for EVERY run, foreground or background — the name is historical, from
// when it only ran on the async side of the deleted 15s threshold.
//
// It waits for the child under the 30-minute cap, records the terminal status,
// clears the spec, releases any blocked foreground caller, and notifies the hub
// only when the run is a BACKGROUND one.
bridge_shell_async_worker :: proc(data: rawptr) {
	ctx := (^Bridge_Shell_Async_Ctx)(data)

	// Wait for the process, but no longer than the remaining 30-minute budget
	// measured from spawn. The budget is measured from SPAWN rather than from here
	// so the cap means the same thing however long this thread took to start (W4:
	// it bounds the process, and nothing about a wait call can move it).
	elapsed := time.Duration(bridge_now_unix_ms() - ctx.started_unix_ms) * time.Millisecond
	remaining := BRIDGE_SHELL_HARD_TIMEOUT - elapsed
	if remaining <= 0 do remaining = time.Millisecond
	state, werr := os.process_wait(ctx.process, remaining)

	status := Bridge_Shell_Session_Status.Exited
	exit_code := 0
	if bridge_shell_err_is_timeout(werr) {
		// Exceeded the hard cap: kill the entire process group (setsid made the
		// shell the group leader, so kill(-pgid) reaches all its children too).
		when ODIN_OS == .Darwin {
			_ = posix.kill(posix.pid_t(-i32(ctx.process.pid)), .SIGKILL)
			_ = posix.kill(posix.pid_t(ctx.process.pid), .SIGKILL)
		} else {
			_ = posix.kill(posix.pid_t(-i32(ctx.process.pid)), .SIGKILL)
		}
		_, _ = os.process_wait(ctx.process)
		bridge_shell_append_line(ctx.output_path, "[job killed: exceeded 30-minute timeout]")
		status = .Killed
		exit_code = -1
	} else if werr == nil {
		exit_code = state.exit_code
	} else {
		status = .Failed
		exit_code = -1
	}

	bridge_shell_session_finish(&bridge_shell_session_map, ctx.exec_id, status, exit_code, bridge_now_unix_ms())

	// The run is over: drop its spec, so the on-disk set is exactly the live set and
	// reconcile never sees a finished run as an orphan to reap.
	data_dir := bridge_shell_data_dir()
	bridge_shell_session_delete_spec(data_dir, ctx.exec_id)
	delete(data_dir)

	// Release a blocked FOREGROUND caller. Must happen whether or not the hub is
	// notified below: these are two independent consumers of one exit (W3), and a
	// foreground caller is released precisely because it will NOT get a
	// notification.
	bridge_shell_wait_signal_exit(ctx.exec_id, status, exit_code, true)

	// Re-read the CURRENT background flag rather than trusting ctx.background: the
	// run may have been converted to background mid-flight, after this worker
	// started, and a converted run must notify exactly as a born-background one
	// does. ctx.background is only the value at spawn.
	notify := ctx.background
	if sc, ok := bridge_shell_session_scalars(&bridge_shell_session_map, ctx.exec_id); ok do notify = sc.background

	// ONLY a background run notifies. A foreground run returned its result inline to
	// the caller that was blocked on it, so a notification would be telling someone
	// what they are already holding. Status + metadata only, never output.
	if notify {
		sync.atomic_add(&bridge_shell_notify_decisions, 1)
		status_str := "completed"
		if status == .Killed || status == .Failed do status_str = "failed"
		rec := Bridge_Local_Agent_Token_Record{instance_token = ctx.instance_token, agent_instance_id = ctx.instance_id}
		bridge_shell_cmd_notify_hub(ctx.exec_id, status_str, exit_code, true, ctx.cmd, ctx.start_time, rec)
	}

	// Freed from the SAME allocator the spawning thread used (see the ctx build).
	heap := runtime.default_allocator()
	delete(ctx.exec_id, heap)
	delete(ctx.cmd, heap)
	delete(ctx.start_time, heap)
	delete(ctx.output_path, heap)
	delete(ctx.instance_token, heap)
	delete(ctx.instance_id, heap)
	free(ctx, heap)
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

// bridge_shell_notify_decisions counts the times a finished run DECIDED to notify
// the hub. It is a test seam for the property AC1 asks to be tested explicitly:
// ONLY a background run notifies, and a foreground run — which returned its result
// inline to a caller that was blocked on it — sends nothing.
//
// It counts the DECISION rather than a delivered message on purpose. Delivery
// needs a hub, and a test that asserted on delivery would be asserting the
// transport works; what must be pinned here is the rule about which runs notify at
// all, which is the thing the deleted 15s threshold used to get wrong.
bridge_shell_notify_decisions: int

// bridge_shell_test_notify_decisions reads the counter.
bridge_shell_test_notify_decisions :: proc() -> int {
	return sync.atomic_load(&bridge_shell_notify_decisions)
}

// bridge_shell_test_kill_pid terminates a process group a test spawned, so a
// `sleep` left behind by a reconcile test does not outlive the suite. Kills the
// GROUP (setsid made the child a leader), matching how the reaper cleans up.
bridge_shell_test_kill_pid :: proc(pid: int) {
	if pid <= 0 do return
	_ = posix.kill(posix.pid_t(-i32(pid)), .SIGKILL)
	_ = posix.kill(posix.pid_t(pid), .SIGKILL)
}

// bridge_shell_test_session_str clones a string from THE SESSION MAP'S allocator, for
// a test that builds a Bridge_Shell_Session by hand and hands it to
// bridge_shell_session_register.
//
// It exists because the map frees what it is given (REQ-SHELL-11), and under
// `odin test` context.allocator is a PER-TEST TRACKING ALLOCATOR while the map's is
// the process heap — so a plain strings.clone here would be freed through an
// allocator it never came from, which the tracking allocator reports as a bad free.
bridge_shell_test_session_str :: proc(str: string) -> string {
	return strings.clone(str, bridge_shell_session_map_allocator(&bridge_shell_session_map))
}

// bridge_shell_test_reset clears the session map (for tests).
bridge_shell_test_reset :: proc() {
	bridge_shell_session_map_reset(&bridge_shell_session_map)
	// REQ-SHELL-3: the pending kill-intent set is process-global too, so a test that
	// records one must not leak it into the next test's spawn path — where it would be
	// consumed and turn a healthy start into an immediate kill.
	bridge_shell_kill_intent_reset()
}

// ---- helpers -------------------------------------------------------------

// bridge_shell_write_session_json writes the rich exec-response object for a
// kind=Run session. exit_code and execution_time_ms are omitted while the
// session is still running; output/truncated are included only when
// include_output is set.
bridge_shell_write_session_json :: proc(b: ^strings.Builder, s: ^Bridge_Shell_Session, output_tail: string, truncated: bool, output_size: int, include_output: bool) {
	status_str := bridge_shell_session_exec_status_str(s)
	output_path := bridge_shell_output_path(s.session_id)
	defer delete(output_path)

	strings.write_string(b, "{\"exec_id\":\"")
	bridge_local_write_json_string(b, s.session_id)
	// session_id is the SAME value as exec_id, emitted under both names on purpose.
	// exec_id is shell-cmd's historic spelling and its callers still read it; every
	// other shell surface (create, kill, log, the wait RPC) speaks session_id. Since
	// REQ-SHELL-2 routes both through this one renderer, emitting both means neither
	// caller has to know which surface produced the response.
	strings.write_string(b, "\",\"session_id\":\"")
	bridge_local_write_json_string(b, s.session_id)
	strings.write_string(b, "\",\"status\":\"")
	bridge_local_write_json_string(b, status_str)
	strings.write_byte(b, '"')
	if s.status != .Running && s.status != .Starting {
		strings.write_string(b, ",\"exit_code\":")
		strings.write_string(b, bridge_agent_itoa(s.exit_code))
		if s.finished_unix_ms > 0 {
			strings.write_string(b, ",\"execution_time_ms\":")
			strings.write_string(b, bridge_agent_itoa(int(s.finished_unix_ms - s.started_unix_ms)))
		}
	}
	strings.write_string(b, ",\"start_time\":\"")
	bridge_local_write_json_string(b, s.started_at)
	strings.write_string(b, "\",\"output_size_bytes\":")
	strings.write_string(b, bridge_agent_itoa(output_size))
	strings.write_string(b, ",\"raw_output_location\":\"")
	bridge_local_write_json_string(b, output_path)
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

bridge_shell_jobs_dir :: proc() -> string {
	raw_dir := strings.trim_space(bridge_config.data_dir)
	if raw_dir == "" do raw_dir = "~/.local/share/heimdall"
	data_dir := bridge_expand_home(raw_dir)
	defer if raw_data(data_dir) != raw_data(raw_dir) do delete(data_dir)
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/shell_jobs"})
}

bridge_shell_output_path :: proc(session_id: string) -> string {
	jobs_dir := bridge_shell_jobs_dir()
	defer delete(jobs_dir)
	return strings.concatenate({jobs_dir, "/", session_id, ".out"})
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
