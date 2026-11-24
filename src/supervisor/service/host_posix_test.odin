#+build linux, darwin
package service

// A stop that leaves a survivor (T13b safety review): its record must stay in procs.json,
// and no runtime may start beside it; the idle watcher escalates (fatal stop_timeout).

import "core:os"
import "core:sync"
import "core:testing"
import "../engine"
import "../procs"

@(test)
test_stop_survivor_is_kept_and_blocks_start :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&g_install_mutex) // writes and execs a file: see world_init
	defer sync.mutex_unlock(&g_install_mutex)
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "t13b-host-*", context.temp_allocator)
	defer os.remove_all(root)
	tree := "0.6.0-aaaaaaaaaaaa"
	bin := engine.join(root, "releases", tree, "bin")
	testing.expect(t, os.make_directory_all(bin) == nil)
	testing.expect(t, os.make_directory_all(engine.join(root, "supervisor")) == nil)
	script := engine.join(bin, "fake-runtime")
	testing.expect(t, os.write_entire_file(script, transmute([]byte)string("#!/bin/sh\nexec sleep 60\n")) == nil)
	testing.expect(t, os.chmod(script, {.Read_User, .Write_User, .Execute_User}) == nil)

	h: Host_Ctx
	h.specs = proc(h: ^Host_Ctx, tree: string) -> []Child_Spec {
		out := make([]Child_Spec, 1, context.temp_allocator)
		out[0] = Child_Spec{role = "runtime", exe = "fake-runtime"}
		return out
	}
	// The stop "fails": nothing is signalled, the process survives.
	h.stop_fn = proc(h: ^Host_Ctx, recorded: []procs.Target) -> bool {return false}
	host_init(&h, root, root, "ins_0123456789abcdef0123456789abcdef")
	defer host_destroy(&h)

	testing.expect(t, host_start(&h, tree), "first start")
	first := read_procs(root)
	testing.expect_value(t, len(first), 1)
	if len(first) != 1 do return
	survivor := first[0].id
	defer {
		_ = procs.stop([]procs.Target{{id = survivor, group = true}}, 100, 5_000)
	}

	testing.expect(t, !host_stop(&h), "stop reports the survivor")
	after := read_procs(root)
	testing.expectf(t, len(after) == 1 && after[0].id == survivor, "survivor kept in procs.json: %v", after)

	testing.expect(t, !host_start(&h, tree), "no start beside a recorded survivor")
	again := read_procs(root)
	testing.expectf(t, len(again) == 1 && again[0].id == survivor, "procs.json unchanged: %v", again)
	testing.expect_value(t, host_health(&h), engine.Health.Exited)
	testing.expect(t, procs.alive(survivor), "the survivor is still the only runtime")
}
