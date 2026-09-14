package bridge_runtime

import "core:fmt"
import "core:testing"
import "core:thread"
import project_service "odin_test:hub/service/project"

@(private = "file")
Writer_Job :: struct {
	registry: ^project_service.Bridge_Runtime_Registry,
	ids:      []string,
	results:  []string,
	lo, hi:   int,
}

@(private = "file")
writer_entry :: proc(th: ^thread.Thread) {
	j := (^Writer_Job)(th.data)
	for i in j.lo ..< j.hi {
		_, _ = runtime_command_result_idempotent(j.registry, "brg_x", j.ids[i], j.results[i])
	}
}

@(private = "file")
reader_entry :: proc(th: ^thread.Thread) {
	j := (^Writer_Job)(th.data)
	// Hammer the cache read path concurrently with the writers to shake out any
	// unsynchronized read-vs-write on command_ids/command_count.
	for _ in 0 ..< 2000 {
		_, _ = runtime_command_cached(j.registry, j.ids[0])
	}
}

@(test)
runtime_command_cache_is_thread_safe :: proc(t: ^testing.T) {
	// DEFECT #1 guard: multiple threads writing command results (the runtime loop +
	// concurrent fs/file commands all funnel through runtime_command_result_idempotent)
	// plus a concurrent reader must not tear command_count or lose/duplicate entries.
	// With the registry command mutex every distinct id lands exactly once; without
	// it, racing count++ increments drop or corrupt entries.
	N :: 200 // < the 256-slot cache cap
	ids: [N]string
	results: [N]string
	for i in 0 ..< N {
		ids[i] = fmt.aprintf("cmd_%d", i)
		results[i] = fmt.aprintf("{\"command_id\":\"cmd_%d\",\"n\":%d}", i, i)
	}
	defer for i in 0 ..< N { delete(ids[i]); delete(results[i]) }

	registry := new(project_service.Bridge_Runtime_Registry)
	defer free(registry)

	WRITERS :: 4
	per := N / WRITERS
	jobs: [WRITERS]Writer_Job
	threads: [WRITERS]^thread.Thread
	reader_job := Writer_Job{registry = registry, ids = ids[:], results = results[:]}
	reader := thread.create(reader_entry)
	reader.data = rawptr(&reader_job)
	thread.start(reader)

	for w in 0 ..< WRITERS {
		jobs[w] = Writer_Job{registry = registry, ids = ids[:], results = results[:], lo = w * per, hi = (w + 1) * per}
		threads[w] = thread.create(writer_entry)
		threads[w].data = rawptr(&jobs[w])
		thread.start(threads[w])
	}
	for w in 0 ..< WRITERS {
		thread.join(threads[w])
		thread.destroy(threads[w])
	}
	thread.join(reader)
	thread.destroy(reader)

	// Every distinct id stored exactly once — no torn count, no lost/dup entries.
	testing.expect_value(t, registry.command_count, N)
	for i in 0 ..< N {
		cached, ok := runtime_command_cached(registry, ids[i])
		testing.expect(t, ok, "each written command id must be retrievable")
		testing.expect_value(t, cached, results[i])
	}
}
