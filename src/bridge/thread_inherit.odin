package main

import "core:thread"

// Bridge worker threads start through bridge_thread_*. In production they are
// thread.run*. In test builds the worker also inherits the spawning thread's
// per-test state (bridge_cfg() and the environment overrides), because each test
// is a thread of one process and keeps that state per thread.

Bridge_Thread_Inherit :: struct {
	cfg: ^Bridge_Config,
	env: ^map[string]Bridge_Env_Override,
	pty: ^Pty_Host_Daemon,
}

// The spawning thread's snapshot; a worker copies it when it starts. Only one
// pointer is passed so the thread arguments stay within thread.MAX_USER_ARGUMENTS.
@(thread_local, private = "file")
g_bridge_thread_inherit: Bridge_Thread_Inherit

bridge_thread_inherit_capture :: proc() -> ^Bridge_Thread_Inherit {
	g_bridge_thread_inherit = {cfg = bridge_cfg(), env = bridge_env_overrides(), pty = pty_host_daemon()}
	return &g_bridge_thread_inherit
}

bridge_thread_inherit_install :: proc(p: ^Bridge_Thread_Inherit) {
	inh := p^
	bridge_cfg_inherit(inh.cfg)
	bridge_env_overrides_inherit(inh.env)
	pty_host_daemon_inherit(inh.pty)
}

bridge_thread_run :: proc(fn: proc()) {
	when ODIN_TEST {
		thread.run_with_poly_data2(bridge_thread_inherit_capture(), fn, proc(inh: ^Bridge_Thread_Inherit, fn: proc()) {
			bridge_thread_inherit_install(inh)
			fn()
		})
	} else {
		thread.run(fn)
	}
}

bridge_thread_run_with_data :: proc(data: rawptr, fn: proc(data: rawptr)) {
	when ODIN_TEST {
		thread.run_with_poly_data3(bridge_thread_inherit_capture(), data, fn, proc(inh: ^Bridge_Thread_Inherit, data: rawptr, fn: proc(data: rawptr)) {
			bridge_thread_inherit_install(inh)
			fn(data)
		})
	} else {
		thread.run_with_data(data, fn)
	}
}

bridge_thread_run_with_poly_data :: proc(data: $T, fn: proc(data: T)) {
	when ODIN_TEST {
		thread.run_with_poly_data3(bridge_thread_inherit_capture(), data, fn, proc(inh: ^Bridge_Thread_Inherit, data: T, fn: proc(data: T)) {
			bridge_thread_inherit_install(inh)
			fn(data)
		})
	} else {
		thread.run_with_poly_data(data, fn)
	}
}

// bridge_thread_start_with_data / _with_poly_data are thread.create_and_start_with_*
// that pass on the per-test state the same way (tests spawn their own threads).
bridge_thread_start_with_data :: proc(data: rawptr, fn: proc(data: rawptr)) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data3(bridge_thread_inherit_capture(), data, fn, proc(inh: ^Bridge_Thread_Inherit, data: rawptr, fn: proc(data: rawptr)) {
		bridge_thread_inherit_install(inh)
		fn(data)
	})
}

bridge_thread_start_with_poly_data :: proc(data: $T, fn: proc(data: T)) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data3(bridge_thread_inherit_capture(), data, fn, proc(inh: ^Bridge_Thread_Inherit, data: T, fn: proc(data: T)) {
		bridge_thread_inherit_install(inh)
		fn(data)
	})
}
