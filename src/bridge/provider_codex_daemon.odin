package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Bridge_Codex_Daemon_Support :: enum { Unknown, Supported, Unsupported }
Bridge_Codex_Daemon_Probe_Result :: struct {
	status: Bridge_Codex_Daemon_Support,
	exit_code: int,
	timed_out: bool,
}
Bridge_Codex_Daemon_Probe :: proc(path: string) -> Bridge_Codex_Daemon_Probe_Result
bridge_codex_daemon_probe_mu: sync.Mutex
bridge_codex_daemon_probe_cache: map[string]bool

// Probe the resolved executable, not the provider name: account profiles can
// select different Codex versions. Cache only completed capability checks;
// transient failures must retry on the next launch. The bounded probe is
// serialized so concurrent launches cannot duplicate it. A binary upgraded
// in place at the same path needs a bridge restart to clear a completed result.
bridge_codex_no_daemon_supported :: proc(path: string, probe: Bridge_Codex_Daemon_Probe = proc(path: string) -> Bridge_Codex_Daemon_Probe_Result { return bridge_codex_no_daemon_probe(path) }) -> bool {
	if path == "" do return false
	sync.mutex_lock(&bridge_codex_daemon_probe_mu)
	defer sync.mutex_unlock(&bridge_codex_daemon_probe_mu)
	if supported, found := bridge_codex_daemon_probe_cache[path]; found do return supported
	context.allocator = runtime.heap_allocator()
	result := probe(path)
	if result.status == .Unknown {
		fmt.printfln("bridge Codex: %s --help probe could not complete (exit_code=%d, timed_out=%t); keeping legacy launch for this attempt, will retry next launch", path, result.exit_code, result.timed_out)
		return false
	}
	if bridge_codex_daemon_probe_cache == nil do bridge_codex_daemon_probe_cache = make(map[string]bool)
	supported := result.status == .Supported
	bridge_codex_daemon_probe_cache[strings.clone(path)] = supported
	if !supported do fmt.printfln("bridge Codex: %s --help completed but does not advertise --no-daemon; keeping legacy launch; shared daemon threads may survive stop", path)
	return supported
}

bridge_codex_no_daemon_probe :: proc(path: string, run := bridge_process_run_capture_status) -> Bridge_Codex_Daemon_Probe_Result {
	stdout, stderr, exit_code, ok, timed_out := run({path, "--help"}, 2*time.Second)
	defer { delete(stdout); delete(stderr) }
	if !ok || timed_out || exit_code != 0 || strings.trim_space(stdout) == "" do return {.Unknown, exit_code, timed_out}
	words := strings.fields(stdout)
	defer delete(words)
	for word in words do if word == "--no-daemon" do return {.Supported, exit_code, false}
	return {.Unsupported, exit_code, false}
}
