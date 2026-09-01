package main

import "core:strings"
import "core:testing"

// Unit tests for the harness-agnostic STATELESS burst pane-activity detector
// (pane_activity.odin). Each detection cycle is self-contained: a burst of 3
// pane-tail snapshots is normalized and diffed (all identical => idle, any differ
// => active), with a braille-spinner override => active and a raw waiting-on-user
// prompt => waiting_user. These tests feed frames directly, no tmux required, and
// cover the failure modes a naive text-diff would get wrong: spinner-only churn,
// timer/counter-only churn, slow token streams, and static idle prompts.

// pane_burst builds a 3-frame burst from the given raw frames and classifies it
// through the stateless pipeline (normalize each, OR spinner, OR waiting-user).
@(private="file")
pane_burst :: proc(a, b, c: string) -> Pane_Activity_Sample {
	frames := []string{a, b, c}
	return pane_activity_burst_status(frames)
}

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
	// A braille spinner in ANY burst frame => active, even if the masked body text
	// is identical across all three snapshots.
	s := pane_burst("\u2801 Working", "\u2839 Working", "\u2802 Working")
	testing.expect(t, s.spinner_present, "spinner should be present")
	testing.expect(t, s.status == .Active, "spinner burst must be active")
	// Spinner in just one of the three still forces active.
	s2 := pane_burst("Working", "\u2839 Working", "Working")
	testing.expect(t, s2.status == .Active, "spinner in any single frame keeps the burst active")
}

@(test)
pane_activity_timer_only_churn_goes_idle :: proc(t: ^testing.T) {
	// A pane whose ONLY change across the burst is a ticking clock/counter with no
	// spinner must classify idle — the key false-active case a naive diff fails.
	s := pane_burst(
		"Session log\nlast update 10:00:01",
		"Session log\nlast update 10:00:02",
		"Session log\nlast update 10:00:03",
	)
	testing.expect(t, !s.spinner_present, "no spinner in timer-only burst")
	testing.expect(t, !s.changed, "masked content must be unchanged across clock ticks")
	testing.expect(t, s.status == .Idle, "timer-only churn must classify idle")
}

@(test)
pane_activity_streaming_is_active :: proc(t: ^testing.T) {
	// Content grows across the ~1s burst (streaming tokens). The normalized frames
	// differ => active. This is why the burst spans ~1s: a slow stream still moves
	// the body between the first and last snapshot.
	s := pane_burst(
		"The answer begins",
		"The answer begins here",
		"The answer begins here now",
	)
	testing.expect(t, s.changed, "growing body across the burst must register as changed")
	testing.expect(t, s.status == .Active, "streaming tokens must classify active")
}

@(test)
pane_activity_static_content_goes_idle :: proc(t: ^testing.T) {
	// Three identical static frames => idle.
	s := pane_burst("$ ", "$ ", "$ ")
	testing.expect(t, !s.changed, "identical static frames are unchanged")
	testing.expect(t, s.status == .Idle, "static pane burst must be idle")
}

@(test)
pane_activity_detects_waiting_user :: proc(t: ^testing.T) {
	// A y/n prompt present in the (static) burst => waiting_user. The hub maps
	// waiting_user => idle (see activity_status_normalize_test.odin), so a
	// blocked-on-user agent never renders as working.
	frame := "Ran command foo\nDo you want to proceed? (y/n)"
	s := pane_burst(frame, frame, frame)
	testing.expect(t, s.status == .Waiting_User, "y/n prompt must classify waiting_user")
	// Even if the prompt appears in only one frame of the burst, detect it.
	s2 := pane_burst("Ran command foo", frame, frame)
	testing.expect(t, s2.status == .Waiting_User, "waiting_user detected from any raw frame")
}

@(test)
pane_classify_burst_precedence :: proc(t: ^testing.T) {
	// Pure classifier precedence: spinner > waiting_user > changed > idle.
	same := []string{"x", "x", "x"}
	diff := []string{"x", "y", "x"}
	// spinner beats everything.
	st, _ := pane_classify_burst(same, true, true)
	testing.expect(t, st == .Active, "spinner overrides waiting_user")
	// waiting_user beats a plain change decision when no spinner.
	st2, _ := pane_classify_burst(same, false, true)
	testing.expect(t, st2 == .Waiting_User, "waiting_user when no spinner and frames identical")
	// changed (no spinner, no waiting) => active.
	st3, ch3 := pane_classify_burst(diff, false, false)
	testing.expect(t, ch3 && st3 == .Active, "differing frames => active")
	// all identical, no spinner/waiting => idle.
	st4, ch4 := pane_classify_burst(same, false, false)
	testing.expect(t, !ch4 && st4 == .Idle, "identical quiet frames => idle")
}

// REQ-3: the ACTUAL Claude Code footer captured from a live idle agent (tmux
// capture-pane -p on inst_18d1235fc148693a / pane %57). The only thing that
// changes frame-to-frame on an idle Claude pane is the numeric run in the status
// footer (token counters, cost, cost %, the watchdog "idle Ns" seconds counter).
// pane_normalize must collapse all of that so the burst frames of a genuinely
// idle pane are byte-identical and the cycle classifies idle rather than active.
@(private="file")
CLAUDE_FOOTER_FRAME_A :: "The coordinator asked the user to clarify the request.\n" +
	"────────────────────\n" +
	"/private/tmp/heimdall/instances/inst_18d1235fc148693a\n" +
	"↑56 ↓9.1k R698k W73k $0.973 (sub) 5.9%/1.0M (auto)   (anthropic) claude-opus-4-8 • high\n" +
	"watchdog: idle 300s (0/∞) Heimdall: working · settling"
@(private="file")
CLAUDE_FOOTER_FRAME_B :: "The coordinator asked the user to clarify the request.\n" +
	"────────────────────\n" +
	"/private/tmp/heimdall/instances/inst_18d1235fc148693a\n" +
	"↑56 ↓11k R700k W73k $1.004 (sub) 6.0%/1.0M (auto)   (anthropic) claude-opus-4-8 • high\n" +
	"watchdog: idle 315s (0/∞) Heimdall: working · settling"
@(private="file")
CLAUDE_FOOTER_FRAME_C :: "The coordinator asked the user to clarify the request.\n" +
	"────────────────────\n" +
	"/private/tmp/heimdall/instances/inst_18d1235fc148693a\n" +
	"↑56 ↓12k R701k W73k $1.021 (sub) 6.1%/1.0M (auto)   (anthropic) claude-opus-4-8 • high\n" +
	"watchdog: idle 330s (0/∞) Heimdall: working · settling"

@(test)
pane_normalize_collapses_real_claude_footer :: proc(t: ^testing.T) {
	a, spin_a := pane_normalize(CLAUDE_FOOTER_FRAME_A)
	b, spin_b := pane_normalize(CLAUDE_FOOTER_FRAME_B)
	c, spin_c := pane_normalize(CLAUDE_FOOTER_FRAME_C)
	defer delete(a); defer delete(b); defer delete(c)
	// No braille spinner in an idle Claude footer.
	testing.expect(t, !spin_a && !spin_b && !spin_c, "idle Claude footer has no braille spinner")
	// The frames differ ONLY by numeric counters (tokens/cost/%/watchdog secs) so
	// after masking + collapsing they must be byte-identical => equal hash.
	testing.expect(t, a == b && b == c, "idle Claude footer frames differing only by counters must normalize equal")
	testing.expect(t, pane_hash(a) == pane_hash(c), "idle Claude footer must hash stably across the burst")
}

@(test)
pane_activity_real_claude_idle_footer_goes_idle :: proc(t: ^testing.T) {
	// Classify one stateless cycle from the 3 real footer snapshots whose only
	// delta is the ticking counters. It must classify idle, not active.
	s := pane_burst(CLAUDE_FOOTER_FRAME_A, CLAUDE_FOOTER_FRAME_B, CLAUDE_FOOTER_FRAME_C)
	testing.expect(t, !s.spinner_present, "no spinner in idle Claude footer")
	testing.expect(t, !s.changed, "counter-only churn must not read as a content change")
	testing.expect(t, s.status == .Idle, "real idle Claude footer burst must classify idle, not active")
}

@(test)
pane_normalize_collapses_decimal_and_grouped_numbers :: proc(t: ^testing.T) {
	// Direct check of the #.# / #,# collapsing rule: value AND width/precision
	// changes of a formatted number must hash identically, while surrounding text
	// (and non-numeric punctuation) is preserved.
	n1, _ := pane_normalize("tokens 9.1k cost $0.973 ratio 5.9%")
	n2, _ := pane_normalize("tokens 12k cost $1.02 ratio 6%")
	defer delete(n1); defer delete(n2)
	testing.expect(t, n1 == n2, "decimal/grouped counters must collapse to the same masked form")
	// Sentence-ending period (not between digits) must survive.
	p1, _ := pane_normalize("Done. Next step.")
	defer delete(p1)
	testing.expect(t, strings.contains(p1, "."), "prose punctuation must be preserved")
}

@(test)
pane_activity_burst_populates_hashes_and_flags :: proc(t: ^testing.T) {
	// The burst sample must expose per-NORMALIZED-frame FNV hashes + the
	// waiting_user flag so the (env-gated) debug logger can show frame movement
	// without retaining raw pane text.
	// Idle (counter-only churn) => all 3 normalized hashes identical.
	idle := pane_burst(
		"Session log\nlast update 10:00:01",
		"Session log\nlast update 10:00:02",
		"Session log\nlast update 10:00:03",
	)
	testing.expect(t, idle.frame_count == 3, "three frames classified")
	testing.expect(t, !idle.waiting_user, "no waiting_user for idle log")
	testing.expect(t, idle.frame_hashes[0] == idle.frame_hashes[1] && idle.frame_hashes[1] == idle.frame_hashes[2], "counter-only churn hashes identically across the burst")
	testing.expect(t, idle.frame_hashes[0] != 0, "hash is populated")

	// Streaming (growing body) => normalized hashes differ across the burst.
	streaming := pane_burst("The answer begins", "The answer begins here", "The answer begins here now")
	testing.expect(t, streaming.frame_hashes[0] != streaming.frame_hashes[2], "growing body yields differing frame hashes")

	// waiting_user flag propagates to the sample.
	frame := "Ran command foo\nDo you want to proceed? (y/n)"
	waiting := pane_burst(frame, frame, frame)
	testing.expect(t, waiting.waiting_user, "waiting_user flag set on the sample")
}

@(test)
pane_activity_debug_line_has_required_fields :: proc(t: ^testing.T) {
	// The pure Level-1 formatter must emit every field the spec requires, as a
	// single greppable line, using the frame hashes (never raw text).
	sample := pane_burst(
		"Session log\nlast update 10:00:01",
		"Session log\nlast update 10:00:02",
		"Session log\nlast update 10:00:03",
	)
	line := pane_activity_debug_line(
		"2026-09-01T09:15:30Z",
		"inst_18d12670b46fe0b6",
		"%63",
		sample,
		false,      // report_sent
		"suppressed",
		"idle",     // last_reported_status
		1450,       // ms_since_last_activity
	)
	for field in ([]string{
		"ts=2026-09-01T09:15:30Z",
		"agent=inst_18d12670b46fe0b6",
		"pane=%63",
		"samples=3",
		"status=idle",
		"changed=false",
		"spinner=false",
		"waiting_user=false",
		"report_sent=false",
		"reason=suppressed",
		"last_reported=idle",
		"ms_since_activity=1450",
		"hashes=[",
	}) {
		testing.expect(t, strings.contains(line, field), field)
	}
	// No raw pane text (the log line must never leak content at level 1).
	testing.expect(t, !strings.contains(line, "Session log"), "debug line must not contain raw pane text")
	testing.expect(t, !strings.contains(line, "\n"), "debug line must be a single line")
	// A defaulted empty last_reported/reason must render as 'none'.
	empty := pane_activity_debug_line("2026-09-01T09:15:31Z", "a", "%1", sample, true, "", "", 0)
	testing.expect(t, strings.contains(empty, "reason=none"), "empty reason renders none")
	testing.expect(t, strings.contains(empty, "last_reported=none"), "empty last_reported renders none")
	testing.expect(t, strings.contains(empty, "report_sent=true"), "report_sent true renders")
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
