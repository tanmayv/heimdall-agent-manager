package agent

import "core:testing"

@(test)
test_instance_probe_requires_bound_process_and_exit_evidence :: proc(t: ^testing.T) {
	accepted := parse_instance_probe(`{"command_id":"cmd","ok":true,"payload":{"result":{"agent_instance_id":"inst","state":"exited","pid":42,"exit_code":0}}}`, "cmd", "inst")
	testing.expect(t, accepted.state == .Exited && accepted.pid == 42 && accepted.exit_code == 0)
	for reply in ([]string{
		`{"command_id":"old","ok":true,"payload":{"result":{"agent_instance_id":"inst","state":"exited","pid":42,"exit_code":0}}}`,
		`{"command_id":"cmd","ok":true,"payload":{"result":{"agent_instance_id":"other","state":"exited","pid":42,"exit_code":0}}}`,
		`{"command_id":"cmd","ok":true,"payload":{"result":{"agent_instance_id":"inst","state":"exited","pid":42}}}`,
		`{"command_id":"cmd","ok":false,"payload":{"result":{"agent_instance_id":"inst","state":"exited","pid":42,"exit_code":0}}}`,
	}) {
		testing.expect_value(t, parse_instance_probe(reply, "cmd", "inst").state, Instance_Probe_State.Unknown)
	}
}
