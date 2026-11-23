package fetch

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// process_start is not thread-safe with respect to handle inheritance
// (core:os docs); serialize our starts so one child never inherits another's
// pipe ends (on Windows that would keep them open and block EOF and deletes).
@(private)
spawn_mutex: sync.Mutex

// Output beyond this is drained but not kept.
@(private)
MAX_CAPTURE :: 1 << 20

@(private)
Capture :: struct {
	r:   ^os.File,
	buf: [dynamic]byte,
}

@(private)
capture_proc :: proc(data: rawptr) {
	c := (^Capture)(data)
	context.allocator = runtime.heap_allocator()
	chunk: [4096]byte
	for {
		n, err := os.read(c.r, chunk[:])
		if n > 0 && len(c.buf) < MAX_CAPTURE do append(&c.buf, ..chunk[:min(n, MAX_CAPTURE - len(c.buf))])
		if err != nil || n <= 0 do return
	}
}

// run_process runs cmd with stdin closed and stdout/stderr captured through
// pipes (read by two threads, so a chatty child never blocks), waits at most
// timeout_ms, and kills the process if it is still running then. It always
// waits for the process to exit before returning (on Windows: the process
// handle is signalled), so nothing it ran keeps a file of its tree open.
// `ran` is false when the process could not be started or had to be killed.
//
// Pipes, not files: on Windows a file handed to os.process_start as stdout
// came out empty (chain dead end from the launcher task, confirmed here).
run_process :: proc(cmd: []string, timeout_ms: int, working_dir := "") -> (exit_code: int, stdout, stderr: string, ran: bool) {
	out_r, out_w, e1 := os.pipe()
	if e1 != nil do return
	err_r, err_w, e2 := os.pipe()
	if e2 != nil {
		os.close(out_r)
		os.close(out_w)
		return
	}
	p: os.Process
	start_err: os.Error
	{
		sync.mutex_lock(&spawn_mutex)
		defer sync.mutex_unlock(&spawn_mutex)
		p, start_err = os.process_start({command = cmd, stdout = out_w, stderr = err_w, working_dir = working_dir})
		// Our copies of the write ends must go, or the readers never see EOF.
		os.close(out_w)
		os.close(err_w)
	}
	if start_err != nil {
		os.close(out_r)
		os.close(err_r)
		return
	}
	// Heap, not stack/temp: an abandoned reader (see finish_reader) may still
	// touch its Capture after we return.
	out_c := new(Capture, runtime.heap_allocator())
	err_c := new(Capture, runtime.heap_allocator())
	out_c^ = Capture{r = out_r, buf = make([dynamic]byte, runtime.heap_allocator())}
	err_c^ = Capture{r = err_r, buf = make([dynamic]byte, runtime.heap_allocator())}
	t1 := thread.create_and_start_with_data(out_c, capture_proc, context)
	t2 := thread.create_and_start_with_data(err_c, capture_proc, context)

	state, werr := os.process_wait(p, time.Duration(timeout_ms) * time.Millisecond)
	killed := false
	if werr != nil {
		_ = os.process_kill(p)
		state, _ = os.process_wait(p) // until it is gone
		killed = true
	}
	stdout = finish_reader(t1, out_c)
	stderr = finish_reader(t2, err_c)
	return state.exit_code, stdout, stderr, state.exited && !killed
}

// finish_reader waits up to 2 s for a reader to reach EOF and returns what
// it read (temp-allocated). A grandchild that inherited the write end can keep
// the pipe open; closing the read end does not reliably wake a blocked read on
// Linux, so such a reader is abandoned (thread, pipe and buffer leak; rare,
// and bounded by MAX_CAPTURE).
@(private)
finish_reader :: proc(t: ^thread.Thread, c: ^Capture) -> string {
	for _ in 0 ..< 200 {
		if thread.is_done(t) do break
		time.sleep(10 * time.Millisecond)
	}
	if !thread.is_done(t) do return ""
	thread.join(t)
	thread.destroy(t)
	os.close(c.r)
	out := strings.clone(string(c.buf[:]), context.temp_allocator)
	delete(c.buf)
	free(c, runtime.heap_allocator())
	return out
}
