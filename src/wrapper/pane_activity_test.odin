package main

import "core:strings"
import "core:testing"

// Unit tests for the harness-agnostic pane-activity detector (pane_activity.odin).
// These feed synthetic pane frames into the pure classifier and assert the derived
// working/idle/waiting_user status, covering the failure modes a naive text-diff
// would get wrong: spinner-only churn, timer-only churn, slow token streams, and
// static idle prompts.

@(test)
pane_normalize_masks_timers_and_spinners :: proc(t: ^testing.T) {
	// A frame that differs only by an elapsed-time counter and a spinner glyph must
	// normalize to identical content (so it does NOT count as a change), and the
	// spinner must be detected.
	a, spin_a := pane_normalize("\u2801 Thinking… (12s · 3450 tokens)")
	b, spin_b := pane_normalize("\u2839 Thinking… (13s · 5120 tokens)")
	defer delete(a); defer delete(b)
	testing.expect(t, spin_a && spin_b, "spinner glyphs must be detected")
	testing.expect(t, a == b, "frames differing only by timer/spinner must normalize equal")
}

@(test)
pane_normalize_preserves_real_content_change :: proc(t: ^testing.T) {
	a, _ := pane_normalize("Reading file foo.odin")
	b, _ := pane_normalize("Writing file bar.odin")
	defer delete(a); defer delete(b)
	testing.expect(t, a != b, "genuinely different content must normalize differently")
}

@(test)
pane_activity_spinner_is_active :: proc(t: ^testing.T) {
	cfg := pane_activity_default_config()
	state := Pane_Activity_State{}
	// Even with identical text, a present spinner => active.
	s1 := pane_activity_step(&state, cfg, "\u2801 Working", 1000)
	testing.expect(t, s1.spinner_present, "spinner should be present")
	testing.expect(t, s1.status == .Active, "spinner frame must be active")
	// Same content, later; spinner still present => still active well past idle_after.
	s2 := pane_activity_step(&state, cfg, "\u2839 Working", 1000 + cfg.idle_after_ms + 5000)
	testing.expect(t, s2.status == .Active, "spinner keeps it active despite masked-content stability")
}

@(test)
pane_activity_timer_only_churn_goes_idle :: proc(t: ^testing.T) {
	// A pane whose ONLY change is a ticking clock with no spinner must settle idle
	// once past idle_after_ms — this is the key false-active case a naive diff fails.
	cfg := pane_activity_default_config()
	state := Pane_Activity_State{}
	_ = pane_activity_step(&state, cfg, "Session log\nlast update 10:00:01", 0)
	_ = pane_activity_step(&state, cfg, "Session log\nlast update 10:00:02", 1000)
	final := pane_activity_step(&state, cfg, "Session log\nlast update 10:00:11", cfg.idle_after_ms + 2000)
	testing.expect(t, !final.spinner_present, "no spinner in timer-only frame")
	testing.expect(t, !final.changed, "masked content must be unchanged across clock ticks")
	testing.expect(t, final.status == .Idle, "timer-only churn must settle to idle")
}

@(test)
pane_activity_streaming_stays_active_with_hysteresis :: proc(t: ^testing.T) {
	// Content changes every couple seconds (streaming tokens). Even sampling in the
	// ambiguous band, hysteresis + recent-change must keep it active, never idle.
	cfg := pane_activity_default_config()
	state := Pane_Activity_State{}
	_ = pane_activity_step(&state, cfg, "The answer begins", 0)
	s2 := pane_activity_step(&state, cfg, "The answer begins here", 2000)
	testing.expect(t, s2.status == .Active, "recent content change => active")
	// 4s after last change: within idle_after (8s) => hysteresis holds active.
	s3 := pane_activity_step(&state, cfg, "The answer begins here", 6000)
	testing.expect(t, s3.status == .Active, "hysteresis holds active in the ambiguous band")
	// New token arrives, resets the change timer.
	s4 := pane_activity_step(&state, cfg, "The answer begins here now", 7000)
	testing.expect(t, s4.changed && s4.status == .Active, "new token => changed + active")
}

@(test)
pane_activity_static_content_goes_idle :: proc(t: ^testing.T) {
	cfg := pane_activity_default_config()
	state := Pane_Activity_State{}
	_ = pane_activity_step(&state, cfg, "$ ", 0)
	final := pane_activity_step(&state, cfg, "$ ", cfg.idle_after_ms + 1000)
	testing.expect(t, final.status == .Idle, "long-static pane must be idle")
}

@(test)
pane_activity_detects_waiting_user :: proc(t: ^testing.T) {
	cfg := pane_activity_default_config()
	state := Pane_Activity_State{}
	frame := "Ran command foo\nDo you want to proceed? (y/n)"
	_ = pane_activity_step(&state, cfg, frame, 0)
	final := pane_activity_step(&state, cfg, frame, cfg.idle_after_ms + 1000)
	testing.expect(t, final.status == .Waiting_User, "y/n prompt after stability must read waiting_user")
}

@(test)
pane_activity_status_strings :: proc(t: ^testing.T) {
	testing.expect(t, pane_activity_status_string(.Active) == "active")
	testing.expect(t, pane_activity_status_string(.Idle) == "idle")
	testing.expect(t, pane_activity_status_string(.Waiting_User) == "waiting_user")
	testing.expect(t, pane_activity_status_string(.Unknown) == "unknown")
}

@(test)
pane_hash_is_stable_and_sensitive :: proc(t: ^testing.T) {
	testing.expect(t, pane_hash("abc") == pane_hash("abc"), "hash must be deterministic")
	testing.expect(t, pane_hash("abc") != pane_hash("abd"), "hash must differ on content change")
	// Collapsing digit runs means different-width counters hash equal after normalize.
	n1, _ := pane_normalize("count 9")
	n2, _ := pane_normalize("count 100000")
	defer delete(n1); defer delete(n2)
	testing.expect(t, pane_hash(n1) == pane_hash(n2), "digit-run width must not change the hash")
	_ = strings.trim_space("")
}
