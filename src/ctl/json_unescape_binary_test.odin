package main

import "core:strings"
import "core:testing"

// Regression coverage for the binary-artifact download corruption.
//
// The Hub escaper (contracts.write_json_string) walks BYTES: it emits \" \\ \n
// \r \t and \u00xx for every byte < 0x20, and passes every byte >= 0x20 through
// verbatim. ham-ctl's unescaper had no \u case, so its default branch wrote the
// 'u' and left "001a" as literal text — every control byte in a PNG became five
// junk bytes and the file would not open. These tests pin the byte-for-byte
// round trip through that exact escaping, plus the standard JSON escapes.

// hub_escape mirrors contracts.write_json_string so the tests exercise the real
// producer's output shape rather than a hand-written approximation.
hub_escape :: proc(value: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(value) {
		ch := value[i]
		switch ch {
		case '"': strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case '\t': strings.write_string(&b, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(&b, "\\u00")
				strings.write_byte(&b, hex_digit(ch >> 4))
				strings.write_byte(&b, hex_digit(ch & 0x0f))
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	return strings.to_string(b)
}

hex_digit :: proc(v: u8) -> u8 {
	if v < 10 do return '0' + v
	return 'a' + (v - 10)
}

@(test)
test_unescape_decodes_unicode_escape_to_one_byte :: proc(t: ^testing.T) {
	// The exact byte that broke the user's PNG: 0x1A arrived as "u001a".
	got := json_unescape_string("\\u001a")
	testing.expect(t, got == "\x1a", got)
}

@(test)
test_unescape_round_trips_png_signature :: proc(t: ^testing.T) {
	signature := "\x89PNG\r\n\x1a\n"
	got := json_unescape_string(hub_escape(signature))
	testing.expect(t, got == signature, "PNG signature must survive byte-for-byte")
}

@(test)
test_unescape_round_trips_every_byte_value :: proc(t: ^testing.T) {
	// 0x00..0xFF, NUL and the high bytes included: this is the whole claim.
	all := strings.builder_make()
	for v in 0 ..< 256 do strings.write_byte(&all, u8(v))
	original := strings.to_string(all)
	got := json_unescape_string(hub_escape(original))
	testing.expect(t, len(got) == 256, "every byte must round-trip exactly once")
	for v in 0 ..< 256 {
		if got[v] != u8(v) {
			testing.expectf(t, false, "byte %d came back as %d", v, got[v])
			return
		}
	}
}

@(test)
test_unescape_keeps_standard_escapes :: proc(t: ^testing.T) {
	got := json_unescape_string("a\\nb\\tc\\\"d\\\\e\\/f\\bg\\fh")
	testing.expect(t, got == "a\nb\tc\"d\\e/f\bg\fh", got)
}

@(test)
test_unescape_text_content_is_unchanged :: proc(t: ^testing.T) {
	// A text artifact must not be broken by the binary fix.
	text := "# Title\n\nA line with \"quotes\", a tab\there, and UTF-8: héllo ✓\n"
	got := json_unescape_string(hub_escape(text))
	testing.expect(t, got == text, got)
}

@(test)
test_unescape_decodes_multibyte_codepoint_as_utf8 :: proc(t: ^testing.T) {
	// A \u escape above 0x7F follows JSON semantics (codepoint -> UTF-8).
	testing.expect(t, json_unescape_string("\\u00e9") == "é", "U+00E9")
	testing.expect(t, json_unescape_string("\\u2713") == "✓", "U+2713")
}

@(test)
test_unescape_joins_surrogate_pair :: proc(t: ^testing.T) {
	got := json_unescape_string("\\ud83d\\ude00")
	testing.expect(t, got == "\U0001F600", got)
}

@(test)
test_unescape_leaves_malformed_escape_alone :: proc(t: ^testing.T) {
	// Truncated / non-hex escapes must not invent bytes or drop input.
	testing.expect(t, json_unescape_string("\\u00") == "u00", "truncated escape")
	testing.expect(t, json_unescape_string("\\uzzzz") == "uzzzz", "non-hex escape")
	testing.expect(t, json_unescape_string("\\ud83d") == "ud83d", "lone high surrogate")
}
