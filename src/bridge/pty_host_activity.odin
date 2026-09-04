package main

// BR-3: harness-agnostic working/idle classification, ported from the wrapper's
// pane_activity.odin into the bridge for the wrapper-free runtime.
//
// In the tmux/wrapper model the ham-wrapper captured a burst of 3 pane-tail
// snapshots and classified them locally. In the ham-pty-host model the daemon
// emits a ScreenChanged{instance,hash} dirty signal (HOST-2) whenever the rendered
// screen content changes; the bridge captures the screen (host.capture) around
// those signals to build the same 3-frame burst and runs the IDENTICAL stateless
// masking+classify logic here, then reports activity to the hub. The spinner
// masking is intentionally bridge-side (the daemon's hash is a raw content hash;
// a ticking footer/spinner would otherwise flip it every frame => false-active).
//
// This is a faithful port of the pure classifier — the masking rules, the
// spinner/waiting precedence, and the FNV hashing all match the wrapper so the
// recorded-frame parity tests carry over unchanged.

import "core:strings"

BRIDGE_ACTIVITY_MAX_FRAMES :: 8

Bridge_Activity_Status :: enum {
	Unknown,
	Active,
	Idle,
	Waiting_User,
}

bridge_activity_status_string :: proc(status: Bridge_Activity_Status) -> string {
	switch status {
	case .Active:       return "active"
	case .Idle:         return "idle"
	case .Waiting_User: return "waiting_user"
	case .Unknown:      return "unknown"
	}
	return "unknown"
}

// Bridge_Activity_Sample is one classified burst cycle. frame_hashes carries the
// per-frame FNV hashes of the NORMALIZED frames (hashes only, never raw text) for
// observability.
Bridge_Activity_Sample :: struct {
	status:          Bridge_Activity_Status,
	changed:         bool,
	spinner_present: bool,
	waiting_user:    bool,
	frame_count:     int,
	frame_hashes:    [BRIDGE_ACTIVITY_MAX_FRAMES]u64,
}

// Spinner detection is restricted to the Unicode Braille Patterns block
// (U+2800..U+28FF): modern agent TUIs animate their working spinner with braille,
// which essentially never appears in normal output, so its PRESENCE is a strong,
// low-false-positive "active" signal.
bridge_activity_is_spinner_rune :: proc(r: rune) -> bool {
	return r >= '\u2800' && r <= '\u28ff'
}

// bridge_activity_normalize masks volatile regions (spinners -> '*', digits -> '#',
// with numeric separators collapsed) and trims trailing whitespace/blank lines so
// only meaningful content changes survive. Reports whether any spinner glyph was
// present in the raw frame. Caller owns the returned string.
bridge_activity_normalize :: proc(raw: string) -> (normalized: string, spinner_present: bool) {
	b := strings.builder_make()
	spinner := false
	for r in raw {
		if bridge_activity_is_spinner_rune(r) {
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
	defer strings.builder_destroy(&b)

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
		// Collapse consecutive '#' into one, swallowing numeric separators ('.'/',')
		// that sit between two masked digits, so a counter mutating in value OR width
		// hashes identically ("9.1k" and "12k" -> "#k"). Real prose punctuation is
		// kept (a separator only collapses BETWEEN two '#').
		cl := strings.builder_make()
		defer strings.builder_destroy(&cl)
		prev_hash := false
		for j in 0..<len(line) {
			ch := line[j]
			if ch == '#' {
				if prev_hash do continue
				prev_hash = true
			} else if (ch == '.' || ch == ',') && prev_hash && j+1 < len(line) && line[j+1] == '#' {
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

BRIDGE_FNV64_OFFSET :: 0xcbf29ce484222325
BRIDGE_FNV64_PRIME :: 0x100000001b3

bridge_activity_hash :: proc(s: string) -> u64 {
	h: u64 = BRIDGE_FNV64_OFFSET
	for i in 0..<len(s) {
		h ~= u64(s[i])
		h *= BRIDGE_FNV64_PRIME
	}
	return h
}

// bridge_activity_detect_waiting_user is a conservative best-effort hint: it scans
// the last few non-blank lines for well-known "blocked on the user" affordances.
// When unsure it returns false and the caller falls back to idle.
bridge_activity_detect_waiting_user :: proc(text: string) -> bool {
	lines := strings.split(text, "\n")
	defer delete(lines)
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

// bridge_activity_classify_burst is the PURE core of the stateless detector.
// Precedence: spinner => Active; else waiting-on-user => Waiting_User; else all
// normalized frames identical => Idle; else (frames differ) => Active.
bridge_activity_classify_burst :: proc(normalized_frames: []string, spinner_present, waiting_user: bool) -> (status: Bridge_Activity_Status, changed: bool) {
	changed = false
	for i in 1..<len(normalized_frames) {
		if normalized_frames[i] != normalized_frames[0] {
			changed = true
			break
		}
	}
	if spinner_present do return .Active, changed
	if waiting_user do return .Waiting_User, changed
	if changed do return .Active, true
	return .Idle, false
}

// bridge_activity_burst_status classifies one stateless cycle from a burst of RAW
// captured-screen frames. It normalizes each frame, ORs the spinner signal across
// the raw frames, ORs the waiting-on-user prompt across the RAW frames (so masked
// '/'+digits don't corrupt affordances like "(y/n)"), then classifies.
bridge_activity_burst_status :: proc(raw_frames: []string) -> Bridge_Activity_Sample {
	if len(raw_frames) == 0 do return Bridge_Activity_Sample{status = .Unknown}
	normalized := make([]string, len(raw_frames))
	defer {
		for n in normalized do delete(n)
		delete(normalized)
	}
	spinner := false
	waiting := false
	for raw, i in raw_frames {
		n, spin := bridge_activity_normalize(raw)
		normalized[i] = n
		if spin do spinner = true
		if bridge_activity_detect_waiting_user(raw) do waiting = true
	}
	status, changed := bridge_activity_classify_burst(normalized, spinner, waiting)
	sample := Bridge_Activity_Sample{
		status          = status,
		changed         = changed,
		spinner_present = spinner,
		waiting_user    = waiting,
		frame_count     = min(len(normalized), BRIDGE_ACTIVITY_MAX_FRAMES),
	}
	for i in 0..<sample.frame_count {
		sample.frame_hashes[i] = bridge_activity_hash(normalized[i])
	}
	return sample
}

// bridge_activity_screen_to_text joins a captured screen's rendered lines into a
// single frame string for classification. Caller owns the returned string.
bridge_activity_screen_to_text :: proc(lines: []string) -> string {
	return strings.join(lines, "\n")
}
