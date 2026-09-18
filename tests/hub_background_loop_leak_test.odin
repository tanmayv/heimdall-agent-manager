// Regression guard for persistent-heap memory leaks in reaper sweep and bridge WebSocket runtime loop.
//
// Verifies:
// 1. reaper_sweep_once does not leak memory over repeated sweeps.
// 2. bridge_ws_process_frame (heartbeats and agent status reports) does not leak memory.
// 3. live heap memory allocated stays flat (growth is 0 bytes or < 0.1 B/iteration).
package hub_background_loop_leak_test

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import http "odin_test:hub/transport/http"

PORT :: 39720
WARMUP :: 50
ITERATIONS :: 500

drive_cycle :: proc(g: ^app.App_Graph, bridge_id: string, gen: int, server_sock, client_sock: net.TCP_Socket, reassemblies: ^[dynamic]http.Bridge_Chunk_Reassembly, hb, st: string) {
	app.reaper_sweep_once(g)
	_ = http.bridge_ws_process_frame(&g.bridge_handlers, bridge_id, gen, server_sock, reassemblies, strings.clone(hb))
	_ = http.bridge_ws_process_frame(&g.bridge_handlers, bridge_id, gen, server_sock, reassemblies, strings.clone(st))
	buf: [8192]byte
	for {
		n, err := net.recv_tcp(client_sock, buf[:])
		if err != nil || n <= 0 do break
	}
	free_all(context.temp_allocator)
}

run_test :: proc() -> bool {
	db_path := "/tmp/hub_background_loop_leak_test.db"
	os.remove(db_path)
	os.remove(strings.concatenate({db_path, "-wal"}))
	os.remove(strings.concatenate({db_path, "-shm"}))
	defer {
		_ = os.remove(db_path)
		_ = os.remove(strings.concatenate({db_path, "-wal"}))
		_ = os.remove(strings.concatenate({db_path, "-shm"}))
	}

	config := app.default_config()
	config.database_path = db_path
	config.port = PORT

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, config)
	if !ok {
		fmt.eprintln("build_graph failed:", msg)
		return false
	}
	defer app.shutdown_graph(&graph)

	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT})
	if lerr != nil {
		fmt.eprintln("listen failed:", lerr)
		return false
	}
	defer net.close(listener)

	client_sock, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = PORT})
	if derr != nil {
		fmt.eprintln("dial failed:", derr)
		return false
	}
	defer net.close(client_sock)

	server_sock, _, aerr := net.accept_tcp(listener)
	if aerr != nil {
		fmt.eprintln("accept failed:", aerr)
		return false
	}
	defer net.close(server_sock)

	_ = net.set_option(client_sock, .Receive_Timeout, 5 * time.Millisecond)

	now_str := "2026-09-18T19:00:00Z"
	bridge_id := "brg_leak_test"
	_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, domain.Bridge{
		bridge_id = bridge_id,
		owner_user_id = "test_user",
		label = "Test Bridge",
		status = .Online,
		created_at = now_str,
		updated_at = now_str,
	})
	project_service.bridge_runtime_registry_mark_live(&graph.bridge_runtime_registry, bridge_id, false, "")
	generation := bridge_runtime.runtime_next_generation(&graph.bridge_runtime_registry, bridge_id)
	bridge_runtime.runtime_set_generation(&graph.bridge_runtime_registry, bridge_id, generation)
	project_service.bridge_runtime_registry_set_command_socket(&graph.bridge_runtime_registry, bridge_id, server_sock)

	inst_id_1 := "inst_leak_test_1"
	inst_id_2 := "inst_leak_test_2"
	_, _, _ = iface.agent_save_instance(graph.agents.agents, domain.Agent_Instance{
		agent_instance_id = inst_id_1,
		owner_user_id = "test_user",
		agent_id = "agt_leak_1",
		bridge_id = bridge_id,
		display_name = "Test Agent 1",
		provider = "claude",
		tier = "normal",
		runtime_status = "running",
		startup_status = "ready",
		activity_status = "busy",
		created_at = now_str,
		updated_at = now_str,
		last_seen_at = now_str,
	})
	_, _, _ = iface.agent_save_instance(graph.agents.agents, domain.Agent_Instance{
		agent_instance_id = inst_id_2,
		owner_user_id = "test_user",
		agent_id = "agt_leak_2",
		bridge_id = bridge_id,
		display_name = "Test Agent 2",
		provider = "claude",
		tier = "normal",
		runtime_status = "running",
		startup_status = "ready",
		activity_status = "idle",
		created_at = now_str,
		updated_at = now_str,
		last_seen_at = now_str,
	})

	reassemblies := make([dynamic]http.Bridge_Chunk_Reassembly)
	defer http.bridge_chunk_reassemblies_free(&reassemblies)

	heartbeat_frame := fmt.tprintf("{{\"type\":\"bridge_heartbeat\",\"active_instance_ids\":[\"%s\",\"%s\"]}}", inst_id_1, inst_id_2)
	status_frame := fmt.tprintf("{{\"type\":\"agent_instance_status\",\"agent_instance_id\":\"%s\",\"state_seq\":10,\"runtime_status\":\"running\",\"activity_status\":\"busy\"}}", inst_id_1)

	// Warmup
	for _ in 0 ..< WARMUP {
		drive_cycle(&graph, bridge_id, generation, server_sock, client_sock, &reassemblies, heartbeat_frame, status_frame)
	}

	// Install tracking allocator as ambient heap
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	baseline := track.current_memory_allocated

	for _ in 0 ..< ITERATIONS {
		drive_cycle(&graph, bridge_id, generation, server_sock, client_sock, &reassemblies, heartbeat_frame, status_frame)
	}

	after := track.current_memory_allocated
	growth := after - baseline
	per_iter := f64(growth) / f64(ITERATIONS)

	fmt.printf("baseline_live=%d after_live=%d growth=%d over %d iterations (%.3f B/iteration)\n",
		baseline, after, growth, ITERATIONS, per_iter)

	THRESHOLD_B_PER_ITER :: 0.1
	if per_iter > THRESHOLD_B_PER_ITER {
		for key, value in track.allocation_map {
			bytes := ([^]byte)(key)[:value.size]
			fmt.eprintfln("leaked: %d bytes %q at %v", value.size, string(bytes), value.location)
		}
		fmt.eprintfln("FAIL: background loop live-heap growth %.3f B/iteration exceeds %.1f B/iteration — persistent heap leak regressed",
			per_iter, THRESHOLD_B_PER_ITER)
		return false
	}
	fmt.println("PASS: hub background loop leak guard (live heap flat across reaper sweeps and bridge runtime events)")
	return true
}

main :: proc() {
	if !run_test() {
		os.exit(1)
	}
	os.exit(0)
}
