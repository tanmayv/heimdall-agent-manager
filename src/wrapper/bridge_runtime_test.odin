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

// H7 restart-reap: the wrapper classifies a bridge liveness response and
// self-terminates ONLY on an explicit auth failure (its local token was
// invalidated because the instance was relaunched here or on another bridge).
// A success, an unrelated error, or a blank/transport-failed response must NOT
// trigger termination, so a transient bridge hiccup never kills a healthy agent.
@(test)
wrapper_bridge_response_auth_failure_classifier :: proc(t: ^testing.T) {
	// Auth failures -> terminate. These mirror bridge_local_response_error output
	// for an invalidated/rotated token ("unauthenticated") and a role/spoof block
	// ("forbidden").
	testing.expect(t, wrapper_bridge_response_is_auth_failure(`{"v":1,"id":"x","ok":false,"error":{"code":"unauthenticated","message":"local agent token is invalid or rotated"}}`), "unauthenticated -> auth failure")
	testing.expect(t, wrapper_bridge_response_is_auth_failure(`{"ok":false,"error":{"code":"forbidden","message":"method is not allowed for this local token role"}}`), "forbidden -> auth failure")

	// NOT auth failures -> keep running.
	testing.expect(t, !wrapper_bridge_response_is_auth_failure(`{"v":1,"id":"x","ok":true,"data":{"accepted":true}}`), "ok response is not an auth failure")
	testing.expect(t, !wrapper_bridge_response_is_auth_failure(`{"ok":false,"error":{"code":"not_found","message":"pane capture request is no longer pending"}}`), "unrelated error is not an auth failure")
	testing.expect(t, !wrapper_bridge_response_is_auth_failure(""), "blank/transport-failed response is not an auth failure")
}
