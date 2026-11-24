package main
import "core:testing"
import "core:fmt"

@(test)
test_agent_webhook_routes :: proc(t:^testing.T) {
 for verb in ([]string{"create","list","show","rotate","enable","disable","delete","test"}) {
  method:=fmt.tprintf("agent.automations.webhooks.%s",verb)
  testing.expect(t,bridge_agent_method_allowed(method),method)
  route:=bridge_agent_route(method,"{}")
  testing.expect_value(t,route.kind,Bridge_Agent_Route_Kind.Envelope)
  testing.expect_value(t,bridge_agent_route_target(route),fmt.tprintf("/api/v1/agent-actions/automations/webhooks/%s",verb))
 }
 testing.expect(t,!bridge_agent_method_allowed("agent.automations.webhooks.unknown"))
}
