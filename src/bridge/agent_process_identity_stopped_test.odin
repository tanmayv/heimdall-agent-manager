#+build linux
package main

import "core:testing"

// Regression: a cleanly stopped instance has no recorded process identity.
// With no process carrying its id, roster loss is confirmed so it can start.
@(test)
test_roster_loss_confirmed_for_stopped_instance_without_identity :: proc(t: ^testing.T) {
	id := "inst_hotfix_never_ran_0000000000"
	found, _, scanned := bridge_agent_process_find_by_instance(id)
	testing.expect(t, scanned, "proc scan works")
	testing.expect(t, !found, "no process carries the id")
	testing.expect(t, bridge_agent_roster_loss_confirmed(id, 3), "stopped instance is startable")
	state, _, _ := bridge_agent_process_after_roster_loss(id, 3, false)
	testing.expect_value(t, state, Bridge_Agent_Process_State.Gone)
}

@(test)
test_agent_environ_has_matches_exact_entries :: proc(t: ^testing.T) {
	env := "A=1\x00HEIMDALL_AGENT_INSTANCE_ID=inst_x\x00B=2\x00"
	testing.expect(t, bridge_agent_environ_has(env, "HEIMDALL_AGENT_INSTANCE_ID=inst_x"), "exact entry")
	testing.expect(t, !bridge_agent_environ_has(env, "HEIMDALL_AGENT_INSTANCE_ID=inst"), "no prefix match")
	testing.expect(t, !bridge_agent_environ_has("HEIMDALL_AGENT_INSTANCE_ID=inst_xy\x00", "HEIMDALL_AGENT_INSTANCE_ID=inst_x"), "no longer-id match")
	testing.expect(t, bridge_agent_environ_has("HEIMDALL_AGENT_INSTANCE_ID=inst_x", "HEIMDALL_AGENT_INSTANCE_ID=inst_x"), "unterminated last entry")
}
