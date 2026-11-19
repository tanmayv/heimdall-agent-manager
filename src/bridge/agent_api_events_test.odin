package main
import "core:fmt"
import "core:testing"

@(test)
test_event_agent_routes :: proc(t: ^testing.T) {
	for verb in ([]string{"next", "ack", "watch", "unwatch", "subscriptions"}) {
		method := fmt.tprintf("agent.events.%s", verb)
		route := bridge_agent_route(method, "{}")
		testing.expect(t, route.kind == .Envelope)
		testing.expect_value(t, len(route.path), 5)
		if len(route.path) == 5 {
			testing.expect_value(t, route.path[3], "events")
			testing.expect_value(t, route.path[4], verb)
		}
		// Capability discovery and local request dispatch use the same allowlist.
		testing.expect(t, bridge_agent_method_allowed(method))
	}
}
