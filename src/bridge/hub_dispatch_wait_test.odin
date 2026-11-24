package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Dispatch_Wait_Test :: struct {
	class: Bridge_Command_Class,
	done: bool,
}

dispatch_wait_test_worker :: proc(data: rawptr) {
	f := (^Dispatch_Wait_Test)(data)
	job, ok := bridge_command_dispatch_take(f.class, wait = true)
	assert(ok)
	worker: Bridge_Dispatch_Worker
	bridge_command_dispatch_finish(&worker, &job)
	sync.atomic_store(&f.done, true)
}

dispatch_wait_test_until :: proc(waiting: int) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 2*time.Second {
		sync.mutex_lock(&bridge_dispatch_mu)
		ready := bridge_dispatch_metrics.waiting_workers == waiting
		sync.mutex_unlock(&bridge_dispatch_mu)
		if ready do return true
		time.sleep(time.Millisecond)
	}
	return false
}

dispatch_wait_test_enqueue :: proc(class: Bridge_Command_Class, key := "") {
	sync.mutex_lock(&bridge_dispatch_mu)
	bridge_command_dispatch_enqueue_locked({class = class, ordering_key = strings.clone(key, runtime.default_allocator())})
	sync.mutex_unlock(&bridge_dispatch_mu)
}

@(test)
bridge_dispatch_waits_without_polling_and_wakes_on_enqueue_and_key_release :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.default_allocator()
	// No permanent handler threads: use the production take/enqueue/finish paths
	// with joinable one-job consumers, and restore all process-global state.
	if !testing.expect(t, !bridge_dispatch_initialized) do return
	queues := []^[dynamic]Bridge_Dispatch_Job{&bridge_dispatch_lifecycle, &bridge_dispatch_interactive, &bridge_dispatch_background, &bridge_dispatch_exclusive, &bridge_dispatch_general_io, &bridge_dispatch_shell, &bridge_dispatch_model_discovery}
	saved: [7][dynamic]Bridge_Dispatch_Job
	for q, i in queues { saved[i] = q^; q^ = nil }
	metrics, keys := bridge_dispatch_metrics, bridge_dispatch_active_keys
	bridge_dispatch_metrics, bridge_dispatch_active_keys = {}, nil
	defer {
		for q, i in queues { delete(q^); q^ = saved[i] }
		delete(bridge_dispatch_active_keys)
		bridge_dispatch_metrics, bridge_dispatch_active_keys = metrics, keys
	}

	// An enqueue before a waiter exists must be observed by the predicate.
	dispatch_wait_test_enqueue(.Exclusive)
	first := Dispatch_Wait_Test{class = .Exclusive}
	th := thread.create_and_start_with_data(&first, dispatch_wait_test_worker)
	thread.join(th); thread.destroy(th)
	testing.expect(t, sync.atomic_load(&first.done))

	fixtures: [len(BRIDGE_DISPATCH_WORKER_CLASSES)]Dispatch_Wait_Test
	threads: [len(fixtures)]^thread.Thread
	for class, i in BRIDGE_DISPATCH_WORKER_CLASSES {
		fixtures[i].class = class
		threads[i] = thread.create_and_start_with_data(&fixtures[i], dispatch_wait_test_worker)
	}
	testing.expect(t, dispatch_wait_test_until(len(fixtures)), "all 14 class workers must sleep")
	sync.mutex_lock(&bridge_dispatch_mu)
	before := bridge_dispatch_metrics.take_attempts
	sync.mutex_unlock(&bridge_dispatch_mu)
	time.sleep(250*time.Millisecond)
	sync.mutex_lock(&bridge_dispatch_mu)
	idle_attempts := bridge_dispatch_metrics.take_attempts - before
	sync.mutex_unlock(&bridge_dispatch_mu)
	fmt.printfln("dispatch idle: 14 workers, 250 ms, %d queue retries (polling baseline ceiling: 700)", idle_attempts)
	testing.expect(t, idle_attempts <= 1, "idle workers should not retry the queue")
	for class in BRIDGE_DISPATCH_WORKER_CLASSES do dispatch_wait_test_enqueue(class)
	// Bound a missed-signal failure; rescue permits joining and reporting it.
	start := time.tick_now()
	complete := false
	for time.tick_since(start) < 2*time.Second {
		complete = true
		for &f in fixtures do complete = complete && sync.atomic_load(&f.done)
		if complete do break
		time.sleep(time.Millisecond)
	}
	testing.expect(t, complete, "enqueue signals must wake all eligible workers")
	sync.mutex_lock(&bridge_dispatch_mu)
	for &ready in bridge_dispatch_ready do sync.cond_broadcast(&ready)
	sync.mutex_unlock(&bridge_dispatch_mu)
	for th in threads { thread.join(th); thread.destroy(th) }

	// A lifecycle key also blocks Interactive work. Enqueue notification alone
	// cannot make this job runnable: only finish's cross-class broadcast can.
	dispatch_wait_test_enqueue(.Lifecycle, "agent:shared")
	owner, ok := bridge_command_dispatch_take(.Lifecycle)
	testing.expect(t, ok)
	dispatch_wait_test_enqueue(.Interactive, "agent:shared")
	blocked := Dispatch_Wait_Test{class = .Interactive}
	th = thread.create_and_start_with_data(&blocked, dispatch_wait_test_worker)
	testing.expect(t, dispatch_wait_test_until(1))
	testing.expect(t, !sync.atomic_load(&blocked.done), "ordering key holds the follower")
	worker: Bridge_Dispatch_Worker
	bridge_command_dispatch_finish(&worker, &owner)
	start = time.tick_now()
	for !sync.atomic_load(&blocked.done) && time.tick_since(start) < 2*time.Second do time.sleep(time.Millisecond)
	testing.expect(t, sync.atomic_load(&blocked.done), "key release must wake another class without an enqueue")
	sync.mutex_lock(&bridge_dispatch_mu)
	sync.cond_broadcast(&bridge_dispatch_ready[.Interactive])
	sync.mutex_unlock(&bridge_dispatch_mu)
	thread.join(th); thread.destroy(th)
}
