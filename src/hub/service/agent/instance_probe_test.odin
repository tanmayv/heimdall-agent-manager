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

@(test)
test_confirmed_stop_receipt_is_fenced_by_operation_and_pid :: proc(t: ^testing.T) {
	reply := `{"command_id":"op","ok":true,"payload":{"status":"succeeded","result":{"runtime_status":"stopped","agent_instance_id":"inst","expected_process_pid":42}}}`
	testing.expect(t, confirmed_stop_receipt(reply, "op", "inst", 42))
	testing.expect(t, !confirmed_stop_receipt(reply, "old", "inst", 42))
	testing.expect(t, !confirmed_stop_receipt(reply, "op", "other", 42))
	testing.expect(t, !confirmed_stop_receipt(reply, "op", "inst", 43))
	testing.expect(t, !confirmed_stop_receipt(`{"command_id":"op","ok":true,"payload":{"status":"accepted"}}`, "op", "inst", 42))
}

@(test)
test_instance_probe_distinguishes_absence_and_orphan_from_unproven_loss :: proc(t: ^testing.T) {
	raw := `{"command_id":"cmd","ok":true,"payload":{"result":{"agent_instance_id":"inst","state":"absent","source":"os_identity_gone","pid":0,"run_count":3,"launch_epoch":"epoch"}}}`
	testing.expect_value(t, parse_instance_probe(raw, "cmd", "inst", 3, "epoch").state, Instance_Probe_State.Absent)
	testing.expect_value(t, parse_instance_probe(raw, "cmd", "inst", 4, "epoch").state, Instance_Probe_State.Unknown)
	testing.expect_value(t, parse_instance_probe(raw, "cmd", "inst", 3, "old").state, Instance_Probe_State.Unknown)
	unproven := `{"command_id":"cmd","ok":true,"payload":{"result":{"agent_instance_id":"inst","state":"absent","pid":0,"run_count":3,"launch_epoch":"epoch"}}}`
	testing.expect_value(t, parse_instance_probe(unproven, "cmd", "inst", 3, "epoch").state, Instance_Probe_State.Unknown)
	orphan := parse_instance_probe(`{"command_id":"cmd","ok":true,"payload":{"result":{"agent_instance_id":"inst","state":"exited","source":"orphan_reaped","pid":42,"run_count":3,"launch_epoch":"epoch"}}}`, "cmd", "inst", 3, "epoch")
	testing.expect(t, orphan.state == .Exited && orphan.orphan_reaped && orphan.pid == 42)
}

@(test)
test_launch_absence_is_only_accepted_for_the_requested_generation :: proc(t: ^testing.T) {
	raw := `{"command_id":"cmd","ok":true,"payload":{"result":{"agent_instance_id":"inst","state":"absent","source":"launch_absence","pid":0,"run_count":3,"launch_epoch":"epoch"}}}`
	valid := parse_instance_probe(raw, "cmd", "inst", 3, "epoch", for_launch = true)
	testing.expect(t, valid.state == .Absent && valid.launch_absence)
	testing.expect_value(t, parse_instance_probe(raw, "cmd", "inst", 3, "epoch").state, Instance_Probe_State.Unknown)
	testing.expect_value(t, parse_instance_probe(raw, "cmd", "inst", 4, "epoch", for_launch = true).state, Instance_Probe_State.Unknown)
	testing.expect_value(t, parse_instance_probe(raw, "cmd", "inst", 3, "old", for_launch = true).state, Instance_Probe_State.Unknown)
	testing.expect_value(t, parse_instance_probe(raw, "cmd", "inst", for_launch = true).state, Instance_Probe_State.Unknown)
}
