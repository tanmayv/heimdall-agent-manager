package main

// Harness-agnostic working/idle detection from a tmux pane snapshot.
//
// Motivation: the primary activity signal (agent.activity.report) is emitted by
// per-harness hooks/extensions (Pi, Antigravity) and does not exist for arbitrary
// CLI agents (Claude Code, Codex, …). Because every terminal agent renders to the
// tmux pane the wrapper already owns, sampling + classifying the pane gives a
// detector that works for ANY harness.
//
// A naive "did the text change?" diff is unreliable:
//   - spinners / elapsed-time counters / clocks change every frame => false active
//   - slow token streams look static within one sample                => false idle
//
// STATELESS BURST DETECTOR (per the user's design decision):
// Each detection cycle is self-contained — we do NOT carry any last_hash/
// last_change_ms across cycles. Once per cycle the caller captures a BURST of 3
// pane-tail snapshots a few hundred ms apart (~1-1.2s total), then:
//   (a) MASKS volatile regions of each snapshot (timers/clocks/counters/spinners)
//       via pane_normalize so a mutating footer never reads as "content changed";
//   (b) treats the PRESENCE of a braille spinner glyph in ANY snapshot as a strong
//       positive "active" signal;
//   (c) diffs the 3 NORMALIZED snapshots: all identical => idle, any differ =>
//       active. The ~1s burst span guards against false-idle on slow token streams
//       (a stream will grow the body across the 3 frames), while masking guards
//       against false-active from the ticking footer.
//   (d) detects a "blocked on the user" prompt (y/n, press enter, …) from the RAW
//       frame; the hub maps waiting_user => idle (a blocked agent is not working).
//
// The functions here are pure and unit-testable without tmux: build the 3
// normalized frames (+ spinner/waiting flags) and call pane_classify_burst, or
// feed 3 raw frames to pane_activity_burst_status.

import "core:fmt"
import "core:strings"

// Upper bound on burst frames we retain per-frame hashes for. The design uses 3
// samples; keep a small fixed array so Pane_Activity_Sample stays alloc-free and
// trivially copyable (no cleanup needed by callers).
PANE_ACTIVITY_MAX_FRAMES :: 8

Pane_Activity_Status :: enum {
	Unknown,
	Active,
	Idle,
	Waiting_User,
}

pane_activity_status_string :: proc(status: Pane_Activity_Status) -> string {
	switch status {
	case .Active:       return "active"
	case .Idle:         return "idle"
	case .Waiting_User: return "waiting_user"
	case .Unknown:      return "unknown"
	}
	return "unknown"
}

// Tunables for the stateless burst detector. A cycle captures `burst_samples`
// snapshots of the pane tail (`line_limit` lines each), waiting `burst_gap_ms`
// between snapshots. Defaults: 3 samples @ ~500ms gaps => ~1s burst span, which
// lets a slow token stream visibly grow across frames (=> active) while a quiet
// pane's masked frames stay identical (=> idle).
Pane_Activity_Config :: struct {
	burst_samples: int, // snapshots captured per cycle (design: 3)
	burst_gap_ms:  i64, // delay between snapshots (design: ~400-600ms)
	line_limit:    int, // pane tail lines to consider (design: 20)
}

pane_activity_default_config :: proc() -> Pane_Activity_Config {
	return Pane_Activity_Config{burst_samples = 3, burst_gap_ms = 500, line_limit = 20}
}

// Result of classifying one burst cycle. Carries just enough observability for
// the (env-gated) debug logger in bridge_runtime.odin WITHOUT retaining raw pane
// text: the per-frame FNV hashes of the NORMALIZED frames let the log show
// frame-to-frame movement (or stability) while never leaking pane contents.
Pane_Activity_Sample :: struct {
	status:          Pane_Activity_Status,
	changed:         bool, // any of the normalized burst frames differed
	spinner_present: bool, // a braille spinner appeared in any raw burst frame
	waiting_user:    bool, // a waiting-on-user prompt appeared in any raw burst frame
	frame_count:     int,  // number of frames actually classified (<= PANE_ACTIVITY_MAX_FRAMES)
	frame_hashes:    [PANE_ACTIVITY_MAX_FRAMES]u64, // FNV hash of each normalized frame
}

// Spinner detection is restricted to the Unicode Braille Patterns block
// (U+2800..U+28FF). Modern agent TUIs (Claude Code, Pi, Codex, Antigravity) all
// animate their "thinking/working" spinner with braille glyphs, and braille
// essentially never appears in normal agent output — so its PRESENCE is a strong,
// low-false-positive "active" signal.
//
// We deliberately do NOT treat these as spinners, because they occur in ordinary
// content/footers/progress bars and caused chronic false-active in real panes:
//   - bullets/circles: • ◦ ● ○ ◐…
//   - block shades / eighths: ░ ▒ ▓ ▏…█
//   - box drawing: ─ │
//   - ASCII: | / - \
@(private="file")
pane_is_spinner_rune :: proc(r: rune) -> bool {
	return r >= '\u2800' && r <= '\u28ff'
}


// pane_normalize masks volatile regions (spinners, digit/timer/clock runs) and
// trims trailing whitespace/blank lines so that only meaningful content changes
// are reflected in the returned string. It also reports whether any spinner glyph
// was present in the raw frame.
pane_normalize :: proc(raw: string) -> (normalized: string, spinner_present: bool) {
	b := strings.builder_make()
	spinner := false
	// First pass: rune-walk, replacing spinner glyphs with a sentinel and digits
	// (and the separators inside clock/time patterns) with '#'. Collapsing every
	// digit to '#' also neutralizes clocks (12:34 -> ##:##) and token counters.
	for r in raw {
		if pane_is_spinner_rune(r) {
			spinner = true
			strings.write_byte(&b, '*')
			continue
		}
		if r >= '0' && r <= '9' {
			strings.write_byte(&b, '#')
			continue
		}
		strings.write_rune(&b, r)
	}
	masked := strings.to_string(b)

	// Second pass: trim trailing whitespace per line, drop trailing blank lines,
	// and collapse runs of '#' so "1234" and "9" hash identically (a counter that
	// changes width must not read as a content change).
	lines := strings.split(masked, "\n")
	defer delete(lines)
	out := strings.builder_make()
	last_nonblank := -1
	for line, i in lines {
		trimmed := strings.trim_right(line, " \t\r")
		if strings.trim_space(trimmed) != "" do last_nonblank = i
	}
	for i in 0..=last_nonblank {
		if i < 0 do break
		line := strings.trim_right(lines[i], " \t\r")
		// Collapse consecutive '#' into a single '#'. We also swallow the internal
		// punctuation of a formatted number (thousands separators and decimal
		// points) so that a counter mutating in value OR width/precision hashes
		// identically: "9.1k" and "12k" both mask to "#k", "1,234" and "9" both to
		// "#". Without this, real agent footers (token counters like "↓9.1k",
		// cost "$0.973", ratios "5.9%/1.0M") flip the hash every frame on a pane
		// that is otherwise idle and read as false-active. A '.'/',' only collapses
		// when it sits BETWEEN two masked digits, so real prose punctuation is kept.
		cl := strings.builder_make()
		prev_hash := false
		for j in 0..<len(line) {
			ch := line[j]
			if ch == '#' {
				if prev_hash do continue
				prev_hash = true
			} else if (ch == '.' || ch == ',') && prev_hash && j+1 < len(line) && line[j+1] == '#' {
				// Numeric separator between two '#': skip it, keep prev_hash so the
				// following '#' run is also collapsed into the single leading '#'.
				continue
			} else {
				prev_hash = false
			}
			strings.write_byte(&cl, ch)
		}
		strings.write_string(&out, strings.to_string(cl))
		if i != last_nonblank do strings.write_byte(&out, '\n')
	}
	return strings.to_string(out), spinner
}

@(private="file")
FNV64_OFFSET :: 0xcbf29ce484222325
@(private="file")
FNV64_PRIME :: 0x100000001b3

pane_hash :: proc(s: string) -> u64 {
	h: u64 = FNV64_OFFSET
	for i in 0..<len(s) {
		h ~= u64(s[i])
		h *= FNV64_PRIME
	}
	return h
}

// pane_detect_waiting_user is a best-effort hint: it looks at the last few
// non-blank lines for well-known "the agent is blocked on the user" affordances.
// It is intentionally conservative — when unsure we return false and the caller
// falls back to idle.
pane_detect_waiting_user :: proc(normalized: string) -> bool {
	lines := strings.split(normalized, "\n")
	defer delete(lines)
	// Inspect up to the last 4 non-blank lines.
	checked := 0
	for i := len(lines) - 1; i >= 0 && checked < 4; i -= 1 {
		line := strings.trim_space(lines[i])
		if line == "" do continue
		checked += 1
		lower := strings.to_lower(line)
		defer delete(lower)
		if strings.contains(lower, "(y/n)") do return true
		if strings.contains(lower, "[y/n]") do return true
		if strings.contains(lower, "yes/no") do return true
		if strings.contains(lower, "press enter") do return true
		if strings.contains(lower, "do you want") do return true
		if strings.contains(lower, "approve") && strings.contains(lower, "?") do return true
		if strings.contains(lower, "continue?") do return true
		if strings.contains(lower, "allow") && strings.contains(lower, "?") do return true
	}
	return false
}

// pane_classify_burst is the PURE core of the stateless detector. It takes the
// already-NORMALIZED frames of one burst plus the spinner/waiting flags (both
// OR'd across the raw frames of the burst) and returns the derived status. It
// carries no state across cycles, so tests can call it directly.
//
// Precedence:
//   1. spinner present in any raw frame        => Active (strong working signal)
//   2. else waiting-on-user prompt in any frame => Waiting_User (hub maps to idle)
//   3. else all normalized frames identical     => Idle
//   4. else (frames differ)                     => Active (content is moving)
pane_classify_burst :: proc(normalized_frames: []string, spinner_present: bool, waiting_user: bool) -> (status: Pane_Activity_Status, changed: bool) {
	changed = false
	for i in 1..<len(normalized_frames) {
		if normalized_frames[i] != normalized_frames[0] {
			changed = true
			break
		}
	}
	if spinner_present {
		// A visible spinner means the TUI is actively rendering progress => active,
		// even if the masked body text happens to be identical across the burst.
		return .Active, changed
	}
	if waiting_user {
		// Blocked on the user (y/n, press enter, …). Not working; the hub maps
		// waiting_user => idle. Detected from the RAW frame by the caller.
		return .Waiting_User, changed
	}
	if changed {
		// The masked content moved across the ~1s burst (e.g. a growing token
		// stream) => active.
		return .Active, true
	}
	// All normalized frames identical and no spinner/prompt => genuinely quiet.
	return .Idle, false
}

// pane_activity_burst_status classifies one stateless cycle from a burst of RAW
// pane-tail snapshots (already captured `burst_gap_ms` apart by the caller). It
// normalizes each frame, ORs the spinner signal across the raw frames, ORs the
// waiting-on-user prompt across the raw frames, then delegates to
// pane_classify_burst. Returns a sample with the derived status.
pane_activity_burst_status :: proc(raw_frames: []string) -> Pane_Activity_Sample {
	if len(raw_frames) == 0 do return Pane_Activity_Sample{status = .Unknown}
	normalized := make([]string, len(raw_frames))
	defer {
		for n in normalized do delete(n)
		delete(normalized)
	}
	spinner := false
	waiting := false
	for raw, i in raw_frames {
		n, spin := pane_normalize(raw)
		normalized[i] = n
		if spin do spinner = true
		// Detect prompts from the RAW frame: normalization masks '/' (a spinner
		// glyph) and digits, which would corrupt affordances like "(y/n)".
		if pane_detect_waiting_user(raw) do waiting = true
	}
	status, changed := pane_classify_burst(normalized, spinner, waiting)
	sample := Pane_Activity_Sample{
		status          = status,
		changed         = changed,
		spinner_present = spinner,
		waiting_user    = waiting,
		frame_count     = min(len(normalized), PANE_ACTIVITY_MAX_FRAMES),
	}
	// Record per-frame hashes of the NORMALIZED frames (hashes only — never raw
	// text) so the debug logger can show frame-to-frame movement.
	for i in 0..<sample.frame_count {
		sample.frame_hashes[i] = pane_hash(normalized[i])
	}
	return sample
}

// pane_activity_debug_line is the PURE formatter for one Level-1 debug log line.
// It builds a single structured, greppable line from already-derived values (no
// DOM/tmux/IO). Kept here so it is unit-testable and so bridge_runtime.odin only
// supplies observed values. NEVER include raw pane text — the per-frame movement
// is conveyed via the normalized-frame FNV hashes on the sample.
//
// Fields (key=value, space-separated):
//   ts, agent, pane, samples, status, changed, spinner, waiting_user,
//   report_sent, reason, last_reported, ms_since_activity, hashes=[hex,…]
pane_activity_debug_line :: proc(
	ts_iso: string,
	agent_instance_id: string,
	pane_id: string,
	sample: Pane_Activity_Sample,
	report_sent: bool,
	reason: string,
	last_reported_status: string,
	ms_since_last_activity: i64,
) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "ts=")
	strings.write_string(&b, ts_iso)
	strings.write_string(&b, " agent=")
	strings.write_string(&b, agent_instance_id)
	strings.write_string(&b, " pane=")
	strings.write_string(&b, pane_id)
	strings.write_string(&b, " samples=")
	strings.write_string(&b, fmt.tprintf("%d", sample.frame_count))
	strings.write_string(&b, " status=")
	strings.write_string(&b, pane_activity_status_string(sample.status))
	strings.write_string(&b, " changed=")
	strings.write_string(&b, "true" if sample.changed else "false")
	strings.write_string(&b, " spinner=")
	strings.write_string(&b, "true" if sample.spinner_present else "false")
	strings.write_string(&b, " waiting_user=")
	strings.write_string(&b, "true" if sample.waiting_user else "false")
	strings.write_string(&b, " report_sent=")
	strings.write_string(&b, "true" if report_sent else "false")
	strings.write_string(&b, " reason=")
	strings.write_string(&b, reason if strings.trim_space(reason) != "" else "none")
	strings.write_string(&b, " last_reported=")
	strings.write_string(&b, last_reported_status if strings.trim_space(last_reported_status) != "" else "none")
	strings.write_string(&b, " ms_since_activity=")
	strings.write_string(&b, fmt.tprintf("%d", ms_since_last_activity))
	strings.write_string(&b, " hashes=[")
	for i in 0..<sample.frame_count {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, fmt.tprintf("%016x", sample.frame_hashes[i]))
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}
