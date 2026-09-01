package main

import "core:testing"

// Regression tests for bridge_runtime_normalize_activity_status
// (task_18d1244749a796e3, REQ-4).
//
// BUG: an agent that finished its turn and is BLOCKED on the user reported
// activity_status=waiting_user, which the bridge collapsed to "active" — so the
// hub agents list showed it "working · settling" forever even though the runtime
// watchdog said "idle 300s". A not-working agent must not render as working.
//
// FIX: waiting_user / waiting / waiting_approval now project to the idle-equivalent
// "idle" status. Genuinely active signals (active/working/busy) must be untouched.

@(test)
activity_normalize_waiting_user_is_idle :: proc(t: ^testing.T) {
	testing.expect(t, bridge_runtime_normalize_activity_status("waiting_user") == "idle",
		"waiting_user must project to idle, not active (blocked-on-user agent is not working)")
	testing.expect(t, bridge_runtime_normalize_activity_status("waiting") == "idle",
		"waiting must project to idle")
	testing.expect(t, bridge_runtime_normalize_activity_status("waiting_approval") == "idle",
		"waiting_approval must project to idle")
	// Case/whitespace insensitivity.
	testing.expect(t, bridge_runtime_normalize_activity_status("  Waiting_User  ") == "idle",
		"normalization must be case- and whitespace-insensitive")
}

@(test)
activity_normalize_active_signals_unchanged :: proc(t: ^testing.T) {
	// REQ-2: genuinely working agents must still be active — no regression.
	testing.expect(t, bridge_runtime_normalize_activity_status("active") == "active", "active stays active")
	testing.expect(t, bridge_runtime_normalize_activity_status("working") == "active", "working maps to active")
	testing.expect(t, bridge_runtime_normalize_activity_status("busy") == "active", "busy maps to active")
}

@(test)
activity_normalize_idle_and_unknown :: proc(t: ^testing.T) {
	testing.expect(t, bridge_runtime_normalize_activity_status("idle") == "idle", "idle stays idle")
	testing.expect(t, bridge_runtime_normalize_activity_status("inactive") == "idle", "inactive maps to idle")
	testing.expect(t, bridge_runtime_normalize_activity_status("unknown") == "unknown", "unknown stays unknown")
	testing.expect(t, bridge_runtime_normalize_activity_status("") == "unknown", "empty maps to unknown")
}
