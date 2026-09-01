package main

import "core:strings"
import "core:testing"

// Activity-source contract for pi (and every provider) after the Heimdall pi
// activity extension was REMOVED (task_18d129291c6a455d, Option A). The
// harness-agnostic tmux pane-capture detector (source=pane_diff) is now the SOLE
// activity source: there is no longer any pi-specific extension file written or
// injected, and the wrapper's activity report always carries source=pane_diff.
// These tests lock that in so the pi_extension path cannot silently return.

@(test)
wrapper_pi_activity_extension_removed :: proc(t: ^testing.T) {
	// pane_diff detection defaults ON (opt out only via --no-pane-activity /
	// HEIMDALL_WRAPPER_PANE_ACTIVITY=0), so a pi-style launch runs the detector.
	testing.expect(t, wrapper_bridge_pane_activity_default([]string{}), "pane_diff is on by default")
	testing.expect(t, wrapper_bridge_pane_activity_default([]string{"pi", "--provider", "anthropic"}), "pi launch keeps pane_diff on by default")
	// Explicit opt-out still honored.
	testing.expect(t, !wrapper_bridge_pane_activity_default([]string{"--no-pane-activity"}), "--no-pane-activity opts out")
}

@(test)
wrapper_activity_report_source_is_pane_diff :: proc(t: ^testing.T) {
	// The only wrapper-emitted activity report uses source=pane_diff — never
	// pi_extension. Assert both active and idle reports carry pane_diff.
	active := wrapper_bridge_pane_activity_report_json("active")
	idle := wrapper_bridge_pane_activity_report_json("idle")
	testing.expect(t, strings.contains(active, "\"source\":\"pane_diff\""), "active report is source=pane_diff")
	testing.expect(t, strings.contains(idle, "\"source\":\"pane_diff\""), "idle report is source=pane_diff")
	testing.expect(t, !strings.contains(active, "pi_extension"), "no pi_extension source in wrapper report")
	testing.expect(t, strings.contains(active, "\"status\":\"active\""), "status propagated")
	testing.expect(t, strings.contains(idle, "\"status\":\"idle\""), "status propagated")
}
