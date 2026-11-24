package main
import "core:testing"
import "core:fmt"

@(test)
test_agent_automation_routes :: proc(t:^testing.T) {
 for verb in ([]string{"list","show","create","update","delete","runs","trigger-types","filter-test"}) {
  method:=fmt.tprintf("agent.automations.%s",verb)
  testing.expect(t,bridge_agent_method_allowed(method),method)
  route:=bridge_agent_route(method,"{}")
  testing.expect_value(t,route.kind,Bridge_Agent_Route_Kind.Envelope)
  testing.expect_value(t,bridge_agent_route_target(route),fmt.tprintf("/api/v1/agent-actions/automations/%s",verb))
 }
}
