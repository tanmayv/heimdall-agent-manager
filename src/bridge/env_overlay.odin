package main

import "base:runtime"
import "core:os"
import "core:strings"
import cfg_lib "odin_test:lib/config"

// Every environment read in this package goes through bridge_env_*. Odin runs each
// test as a thread of ONE process, so a test that called os.set_env would leak into
// every concurrent test. Tests set per-thread overrides instead
// (bridge_test_env_set / bridge_test_env_unset, cleared by bridge_test_env_reset);
// production never sets one and reads the process environment unchanged.
//
// An override is seen only by the thread that set it: code a test drives on a
// worker thread reads the real environment.

Bridge_Env_Override :: struct {
	value: string,
	unset: bool,
}

@(thread_local, private = "file")
g_bridge_env_overrides_own: map[string]Bridge_Env_Override
@(thread_local, private = "file")
g_bridge_env_overrides_inherited: ^map[string]Bridge_Env_Override

bridge_env_overrides :: proc "contextless" () -> ^map[string]Bridge_Env_Override {
	if g_bridge_env_overrides_inherited != nil do return g_bridge_env_overrides_inherited
	return &g_bridge_env_overrides_own
}

// bridge_env_overrides_inherit makes a test worker thread read its spawning
// test's overrides (bridge_thread_*).
bridge_env_overrides_inherit :: proc(m: ^map[string]Bridge_Env_Override) {
	g_bridge_env_overrides_inherited = m
}

bridge_env_lookup :: proc(key: string, allocator: runtime.Allocator) -> (value: string, found: bool) {
	if o, ok := bridge_env_overrides()[key]; ok {
		if o.unset do return "", false
		return strings.clone(o.value, allocator), true
	}
	return os.lookup_env(key, allocator)
}

bridge_env_get :: proc(key: string, allocator: runtime.Allocator) -> string {
	v, _ := bridge_env_lookup(key, allocator)
	return v
}

bridge_env_get_alloc :: bridge_env_get

// bridge_env_unset removes key from the process environment, or, when the calling
// thread overrides key (tests), only from that override.
bridge_env_unset :: proc(key: string) {
	if _, ok := bridge_env_overrides()[key]; ok {
		bridge_test_env_unset(key)
		return
	}
	_ = os.unset_env(key)
}

// bridge_test_env_set overrides key for the calling thread (tests only).
bridge_test_env_set :: proc(key, value: string) {
	cfg_lib.env_lookup_override = bridge_env_lookup
	bridge_test_env_drop(key)
	bridge_env_overrides()[strings.clone(key, runtime.default_allocator())] = {value = strings.clone(value, runtime.default_allocator())}
}

// bridge_test_env_unset makes key read as unset for the calling thread (tests only).
bridge_test_env_unset :: proc(key: string) {
	cfg_lib.env_lookup_override = bridge_env_lookup
	bridge_test_env_drop(key)
	bridge_env_overrides()[strings.clone(key, runtime.default_allocator())] = {unset = true}
}

// bridge_test_env_reset drops every override of the calling thread. Tests defer it:
// the test runner reuses threads.
bridge_test_env_reset :: proc() {
	m := bridge_env_overrides()
	for k, o in m {
		delete(k, runtime.default_allocator())
		delete(o.value, runtime.default_allocator())
	}
	delete(m^)
	m^ = nil
	cfg_lib.env_lookup_override = nil
}

@(private = "file")
bridge_test_env_drop :: proc(key: string) {
	m := bridge_env_overrides()
	if m^ == nil do m^ = make(map[string]Bridge_Env_Override, runtime.default_allocator())
	if _, ok := bridge_env_overrides()[key]; ok {
		k, o := delete_key(bridge_env_overrides(), key)
		delete(k, runtime.default_allocator())
		delete(o.value, runtime.default_allocator())
	}
}
