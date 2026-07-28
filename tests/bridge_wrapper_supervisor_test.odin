package bridge_wrapper_supervisor_test

import "core:fmt"
import "core:os"
import "core:strings"
import bridge "odin_test:bridge"

main :: proc() {
	bridge.bridge_runtime_init()
	bridge.bridge_agent_token_store_init()
	issued := bridge.bridge_agent_token_issue("inst_wrapper_test", "hit_bridge_held", .Wrapper)
	config := bridge.bridge_local_endpoint_config_default("/tmp/heimdall-bridge-wrapper-supervisor-test", 49702)
	check(bridge.bridge_local_endpoint_start_loopback(config), "loopback local endpoint should start")
	args := []string{"ham-bridge", "wrapper-supervisor", "--bridge-endpoint", bridge.bridge_local_endpoint_env_value(config, false), "--agent-token", issued.plaintext_token, "--agent-instance-id", "inst_wrapper_test", "--cwd", "/tmp", "--agent-command", "true", "--liveness-interval-ms", "10", "--activity-interval-ms", "10"}
	_ = os.set_env("HEIMDALL_HUB_URL", "https://hub.example.invalid")
	_ = os.set_env("HEIMDALL_USER_TOKEN", "hut_should_not_leak")
	_ = os.set_env("HAM_BRIDGE_TOKEN", "hbt_should_not_leak")
	_ = os.set_env("HEIMDALL_BRIDGE_TOKEN", "hbt_should_not_leak")
	child_env := bridge.bridge_wrapper_child_env(bridge.bridge_wrapper_supervisor_config_from_args(args))
	check(env_has(child_env, "HEIMDALL_BRIDGE_ENDPOINT=") && env_has(child_env, "HEIMDALL_AGENT_TOKEN=") && env_has(child_env, "HEIMDALL_AGENT_INSTANCE_ID="), "sanitized child env must include local endpoint env")
	check(!env_has(child_env, "HEIMDALL_HUB_URL=") && !env_has(child_env, "HEIMDALL_USER_TOKEN=") && !env_has(child_env, "HAM_BRIDGE_TOKEN=") && !env_has(child_env, "HEIMDALL_BRIDGE_TOKEN="), "sanitized child env must not propagate Hub/Bridge credentials")
	check(bridge.bridge_wrapper_supervisor_main(args), "wrapper supervisor should run child and exit cleanly")
	inst, ok := bridge.bridge_runtime_instance_snapshot("inst_wrapper_test")
	check(ok && inst.runtime_status == "stopped", "wrapper.exited should mark runtime stopped through local endpoint")
	ctx := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"agent_forbidden\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.context.get\",\"params\":{}}"}))
	check(strings.contains(ctx, "\"ok\":false") && strings.contains(ctx, "forbidden"), "wrapper token must not call agent methods")
	fmt.println("PASS: bridge wrapper supervisor")
}

env_has :: proc(env: []string, prefix: string) -> bool {
	for item in env { if strings.has_prefix(item, prefix) do return true }
	return false
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
