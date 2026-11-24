package app

import "core:mem"
import "core:testing"
import http "odin_test:hub/transport/http"

@(test)
test_actions_routes :: proc(t:^testing.T) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	actions_routes_scenario(t)
	testing.expect_value(t,len(track.allocation_map),0)
}
actions_routes_scenario :: proc(t:^testing.T) {
	graph:App_Graph
	register_routes(&graph)
	defer http.router_free(&graph.router)
	found:=false
	for route in graph.router.routes {
		if route.method=="GET" && http.route_matches(route.path,"/api/v1/actions/trigger-types") {
			testing.expect(t,route.handler==http.action_trigger_types_handler)
			found=true
			break
		}
	}
	testing.expect(t,found)
	removed:=[?]struct{method,path:string}{
		{"POST","/api/v1/actions/x/run"},
		{"GET","/api/v1/scheduled-prompts"},{"POST","/api/v1/scheduled-prompts"},
		{"GET","/api/v1/scheduled-prompts/x"},{"PATCH","/api/v1/scheduled-prompts/x"},{"DELETE","/api/v1/scheduled-prompts/x"},
		{"GET","/api/v1/bridge/actions"},{"POST","/api/v1/bridge/actions/x/execute"},
	}
	for request in removed {
		for route in graph.router.routes do testing.expect(t,route.method!=request.method || !http.route_matches(route.path,request.path),request.path)
	}
}
