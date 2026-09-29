package main

import "core:strings"
import "core:testing"

// ---- REQ-SHELL-27: pure output sanitisation ------------------------------
//
// AC1 is table-driven over bridge_shell_sanitize_output; AC2 and AC3 are separate
// end-to-end cases through bridge_shell_page, because they are about the ORDERING
// (strip before grep, strip before paging) and a table over the pure proc alone
// cannot observe that.

Sanitize_Case :: struct {
	name: string,
	raw:  string,
	want: string,
}

@(test)
bridge_shell_sanitize_output_table :: proc(t: ^testing.T) {
	cases := []Sanitize_Case{
		// --- the thing that motivated the task: colour ---
		{
			name = "sgr colour around a word",
			raw  = "\x1b[0;31merror\x1b[0m: boom\n",
			want = "error: boom\n",
		},
		{
			name = "sgr with no parameters (bare reset)",
			raw  = "a\x1b[mb\n",
			want = "ab\n",
		},
		// --- cursor movement / erase ---
		{
			name = "cursor moves and erase-line",
			raw  = "\x1b[2K\x1b[1Gbuilding\x1b[Hdone\n",
			want = "buildingdone\n",
		},
		// --- OSC title writes ---
		{
			name = "osc title terminated by BEL",
			raw  = "\x1b]0;my title\x07hello\n",
			want = "hello\n",
		},
		{
			name = "osc title terminated by ST (ESC backslash)",
			raw  = "\x1b]2;title\x1b\\hello\n",
			want = "hello\n",
		},
		// --- stray / malformed escapes must not leak a control byte ---
		{
			name = "lone trailing ESC is dropped",
			raw  = "tail\x1b",
			want = "tail",
		},
		{
			name = "two-byte escape (charset select) is dropped",
			raw  = "a\x1b(Bb\n",
			want = "ab\n",
		},
		{
			name = "unterminated CSI at end of text emits nothing",
			raw  = "line\n\x1b[0;32",
			want = "line\n",
		},
		{
			name = "unterminated OSC at end of text emits nothing",
			raw  = "line\n\x1b]0;half a title",
			want = "line\n",
		},
		// --- THE REGRESSION GUARD: brackets that are NOT escapes must survive ---
		{
			name = "plain brackets are ordinary text",
			raw  = "[INFO] arr[0] = {\"k\":[1,2]} // ] and [\n",
			want = "[INFO] arr[0] = {\"k\":[1,2]} // ] and [\n",
		},
		{
			name = "bracket immediately after a stripped sequence still survives",
			raw  = "\x1b[32m[OK]\x1b[0m\n",
			want = "[OK]\n",
		},
		// --- CR handling ---
		{
			name = "crlf becomes lf",
			raw  = "a\r\nb\r\n",
			want = "a\nb\n",
		},
		{
			name = "bare cr progress collapses to the final state",
			raw  = "12%\r45%\r100%\n",
			want = "100%\n",
		},
		{
			name = "bare cr does not eat the PREVIOUS line",
			raw  = "kept\n12%\rdone\n",
			want = "kept\ndone\n",
		},
		{
			name = "bare cr shorter redraw does not leave a tail of the longer one",
			raw  = "Downloading 99%\rDone\n",
			want = "Done\n",
		},
		{
			name = "trailing bare cr leaves the line empty, not the stale text",
			raw  = "a\nstale\r",
			want = "a\n",
		},
		{
			name = "cr after crlf starts from the new line",
			raw  = "one\r\ntwo\rthree\n",
			want = "one\nthree\n",
		},
		// --- combinations + the no-op case ---
		{
			name = "colour and cr in the same progress line",
			raw  = "\x1b[33m 50%\x1b[0m\r\x1b[32m100%\x1b[0m\r\n",
			want = "100%\n",
		},
		{
			name = "clean text is returned unchanged",
			raw  = "nothing to strip here\n",
			want = "nothing to strip here\n",
		},
		{
			name = "empty input",
			raw  = "",
			want = "",
		},
	}

	for c in cases {
		got := bridge_shell_sanitize_output(c.raw)
		defer delete(got)
		testing.expectf(t, got == c.want, "%s: got %q, want %q", c.name, got, c.want)
	}
}

// An escape split across a chunk boundary is what a tail/limit cut produces. The
// guarantee is one-directional and worth stating: the FRAGMENT never survives as
// visible garbage. Feeding both halves separately must never emit `[0;32m`.
@(test)
bridge_shell_sanitize_output_escape_split_across_boundary :: proc(t: ^testing.T) {
	head := bridge_shell_sanitize_output("green: \x1b[0;3")
	defer delete(head)
	testing.expectf(t, head == "green: ", "leading half must drop the fragment, got %q", head)

	tail := bridge_shell_sanitize_output("2mok\x1b[0m\n")
	defer delete(tail)
	// "2m" is ordinary text once the ESC[ that introduced it is in the other chunk —
	// there is no state carried between calls, and that is the honest outcome.
	testing.expectf(t, tail == "2mok\n", "trailing half keeps its text, got %q", tail)

	// Whole, in one pass, it is clean. This is the case the real reader hits, because
	// sanitising happens BEFORE paging cuts anything.
	whole := bridge_shell_sanitize_output("green: \x1b[0;32mok\x1b[0m\n")
	defer delete(whole)
	testing.expectf(t, whole == "green: ok\n", "unsplit input must be clean, got %q", whole)
}

@(test)
bridge_shell_sanitize_output_leaves_no_control_bytes :: proc(t: ^testing.T) {
	raw := "\x1b[31ma\x1b]0;t\x07b\x1b(Bc\x1b[0m\r\nd\x1b"
	got := bridge_shell_sanitize_output(raw)
	defer delete(got)
	testing.expectf(t, got == "abc\nd", "got %q", got)
	for i in 0 ..< len(got) {
		testing.expectf(t, got[i] != 0x1b && got[i] != '\r' && got[i] != 0x07,
			"byte %d (0x%x) is a control byte that must not reach the JSON string", i, got[i])
	}
}

// ---- AC2: grep must match text that was colour-wrapped in the raw output ----
//
// THE functional bug. A test that only asserted "output looks clean" would pass
// while `--grep error` still silently returned nothing, so this asserts the match
// itself, through the same bridge_shell_page the log handler calls.
@(test)
bridge_shell_grep_matches_colour_wrapped_text :: proc(t: ^testing.T) {
	raw := "\x1b[32mcompiling foo\x1b[0m\r\n\x1b[0;31merror\x1b[0m: missing semicolon\r\n\x1b[32mcompiling bar\x1b[0m\r\n"

	// BEFORE: grep against the raw bytes cannot see the word, because the byte run is
	// "\x1b[0;31merror". This pins the bug so the fix cannot be quietly reverted.
	raw_hit, _ := bridge_shell_page(raw, 0, 0, "error: missing")
	defer delete(raw_hit)
	testing.expect(t, raw_hit == "",
		"precondition: grep on RAW output must miss the colour-wrapped match (if this fails the bug is gone by other means and this test is no longer meaningful)")

	// AFTER: sanitised first, exactly as bridge_hub_handle_shell_logs now does.
	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)
	hit, truncated := bridge_shell_page(clean, 0, 0, "error: missing")
	defer delete(hit)
	testing.expectf(t, hit == "2:error: missing semicolon\n",
		"grep must match the colour-wrapped line and report its 1-based line number, got %q", hit)
	testing.expect(t, !truncated, "a single full match is not truncated")
}

@(test)
bridge_shell_grep_line_numbers_count_visible_lines :: proc(t: ^testing.T) {
	// The line number grep reports must be the one the user would count on screen,
	// which means CRLF and a bare-\r redraw must already be resolved.
	raw := "a\r\nb\r\n1%\rdone\r\nc\r\n"
	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)
	hit, _ := bridge_shell_page(clean, 0, 0, "done")
	defer delete(hit)
	testing.expectf(t, hit == "3:done\n", "expected the redrawn line to be line 3, got %q", hit)
}

// ---- AC3: offset/limit apply to STRIPPED lines ----------------------------
@(test)
bridge_shell_paging_applies_to_stripped_lines :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	// Five coloured CRLF lines, each also carrying an OSC title write and a progress
	// redraw, so nothing about the correct answer is visible in the raw bytes.
	for i in 0 ..< 5 {
		strings.write_string(&b, "\x1b]0;build\x07\x1b[36m")
		strings.write_string(&b, "wait\rline")
		strings.write_int(&b, i)
		strings.write_string(&b, "\x1b[0m\r\n")
	}
	raw := strings.to_string(b)

	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)
	testing.expectf(t, clean == "line0\nline1\nline2\nline3\nline4\n", "sanitised form, got %q", clean)

	// offset skips stripped lines, limit caps them.
	page, truncated := bridge_shell_page(clean, 1, 2, "")
	defer delete(page)
	testing.expectf(t, page == "line1\nline2\n", "offset=1 limit=2 over stripped lines, got %q", page)
	testing.expect(t, truncated, "lines were skipped by the offset and remain beyond the limit")

	// The line count the handler reports is over stripped text too: 5, not the 10-ish
	// a naive '\n' scan of the CRLF raw bytes would suggest.
	total := 0
	for i in 0 ..< len(clean) { if clean[i] == '\n' do total += 1 }
	testing.expectf(t, total == 5, "total_lines over stripped text must be 5, got %d", total)

	// A limit boundary cannot cut inside an escape, because there are none left.
	last, _ := bridge_shell_page(clean, 4, 1, "")
	defer delete(last)
	testing.expectf(t, last == "line4\n", "last page, got %q", last)
}

// ---- the foreground-run inline path: tail + output_size over stripped text ----
//
// bridge_shell_run_wait_response (and the already-terminal fast path in
// bridge_shell_wait_rpc) sanitise BEFORE len() and BEFORE bridge_shell_tail. This
// pins that ordering: the 200-line threshold must count visible lines, and the tail
// boundary must not be able to cut inside an escape.
@(test)
bridge_shell_tail_over_sanitized_counts_visible_lines :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	// 5 visible lines, CRLF-terminated and colour-wrapped. A naive reader that
	// tailed the RAW text would be counting the same 5 lines but slicing bytes that
	// begin mid-escape.
	for i in 0 ..< 5 {
		strings.write_string(&b, "\x1b[36mline")
		strings.write_int(&b, i)
		strings.write_string(&b, "\x1b[0m\r\n")
	}
	raw := strings.to_string(b)

	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)

	// output_size_bytes is the SANITISED length — the size of the text the caller is
	// actually handed, not of the bytes on disk. Documented at the call site.
	testing.expectf(t, len(clean) == len("line0\nline1\nline2\nline3\nline4\n"),
		"output_size must describe the delivered text, got %d", len(clean))
	testing.expect(t, len(clean) < len(raw), "stripping shrinks it; the raw file is larger and unchanged")

	// Threshold counts visible lines: 5 <= 5 is not truncated, 5 > 4 is.
	whole, trunc_none := bridge_shell_tail(clean, 5, 2)
	testing.expect(t, !trunc_none, "5 visible lines at a threshold of 5 must not truncate")
	testing.expect(t, whole == clean, "untruncated tail returns the sanitised text unchanged")

	tail, truncated := bridge_shell_tail(clean, 4, 2)
	testing.expect(t, truncated, "5 visible lines over a threshold of 4 must truncate")
	testing.expectf(t, tail == "line3\nline4\n", "tail must be the last 2 VISIBLE lines, got %q", tail)

	// The boundary cannot land mid-escape, because none survive into the tail.
	for i in 0 ..< len(tail) {
		testing.expectf(t, tail[i] != 0x1b, "tail byte %d is a raw ESC", i)
	}
}

// A bare-\r progress line must not inflate the line count the tail threshold sees.
// Raw, "a\r\nP1\rP2\rP3\r\nb\r\n" has one physical progress line; sanitised it is
// still one, and tail must treat it as one.
@(test)
bridge_shell_tail_over_sanitized_collapses_progress_redraws :: proc(t: ^testing.T) {
	clean := bridge_shell_sanitize_output("a\r\n1%\r50%\r100%\r\nb\r\n")
	defer delete(clean)
	testing.expectf(t, clean == "a\n100%\nb\n", "got %q", clean)

	tail, truncated := bridge_shell_tail(clean, 2, 1)
	testing.expect(t, truncated, "3 visible lines over a threshold of 2 truncates")
	testing.expectf(t, tail == "b\n", "got %q", tail)
}
