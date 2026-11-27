package main

// T3 (ham-ctl parity): instance detail and reconfiguration routes.

import "core:strings"
import "core:testing"

@(test)
bridge_instance_reconfiguration_methods_are_allowlisted :: proc(t: ^testing.T) {
	for method in ([]string{"agent.agents.instance_get", "agent.agents.instance_reconfigure", "agent.agents.instance_reconfigurations", "agent.agents.instance_reconfiguration_cancel"}) {
		testing.expectf(t, bridge_agent_method_allowed(method), "%s is dispatchable", method)
	}
}

@(test)
bridge_instance_get_and_list_route_to_raw_gets :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.agents.instance_get", `{"instance_id":"inst_a"}`)
	testing.expect(t, r.kind == .Raw && r.http_method == .GET)
	testing.expect_value(t, bridge_agent_route_target(r), "/api/v1/agent-instances/inst_a")
	r = bridge_agent_route("agent.agents.instance_reconfigurations", `{"instance_id":"inst_a"}`)
	testing.expect(t, r.kind == .Raw && r.http_method == .GET && !r.send_body)
	testing.expect_value(t, bridge_agent_route_target(r), "/api/v1/agent-instances/inst_a/reconfigurations")
	testing.expect(t, bridge_agent_route("agent.agents.instance_get", `{}`).kind == .Unknown, "missing instance id is not routed")
}

@(test)
bridge_instance_reconfigure_forwards_only_the_destination :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.agents.instance_reconfigure", `{"instance_id":"inst_a","reconfiguration":{"bridge_id":"brg","project_id":"","provider":"codex","model":"m","expected_revision":3,"idempotency_key":"k"}}`)
	testing.expect(t, r.kind == .Raw && r.http_method == .POST && r.send_body)
	testing.expect_value(t, bridge_agent_route_target(r), "/api/v1/agent-instances/inst_a/reconfigurations")
	// The hub rejects unknown reconfiguration fields: the routing id stays out.
	testing.expect(t, !strings.contains(r.body, "instance_id"), r.body)
	testing.expect(t, strings.contains(r.body, `"project_id":""`), r.body)
	testing.expect(t, strings.contains(r.body, `"expected_revision":3`), r.body)
	testing.expect(t, strings.contains(r.body, `"idempotency_key":"k"`), r.body)

	missing := bridge_agent_route("agent.agents.instance_reconfigure", `{"instance_id":"inst_a"}`)
	testing.expect(t, missing.kind == .Bad_Request, "reconfiguration object is required")
	missing = bridge_agent_route("agent.agents.instance_reconfigure", `{"reconfiguration":{}}`)
	testing.expect(t, missing.kind == .Bad_Request, "instance_id is required")
}

@(test)
bridge_instance_reconfiguration_cancel_routes_to_cancel :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.agents.instance_reconfiguration_cancel", `{"instance_id":"inst_a","idempotency_key":"k","expected_operation_revision":2}`)
	testing.expect(t, r.kind == .Raw && r.http_method == .POST && r.send_body && r.body == "")
	testing.expect_value(t, bridge_agent_route_target(r), "/api/v1/agent-instances/inst_a/reconfigurations/cancel")
}
