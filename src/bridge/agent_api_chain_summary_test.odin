package main

// REQ-OVF-3: `task-chain summary get` reaches a READ-ONLY hub action; the write
// methods keep their own route. Both default to the caller's chain hub-side.

import "core:testing"

@(test)
bridge_task_chain_get_summary_routes_read_only_envelope :: proc(t: ^testing.T) {
	for params in ([]string{"{}", `{"chain_id":"chain_abc"}`}) {
		r := bridge_agent_route("agent.task_chain.get_summary", params)
		testing.expect(t, r.kind == .Envelope, "get_summary is an agent-actions envelope")
		testing.expect_value(t, bridge_agent_route_target(r), "/api/v1/agent-actions/chain/summary/get")
	}
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.get_summary"), "get_summary is in the agent method allowlist")
	testing.expect(t, bridge_local_method_allowed("agent.task_chain.get_summary", .Agent), "agent tokens may read the summary")
	testing.expect(t, !bridge_local_method_allowed("agent.task_chain.get_summary", .Wrapper), "wrapper tokens may not")

	// The write methods are unchanged and never route to the read action.
	for m in ([]string{"agent.task_chain.set_summary", "agent.chain.summary"}) {
		w := bridge_agent_route(m, `{"summary":"x"}`)
		testing.expect(t, w.kind == .Envelope, "set_summary is an envelope")
		testing.expect_value(t, bridge_agent_route_target(w), "/api/v1/agent-actions/chain/summary")
		testing.expect(t, bridge_agent_method_allowed(m), "set_summary still allowed")
	}
}
