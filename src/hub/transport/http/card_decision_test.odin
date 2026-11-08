package http

import "core:testing"

@(test)
test_card_decision_preserves_selected_worker_and_displayed_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // request-scoped strings in production
	decision := card_decision_from_body(`{"expected_block":"failure_observed","replacement_agent_id":"agt_selected"}`)
	testing.expect_value(t, decision.expected_block, "failure_observed")
	testing.expect_value(t, decision.replacement_agent_id, "agt_selected")
	plain := card_decision_from_body(`{"note":"answer"}`)
	testing.expect_value(t, plain.note, "answer")
	testing.expect_value(t, plain.replacement_agent_id, "")
}
