package taskchain

// MEM-4 use-after-free regression guard.
//
// http.handle_client installs a per-request virtual.Arena as context.allocator and
// frees it after the response. Any long-lived state that clones with the IMPLICIT
// allocator on the request path therefore retains ARENA memory that dangles the
// instant the request returns; the next map probe/resize reads freed pages and the
// hub SIGSEGVs (the "intermittent 502 that clears on refresh"). These throttle maps
// (nudge debounce, idle-nudge backoff, orphan-replay) are reached from the request
// path (manual_nudge, the task-status-change cascade, bridge reconnect), so their
// retained keys MUST live on the persistent heap. Each test installs a real arena,
// calls the helper, then asserts the retained key does not point into the arena.

import "base:runtime"
import "core:mem/virtual"
import "core:testing"

@(private = "file")
ptr_in_arena :: proc(arena: ^virtual.Arena, p: rawptr) -> bool {
	addr := uintptr(p)
	for block := arena.curr_block; block != nil; block = block.prev {
		base := uintptr(rawptr(block.base))
		if addr >= base && addr < base + uintptr(block.committed) do return true
	}
	return false
}

@(private = "file")
first_key :: proc(m: map[string]i64) -> string {
	for k in m do return k
	return ""
}

@(test)
test_nudge_debounce_key_not_in_request_arena :: proc(t: ^testing.T) {
	svc: Taskchain_Service
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena, 64 * 1024) == nil)
	defer virtual.arena_destroy(&arena)

	prev := context.allocator
	context.allocator = virtual.arena_allocator(&arena)
	_ = should_debounce_nudge_dispatch(&svc, "inst_x", "task_y")
	context.allocator = prev

	key := first_key(svc.nudge_debounce_last_unix_ms)
	testing.expect(t, key != "", "expected a stored debounce key")
	testing.expect(t, !ptr_in_arena(&arena, rawptr(raw_data(key))),
		"nudge_debounce key retained per-request arena memory (use-after-free)")

	delete_key(&svc.nudge_debounce_last_unix_ms, key)
	delete(key, runtime.heap_allocator())
	delete(svc.nudge_debounce_last_unix_ms)
}

@(test)
test_idle_nudge_key_not_in_request_arena :: proc(t: ^testing.T) {
	svc: Taskchain_Service
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena, 64 * 1024) == nil)
	defer virtual.arena_destroy(&arena)

	prev := context.allocator
	context.allocator = virtual.arena_allocator(&arena)
	_ = idle_nudge_due(&svc, "inst_x", "task_y")
	context.allocator = prev

	key := first_key(svc.idle_nudge_last_unix_ms)
	testing.expect(t, key != "", "expected a stored idle-nudge key")
	testing.expect(t, !ptr_in_arena(&arena, rawptr(raw_data(key))),
		"idle_nudge key retained per-request arena memory (use-after-free)")

	// idle_nudge_reset frees the shared heap key and removes both map entries.
	idle_nudge_reset(&svc, "inst_x", "task_y")
	delete(svc.idle_nudge_last_unix_ms)
	delete(svc.idle_nudge_interval_ms)
}

@(test)
test_replay_bridge_key_not_in_request_arena :: proc(t: ^testing.T) {
	svc: Taskchain_Service
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena, 64 * 1024) == nil)
	defer virtual.arena_destroy(&arena)

	prev := context.allocator
	context.allocator = virtual.arena_allocator(&arena)
	_ = replay_should_run(&svc, "brg_1", 1000)
	context.allocator = prev

	key := first_key(svc.replay_last_unix_ms)
	testing.expect(t, key != "", "expected a stored replay bridge key")
	testing.expect(t, !ptr_in_arena(&arena, rawptr(raw_data(key))),
		"replay bridge_id key retained per-request arena memory (use-after-free)")

	delete_key(&svc.replay_last_unix_ms, key)
	delete(key, runtime.heap_allocator())
	delete(svc.replay_last_unix_ms)
}
