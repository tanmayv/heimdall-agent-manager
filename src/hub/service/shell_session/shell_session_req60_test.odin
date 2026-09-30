package shell_session

// REQ-SHELL-60 — _json_str dropped every '\u' escape.
//
// The bridge encodes a captured screen as correct JSON: an ESC byte goes on the wire as
// the six characters \ u 0 0 1 b. _json_str's escape switch had cases for n, r, t, " and
// \, and a default that wrote the escaped character verbatim — so 'u' hit the default and
// was written as a LITERAL 'u', after which 0,0,1,b were consumed as ordinary text. Every
// ESC therefore arrived as the 5-character string `u001b`.
//
// The user-visible effect was on `ham-ctl shell capture`: a full-screen program's output is
// mostly escape sequences, so a capture came back as visible garbage instead of a screen.
// (Both LIVE pane routes decode through json_string_unescaped, which always had the 'u'
// case — this was a capture-path defect only.)
//
// Every assertion below FAILS with the 'u' case removed from _json_str; that mutation was
// run, not assumed.

import "core:strings"
import "core:testing"

// The exact reproduction from the field, reduced to one byte: the six characters
// backslash-u-0-0-1-b must decode to a single 0x1b, and to NOTHING else.
@(test)
req60_json_str_decodes_unicode_escape_to_one_esc_byte :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"\u001b"}`, "content")
	defer delete(got)

	testing.expectf(t, len(got) == 1, "expected exactly 1 byte, got %d (%q)", len(got), got)
	testing.expectf(
		t,
		len(got) == 1 && got[0] == 0x1b,
		"expected the single byte 0x1b, got %q",
		got,
	)
	// The pre-fix output, named so a regression is unmistakable rather than just "not 1b".
	testing.expectf(t, got != "u001b", "got the pre-fix literal text `u001b` back: %q", got)
}

// The real payload shape: a colour sequence around some text. This is the assertion that
// speaks to the symptom — zero literal `u001b`, and the ESCs back where they belong.
@(test)
req60_json_str_decodes_a_full_colour_sequence :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"\u001b[31mREDTEXT\u001b[0m\r\n"}`, "content")
	defer delete(got)

	testing.expectf(
		t,
		got == "\x1b[31mREDTEXT\x1b[0m\r\n",
		"decoded payload is wrong: %q",
		got,
	)
	testing.expectf(
		t,
		strings.count(got, "u001b") == 0,
		"found literal `u001b` in the decoded payload: %q",
		got,
	)
	testing.expectf(
		t,
		strings.count(got, "\x1b") == 2,
		"expected 2 real ESC bytes, got %d: %q",
		strings.count(got, "\x1b"),
		got,
	)
}

// The other three call sites take bridge ERROR strings, which were corrupted the same way.
// One proc, so they are fixed together — this pins that it is the shared proc under test
// and not the "content" key specifically.
@(test)
req60_json_str_decodes_escapes_in_an_error_string :: proc(t: ^testing.T) {
	got := _json_str(`{"ok":false,"error":"spawn failed: \u001b[1mbad\u001b[0m"}`, "error")
	defer delete(got)

	testing.expectf(
		t,
		got == "spawn failed: \x1b[1mbad\x1b[0m",
		"decoded error string is wrong: %q",
		got,
	)
}

// Non-ASCII goes through write_rune, matching json_string_unescaped exactly. Pinned so the
// two unescapers cannot silently diverge on the same input.
@(test)
req60_json_str_decodes_a_non_ascii_escape_as_a_rune :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"caf\u00e9"}`, "content")
	defer delete(got)

	testing.expectf(t, got == "café", "expected `café`, got %q", got)
}

// The escapes that already worked must keep working — a guard against the new case
// swallowing its neighbours.
@(test)
req60_json_str_still_decodes_the_simple_escapes :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"a\nb\tc\"d\\e\rf"}`, "content")
	defer delete(got)

	testing.expectf(t, got == "a\nb\tc\"d\\e\rf", "simple escapes regressed: %q", got)
}

// A MALFORMED \u must not read past the value or drop the rest of the string. The fallback
// is the reference implementation's: write a literal 'u' and carry on.
//
// BOTH cases below take the PARSE-FAILURE fallback, not the length guard - checked, not
// assumed. For `\u01"}` the guard `i + 4 < len(rest)` is still TRUE (i=2, len=7), so the
// four characters grabbed are `01"}` and it is parse_int that rejects them. The length
// guard itself is only reachable on an UNTERMINATED string, which _json_str already
// rejects by returning "" when it falls out of the loop, so it has no observable output
// of its own to assert on.
@(test)
req60_json_str_falls_back_on_a_malformed_unicode_escape :: proc(t: ^testing.T) {
	// 'zz' are not hex digits, so parse_int fails.
	bad_hex := _json_str(`{"content":"\u00zzTAIL"}`, "content")
	defer delete(bad_hex)
	testing.expectf(t, bad_hex == "u00zzTAIL", "bad-hex fallback is wrong: %q", bad_hex)

	// A short escape: the 4 characters read are `01"}`, which parse_int also rejects.
	truncated := _json_str(`{"content":"\u01"}`, "content")
	defer delete(truncated)
	testing.expectf(t, truncated == "u01", "truncated fallback is wrong: %q", truncated)
}
