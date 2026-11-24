package procs

// Real-process tests (Linux, macOS, Windows): identity by (pid, start_time) and stopping
// only one instance's processes while another instance's keep running (T14 acceptance:
// "Another instance on the same machine is unaffected").

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
test_dir :: proc(t: ^testing.T, prefix: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, fmt.tprintf("%s-*", prefix), context.temp_allocator)
	testing.expect(t, err == nil, "make_directory_temp")
	return dir
}

@(test)
test_identify_self_and_mismatch :: proc(t: ^testing.T) {
	me, ok := self()
	testing.expect(t, ok, "identify self")
	testing.expect(t, me.start_time != 0, "start_time set")
	testing.expect(t, alive(me))
	testing.expect(t, !alive(Id{me.pid, me.start_time + 1}), "same pid, other start time = other process")
	_, none := identify(0)
	testing.expect(t, !none)
	again, _ := self()
	testing.expect_value(t, again, me)
}

// Instance A has two agent process trees (each with a helper), instance B one. Stopping A's
// recorded targets stops A's trees, helpers included, and leaves B's running.
@(test)
test_stop_only_this_instance :: proc(t: ^testing.T) {
	dir := test_dir(t, "t14-procs-two")
	defer os.remove_all(dir)
	a1 := spawn_agent(t, dir, "a1")
	a2 := spawn_agent(t, dir, "a2")
	b1 := spawn_agent(t, dir, "b1")
	defer cleanup_agent(&b1)
	defer cleanup_agent(&a2)
	defer cleanup_agent(&a1)
	if !a1.ok || !a2.ok || !b1.ok do return

	r := stop([]Target{a1.target, a2.target}, grace_ms = 3000, wait_ms = 10_000)
	testing.expect_value(t, r.signalled, 2)
	testing.expect_value(t, r.survivors, 0)
	testing.expect(t, !alive(a1.target.id) && !alive(a2.target.id), "instance A stopped")
	when ODIN_OS != .Windows {
		testing.expect(t, wait_gone(a1.helper) && wait_gone(a2.helper), "A's helpers (same process group) stopped")
	}
	testing.expect(t, alive(b1.target.id), "instance B's agent still runs")
	when ODIN_OS != .Windows {
		testing.expect(t, alive(b1.helper), "instance B's helper still runs")
	}
}

// A recorded pid whose start time does not match is another process (pid reuse): it is
// never signalled.
@(test)
test_stop_skips_reused_pid :: proc(t: ^testing.T) {
	dir := test_dir(t, "t14-procs-reuse")
	defer os.remove_all(dir)
	other := spawn_agent(t, dir, "other")
	defer cleanup_agent(&other)
	if !other.ok do return
	stale := other.target
	stale.id.start_time += 1
	r := stop([]Target{stale}, grace_ms = 200, wait_ms = 200)
	testing.expect_value(t, r.signalled, 0)
	testing.expect_value(t, r.survivors, 0)
	time.sleep(300 * time.Millisecond)
	testing.expect(t, alive(other.target.id), "the process now holding that pid is untouched")
}

// Nothing to stop: already gone.
@(test)
test_stop_nothing_running :: proc(t: ^testing.T) {
	r := stop([]Target{{id = Id{pid = 0x7ffffff0, start_time = 1}, group = true}}, grace_ms = 100, wait_ms = 100)
	testing.expect_value(t, r, Stop_Result{})
}
