package main

import "core:testing"

@(test)
test_instance_probe_observes_only_named_pty_process :: proc(t: ^testing.T) {
	children := [?]Pty_Host_Agent_Info{
		{instance_id = "inst_live", pid = 42, alive = true},
		{instance_id = "inst_exited", pid = 43, has_exit_code = true, exit_code = 0},
		{instance_id = "inst_unverified", pid = 44, has_exit_code = false},
	}
	roster := Pty_Host_Reply{kind = .Agent_List, agents = children[:]}
	live := bridge_instance_probe_from_roster("inst_live", roster)
	testing.expect(t, live.state == "alive" && live.pid == 42)
	exited := bridge_instance_probe_from_roster("inst_exited", roster)
	code, known := exited.exit_code.?
	testing.expect(t, exited.state == "exited" && exited.pid == 43 && known && code == 0)
	testing.expect_value(t, bridge_instance_probe_from_roster("inst_unverified", roster).state, "unknown")
	testing.expect_value(t, bridge_instance_probe_from_roster("inst_missing", roster).state, "absent")
	testing.expect_value(t, bridge_instance_probe_from_roster("inst_live", {}).state, "unknown")
}
