package main

import "core:strings"
import "core:testing"

@(test)
bridge_permission_normalize_decision_maps_canonical :: proc(t: ^testing.T) {
	testing.expect(t, bridge_permission_normalize_decision("allow") == "allow")
	testing.expect(t, bridge_permission_normalize_decision("Approved") == "allow")
	testing.expect(t, bridge_permission_normalize_decision("yes") == "allow")
	testing.expect(t, bridge_permission_normalize_decision("ask") == "ask")
	testing.expect(t, bridge_permission_normalize_decision("deny") == "deny")
	// Unknown / empty fail safe to deny.
	testing.expect(t, bridge_permission_normalize_decision("") == "deny")
	testing.expect(t, bridge_permission_normalize_decision("garbage") == "deny")
}

@(test)
bridge_permission_clamp_timeout_bounds :: proc(t: ^testing.T) {
	testing.expect(t, bridge_permission_clamp_timeout(0) == PERMISSION_DEFAULT_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(-5) == PERMISSION_DEFAULT_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(10) == PERMISSION_MIN_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(9_000_000) == PERMISSION_MAX_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(5000) == 5000)
}

@(test)
bridge_permission_register_rejects_dupes :: proc(t: ^testing.T) {
	bridge_permission_pending = nil
	now := bridge_runtime_now_ms()
	p := Bridge_Permission_Pending{request_id = "r1", agent_instance_id = "inst_a", tool = "bash", risk = "risky", created_unix_ms = now, deadline_unix_ms = now + 1000}
	testing.expect(t, bridge_permission_register(p))
	// Same request_id + instance is rejected.
	testing.expect(t, !bridge_permission_register(p))
	// Empty request_id rejected.
	testing.expect(t, !bridge_permission_register(Bridge_Permission_Pending{request_id = "", agent_instance_id = "inst_a"}))
	bridge_permission_remove("inst_a", "r1")
}

@(test)
bridge_permission_wait_resolves_from_reply :: proc(t: ^testing.T) {
	bridge_permission_pending = nil
	now := bridge_runtime_now_ms()
	p := Bridge_Permission_Pending{request_id = "r2", agent_instance_id = "inst_b", tool = "write", risk = "risky", created_unix_ms = now, deadline_unix_ms = now + 5000}
	testing.expect(t, bridge_permission_register(p))

	// A decision that lands before (or during) wait resolves it; the entry persists
	// as decided until wait consumes it, so pre-resolving is a valid deterministic case.
	testing.expect(t, bridge_permission_resolve("inst_b", "r2", "allow", "ok by user"))

	decision, reason := bridge_permission_wait("inst_b", "r2", 3000)
	testing.expect(t, decision == "allow")
	testing.expect(t, reason == "ok by user")
	// Entry consumed.
	testing.expect(t, len(bridge_permission_pending) == 0)
}

@(test)
bridge_permission_wait_times_out_to_deny :: proc(t: ^testing.T) {
	bridge_permission_pending = nil
	now := bridge_runtime_now_ms()
	p := Bridge_Permission_Pending{request_id = "r3", agent_instance_id = "inst_c", tool = "bash", risk = "risky", created_unix_ms = now, deadline_unix_ms = now + 50}
	testing.expect(t, bridge_permission_register(p))
	decision, reason := bridge_permission_wait("inst_c", "r3", 50)
	testing.expect(t, decision == "deny")
	testing.expect(t, strings.contains(reason, "timed out"))
	testing.expect(t, len(bridge_permission_pending) == 0)
}

@(test)
bridge_permission_request_push_json_shape :: proc(t: ^testing.T) {
	p := Bridge_Permission_Pending{request_id = "r4", agent_instance_id = "inst_d", tool = "edit", risk = "risky"}
	line := bridge_permission_request_push_json(p, "{\"path\":\"a.txt\"}")
	testing.expect(t, strings.contains(line, "\"push\":\"permission_request\""))
	testing.expect(t, strings.contains(line, "\"request_id\":\"r4\""))
	testing.expect(t, strings.contains(line, "\"tool\":\"edit\""))
	testing.expect(t, strings.contains(line, "\"input\":{\"path\":\"a.txt\"}"))
	testing.expect(t, strings.has_suffix(line, "}\n"))
}

@(test)
bridge_permission_reply_push_json_shape :: proc(t: ^testing.T) {
	line := bridge_permission_reply_push_json("inst_e", "r5", "APPROVE", "looks good")
	testing.expect(t, strings.contains(line, "\"push\":\"permission_reply\""))
	testing.expect(t, strings.contains(line, "\"request_id\":\"r5\""))
	// Decision normalized to canonical allow.
	testing.expect(t, strings.contains(line, "\"decision\":\"allow\""))
	testing.expect(t, strings.contains(line, "\"reason\":\"looks good\""))
}
