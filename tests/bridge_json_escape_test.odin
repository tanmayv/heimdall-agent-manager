package bridge_json_escape_test

import "core:fmt"
import "core:strings"
import "core:testing"
import bridge "odin_test:bridge"

write_runtime :: proc(value: string) -> string {
	b := strings.builder_make()
	bridge.bridge_runtime_write_json_string(&b, value)
	return strings.to_string(b)
}

write_local :: proc(value: string) -> string {
	b := strings.builder_make()
	bridge.bridge_local_write_json_string(&b, value)
	return strings.to_string(b)
}

// Returns false if any raw byte < 0x20 appears outside a recognised escape.
json_string_valid :: proc(s: string) -> bool {
	i := 0
	for i < len(s) {
		b := s[i]
		if b == '\\' {
			i += 1
			if i >= len(s) do return false
			switch s[i] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				i += 1
			case 'u':
				if i + 4 >= len(s) do return false
				i += 5
			case:
				return false
			}
		} else if b < 32 {
			return false
		} else {
			i += 1
		}
	}
	return true
}

@(test)
test_ansi_escape_runtime :: proc(t: ^testing.T) {
	ansi := "\x1b[38;2;153;153;153mRan 2 shell commands\x1b[0m\n"
	r := write_runtime(ansi)
	testing.expect(t, strings.contains(r, "\\u001b"), "runtime: ESC must be escaped as \\u001b")
	testing.expect(t, !strings.contains(r, "\x1b"), "runtime: raw ESC byte must not appear")
	testing.expect(t, json_string_valid(r), fmt.tprintf("runtime: output contains raw control byte: %q", r))
}

@(test)
test_ansi_escape_local :: proc(t: ^testing.T) {
	ansi := "\x1b[38;2;153;153;153mRan 2 shell commands\x1b[0m\n"
	l := write_local(ansi)
	testing.expect(t, strings.contains(l, "\\u001b"), "local: ESC must be escaped as \\u001b")
	testing.expect(t, !strings.contains(l, "\x1b"), "local: raw ESC byte must not appear")
	testing.expect(t, json_string_valid(l), fmt.tprintf("local: output contains raw control byte: %q", l))
}

@(test)
test_null_byte_runtime :: proc(t: ^testing.T) {
	s := "\x00abc"
	r := write_runtime(s)
	testing.expect(t, strings.contains(r, "\\u0000"), "runtime: null byte must become \\u0000")
	testing.expect(t, json_string_valid(r), "runtime: null byte output must be valid")
}

@(test)
test_null_byte_local :: proc(t: ^testing.T) {
	s := "\x00abc"
	l := write_local(s)
	testing.expect(t, strings.contains(l, "\\u0000"), "local: null byte must become \\u0000")
	testing.expect(t, json_string_valid(l), "local: null byte output must be valid")
}

@(test)
test_standard_escapes_runtime :: proc(t: ^testing.T) {
	s := "line1\nline2\r\ttab"
	r := write_runtime(s)
	testing.expect(t, strings.contains(r, "\\n"), "runtime: newline must use \\n")
	testing.expect(t, strings.contains(r, "\\r"), "runtime: CR must use \\r")
	testing.expect(t, strings.contains(r, "\\t"), "runtime: tab must use \\t")
	testing.expect(t, json_string_valid(r), "runtime: standard escapes output must be valid")
}

@(test)
test_standard_escapes_local :: proc(t: ^testing.T) {
	s := "line1\nline2\r\ttab"
	l := write_local(s)
	testing.expect(t, strings.contains(l, "\\n"), "local: newline must use \\n")
	testing.expect(t, strings.contains(l, "\\r"), "local: CR must use \\r")
	testing.expect(t, strings.contains(l, "\\t"), "local: tab must use \\t")
	testing.expect(t, json_string_valid(l), "local: standard escapes output must be valid")
}

@(test)
test_quotes_and_backslash :: proc(t: ^testing.T) {
	s := `say "hello" \ world`
	r := write_runtime(s)
	testing.expect(t, strings.contains(r, "\\\""), "runtime: quote must be escaped")
	testing.expect(t, strings.contains(r, "\\\\"), "runtime: backslash must be escaped")
	testing.expect(t, json_string_valid(r), "runtime: quote/backslash output must be valid")

	l := write_local(s)
	testing.expect(t, strings.contains(l, "\\\""), "local: quote must be escaped")
	testing.expect(t, strings.contains(l, "\\\\"), "local: backslash must be escaped")
	testing.expect(t, json_string_valid(l), "local: quote/backslash output must be valid")
}

@(test)
test_other_control_chars :: proc(t: ^testing.T) {
	s := "\x07\x08\x0c"
	r := write_runtime(s)
	testing.expect(t, strings.contains(r, "\\u0007"), "runtime: BEL must be \\u0007")
	testing.expect(t, strings.contains(r, "\\u0008"), "runtime: BS must be \\u0008")
	testing.expect(t, strings.contains(r, "\\u000c"), "runtime: FF must be \\u000c")
	testing.expect(t, json_string_valid(r), "runtime: other control chars output must be valid")

	l := write_local(s)
	testing.expect(t, strings.contains(l, "\\u0007"), "local: BEL must be \\u0007")
	testing.expect(t, strings.contains(l, "\\u0008"), "local: BS must be \\u0008")
	testing.expect(t, strings.contains(l, "\\u000c"), "local: FF must be \\u000c")
	testing.expect(t, json_string_valid(l), "local: other control chars output must be valid")
}
