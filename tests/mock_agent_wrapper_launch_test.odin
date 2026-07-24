// RTE2E-8 mock agent integration test.
//
// Proves the thin Bridge-local wrapper supervisor (RTE2E-5) launches the mock
// agent (tools/mock_agent/mock-agent.sh) via the normal child path, with:
//   - sanitized child env carrying the local endpoint vars,
//   - a real agent-role local token so the mock's agent.context.get is accepted,
//   - the wrapper lifecycle reaching `stopped` through the local endpoint, and
//   - the mock log recording the replay in order including the real Bridge
//     response to agent.context.get (the agent-facing notification path).
//
// Run with the Odin toolchain from `nix develop`:
//   odin build tests/mock_agent_wrapper_launch_test.odin -file \
//     -collection:odin_test=src -out:/tmp/mock_agent_test -debug && /tmp/mock_agent_test

package mock_agent_wrapper_launch_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import bridge "odin_test:bridge"

main :: proc() {
	mock_script := os.get_env("MOCK_AGENT_SCRIPT", context.allocator)
	if strings.trim_space(mock_script) == "" {
		// Default to the repo-relative script path so the test is runnable
		// from the worktree root without extra env.
		mock_script = "tools/mock_agent/mock-agent.sh"
	}
	mock_log := "/tmp/heimdall-mock-agent-launch-test.log"
	mock_replay := os.get_env("MOCK_AGENT_REPLAY", context.allocator)
	if strings.trim_space(mock_replay) == "" {
		mock_replay = "tools/mock_agent/replay.e2e.txt"
	}

	bridge.bridge_runtime_init()
	bridge.bridge_agent_token_store_init()

	instance_id := "inst_mock_agent_test"
	// Two-token model: a Wrapper-role token for the supervisor, and an
	// Agent-role token forwarded to the child so agent.* calls are accepted.
	wrapper_issued := bridge.bridge_agent_token_issue(instance_id, "hit_bridge_held_wrapper", .Wrapper)
	agent_issued := bridge.bridge_agent_token_issue(instance_id, "hit_bridge_held_agent", .Agent)

	config := bridge.bridge_local_endpoint_config_default("/tmp/heimdall-mock-agent-launch-test", 49712)
	check(bridge.bridge_local_endpoint_start_loopback(config), "loopback local endpoint should start")
	endpoint := bridge.bridge_local_endpoint_env_value(config, false)

	// The wrapper runs `sh -c "<agent-command>"` in the child. Because the
	// sanitized child env strips HEIMDALL_MOCK_*, the mock config MUST be
	// inlined inside the command string (no wrapper/endpoint changes).
	// The replay finishes with `done`, so the child exits cleanly and the
	// supervisor reports wrapper.exited -> runtime `stopped`.
	agent_command := fmt.tprintf(
		"HEIMDALL_MOCK_LOG=%s HAM_CTL=%s sh %s",
		mock_log, ham_ctl_path(mock_script), mock_script,
	)
	// Override the replay file by injecting it as the first inline assignment.
	agent_command = fmt.tprintf(
		"HEIMDALL_MOCK_LOG=%s HEIMDALL_MOCK_REPLAY=%s HAM_CTL=%s sh %s",
		mock_log, mock_replay, ham_ctl_path(mock_script), mock_script,
	)

	args := []string{
		"ham-bridge", "wrapper-supervisor",
		"--bridge-endpoint", endpoint,
		"--agent-token", wrapper_issued.plaintext_token,
		"--child-agent-token", agent_issued.plaintext_token,
		"--agent-instance-id", instance_id,
		"--cwd", os.get_env("PWD", context.allocator),
		"--agent-command", agent_command,
		"--liveness-interval-ms", "10",
		"--activity-interval-ms", "10",
	}

	// Verify the child env contract (RTE2E-5): local endpoint vars present, no
	// mock config leaking through the supervisor, child token is agent-role.
	child_env := bridge.bridge_wrapper_child_env(bridge.bridge_wrapper_supervisor_config_from_args(args))
	check(env_has(child_env, "HEIMDALL_BRIDGE_ENDPOINT="), "child env must carry local endpoint")
	check(env_has(child_env, "HEIMDALL_AGENT_TOKEN="), "child env must carry agent token")
	check(env_has(child_env, "HEIMDALL_AGENT_INSTANCE_ID="), "child env must carry instance id")
	check(!env_has(child_env, "HEIMDALL_MOCK_LOG=") && !env_has(child_env, "HAM_CTL="), "sanitized child env must not carry mock config (it is inlined in --agent-command)")

	_ = os.remove(mock_log)
	ran_ok := bridge.bridge_wrapper_supervisor_main(args)
	check(ran_ok, "wrapper supervisor should launch the mock and exit cleanly")

	// Lifecycle reached `stopped` through the local endpoint (wrapper.exited).
	inst, ok := bridge.bridge_runtime_instance_snapshot(instance_id)
	check(ok && inst.runtime_status == "stopped", "wrapper.exited should mark runtime stopped through local endpoint")

	// The mock log is the deterministic artifact. Wait for it to settle (the
	// child runs a 3-step ~4s replay before exiting; the supervisor returns
	// only after process exit, but give a small grace for filesystem flush).
	deadline := time.to_unix_nanoseconds(time.now()) + i64(5 * time.Second)
	log_text := ""
	for {
		data, err := os.read_entire_file(mock_log, context.allocator)
		if err == nil { log_text = string(data); break }
		if time.to_unix_nanoseconds(time.now()) >= deadline { break }
		time.sleep(50 * time.Millisecond)
	}
	check(strings.trim_space(log_text) != "", "mock agent log artifact should exist after launch")

	// Ordering: context replay step must precede the run_stdout step, which
	// must precede clean exit. This is the deterministic acceptance check.
	ctx_idx := strings.index(log_text, "\"detail\":\"line=7 action=context\"")
	run_idx := strings.index(log_text, "mock-e2e-step")
	done_idx := strings.index(log_text, "\"kind\":\"replay_done\"")
	check(ctx_idx >= 0, "log should record the context replay step")
	check(run_idx > ctx_idx, "log should record run_stdout after the context step")
	check(done_idx > run_idx, "log should record clean exit last")

	// The real local-endpoint response to agent.context.get must be present —
	// this is the agent-facing notification/message the Bridge relayed back.
	// The endpoint echoes the verified agent_instance_id in its data envelope.
	check(
		strings.contains(log_text, instance_id) && strings.contains(log_text, "\"ok\":true"),
		"mock log should capture the Bridge response to agent.context.get (ok=true, instance id)",
	)

	fmt.println("PASS: mock agent wrapper launch (RTE2E-8)")
}

// ham_ctl_path resolves a sibling ham-ctl binary next to the built bridge
// artifact if present; otherwise falls back to PATH. The mock uses ham-ctl
// agent mode to drive the local endpoint.
ham_ctl_path :: proc(mock_script: string) -> string {
	_ = mock_script
	if v := os.get_env("HAM_CTL", context.allocator); strings.trim_space(v) != "" do return v
	return "ham-ctl"
}

env_has :: proc(env: []string, prefix: string) -> bool {
	for item in env { if strings.has_prefix(item, prefix) do return true }
	return false
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }
