package app

import "core:fmt"
import "core:testing"
import http "odin_test:hub/transport/http"

// The router dispatches the first matching registration, so a second exact
// (method, path) entry is unreachable and hides which handler really serves it.
// Task cancel once had a dead legacy duplicate behind the taskv2 handler.
@(test)
test_register_routes_has_no_duplicate_method_path :: proc(t: ^testing.T) {
	graph: App_Graph
	register_routes(&graph)
	defer http.router_free(&graph.router)
	seen := make(map[string]bool, context.temp_allocator)
	cancel_routes := 0
	for route in graph.router.routes {
		key := fmt.tprintf("%s %s", route.method, route.path)
		testing.expectf(t, !seen[key], "duplicate route registration: %s", key)
		seen[key] = true
		if route.method == "POST" && route.path == "/api/v1/task-chains/*/tasks/*/cancel" {
			cancel_routes += 1
			testing.expect(t, route.handler == http.task_cancel_handler, "task cancel is served by the taskv2 handler")
		}
	}
	testing.expect_value(t, cancel_routes, 1)
}
