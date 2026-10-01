package shell_session

// REQ-JSON-1..5 — _json_array_raw must extract a JSON array value without being
// fooled by the contents of string literals.
//
// Its only caller is shell_session_get_log, which runs it over the bridge reply's
// "lines" array — i.e. over ARBITRARY PROCESS STDOUT. A bracket-counting extractor
// desynchronises on any log line carrying an unbalanced bracket, and a plain
// strings.index key scan matches a `"lines":` that is really part of a value. Both
// failures are silent: a plausible-looking wrong span, never an error.
//
// Every case below asserts the WHOLE extracted span, not its length — a length check
// would pass on a wrong-but-same-size slice. Bodies are raw (backtick) literals, so
// every backslash and quote in them is the byte the bridge would actually emit.
//
//   REQ-JSON-1 bracket inside a string value does not move depth
//              -> tjson_lone_close_bracket_in_a_line / tjson_lone_open_bracket_in_a_line
//   REQ-JSON-2 escaped quote does not close the string
//              -> tjson_escaped_quote_does_not_end_the_string
//   REQ-JSON-3 the key scan is the package's one string-aware scan
//              -> tjson_lines_decoy_before_the_real_key
//   REQ-JSON-4 the span is inclusive of the closing ']' and heap-allocated
//              -> asserted by every case (all defer delete)
//   REQ-JSON-5 absent key / non-array value / unterminated array all fall back to "[]"
//              -> tjson_fallbacks_return_an_empty_array

import "core:testing"

// A pretty-printed JSON array in the captured output puts a lone `]` on its own line.
// This is the case that is broken today: the bracket counter reaches depth 0 on it and
// returns a truncated span.
@(test)
tjson_lone_close_bracket_in_a_line :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["a ] b","plain","tail"],"truncated":false,"total_lines":3}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["a ] b","plain","tail"]`)
}

// The mirror case: a truncated line ending in `[` leaves depth permanently above 0, so
// the extractor never finds its terminator and silently yields "[]".
@(test)
tjson_lone_open_bracket_in_a_line :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["c [ d","tail"],"truncated":false,"total_lines":2}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["c [ d","tail"]`)
}

// `\"` is one escaped quote, not the end of the value — so the `]` and `[` that follow
// it are still inside the string and must not touch depth. Treating the escape as a
// terminator is the same silent truncation by a different route.
@(test)
tjson_escaped_quote_does_not_end_the_string :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["say \"hi\" ] then [ bye","tail"],"truncated":false}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["say \"hi\" ] then [ bye","tail"]`)
}

// A value carrying the literal text `"lines":` BEFORE the real field. A scan that does
// not track string state matches the decoy and extracts the decoy's `[999]`.
@(test)
tjson_lines_decoy_before_the_real_key :: proc(t: ^testing.T) {
	body := `{"ok":true,"cmd":"echo \"lines\":[999] > f","lines":["real","tail"],"truncated":false}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["real","tail"]`)
}

// The same decoy in its realistic, properly escaped form — as the bridge's JSON string
// writer would emit it from a log line that printed `"lines":`.
@(test)
tjson_escaped_lines_decoy_inside_a_value :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["not a \"lines\": decoy","tail"],"truncated":false}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["not a \"lines\": decoy","tail"]`)
}

// REQ-JSON-5. All three degenerate inputs yield a heap-allocated "[]" rather than an
// error or an empty string, because the caller owns and deletes the result either way.
@(test)
tjson_fallbacks_return_an_empty_array :: proc(t: ^testing.T) {
	absent := _json_array_raw(`{"ok":true,"truncated":false,"total_lines":0}`, "lines")
	defer delete(absent)
	testing.expect_value(t, absent, "[]")

	not_an_array := _json_array_raw(`{"ok":true,"lines":"nope","truncated":false}`, "lines")
	defer delete(not_an_array)
	testing.expect_value(t, not_an_array, "[]")

	unterminated := _json_array_raw(`{"ok":true,"lines":["a","b"`, "lines")
	defer delete(unterminated)
	testing.expect_value(t, unterminated, "[]")
}
