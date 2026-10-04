package main

import "core:strings"
import "core:testing"

@(private = "file")
frame_contains :: proc(haystack, needle: string) -> bool {
	return strings.contains(haystack, needle)
}

// REQ-BVS-1: a legal vault_status is one of exactly three words, shared by the
// heartbeat and the immediate report. Both frames source it from
// bridge_vault_status_string(), so whatever the real vault state is on the machine
// running the test, the emitted value must be one of these.
@(private = "file")
frame_carries_legal_vault_status :: proc(frame: string) -> bool {
	return frame_contains(frame, "\"vault_status\":\"unlocked\"") ||
	       frame_contains(frame, "\"vault_status\":\"locked\"") ||
	       frame_contains(frame, "\"vault_status\":\"disabled\"")
}

// REQ-BVS-1: the hub-bound heartbeat carries the vault tri-state. Before this, the
// bridge computed the value for its own local API and its own gates and never told
// the hub, so the settings page had nothing to render per bridge.
@(test)
heartbeat_frame_carries_vault_status :: proc(t: ^testing.T) {
	frame := bridge_hub_heartbeat_json()
	defer delete(frame)

	testing.expect(t, frame_contains(frame, "\"type\":\"bridge_heartbeat\""), "frame is still a bridge_heartbeat")
	testing.expect(t, frame_contains(frame, "\"vault_status\":\""), "heartbeat carries a vault_status field")
	testing.expect(t, frame_carries_legal_vault_status(frame), "heartbeat vault_status is one of unlocked|locked|disabled")

	// The field must not have displaced what the hub already parses out of this frame.
	testing.expect(t, frame_contains(frame, "\"protocol_version\":1"), "protocol_version intact")
	testing.expect(t, frame_contains(frame, "\"capabilities\":"), "capabilities intact — the hub's heartbeat arm keys off this")
	testing.expect(t, frame_contains(frame, "\"features\":"), "features intact")
	testing.expect(t, frame_contains(frame, "\"active_instance_ids\":["), "active_instance_ids intact")
	testing.expect(t, frame_contains(frame, "\"instances\":["), "instances intact")
}

// REQ-BVS-1: the immediate report sent right after a successful unseal or lock, so
// the UI does not wait up to a heartbeat interval for the new state.
@(test)
vault_status_report_frame_is_its_own_type :: proc(t: ^testing.T) {
	frame := bridge_vault_status_report_json()
	defer delete(frame)

	testing.expect(t, frame_contains(frame, "\"type\":\"bridge_vault_status\""), "report has its own frame type")
	testing.expect(t, frame_contains(frame, "\"protocol_version\":1"), "report carries protocol_version")
	testing.expect(t, frame_carries_legal_vault_status(frame), "report vault_status is one of unlocked|locked|disabled")

	// Deliberately NOT a bridge_heartbeat: the hub's heartbeat arm also reconciles the
	// instance digest and reaps stale instances, and a vault operation must not
	// trigger instance-lifecycle decisions as a side effect.
	testing.expect(t, !frame_contains(frame, "\"type\":\"bridge_heartbeat\""), "report is not a synthetic heartbeat")
	testing.expect(t, !frame_contains(frame, "\"active_instance_ids\""), "report carries no instance digest")
	testing.expect(t, !frame_contains(frame, "\"instances\""), "report carries no instance list")
}

// REQ-BVS-1: the reported value agrees with the function the bridge's own gates use,
// so the hub is told the same thing the bridge acts on.
@(test)
vault_status_report_agrees_with_bridge_vault_status :: proc(t: ^testing.T) {
	expected := bridge_vault_status_string()
	frame := bridge_vault_status_report_json()
	defer delete(frame)

	needle := strings.concatenate({"\"vault_status\":\"", expected, "\""})
	defer delete(needle)
	testing.expect(t, frame_contains(frame, needle), "the frame reports exactly what bridge_vault_status_string() returns")
}
