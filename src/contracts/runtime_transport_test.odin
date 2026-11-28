package contracts

import "core:testing"

// Send now's needs are runtime data: every valid transport declares them, and
// an unknown transport supports nothing.
@(test)
runtime_transport_capabilities_declare_send_now :: proc(t: ^testing.T) {
	testing.expect(t, runtime_transport_capabilities("acp").send_now == .Members, "ACP delivers bodies: explicit members")
	testing.expect(t, runtime_transport_capabilities("pty").send_now == .Notice, "PTY reads its conversation: no members")
	testing.expect(t, runtime_transport_capabilities("tmux").send_now == .Unsupported)
	testing.expect(t, runtime_transport_capabilities("").send_now == .Unsupported)
	for name in ([]string{"pty", "acp"}) {
		testing.expect(t, runtime_transport_valid(name) && runtime_transport_capabilities(name).send_now != .Unsupported, name)
	}
	testing.expect_value(t, RUNTIME_SEND_NOW_WIRE[.Members], "members")
	testing.expect_value(t, RUNTIME_SEND_NOW_WIRE[.Notice], "notice")
}

// Every Send now outcome but Delivered has a cause the Hub maps back, and a
// batch error; Failed is the fallback for an unknown cause.
@(test)
runtime_send_now_outcomes_round_trip_through_their_cause :: proc(t: ^testing.T) {
	for o in Runtime_Send_Now_Outcome {
		if o == .Delivered do continue
		testing.expect(t, RUNTIME_SEND_NOW_CAUSE[o] != "" && RUNTIME_SEND_NOW_BATCH_ERROR[o] != "")
		testing.expect(t, runtime_send_now_outcome_from_cause(RUNTIME_SEND_NOW_CAUSE[o]) == o)
	}
	testing.expect(t, runtime_send_now_outcome_from_cause("something_else") == .Failed)
	testing.expect(t, runtime_send_now_outcome_from_cause("") == .Failed)
	testing.expect(t, runtime_send_now_outcome_queued(.Held))
	testing.expect(t, !runtime_send_now_outcome_queued(.Not_Running) && !runtime_send_now_outcome_queued(.Failed))
	testing.expect_value(t, RUNTIME_SEND_NOW_BATCH_ERROR[.Not_Running], "agent_stopped")
}
