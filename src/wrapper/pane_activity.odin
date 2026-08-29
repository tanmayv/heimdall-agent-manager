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
// This module neutralizes both by (a) MASKING volatile regions before hashing so
// timers/clocks/spinners don't count as "content changed", while (b) treating the
// PRESENCE of a spinner glyph as a strong positive "active" signal, and (c) using
// a stable-duration threshold with hysteresis so we never flip active->idle on the
// gap between streamed tokens.
//
// The functions here are pure and unit-testable without tmux: feed successive
// normalized frames into pane_activity_step and assert the derived status.

import "core:strings"

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

// Tunables. Defaults chosen so streamed-token gaps (usually < a few seconds) do
// not read as idle, while a genuinely quiet pane settles to idle reasonably fast.
Pane_Activity_Config :: struct {
	active_window_ms: i64, // content changed within this window => active
	idle_after_ms:    i64, // stable at least this long (no spinner) => idle
	line_limit:       int, // pane tail lines to consider
}

pane_activity_default_config :: proc() -> Pane_Activity_Config {
	return Pane_Activity_Config{active_window_ms = 3000, idle_after_ms = 8000, line_limit = 60}
}

// Rolling detector state. Carried across samples by the caller.
Pane_Activity_State :: struct {
	initialized:      bool,
	last_hash:        u64,
	last_change_ms:   i64,
	last_status:      Pane_Activity_Status,
}

// Result of analyzing one captured frame.
Pane_Activity_Sample :: struct {
	status:          Pane_Activity_Status,
	changed:         bool, // masked content differed from previous sample
	spinner_present: bool,
}

// Braille + common ASCII/block spinner glyphs. Masked for the content hash and
// used as a positive "active" indicator.
@(private="file")
PANE_SPINNER_RUNES := [?]rune{
	'\u2801','\u2802','\u2804','\u2808','\u2810','\u2820','\u2840','\u2880',
	'\u280b','\u2819','\u2839','\u2838','\u283c','\u2834','\u2826','\u2827',
	'\u2807','\u280f', // ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ family
	'\u2596','\u2597','\u2598','\u2599','\u259a','\u259b','\u259c','\u259d','\u259e','\u259f',
	'\u258f','\u258e','\u258d','\u258c','\u258b','\u258a','\u2589','\u2588', // ▏▎▍▌▋▊▉█
	'\u2591','\u2592','\u2593', // ░▒▓
	'\u25e6','\u2022','\u25cf','\u25cb','\u25d0','\u25d1','\u25d2','\u25d3',
	// NOTE: ASCII glyphs (| / - \\) and box-drawing (line/pipe) are intentionally
	// NOT masked as spinners: they appear constantly in normal content (file paths,
	// "(y/n)", tables, prose) and would cause chronic false-active plus corrupt
	// waiting_user detection. Modern agent TUIs (Claude Code, Pi, Codex) use the
	// braille/block spinners covered above, which are unambiguous.
}

@(private="file")
pane_is_spinner_rune :: proc(r: rune) -> bool {
	for s in PANE_SPINNER_RUNES do if r == s do return true
	return false
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
		// Collapse consecutive '#' into a single '#'.
		cl := strings.builder_make()
		prev_hash := false
		for j in 0..<len(line) {
			ch := line[j]
			if ch == '#' {
				if prev_hash do continue
				prev_hash = true
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

// pane_activity_step advances the detector by one sample. `raw` is the freshly
// captured pane tail; `now_ms` is the current wall-clock in ms. The state is
// updated in place and the derived sample returned.
pane_activity_step :: proc(state: ^Pane_Activity_State, cfg: Pane_Activity_Config, raw: string, now_ms: i64) -> Pane_Activity_Sample {
	normalized, spinner := pane_normalize(raw)
	defer delete(normalized)
	h := pane_hash(normalized)

	changed := false
	if !state.initialized {
		state.initialized = true
		state.last_hash = h
		state.last_change_ms = now_ms
		state.last_status = .Unknown
	} else if h != state.last_hash {
		changed = true
		state.last_hash = h
		state.last_change_ms = now_ms
	}

	stable_for := now_ms - state.last_change_ms

	status: Pane_Activity_Status
	if spinner {
		// A visible spinner means the TUI is actively rendering progress => active.
		status = .Active
	} else if changed || stable_for < cfg.active_window_ms {
		status = .Active
	} else if pane_detect_waiting_user(raw) {
		// Detect prompts from the RAW frame: normalization masks '/' (a spinner
		// glyph) and digits, which would corrupt affordances like "(y/n)".
		status = .Waiting_User
	} else if stable_for >= cfg.idle_after_ms {
		status = .Idle
	} else {
		// In the ambiguous band between active_window and idle_after: hold the last
		// known status (hysteresis) to avoid flicker between streamed tokens.
		status = state.last_status
		if status == .Unknown do status = .Active
	}

	state.last_status = status
	return Pane_Activity_Sample{status = status, changed = changed, spinner_present = spinner}
}
