package main

import "core:testing"

@test
bridge_task_chain_subscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task_chain.subscribe", `{"chain_id":"chain_abc","events":"all"}`)
	testing.expect(t, r.kind == .Envelope, "subscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/chain/subscribe")
}

@test
bridge_task_chain_unsubscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task_chain.unsubscribe", `{"chain_id":"chain_abc"}`)
	testing.expect(t, r.kind == .Envelope, "unsubscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/chain/unsubscribe")
}

@test
bridge_task_subscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task.subscribe", `{"task_id":"task_123","events":"all"}`)
	testing.expect(t, r.kind == .Envelope, "task subscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/task/subscribe")
}

@test
bridge_task_unsubscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task.unsubscribe", `{"task_id":"task_123"}`)
	testing.expect(t, r.kind == .Envelope, "task unsubscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/task/unsubscribe")
}

@test
bridge_subscription_methods_allowed :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.subscribe"), "chain subscribe allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.unsubscribe"), "chain unsubscribe allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.task.subscribe"), "task subscribe allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.task.unsubscribe"), "task unsubscribe allowed")
}
