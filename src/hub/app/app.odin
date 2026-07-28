package app

import http "odin_test:hub/transport/http"

run :: proc(config: Hub_Config) -> (bool, string) {
	graph: App_Graph
	ok, message := build_graph(&graph, config)
	if !ok do return false, message
	// The Hub is a long-running HTTP process; shutdown_graph is intentionally only
	// used by tests that construct App_Graph directly.
	served := http.serve(&graph.router, http.Server_Config{bind_host = config.bind_host, port = config.port})
	if !served do return false, "hub server failed"
	return true, "hub server stopped"
}
