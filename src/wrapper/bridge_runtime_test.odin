package main

import "core:strings"
import "core:testing"

@(test)
wrapper_bridge_child_env_injects_agent_runtime_vars :: proc(t: ^testing.T) {
	env := wrapper_bridge_child_env(Bridge_Runtime_Config{bridge_endpoint = "unix:/tmp/bridge.sock", child_agent_token = "hlat_test", agent_instance_id = "inst_test", working_dir = "/tmp/run"})
	defer wrapper_bridge_test_env_free(env)
	testing.expect(t, wrapper_bridge_test_env_contains(env, "HEIMDALL_BRIDGE_ENDPOINT=unix:/tmp/bridge.sock"))
	testing.expect(t, wrapper_bridge_test_env_contains(env, "HEIMDALL_AGENT_TOKEN=hlat_test"))
	testing.expect(t, wrapper_bridge_test_env_contains(env, "HEIMDALL_AGENT_INSTANCE_ID=inst_test"))
	testing.expect(t, wrapper_bridge_test_env_contains(env, "HEIMDALL_CTL_BIN=/tmp/run/.heimdall/bin/ham-ctl"))
}

wrapper_bridge_test_env_contains :: proc(env: []string, expected: string) -> bool {
	for item in env {
		if strings.trim_space(item) == expected do return true
	}
	return false
}

wrapper_bridge_test_env_free :: proc(env: []string) {
	for item in env do delete(item)
	delete(env)
}
