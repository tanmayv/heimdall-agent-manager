package bridge_runtime

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core:thread"
import "core:time"
import project_service "odin_test:hub/service/project"

@(private = "file")
Writer_Job :: struct {
	registry: ^project_service.Bridge_Runtime_Registry,
	ids:      []string,
	results:  []string,
	bridge_id: string,
	lo, hi:   int,
}

@(private = "file")
writer_entry :: proc(th: ^thread.Thread) {
	j := (^Writer_Job)(th.data)
	for i in j.lo ..< j.hi {
		_, _ = runtime_command_result_idempotent(j.registry, j.bridge_id, j.ids[i], j.results[i])
	}
}

@(private = "file")
reader_entry :: proc(th: ^thread.Thread) {
	j := (^Writer_Job)(th.data)
	// Hammer the cache read path concurrently with the writers to shake out any
	// unsynchronized read-vs-write on command_ids/command_count.
	for _ in 0 ..< 2000 {
		_, _ = runtime_command_cached(j.registry, "brg_0", j.ids[0])
	}
}

@(private = "file")
Terminal_Wait_Job :: struct {
	registry: ^project_service.Bridge_Runtime_Registry,
	result: string,
	ok: bool,
}

@(private = "file")
terminal_wait_entry :: proc(th: ^thread.Thread) {
	j := (^Terminal_Wait_Job)(th.data)
	j.result, j.ok = runtime_command_wait_terminal(j.registry, "brg_wait", "cmd_wait", time.Second)
}

@(test)
runtime_command_cache_is_thread_safe :: proc(t: ^testing.T) {
	// DEFECT #1 guard: multiple threads writing command results (the runtime loop +
	// concurrent fs/file commands all funnel through runtime_command_result_idempotent)
	// plus a concurrent reader must not tear command_count or lose/duplicate entries.
	// With the registry command mutex every distinct id lands exactly once; without
	// it, racing count++ increments drop or corrupt entries.
	WRITERS :: 4
	N :: WRITERS * RUNTIME_COMMAND_RESULTS_PER_BRIDGE
	ids: [N]string
	results: [N]string
	for i in 0 ..< N {
		ids[i] = fmt.aprintf("cmd_%d", i)
		results[i] = fmt.aprintf("{\"command_id\":\"cmd_%d\",\"n\":%d}", i, i)
	}
	defer for i in 0 ..< N { delete(ids[i]); delete(results[i]) }

	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }

	per := N / WRITERS
	jobs: [WRITERS]Writer_Job
	threads: [WRITERS]^thread.Thread
	reader_job := Writer_Job{registry = registry, ids = ids[:], results = results[:], bridge_id = "brg_0"}
	reader := thread.create(reader_entry)
	reader.data = rawptr(&reader_job)
	thread.start(reader)

	for w in 0 ..< WRITERS {
		jobs[w] = Writer_Job{registry = registry, ids = ids[:], results = results[:], bridge_id = fmt.aprintf("brg_%d", w), lo = w * per, hi = (w + 1) * per}
		threads[w] = thread.create(writer_entry)
		threads[w].data = rawptr(&jobs[w])
		thread.start(threads[w])
	}
	for w in 0 ..< WRITERS {
		thread.join(threads[w])
		thread.destroy(threads[w])
		delete(jobs[w].bridge_id)
	}
	thread.join(reader)
	thread.destroy(reader)

	// Every distinct id stored exactly once — no torn count, no lost/dup entries.
	testing.expect_value(t, registry.command_count, N)
	for i in 0 ..< N {
		bridge_id := fmt.aprintf("brg_%d", i / per)
		cached, ok := runtime_command_cached(registry, bridge_id, ids[i])
		delete(bridge_id)
		testing.expect(t, ok, "each written command id must be retrievable")
		testing.expect_value(t, cached, results[i])
	}
}

@(test)
runtime_terminal_waiter_is_signalled_without_polling :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	job := Terminal_Wait_Job{registry = registry}
	waiter := thread.create(terminal_wait_entry)
	waiter.data = rawptr(&job)
	started := time.now()
	thread.start(waiter)
	time.sleep(10 * time.Millisecond)
	terminal := `{"type":"command_result","command_id":"cmd_wait","payload":{"status":"succeeded"}}`
	_, _ = runtime_command_result_idempotent(registry, "brg_wait", "cmd_wait", terminal)
	thread.join(waiter)
	thread.destroy(waiter)
	defer delete(job.result, runtime.default_allocator())
	testing.expect(t, job.ok, "terminal insertion must wake the matching waiter")
	testing.expect_value(t, job.result, terminal)
	testing.expect(t, time.diff(started, time.now()) < 500 * time.Millisecond, "waiter must wake promptly instead of waiting for its deadline")
}
