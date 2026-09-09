// MEM-4 regression guard: proves the per-request memory leak stays fixed.
//
// It drives the REAL http.handle_client over a loopback socket while the ambient
// heap allocator is a mem.Tracking_Allocator. Because handle_client installs a
// per-request arena for the non-upgrade path, everything a request allocates is
// drawn from (and freed with) that arena and never touches the tracking
// allocator; only allocations that deliberately ESCAPE to the persistent heap
// (there should be none for this task/comment/list/health workload) show up as
// still-live in the tracker. So after a batch of identical requests the tracker's
// current_memory_allocated must stay flat instead of growing ~1.48 KB/request as
// it did before the fix (see the MEM-2 RCA).
//
// Run: odin run tests/hub_request_arena_leak_test.odin -file \
//        -collection:odin_test=src -extra-linker-flags:"-L<sqlite>/lib"
// (from the repo root, so the default migrations dir resolves). Exits non-zero on
// regression.
package hub_request_arena_leak_test

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import app "odin_test:hub/app"
import http "odin_test:hub/transport/http"

PORT :: 39717

GRAPH_ROUTER: ^http.Router

one_request :: proc(listener: net.TCP_Socket, raw: string) -> string {
	client, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = PORT})
	if derr != nil { return "" }
	server, source, aerr := net.accept_tcp(listener)
	if aerr != nil { net.close(client); return "" }
	_, _ = net.send_tcp(client, transmute([]byte)raw)
	http.handle_client(server, source, GRAPH_ROUTER)
	buf: [65536]byte
	total := strings.builder_make(context.temp_allocator)
	for {
		n, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || n <= 0 do break
		strings.write_bytes(&total, buf[:n])
	}
	net.close(client)
	return strings.clone(strings.to_string(total), context.temp_allocator)
}

raw_req :: proc(method, path, body: string) -> string {
	return fmt.aprintf(
		"%s %s HTTP/1.1\r\nHost: x\r\nX-authentik-username: tanmay\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		method, path, len(body), body, allocator = context.temp_allocator)
}

extract_chain_id :: proc(resp: string) -> string {
	needle := "\"chain_id\":\""
	i := strings.index(resp, needle)
	if i < 0 do return ""
	rest := resp[i + len(needle):]
	j := strings.index_byte(rest, '"')
	if j < 0 do return ""
	return strings.clone(rest[:j], context.temp_allocator)
}

// drive_batch issues `n` identical mixed request cycles (write + reads).
drive_batch :: proc(listener: net.TCP_Socket, tasks_path: string, n: int) {
	for i in 0 ..< n {
		one_request(listener, raw_req("POST", tasks_path,
			fmt.tprintf("{{\"title\":\"t%d\",\"description\":\"body\"}}", i)))
		one_request(listener, raw_req("GET", tasks_path, ""))
		one_request(listener, raw_req("GET", "/api/v1/me", ""))
		one_request(listener, raw_req("GET", "/api/v1/health", ""))
		free_all(context.temp_allocator)
	}
}

main :: proc() {
	db_path := "/tmp/hub_request_arena_leak_test.db"
	os.remove(db_path)
	os.remove(strings.concatenate({db_path, "-wal"}))
	os.remove(strings.concatenate({db_path, "-shm"}))

	config := app.default_config()
	config.database_path = db_path
	config.port = PORT

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, config)
	if !ok { fmt.eprintln("build_graph failed:", msg); os.exit(1) }
	GRAPH_ROUTER = &graph.router

	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT})
	if lerr != nil { fmt.eprintln("listen failed:", lerr); os.exit(1) }

	chain_resp := one_request(listener, raw_req("POST", "/api/v1/task-chains",
		"{\"title\":\"h\",\"description\":\"d\",\"kind\":\"private_conversation\"}"))
	chain_id := extract_chain_id(chain_resp)
	if chain_id == "" { fmt.eprintln("could not create chain; resp=", chain_resp); os.exit(1) }
	tasks_path := fmt.aprintf("/api/v1/task-chains/%s/tasks", chain_id)

	// Install the tracking allocator as the ambient heap AFTER graph construction so
	// only per-request behaviour is measured.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	// Warm up (first-touch / lazy allocations), then take a live-bytes baseline.
	drive_batch(listener, tasks_path, 50)
	baseline := track.current_memory_allocated

	// Drive a much larger batch; live heap bytes must not grow with request count.
	BATCH :: 400
	drive_batch(listener, tasks_path, BATCH)
	after := track.current_memory_allocated

	growth := after - baseline
	requests := BATCH * 4
	per_req := f64(growth) / f64(requests)

	fmt.printf("baseline_live=%d after_live=%d growth=%d over %d requests (%.3f B/req)\n",
		baseline, after, growth, requests, per_req)

	// Allow a small constant slack for benign, bounded heap use (e.g. map rehashes
	// in shared state); the pre-fix leak was ~1.48 KB/request, so anything under a
	// few bytes/request proves the per-request leak is gone.
	THRESHOLD_B_PER_REQ :: 8.0
	if per_req > THRESHOLD_B_PER_REQ {
		fmt.eprintfln("FAIL: per-request live-heap growth %.3f B/req exceeds %.1f B/req — leak regressed",
			per_req, THRESHOLD_B_PER_REQ)
		os.exit(1)
	}
	fmt.println("PASS: hub per-request arena leak guard (live heap flat across requests)")
	os.exit(0)
}
