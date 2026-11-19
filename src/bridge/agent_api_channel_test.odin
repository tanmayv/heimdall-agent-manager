package main

import "core:fmt"
import "core:testing"

@(test)
test_channel_routes_relay_envelopes :: proc(t: ^testing.T) {
	for verb in ([]string{"read", "send", "history"}) {
		method := fmt.tprintf("agent.channel.%s", verb)
		testing.expect(t, bridge_agent_method_allowed(method))
		route := bridge_agent_route(method, "{}")
		testing.expect(t, route.kind == .Envelope)
		testing.expect_value(t, bridge_agent_route_target(route), fmt.tprintf("/api/v1/agent-actions/channel/%s", verb))
	}
}
