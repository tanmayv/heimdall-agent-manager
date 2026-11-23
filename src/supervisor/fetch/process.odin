package fetch

import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// process_start is not thread-safe with respect to handle inheritance
// (core:os docs); serialize our starts so one child never inherits another's
// output files (on Windows that would keep them open and block deletes).
@(private)
spawn_mutex: sync.Mutex

// run_process runs cmd with stdin closed and stdout/stderr captured through
// temporary files, waits at most timeout_ms, and kills the process if it is
// still running then. It always waits for the process to exit before
// returning (on Windows: the process handle is signalled), so nothing it ran
// keeps a file of its tree open. `ran` is false when the process could not
// be started or had to be killed.
run_process :: proc(cmd: []string, timeout_ms: int, working_dir := "") -> (exit_code: int, stdout, stderr: string, ran: bool) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if terr != nil do return
	out_f, e1 := os.create_temp_file(tmp, "ham-fetch-out-*")
	if e1 != nil do return
	out_path := strings.clone(os.name(out_f), context.temp_allocator) // the name dies with the File
	defer os.remove(out_path)
	err_f, e2 := os.create_temp_file(tmp, "ham-fetch-err-*")
	if e2 != nil {
		os.close(out_f)
		return
	}
	err_path := strings.clone(os.name(err_f), context.temp_allocator)
	defer os.remove(err_path)

	p: os.Process
	start_err: os.Error
	{
		sync.mutex_lock(&spawn_mutex)
		defer sync.mutex_unlock(&spawn_mutex)
		p, start_err = os.process_start({command = cmd, stdout = out_f, stderr = err_f, working_dir = working_dir})
	}
	os.close(out_f)
	os.close(err_f)
	if start_err != nil do return

	state, werr := os.process_wait(p, time.Duration(timeout_ms) * time.Millisecond)
	killed := false
	if werr != nil {
		_ = os.process_kill(p)
		state, _ = os.process_wait(p) // until it is gone
		killed = true
	}
	out_data, _ := os.read_entire_file(out_path, context.temp_allocator)
	err_data, _ := os.read_entire_file(err_path, context.temp_allocator)
	return state.exit_code, string(out_data), string(err_data), state.exited && !killed
}
