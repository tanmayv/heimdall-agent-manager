package main

// REQ-SHELL-1 §8: one clock. The hub assigns started_at and the bridge records
// that value, so a bridge whose local clock is skewed cannot change any age
// decision — neither the hub-side 1-day server reap nor the bridge-side output
// retention window, which both read started_at.

import "core:testing"

@(test)
test_bridge_shell_started_at_prefers_the_hub_clock :: proc(t: ^testing.T) {
	hub   := "2026-09-28T08:00:00Z"
	local := "2026-09-28T08:00:00Z"
	testing.expect_value(t, bridge_shell_authoritative_started_at(hub, local), hub)
}

@(test)
test_bridge_shell_skewed_local_clock_does_not_change_started_at :: proc(t: ^testing.T) {
	hub := "2026-09-28T08:00:00Z"
	// The same hub value against wildly skewed local clocks — hours behind, hours
	// ahead, and a whole day out. The recorded started_at must not move, because
	// every age rule is computed from it.
	skews := []string{
		"2026-09-28T02:13:44Z",
		"2026-09-28T19:47:02Z",
		"2026-09-27T08:00:00Z",
		"2026-09-29T08:00:00Z",
	}
	for skewed in skews {
		testing.expect_value(t, bridge_shell_authoritative_started_at(hub, skewed), hub)
	}
}

@(test)
test_bridge_shell_started_at_falls_back_only_when_hub_sent_none :: proc(t: ^testing.T) {
	local := "2026-09-28T08:00:00Z"
	// No hub-side path omits started_at; the fallback exists so a hand-rolled or
	// replayed frame records a real timestamp rather than an empty one.
	testing.expect_value(t, bridge_shell_authoritative_started_at("", local), local)
}
