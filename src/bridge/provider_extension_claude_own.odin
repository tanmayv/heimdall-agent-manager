package main

// Claude Code loads THIS Bridge's own Heimdall plugin per launch
// (`--plugin-dir <data dir>/extensions/claude-code`), so a launch never
// depends on the user-scope 'heimdall' marketplace that every Bridge profile of
// the OS user shares (~/.claude/plugins/known_marketplaces.json). That shared
// registration could point at a release another profile's setup pruned, and the
// SessionStart hook then never reported (REQ-E2E-1 on Mundus .12,
// task_18e70e44460dc1d5). The start-success instruction is stripped from the
// prompt only when this plugin verifies (bridge_claude_own_plugin_ok).

import "core:fmt"
import "core:os"
import "core:strings"
import bridgesvc "odin_test:lib/bridgesvc"

// <data dir>/extensions/claude-code, or "" without a data dir.
bridge_claude_own_plugin_dir :: proc(data_dir: string = "") -> string {
	dir := strings.trim_space(data_dir)
	if dir == "" do dir = strings.trim_space(bridge_cfg().data_dir)
	if dir == "" do return ""
	return bridgesvc.pjoin(dir, "extensions", "claude-code")
}

// The plugin is loadable: its manifest and its hooks file are present and
// non-empty. (Claude validates the content; a missing or empty file is the
// failure seen in the field.)
bridge_claude_own_plugin_ok :: proc(plugin_dir: string) -> (ok: bool, reason: string) {
	if plugin_dir == "" do return false, "no Bridge data dir"
	if !os.is_dir(plugin_dir) do return false, "plugin dir missing"
	for rel in ([2]string{".claude-plugin/plugin.json", "hooks/hooks.json"}) {
		path := bridgesvc.pjoin(plugin_dir, rel)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil || len(strings.trim_space(string(data))) == 0 do return false, strings.concatenate({rel, " missing or empty"}, context.temp_allocator)
	}
	return true, ""
}

// Launch args that load this Bridge's Claude plugin (none when it does not verify).
bridge_claude_own_launch_args :: proc(data_dir: string = "", allocator := context.temp_allocator) -> []string {
	dir := bridge_claude_own_plugin_dir(data_dir)
	if ok, _ := bridge_claude_own_plugin_ok(dir); !ok do return nil
	out := make([]string, 2, allocator)
	out[0] = strings.clone("--plugin-dir", allocator)
	out[1] = strings.clone(dir, allocator)
	return out
}

// "ok (<dir>)" or "not loadable: <why> (<dir>)", for `ham-bridge status`.
bridge_claude_extension_health :: proc(data_dir: string) -> string {
	dir := bridge_claude_own_plugin_dir(data_dir)
	ok, why := bridge_claude_own_plugin_ok(dir)
	if ok do return strings.concatenate({"ok (", dir, ")"}, context.temp_allocator)
	return strings.concatenate({"not loadable: ", why, " (", dir, ")"}, context.temp_allocator)
}

// THE extension decision of a launch, for every spawn path (the spawn argv in
// pty_host_runtime.odin and the runtime startup state of local native and
// executor-activation launches use the same answer): expected (the
// start-success sentence is stripped and the extension's SessionStart hook is
// relied on), Claude's own plugin args, and why a Claude plugin is not used.
bridge_launch_extension_decision :: proc(provider:string,profile:Bridge_Provider_Profile,profile_id:string) -> (expected:bool,own_args:[]string,why:string) {
	if bridge_extension_canonical_provider(provider) == "claude" {
		own_args = bridge_claude_own_launch_args()
		_, why = bridge_claude_own_plugin_ok(bridge_claude_own_plugin_dir())
		return len(own_args) > 0, own_args, why
	}
	return bridge_provider_launch_extension_expected(profile, profile_id), nil, ""
}

// One diagnostic line per real launch (path: local_native | activation).
@(thread_local)
bridge_startup_log_hook: proc(line: string)
bridge_startup_log_launch :: proc(instance,provider,path:string,expected:bool,why:string) {
	line := fmt.tprintf("bridge startup: %s path=%s provider=%s extension_expected=%v%s start_success_in_prompt=%v", instance, path, provider, expected, "" if why == "" else fmt.tprintf(" own_plugin_unavailable=%q", why), !expected)
	if bridge_startup_log_hook != nil { bridge_startup_log_hook(line); return }
	fmt.eprintln(line)
}
