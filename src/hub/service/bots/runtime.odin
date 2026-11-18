package bots

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "core:time"
import iface "odin_test:hub/repository/iface"

Bots_Runtime :: struct {
	service: ^Bots_Service,
	telegram_bot_token: string, // borrowed process configuration; never logged
	lifecycle_mutex: sync.Mutex,
	wait_mutex: sync.Mutex,
	wait_cond: sync.Cond,
	poller, supervisor: ^thread.Thread,
	poller_running, supervisor_running: bool,
	poller_stop, supervisor_stop: bool,
	// A2a installs its delivery tick from wiring; A4 owns only the loop.
	supervisor_tick: proc(s: ^Bots_Service),
}

bots_runtime_reconcile :: proc(rt: ^Bots_Runtime) {
	if rt == nil || rt.service == nil do return
	sync.mutex_lock(&rt.lifecycle_mutex)
	defer sync.mutex_unlock(&rt.lifecycle_mutex)
	n, err := iface.experiment_count_enabled(rt.service.experiments, "bots")
	if err.code != .None {
		fmt.eprintln("bots: could not count enabled experiments")
		n = 0 // fail closed, including during an existing runtime
	}
	if n == 0 {
		was_running := rt.poller != nil || rt.supervisor != nil
		bots_runtime_stop_locked(rt, true)
		bots_runtime_stop_locked(rt, false)
		if was_running do fmt.println("bots: runtime stopped")
		return
	}
	// Request callbacks can run with an arena allocator. Thread records and all
	// inherited persistent allocation must instead outlive that request.
	context.allocator = runtime.heap_allocator()
	worker_context := context
	worker_context.allocator = runtime.heap_allocator()
	worker_context.temp_allocator = runtime.heap_allocator()
	if rt.supervisor == nil {
		sync.atomic_store(&rt.supervisor_stop, false)
		// thread-spawn: experiment gated; joined and destroyed on stop
		rt.supervisor = thread.create_and_start_with_data(rt, bots_supervisor_entry, init_context = worker_context)
		rt.supervisor_running = rt.supervisor != nil
	}
	if rt.telegram_bot_token != "" && rt.service.adapter != nil {
		if rt.poller == nil {
			sync.atomic_store(&rt.poller_stop, false)
			// thread-spawn: experiment and token gated; joined on stop
			rt.poller = thread.create_and_start_with_data(rt, bots_poller_entry, init_context = worker_context)
			rt.poller_running = rt.poller != nil
		}
	} else {
		bots_runtime_stop_locked(rt, true)
	}
}

bots_runtime_stop_locked :: proc(rt: ^Bots_Runtime, poller: bool) {
	worker := rt.poller if poller else rt.supervisor
	if worker == nil do return
	sync.mutex_lock(&rt.wait_mutex)
	if poller { sync.atomic_store(&rt.poller_stop, true) } else { sync.atomic_store(&rt.supervisor_stop, true) }
	sync.cond_broadcast(&rt.wait_cond)
	sync.mutex_unlock(&rt.wait_mutex)
	thread.join(worker)
	thread.destroy(worker)
	if poller { rt.poller = nil; rt.poller_running = false } else { rt.supervisor = nil; rt.supervisor_running = false }
}

bots_runtime_stop :: proc(rt: ^Bots_Runtime) {
	if rt == nil do return
	sync.mutex_lock(&rt.lifecycle_mutex)
	defer sync.mutex_unlock(&rt.lifecycle_mutex)
	bots_runtime_stop_locked(rt, true)
	bots_runtime_stop_locked(rt, false)
}

// True means stopping. Spurious wake-ups preserve the remaining wait budget.
bots_runtime_wait :: proc(rt: ^Bots_Runtime, stop: ^bool, delay: time.Duration) -> bool {
	started := time.tick_now()
	sync.mutex_lock(&rt.wait_mutex)
	defer sync.mutex_unlock(&rt.wait_mutex)
	for !sync.atomic_load(stop) {
		left := delay - time.tick_since(started)
		if left <= 0 do break
		_ = sync.cond_wait_with_timeout(&rt.wait_cond, &rt.wait_mutex, left)
	}
	return sync.atomic_load(stop)
}

bots_poller_entry :: proc(data: rawptr) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	bots_poller_thread((^Bots_Runtime)(data))
}

bots_supervisor_entry :: proc(data: rawptr) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	bots_supervisor_thread((^Bots_Runtime)(data))
}

bots_supervisor_thread :: proc(rt: ^Bots_Runtime) {
	interval := max(rt.service.timers.bot_supervisor_tick_ms, 1) * i64(time.Millisecond)
	for !sync.atomic_load(&rt.supervisor_stop) {
		if rt.supervisor_tick != nil do rt.supervisor_tick(rt.service)
		free_all(context.temp_allocator)
		if bots_runtime_wait(rt, &rt.supervisor_stop, time.Duration(interval)) do return
	}
}

bots_on_experiment_changed :: proc(ctx: rawptr, owner_user_id, key: string, enabled: bool) {
	if key != "bots" || ctx == nil do return
	rt := (^Bots_Runtime)(ctx)
	bots_runtime_reconcile(rt)
	if !enabled && rt.service != nil do bots_on_experiment_disabled(rt.service, owner_user_id)
}
