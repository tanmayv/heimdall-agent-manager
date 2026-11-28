package contracts

import "core:testing"

@(test)
codex_context_tokens_subtracts_reasoning_and_clamps :: proc(t: ^testing.T) {
	testing.expect_value(t, codex_context_tokens(31000, 500), i64(30500))
	testing.expect_value(t, codex_context_tokens(31000, 0), i64(31000))
	testing.expect_value(t, codex_context_tokens(31000, -7), i64(31000))
	testing.expect_value(t, codex_context_tokens(100, 500), i64(0))
}

// Every capability has a distinct, non-empty wire name (the hello vocabulary).
@(test)
ext_capability_names_are_distinct :: proc(t: ^testing.T) {
	seen: map[string]bool
	defer delete(seen)
	for c in Ext_Capability {
		name := ext_capability_name(c)
		testing.expectf(t, name != "", "%v has no wire name", c)
		testing.expectf(t, !seen[name], "%v reuses %q", c, name)
		seen[name] = true
	}
	testing.expect_value(t, ext_capability_name(.Usage), "usage")
}
