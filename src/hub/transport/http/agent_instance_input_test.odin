package http

import "core:strings"
import "core:testing"

@(test)
test_json_string_unicode_escapes :: proc(t: ^testing.T) {
	body := `{"data":"hello\u0020world\u000a\u001b[31mred\u001b[0m"}`
	parsed := json_string(body, "data")
	defer delete(parsed)

	testing.expect_value(t, parsed, "hello world\n\x1b[31mred\x1b[0m")
}

@(test)
test_json_string_ctrl_c :: proc(t: ^testing.T) {
	body := `{"data":"\u0003"}`
	parsed := json_string(body, "data")
	defer delete(parsed)

	testing.expect_value(t, parsed, "\x03")
}
