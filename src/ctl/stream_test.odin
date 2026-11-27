package main

import "core:testing"

// Feed actual CLI argv through the same generic tokenizer as main before
// dispatching the remainder to the stream-specific parser.
@(test)
test_stream_argv_keeps_source_flags_via_option_accessor :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, argv: []string, want_method, want_key, want_value: string) {
		cmd := command_tokens(argv)
		defer delete(cmd)
		method, key, value := ctl_stream_parse(cmd[1:], argv)
		testing.expect_value(t, method, want_method)
		testing.expect_value(t, key, want_key)
		testing.expect_value(t, value, want_value)
	}
	check(t, {"ham-ctl", "stream", "share", "--tab", "AB123"}, "agent.stream.share", "tab", "AB123")
	check(t, {"ham-ctl", "stream", "list", "--sources", "tabs"}, "agent.stream.list", "sources", "tabs")
	check(t, {"ham-ctl", "stream", "share", "AB123"}, "", "", "")
	check(t, {"ham-ctl", "stream", "list", "tabs"}, "", "", "")
}
