package main

import "core:strings"
import "core:testing"

// Contract tests for the generated Pi extension (task_18c7088792ad330c). The extension
// text is produced by wrapper_bridge_build_pi_activity_extension and injected into pi
// via --extension. These lock in the activity + blocking permission-gate contract so
// regressions in the embedded TypeScript are caught at build time.

@(test)
wrapper_pi_detection :: proc(t: ^testing.T) {
	testing.expect(t, wrapper_bridge_should_load_pi_activity(Bridge_Runtime_Config{provider = "pi"}))
	testing.expect(t, wrapper_bridge_should_load_pi_activity(Bridge_Runtime_Config{agent_argv = []string{"pi"}}))
	testing.expect(t, wrapper_bridge_should_load_pi_activity(Bridge_Runtime_Config{agent_argv = []string{"/nix/store/x/bin/pi"}}))
	testing.expect(t, !wrapper_bridge_should_load_pi_activity(Bridge_Runtime_Config{provider = "antigravity"}))
	testing.expect(t, !wrapper_bridge_should_load_pi_activity(Bridge_Runtime_Config{agent_argv = []string{"agy"}}))
}

@(test)
wrapper_pi_argv_injects_extension_once :: proc(t: ^testing.T) {
	argv := []string{"pi", "--provider", "anthropic"}
	out := wrapper_bridge_agent_argv_with_pi_activity(argv)
	// --extension <path> inserted right after the binary.
	testing.expect(t, out[0] == "pi")
	testing.expect(t, out[1] == "--extension")
	testing.expect(t, out[2] == PI_ACTIVITY_EXTENSION_REL_PATH)
	// Idempotent: re-running does not double-inject.
	again := wrapper_bridge_agent_argv_with_pi_activity(out)
	count := 0
	for a in again { if a == PI_ACTIVITY_EXTENSION_REL_PATH do count += 1 }
	testing.expect(t, count == 1)
}

@(test)
wrapper_pi_extension_activity_contract :: proc(t: ^testing.T) {
	s := wrapper_bridge_build_pi_activity_extension()
	// Posts activity to the bridge and reacts to the key lifecycle events.
	testing.expect(t, strings.contains(s, "agent.activity.report"))
	events := [?]string{"session_start", "agent_start", "turn_start", "tool_call", "agent_end", "session_shutdown"}
	for ev in events {
		testing.expect(t, strings.contains(s, ev))
	}
	// Idle is keyed off isIdle/settling, not agent_end alone.
	testing.expect(t, strings.contains(s, "isIdle"))
}

@(test)
wrapper_pi_extension_permission_gate_contract :: proc(t: ^testing.T) {
	s := wrapper_bridge_build_pi_activity_extension()
	// Blocking request/response helper + the Task 1 bridge method.
	testing.expect(t, strings.contains(s, "function bridgeRequest("))
	testing.expect(t, strings.contains(s, "agent.permission.request"))
	// Opt-in gate; deny maps to Pi's { block: true }; risk classifier present.
	testing.expect(t, strings.contains(s, "HEIMDALL_PERMISSION_GATE"))
	testing.expect(t, strings.contains(s, "block: true"))
	testing.expect(t, strings.contains(s, "function toolRisk("))
	// Reads bridge endpoint/token from env (no hardcoded secrets).
	testing.expect(t, strings.contains(s, "HEIMDALL_BRIDGE_ENDPOINT"))
	testing.expect(t, strings.contains(s, "HEIMDALL_AGENT_TOKEN"))
}
