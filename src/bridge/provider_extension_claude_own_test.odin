package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import agent_runtime "odin_test:lib/agent_runtime"
import bridgesvc "odin_test:lib/bridgesvc"

@(private = "file")
claude_own_write :: proc(path, body: string) {
	_ = os.make_directory_all(bridgesvc.pdir(path))
	_ = os.write_entire_file(path, transmute([]byte)body)
}

// task_18e70e44460dc1d5 (A/B): each Bridge profile loads its OWN Claude plugin;
// a missing or unloadable plugin keeps the start-success instruction.
@(test)
test_claude_own_plugin_per_profile_and_unloadable_keeps_start_success :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/.cache/heimdall-tests/claude-own-%d", bridge_env_get("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	defer _ = os.remove_all(root)
	a, b := bridgesvc.pjoin(root, "hub-a"), bridgesvc.pjoin(root, "hub-a_b")
	for dir in ([2]string{a, b}) {
		claude_own_write(bridgesvc.pjoin(dir, "extensions", "claude-code", ".claude-plugin", "plugin.json"), `{"name":"heimdall"}`)
		claude_own_write(bridgesvc.pjoin(dir, "extensions", "claude-code", "hooks", "hooks.json"), `{"hooks":{}}`)
	}
	args_a := bridge_claude_own_launch_args(a)
	args_b := bridge_claude_own_launch_args(b)
	testing.expectf(t, len(args_a) == 2 && args_a[0] == "--plugin-dir" && strings.has_prefix(args_a[1], a), "profile a loads its own plugin: %v", args_a)
	testing.expectf(t, len(args_b) == 2 && strings.has_prefix(args_b[1], b), "profile b loads its own plugin: %v", args_b)
	testing.expect(t, strings.has_prefix(bridge_claude_extension_health(a), "ok ("))
	// Unloadable: empty hooks file, then a missing plugin dir.
	claude_own_write(bridgesvc.pjoin(b, "extensions", "claude-code", "hooks", "hooks.json"), "")
	testing.expect(t, len(bridge_claude_own_launch_args(b)) == 0, "an empty hooks file is not loadable")
	testing.expect(t, strings.contains(bridge_claude_extension_health(b), "hooks/hooks.json missing or empty"))
	testing.expect(t, len(bridge_claude_own_launch_args(bridgesvc.pjoin(root, "absent"))) == 0, "a missing plugin dir is not loadable")
	// The prompt keeps start-success unless the extension is expected (verified).
	profile := agent_runtime.Agent_Profile{starter_prompt = "First, run: {ctl_bin} agent start-success. Then read TASK.md."}
	kept := agent_runtime.render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expectf(t, strings.contains(kept, "start-success"), "unverified plugin: the instruction stays: %q", kept)
	profile.extension_expected = true
	stripped := agent_runtime.render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expectf(t, !strings.contains(stripped, "agent start-success."), "verified plugin: stripped: %q", stripped)
}

// task_18e70e44460dc1d5 (A): two profiles on one machine with different
// versions; pruning old shared releases never removes one a provider
// registration still references (the shared Claude marketplace pointed at .4).
@(test)
test_extensions_prune_shared_keeps_referenced_releases :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/.cache/heimdall-tests/shared-prune-%d/%s", bridge_env_get("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()), BRIDGE_SHARED_EXTENSIONS_DIR)
	defer _ = os.remove_all(bridgesvc.pdir(root))
	for v in ([3]string{"0.5.50-subagents.4", "0.5.50-subagents.11", "0.5.50-subagents.12"}) {
		_ = os.make_directory_all(bridgesvc.pjoin(root, v, "extensions"))
	}
	refs := []string{fmt.tprintf(`{{"heimdall":{{"installLocation":"%s/0.5.50-subagents.4/extensions"}}}}`, root)}
	bridge_extensions_prune_shared(bridgesvc.pjoin(root, "0.5.50-subagents.12", "extensions"), refs)
	testing.expect(t, os.is_dir(bridgesvc.pjoin(root, "0.5.50-subagents.4", "extensions")), "the referenced older release is kept")
	testing.expect(t, !os.exists(bridgesvc.pjoin(root, "0.5.50-subagents.11")), "an unreferenced older release is pruned")
	testing.expect(t, os.is_dir(bridgesvc.pjoin(root, "0.5.50-subagents.12", "extensions")), "the kept release stays")
}
