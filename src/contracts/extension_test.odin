package contracts

import "core:testing"

@(test)
codex_context_tokens_subtracts_reasoning_and_clamps :: proc(t: ^testing.T) {
	testing.expect_value(t, codex_context_tokens(31000, 500), i64(30500))
	testing.expect_value(t, codex_context_tokens(31000, 0), i64(31000))
	testing.expect_value(t, codex_context_tokens(31000, -7), i64(31000))
	testing.expect_value(t, codex_context_tokens(100, 500), i64(0))
}
