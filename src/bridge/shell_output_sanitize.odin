package main

import "core:strings"

// ---- read-time output sanitisation (REQ-SHELL-27) -------------------------
//
// A run/server/shell is spawned under a PTY, so its tee'd output carries what a
// TERMINAL was meant to consume, not what a reader wants: SGR colour codes,
// cursor moves, OSC title writes, and `\r\n` line endings. `shell log` hands that
// text to a JSON array of lines. Nobody renders that array into a terminal, so the
// escapes are pure noise there — and worse than noise, because `--grep error`
// cannot match an "error" that the compiler wrapped in red.
//
// WHY READ-TIME AND NOT CAPTURE-TIME. Stripping into the tee file would be
// destructive and irreversible: that same file is what retention serves for five
// days and what a future reader may legitimately want byte-exact. So this is a
// transform applied to a COPY on the way out; the bytes on disk never change.
//
// WHY NOT ON THE INTERACTIVE PATH. The live terminal is served by different
// commands entirely (`shell_capture`, `shell_get_pane`). There the escapes ARE the
// payload and stripping them would break the pane. Nothing in this file is reachable
// from those; see the header on bridge_shell_sanitize_output.

// bridge_shell_sanitize_output removes terminal control sequences from `raw` and
// normalises line endings, returning a freshly allocated string the caller owns.
//
// It is deliberately PURE — a string in, a string out, no globals, no filesystem,
// no PTY — so the whole of REQ-SHELL-27's behaviour is unit-testable without a
// bridge running. The only caller is bridge_hub_handle_shell_logs, which applies it
// to the text read back off disk BEFORE grep and BEFORE offset/limit paging.
//
// WHAT IT REMOVES
//   CSI   ESC [ <params...> <final byte in @..~>   — colour/SGR, cursor moves, erases.
//   OSC   ESC ] <payload> <BEL | ESC \>            — window/tab title writes, common
//                                                    in build and test output.
//   other ESC <intermediates 0x20-0x2F> <final 0x30-0x7E>
//                                                  — charset select ESC(B, ESC)0, ESC#8,
//                                                    and the no-intermediate ESC=, ESC>,
//                                                    ESC7, ESC8. NOTE ESC(B is THREE bytes;
//                                                    a "drop two" shortcut leaks the final
//                                                    byte as text (caught by the tests).
//   a trailing/unterminated ESC                    — dropped rather than emitted, so a
//                                                    truncated sequence can never leak a
//                                                    raw control byte into the JSON string.
//
// An UNTERMINATED CSI or OSC (the escape ran off the end of the text, which is what a
// tail/limit boundary landing mid-sequence produces) consumes to the end and emits
// nothing. That is the point of stripping before paging: the fragment is dropped
// instead of being printed as `[0;32m`.
//
// `[` and `]` that are NOT preceded by ESC are ordinary text and survive untouched —
// array indices, `[INFO]` log tags, JSON — which is most of what a log line is.
//
// CARRIAGE RETURNS
//   \r\n            -> \n   (PTY line endings; the normal case)
//   bare \r         -> the line so far is DISCARDED.
// The bare-\r rule is a DECISION, stated here because the task required one to be
// stated. A bare \r is in-place progress rendering (npm, cargo, pip: "12%\r45%\r100%\n").
// Discarding the line so far collapses it to its FINAL state, which is what the user
// actually saw on the terminal and the only part with any information left in it.
// We do NOT emulate column-wise overwrite (where a shorter redraw leaves the tail of a
// longer previous one visible, "Downloading 99%" + \r + "Done" -> "Doneoading 99%").
// That is technically what a real terminal shows, but it manufactures words that were
// never in the output and it would make grep match them — exactly the class of
// wrong answer this task exists to remove. Discard is lossy in the same direction the
// user's own eyes were.
bridge_shell_sanitize_output :: proc(raw: string) -> string {
	b := strings.builder_make()
	// line_start tracks where the CURRENT output line begins inside the builder, so a
	// bare \r can rewind to it. Resetting to the line start (rather than buffering a
	// line and flushing it) keeps this a single pass with no second allocation.
	line_start := 0

	i := 0
	for i < len(raw) {
		c := raw[i]

		switch c {
		case 0x1b: // ESC
			if i + 1 >= len(raw) {
				// Trailing lone ESC: drop it. Emitting it would put a raw control
				// byte in the JSON string for no reader's benefit.
				i = len(raw)
				continue
			}
			switch raw[i + 1] {
			case '[': // CSI: parameters, then a final byte in @..~
				j := i + 2
				for j < len(raw) && !(raw[j] >= '@' && raw[j] <= '~') do j += 1
				// j == len(raw) means unterminated -> consume the remainder, emit nothing.
				i = j + 1 if j < len(raw) else len(raw)
			case ']': // OSC: payload terminated by BEL or ST (ESC \)
				j := i + 2
				for j < len(raw) {
					if raw[j] == 0x07 { // BEL
						j += 1
						break
					}
					if raw[j] == 0x1b && j + 1 < len(raw) && raw[j + 1] == '\\' { // ST
						j += 2
						break
					}
					j += 1
				}
				i = j
			case:
				// Every other escape: zero or more INTERMEDIATE bytes (0x20-0x2F),
				// then one FINAL byte (0x30-0x7E). Getting this right matters — the
				// common charset-select `ESC ( B` is THREE bytes, not two, and a
				// blanket "drop two" leaves a stray `B` in the middle of the text.
				// This form also covers ESC)0, ESC#8 and the two-byte ESC=, ESC>,
				// ESC7, ESC8 (no intermediates, final byte immediately).
				j := i + 1
				for j < len(raw) && raw[j] >= 0x20 && raw[j] <= 0x2f do j += 1
				// Consume the final byte when it is present and in range. Anything
				// else (text ran out, or a byte outside the grammar) consumes only
				// what we have scanned, so a non-escape byte is never eaten.
				if j < len(raw) && raw[j] >= 0x30 && raw[j] <= 0x7e do j += 1
				i = j
			}

		case '\r':
			if i + 1 < len(raw) && raw[i + 1] == '\n' {
				// CRLF -> LF. The newline is written here and the pair consumed
				// together, so the \n cannot be re-read as a fresh line ending.
				strings.write_byte(&b, '\n')
				i += 2
				line_start = len(b.buf)
			} else {
				// Bare \r: rewind to the start of this line. See the header.
				resize(&b.buf, line_start)
				i += 1
			}

		case '\n':
			strings.write_byte(&b, '\n')
			i += 1
			line_start = len(b.buf)

		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}

	return strings.to_string(b)
}
