package main

import "core:fmt"
import "core:strings"
import "core:testing"
import agent_runtime "odin_test:lib/agent_runtime"
import cfg_lib "odin_test:lib/config"

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

// AE-3: the concurrent startup probe maps its outcome to a wrapper.startup.report
// phase. Only blocked/failed are surfaced; ready/disabled/unknown must NOT emit a
// report (a fine probe must not overwrite the agent's real readiness, which the
// child establishes via its own start-success RPC).
@(test)
wrapper_bridge_startup_phase_for_result_maps_blocked_and_failed :: proc(t: ^testing.T) {
	blocked, blocked_ok := wrapper_bridge_startup_phase_for_result(agent_runtime.Startup_Probe_Result{status = "startup_blocked", detail = "folder trust"})
	testing.expect(t, blocked_ok, "startup_blocked is reported")
	testing.expect_value(t, blocked, "startup_blocked")

	failed, failed_ok := wrapper_bridge_startup_phase_for_result(agent_runtime.Startup_Probe_Result{status = "startup_failed", detail = "pane exited"})
	testing.expect(t, failed_ok, "startup_failed is reported")
	testing.expect_value(t, failed, "startup_failed")

	_, ready_ok := wrapper_bridge_startup_phase_for_result(agent_runtime.Startup_Probe_Result{status = "ready"})
	testing.expect(t, !ready_ok, "ready is NOT reported (must not downgrade readiness)")

	_, disabled_ok := wrapper_bridge_startup_phase_for_result(agent_runtime.Startup_Probe_Result{status = "disabled"})
	testing.expect(t, !disabled_ok, "disabled is NOT reported")

	_, unknown_ok := wrapper_bridge_startup_phase_for_result(agent_runtime.Startup_Probe_Result{status = ""})
	testing.expect(t, !unknown_ok, "empty/unknown is NOT reported")
}

// AE-1+AE-2 round-trip: the bridge serializes the resolved provider
// startup_detection to JSON (bridge_runtime_startup_detection_arg ->
// bridge_provider_write_startup_json) and the wrapper parses it back
// (wrapper_bridge_parse_startup_detection). This proves the wrapper-side
// deserializer recovers every field the bridge writer emits, including patterns
// that contain commas (e.g. the claude folder-trust prompt), the parallel
// auto_enter_pre_keys, blocked_patterns, startup_unknown_is_blocked, and the
// sanitized_reason_mapping. We mirror the exact writer JSON here (a copy of
// bridge_provider_write_startup_json) so the wrapper test package stays
// self-contained while asserting the shared contract.
@(test)
wrapper_bridge_startup_detection_round_trip :: proc(t: ^testing.T) {
	original := cfg_lib.Startup_Detection_Config{
		enabled = true,
		startup_probe_seconds = 25,
		capture_interval_ms = 500,
		blocked_patterns = {"Login required", "Error: quota exceeded, try again"},
		auto_enter_patterns = {"Yes, I trust this folder", "WARNING: Claude Code running in Bypass Permissions mode"},
		auto_enter_pre_keys = {"", "Down"},
		startup_unknown_is_blocked = true,
		sanitized_reason_mapping = {"login needed", "quota, exceeded"},
	}

	json := wrapper_bridge_test_write_startup_json(original)
	round := wrapper_bridge_parse_startup_detection(json)

	testing.expect(t, round.enabled == original.enabled, "enabled preserved")
	testing.expect(t, round.startup_probe_seconds == original.startup_probe_seconds, "startup_probe_seconds preserved")
	testing.expect(t, round.capture_interval_ms == original.capture_interval_ms, "capture_interval_ms preserved")
	testing.expect(t, round.startup_unknown_is_blocked == original.startup_unknown_is_blocked, "startup_unknown_is_blocked preserved")
	wrapper_bridge_test_expect_string_slice(t, round.blocked_patterns, original.blocked_patterns, "blocked_patterns")
	wrapper_bridge_test_expect_string_slice(t, round.auto_enter_patterns, original.auto_enter_patterns, "auto_enter_patterns")
	wrapper_bridge_test_expect_string_slice(t, round.auto_enter_pre_keys, original.auto_enter_pre_keys, "auto_enter_pre_keys")
	wrapper_bridge_test_expect_string_slice(t, round.sanitized_reason_mapping, original.sanitized_reason_mapping, "sanitized_reason_mapping")

	// Specifically assert the comma-bearing pattern survived intact and was not
	// split on its embedded comma.
	testing.expect(t, len(round.auto_enter_patterns) == 2, "comma pattern not split into extra elements")
	if len(round.auto_enter_patterns) == 2 {
		testing.expect_value(t, round.auto_enter_patterns[0], "Yes, I trust this folder")
	}
}

// The wrapper also parses the arg straight off the argv the bridge builds.
@(test)
wrapper_bridge_startup_detection_from_args_parses_flag :: proc(t: ^testing.T) {
	sd := cfg_lib.Startup_Detection_Config{
		enabled = true,
		auto_enter_patterns = {"Yes, I trust this folder"},
		auto_enter_pre_keys = {""},
	}
	args := []string{"--startup-detection", wrapper_bridge_test_write_startup_json(sd), "--", "claude"}
	round := wrapper_bridge_startup_detection_from_args(args)
	testing.expect(t, round.enabled, "enabled parsed from --startup-detection arg")
	testing.expect(t, len(round.auto_enter_patterns) == 1, "auto_enter_patterns parsed")
	if len(round.auto_enter_patterns) == 1 {
		testing.expect_value(t, round.auto_enter_patterns[0], "Yes, I trust this folder")
	}
}

// A missing --startup-detection arg yields a zero/disabled config (no crash).
@(test)
wrapper_bridge_startup_detection_absent_is_disabled :: proc(t: ^testing.T) {
	round := wrapper_bridge_startup_detection_from_args([]string{"--", "claude"})
	testing.expect(t, !round.enabled, "absent arg -> disabled")
	testing.expect(t, len(round.auto_enter_patterns) == 0, "absent arg -> no patterns")
}

wrapper_bridge_test_expect_string_slice :: proc(t: ^testing.T, got: []string, want: []string, label: string) {
	testing.expectf(t, len(got) == len(want), "%s length: got %d want %d", label, len(got), len(want))
	if len(got) != len(want) do return
	for value, i in want {
		testing.expectf(t, got[i] == value, "%s[%d]: got %q want %q", label, i, got[i], value)
	}
}

// wrapper_bridge_test_write_startup_json mirrors bridge_provider_write_startup_json
// (src/bridge/provider_store.odin) so the wrapper test package can assert the
// serialize->parse contract without importing the bridge package.
wrapper_bridge_test_write_startup_json :: proc(sd: cfg_lib.Startup_Detection_Config) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"enabled\":"); strings.write_string(&b, "true" if sd.enabled else "false")
	strings.write_string(&b, ",\"startup_probe_seconds\":"); wrapper_bridge_test_write_int(&b, sd.startup_probe_seconds)
	strings.write_string(&b, ",\"capture_interval_ms\":"); wrapper_bridge_test_write_int(&b, sd.capture_interval_ms)
	strings.write_string(&b, ",\"blocked_patterns\":"); wrapper_bridge_test_write_string_array(&b, sd.blocked_patterns)
	strings.write_string(&b, ",\"auto_enter_patterns\":"); wrapper_bridge_test_write_string_array(&b, sd.auto_enter_patterns)
	strings.write_string(&b, ",\"auto_enter_pre_keys\":"); wrapper_bridge_test_write_string_array(&b, sd.auto_enter_pre_keys)
	strings.write_string(&b, ",\"startup_unknown_is_blocked\":"); strings.write_string(&b, "true" if sd.startup_unknown_is_blocked else "false")
	strings.write_string(&b, ",\"sanitized_reason_mapping\":"); wrapper_bridge_test_write_string_array(&b, sd.sanitized_reason_mapping)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

wrapper_bridge_test_write_int :: proc(b: ^strings.Builder, value: int) {
	strings.write_string(b, fmt.tprintf("%d", value))
}

wrapper_bridge_test_write_string_array :: proc(b: ^strings.Builder, values: []string) {
	strings.write_byte(b, '[')
	for value, i in values {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"')
		json_write_string(b, value)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
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
