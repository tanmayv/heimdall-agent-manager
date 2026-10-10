package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

BRIDGE_PROCESS_OUTPUT_LIMIT :: 1024 * 1024

// A Bridge-wide budget for child processes started by command workers. Long-lived
// LSP servers retain their slot until removal; short-lived probes and bounded
// subprocesses release it after wait/reap. This keeps persistent children from
// defeating the dispatcher's worker-count bound.
BRIDGE_PROCESS_SLOT_LIMIT :: 16

bridge_process_slot_mu: sync.Mutex
bridge_process_slots_active: int

bridge_process_slot_has_capacity :: proc(active: int) -> bool {
	return active >= 0 && active < BRIDGE_PROCESS_SLOT_LIMIT
}

bridge_process_slot_try_acquire :: proc() -> bool {
	sync.mutex_lock(&bridge_process_slot_mu)
	defer sync.mutex_unlock(&bridge_process_slot_mu)
	if !bridge_process_slot_has_capacity(bridge_process_slots_active) do return false
	bridge_process_slots_active += 1
	return true
}

bridge_process_slot_release :: proc() {
	sync.mutex_lock(&bridge_process_slot_mu)
	defer sync.mutex_unlock(&bridge_process_slot_mu)
	if bridge_process_slots_active > 0 do bridge_process_slots_active -= 1
}

bridge_process_slot_count :: proc() -> int {
	sync.mutex_lock(&bridge_process_slot_mu)
	defer sync.mutex_unlock(&bridge_process_slot_mu)
	return bridge_process_slots_active
}

bridge_process_drain_pipe :: proc(file: ^os.File, output: ^[dynamic]byte) -> (read_any: bool, open: bool) {
	if file == nil do return false, false
	ready, ready_err := os.pipe_has_data(file)
	if ready_err != nil do return false, false
	if !ready do return false, true
	buf: [8192]byte
	n, read_err := os.read(file, buf[:])
	if read_err != nil || n <= 0 do return false, false
	remaining := BRIDGE_PROCESS_OUTPUT_LIMIT - len(output)
	if remaining > 0 {
		keep := min(n, remaining)
		append(output, ..buf[:keep])
	}
	return true, true
}

// Executes argv without a shell, drains stdout/stderr while it runs, and always
// kills+reaps on deadline. Returned strings belong to context.allocator.
bridge_process_run_capture :: proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, ok, timed_out: bool) {
	if len(args) == 0 || timeout <= 0 do return "", "", false, false
	if !bridge_process_slot_try_acquire() do return "", "", false, false
	defer bridge_process_slot_release()
	stdout_r, stdout_w, stdout_pipe_err := os.pipe()
	if stdout_pipe_err != nil do return "", "", false, false
	defer os.close(stdout_r)
	stderr_r, stderr_w, stderr_pipe_err := os.pipe()
	if stderr_pipe_err != nil {
		_ = os.close(stdout_w)
		return "", "", false, false
	}
	defer os.close(stderr_r)

	process, start_err := os.process_start(os.Process_Desc{command = args, stdout = stdout_w, stderr = stderr_w})
	_ = os.close(stdout_w)
	_ = os.close(stderr_w)
	if start_err != nil do return "", "", false, false

	out_bytes := make([dynamic]byte, 0, 8192)
	err_bytes := make([dynamic]byte, 0, 4096)
	defer { delete(out_bytes); delete(err_bytes) }
	deadline := time.time_add(time.now(), timeout)
	state: os.Process_State
	exited := false
	for !exited {
		out_read, _ := bridge_process_drain_pipe(stdout_r, &out_bytes)
		err_read, _ := bridge_process_drain_pipe(stderr_r, &err_bytes)
		if current, wait_err := os.process_wait(process, 0); wait_err == nil {
			state = current
			exited = true
			break
		}
		if time.diff(time.now(), deadline) <= 0 {
			timed_out = true
			_ = os.process_kill(process)
			state, _ = os.process_wait(process, 500 * time.Millisecond)
			exited = true
			break
		}
		if !out_read && !err_read do time.sleep(5 * time.Millisecond)
	}
	// Child write ends are closed after exit. Drain any final buffered bytes without
	// blocking; output beyond the cap is deliberately discarded but still drained.
	for {
		out_read, _ := bridge_process_drain_pipe(stdout_r, &out_bytes)
		err_read, _ := bridge_process_drain_pipe(stderr_r, &err_bytes)
		if !out_read && !err_read do break
	}
	stdout = strings.clone(string(out_bytes[:]), context.allocator)
	stderr = strings.clone(string(err_bytes[:]), context.allocator)
	return stdout, stderr, !timed_out && state.exited && state.success, timed_out
}
