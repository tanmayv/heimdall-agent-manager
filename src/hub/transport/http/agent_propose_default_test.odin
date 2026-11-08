package http

import "core:testing"

// F1: agent plan proposals auto-approve unless the caller opts in to a decision.
@(test)
test_agent_propose_auto_approves_by_default :: proc(t: ^testing.T) {
	testing.expect(t, agent_propose_auto_approve(`{"tasks":[]}`), "absent → auto-approve")
	testing.expect(t, agent_propose_auto_approve(`{"auto_approve":true}`), "explicit true")
	testing.expect(t, !agent_propose_auto_approve(`{"auto_approve":false}`), "explicit false keeps it pending")
	testing.expect(t, !agent_propose_auto_approve(`{"require_decision":true}`), "require_decision keeps it pending")
	testing.expect(t, !agent_propose_auto_approve(`{"require_decision":true,"auto_approve":true}`), "require_decision wins")
}
