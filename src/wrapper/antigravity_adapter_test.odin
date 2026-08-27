package main

import "core:strings"
import "core:testing"

@(test)
wrapper_antigravity_detection :: proc(t: ^testing.T) {
	testing.expect(t, wrapper_bridge_should_load_antigravity(Bridge_Runtime_Config{provider = "antigravity"}))
	testing.expect(t, wrapper_bridge_should_load_antigravity(Bridge_Runtime_Config{provider = "agy"}))
	testing.expect(t, wrapper_bridge_should_load_antigravity(Bridge_Runtime_Config{agent_argv = []string{"agy", "-i"}}))
	testing.expect(t, wrapper_bridge_should_load_antigravity(Bridge_Runtime_Config{agent_argv = []string{"/nix/store/x/bin/agy"}}))
	testing.expect(t, !wrapper_bridge_should_load_antigravity(Bridge_Runtime_Config{provider = "pi"}))
	testing.expect(t, !wrapper_bridge_should_load_antigravity(Bridge_Runtime_Config{agent_argv = []string{"pi"}}))
}

@(test)
wrapper_antigravity_hooks_json_shape :: proc(t: ^testing.T) {
	j := wrapper_bridge_build_antigravity_hooks_json("/run/.heimdall/antigravity/heimdall_hook.py")
	// All activity + permission events wired.
	events := [?]string{"BeforeTool", "AfterTool", "BeforeModel", "AfterModel", "AfterAgent", "Stop", "Notification"}
	for ev in events {
		testing.expect(t, strings.contains(j, ev))
	}
	// Each entry sets HEIMDALL_HOOK_EVENT and calls the script via python3.
	testing.expect(t, strings.contains(j, "HEIMDALL_HOOK_EVENT=before_tool"))
	testing.expect(t, strings.contains(j, "python3 /run/.heimdall/antigravity/heimdall_hook.py"))
	testing.expect(t, strings.contains(j, "\"matcher\":\"*\""))
	// Valid-ish JSON envelope.
	testing.expect(t, strings.has_prefix(j, "{\"hooks\":{"))
	testing.expect(t, strings.has_suffix(j, "}}"))
}

@(test)
wrapper_antigravity_hook_script_contract :: proc(t: ^testing.T) {
	s := wrapper_bridge_build_antigravity_hook_script()
	// Blocking permission relay via the bridge contract from Task 1.
	testing.expect(t, strings.contains(s, "agent.permission.request"))
	testing.expect(t, strings.contains(s, "agent.activity.report"))
	// Decision mapping: allow -> allowTool true; deny -> allowTool false + denyReason.
	testing.expect(t, strings.contains(s, "\"allowTool\": True"))
	testing.expect(t, strings.contains(s, "\"allowTool\": False, \"denyReason\": reason"))
	// Risk policy + waiting_user activity while gating.
	testing.expect(t, strings.contains(s, "def _risk"))
	testing.expect(t, strings.contains(s, "waiting_user"))
	// Reads bridge endpoint/token from env (no hardcoded secrets).
	testing.expect(t, strings.contains(s, "HEIMDALL_BRIDGE_ENDPOINT"))
	testing.expect(t, strings.contains(s, "HEIMDALL_AGENT_TOKEN"))
}
