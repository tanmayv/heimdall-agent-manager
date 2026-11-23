package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Bridge_Codex_Daemon_Probe :: proc(path: string) -> bool
bridge_codex_daemon_probe_mu: sync.Mutex
bridge_codex_daemon_probe_cache: map[string]bool

// Probe the resolved executable, not the provider name: account profiles can
// select different Codex versions. Cache failures too, and warn once per path.
// The bounded probe is serialized so concurrent launches cannot duplicate it.
bridge_codex_no_daemon_supported :: proc(path: string, probe: Bridge_Codex_Daemon_Probe = proc(path: string) -> bool { return bridge_codex_no_daemon_probe(path) }) -> bool {
	if path == "" do return false
	sync.mutex_lock(&bridge_codex_daemon_probe_mu)
	defer sync.mutex_unlock(&bridge_codex_daemon_probe_mu)
	if supported, found := bridge_codex_daemon_probe_cache[path]; found do return supported
	context.allocator = runtime.heap_allocator()
	if bridge_codex_daemon_probe_cache == nil do bridge_codex_daemon_probe_cache = make(map[string]bool)
	supported := probe(path)
	bridge_codex_daemon_probe_cache[strings.clone(path)] = supported
	if !supported do fmt.printfln("bridge Codex: %s does not advertise --no-daemon (or help probe failed); keeping legacy launch; shared daemon threads may survive stop", path)
	return supported
}

bridge_codex_no_daemon_probe :: proc(path: string, run := bridge_process_run_capture_status) -> bool {
	stdout, stderr, _, ok, _ := run({path, "--help"}, 2*time.Second)
	defer { delete(stdout); delete(stderr) }
	if !ok do return false
	words := strings.fields(stdout)
	defer delete(words)
	for word in words do if word == "--no-daemon" do return true
	return false
}
