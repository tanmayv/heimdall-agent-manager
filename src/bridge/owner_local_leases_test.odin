package main

import "core:testing"

@(test)
test_owner_local_lease_agent_route_and_wrapper_denial :: proc(t:^testing.T) {
    testing.expect(t,bridge_local_method_allowed("agent.owner_local.lease",.Agent))
    testing.expect(t,!bridge_local_method_allowed("agent.owner_local.lease",.Wrapper))
    testing.expect(t,!bridge_local_method_allowed("agent.owner_local.submit",.Agent))
    route:=bridge_agent_route("agent.owner_local.lease","{}")
    testing.expect_value(t,route.kind,Bridge_Agent_Route_Kind.Local)
    testing.expect_value(t,route.local_op,"owner_local.lease")
    testing.expect_value(t,len(route.path),0)
}
