package main

import "core:strings"
import "core:testing"

@(test)
bridge_wrapper_child_env_keeps_agent_runtime_vars :: proc(t: ^testing.T) {
	env := bridge_wrapper_child_env(Bridge_Wrapper_Supervisor_Config{bridge_endpoint = "unix:/tmp/bridge.sock", child_agent_token = "hlat_test", agent_instance_id = "inst_test"})
	defer bridge_test_env_free(env)
	testing.expect(t, bridge_test_env_contains(env, "HEIMDALL_BRIDGE_ENDPOINT=unix:/tmp/bridge.sock"))
	testing.expect(t, bridge_test_env_contains(env, "HEIMDALL_AGENT_TOKEN=hlat_test"))
	testing.expect(t, bridge_test_env_contains(env, "HEIMDALL_AGENT_INSTANCE_ID=inst_test"))
}

bridge_test_env_contains :: proc(env: []string, expected: string) -> bool {
	for item in env {
		if strings.trim_space(item) == expected do return true
	}
	return false
}

bridge_test_env_free :: proc(env: []string) {
	for item in env do delete(item)
	delete(env)
}
