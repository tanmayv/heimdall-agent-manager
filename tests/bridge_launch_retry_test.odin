package bridge_launch_retry_test

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "odin_test:lib/http_client"
import bridge "odin_test:bridge"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

test_classifier :: proc() {
	// Retriable: Transport failure (!ok or status == 0)
	check(bridge.bridge_http_is_retriable(0, false), "status=0 ok=false must be retriable")
	check(bridge.bridge_http_is_retriable(0, true), "status=0 ok=true must be retriable")
	check(!bridge.bridge_http_is_terminal(0, false), "status=0 ok=false must not be terminal")

	// Retriable: HTTP 429 (Too Many Requests / Rate Limited)
	check(bridge.bridge_http_is_retriable(429, true), "HTTP 429 must be retriable")
	check(!bridge.bridge_http_is_terminal(429, true), "HTTP 429 must not be terminal")

	// Retriable: HTTP 5xx (Server Errors)
	check(bridge.bridge_http_is_retriable(500, true), "HTTP 500 must be retriable")
	check(bridge.bridge_http_is_retriable(502, true), "HTTP 502 must be retriable")
	check(bridge.bridge_http_is_retriable(503, true), "HTTP 503 must be retriable")
	check(bridge.bridge_http_is_retriable(504, true), "HTTP 504 must be retriable")
	check(!bridge.bridge_http_is_terminal(500, true), "HTTP 500 must not be terminal")
	check(!bridge.bridge_http_is_terminal(503, true), "HTTP 503 must not be terminal")

	// Terminal: HTTP 4xx (Client / Auth / Validation, except 429)
	check(!bridge.bridge_http_is_retriable(400, true), "HTTP 400 must be terminal")
	check(bridge.bridge_http_is_terminal(400, true), "HTTP 400 must be terminal")
	check(!bridge.bridge_http_is_retriable(401, true), "HTTP 401 must be terminal")
	check(bridge.bridge_http_is_terminal(401, true), "HTTP 401 must be terminal")
	check(!bridge.bridge_http_is_retriable(403, true), "HTTP 403 must be terminal")
	check(bridge.bridge_http_is_terminal(403, true), "HTTP 403 must be terminal")
	check(!bridge.bridge_http_is_retriable(404, true), "HTTP 404 must be terminal")
	check(bridge.bridge_http_is_terminal(404, true), "HTTP 404 must be terminal")
	check(!bridge.bridge_http_is_retriable(409, true), "HTTP 409 must be terminal")
	check(!bridge.bridge_http_is_retriable(422, true), "HTTP 422 must be terminal")

	// Terminal: HTTP 2xx / 3xx (Success / Redirect)
	check(!bridge.bridge_http_is_retriable(200, true), "HTTP 200 must be terminal")
	check(bridge.bridge_http_is_terminal(200, true), "HTTP 200 must be terminal")
	check(!bridge.bridge_http_is_retriable(201, true), "HTTP 201 must be terminal")
	check(!bridge.bridge_http_is_retriable(202, true), "HTTP 202 must be terminal")
	check(!bridge.bridge_http_is_retriable(204, true), "HTTP 204 must be terminal")
	check(!bridge.bridge_http_is_retriable(304, true), "HTTP 304 must be terminal")

	fmt.println("PASS: retry classifier tests")
}

test_http_5xx_then_200_sequence :: proc() {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, err := net.listen_tcp(endpoint)
	check(err == nil, "listen_tcp failed")
	defer net.close(listener)

	bound_ep, ep_err := net.bound_endpoint(listener)
	check(ep_err == nil, "bound_endpoint failed")
	port := bound_ep.port

	server_thread := thread.create_and_start_with_data(rawptr(uintptr(listener)), proc(data: rawptr) {
		l := net.TCP_Socket(uintptr(data))
		req_count := 0
		for req_count < 2 {
			client, _, accept_err := net.accept_tcp(l)
			if accept_err != nil do return
			req_count += 1
			buf: [1024]byte
			_, _ = net.recv_tcp(client, buf[:])
			if req_count == 1 {
				body := "503 service unavailable"
				resp := fmt.tprintf("HTTP/1.1 503 Service Unavailable\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
				net.send_tcp(client, transmute([]byte)resp)
			} else {
				body := "{\"restarted\":true}"
				resp := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
				net.send_tcp(client, transmute([]byte)resp)
			}
			net.close(client)
		}
	})

	time.sleep(20 * time.Millisecond)

	hub_url := fmt.tprintf("http://127.0.0.1:%d", port)
	headers := [?]http.Header{
		{name = "Authorization", value = "Bearer test_token"},
		{name = "Content-Type", value = "application/json"},
	}

	// base_backoff_ms = 5 for fast test execution
	resp, ok := bridge.bridge_http_request_retry("POST", hub_url, "/api/v1/agent-instances/inst_test/restart", "{}", headers[:], 2000, 4, 5)
	check(ok, "request_retry must return ok=true")
	check(resp.status == 200, "status must be 200 after retry")
	check(strings.contains(resp.body, "restarted"), "body must contain restarted")

	thread.join(server_thread)
	thread.destroy(server_thread)

	fmt.println("PASS: 5xx-then-200 retry sequence succeeded")
}

test_terminal_4xx_no_retry :: proc() {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, err := net.listen_tcp(endpoint)
	check(err == nil, "listen_tcp failed")
	defer net.close(listener)

	bound_ep, ep_err := net.bound_endpoint(listener)
	check(ep_err == nil, "bound_endpoint failed")
	port := bound_ep.port

	server_thread := thread.create_and_start_with_data(rawptr(uintptr(listener)), proc(data: rawptr) {
		l := net.TCP_Socket(uintptr(data))
		client, _, accept_err := net.accept_tcp(l)
		if accept_err != nil do return
		buf: [1024]byte
		_, _ = net.recv_tcp(client, buf[:])
		body := "{\"error\":\"unauthorized\"}"
		resp := fmt.tprintf("HTTP/1.1 401 Unauthorized\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
		net.send_tcp(client, transmute([]byte)resp)
		net.close(client)
	})

	time.sleep(20 * time.Millisecond)

	hub_url := fmt.tprintf("http://127.0.0.1:%d", port)
	headers := [?]http.Header{{name = "Authorization", value = "Bearer bad"}}

	resp, ok := bridge.bridge_http_request_retry("POST", hub_url, "/api/v1/agent-instances/inst_test/restart", "{}", headers[:], 2000, 4, 5)
	check(ok, "request_retry must return ok=true for 401")
	check(resp.status == 401, "status must be 401 immediately (no retry)")
	check(strings.contains(resp.body, "unauthorized"), "body must contain auth error")

	thread.join(server_thread)
	thread.destroy(server_thread)

	fmt.println("PASS: terminal 4xx returned immediately without retry")
}

test_relay_restart_with_retry :: proc() {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, err := net.listen_tcp(endpoint)
	check(err == nil, "listen_tcp failed")
	defer net.close(listener)

	bound_ep, ep_err := net.bound_endpoint(listener)
	check(ep_err == nil, "bound_endpoint failed")
	port := bound_ep.port

	server_thread := thread.create_and_start_with_data(rawptr(uintptr(listener)), proc(data: rawptr) {
		l := net.TCP_Socket(uintptr(data))
		req_count := 0
		for req_count < 2 {
			client, _, accept_err := net.accept_tcp(l)
			if accept_err != nil do return
			req_count += 1
			buf: [1024]byte
			_, _ = net.recv_tcp(client, buf[:])
			if req_count == 1 {
				body := "500 internal error"
				resp := fmt.tprintf("HTTP/1.1 500 Internal Server Error\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
				net.send_tcp(client, transmute([]byte)resp)
			} else {
				body := "{\"ok\":true,\"restarted\":true}"
				resp := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
				net.send_tcp(client, transmute([]byte)resp)
			}
			net.close(client)
		}
	})

	time.sleep(20 * time.Millisecond)

	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", port)
	bridge.bridge_config.bridge_token = "hbr_test"
	rec := bridge.Bridge_Local_Agent_Token_Record{
		agent_instance_id = "inst_relay_test",
		instance_token    = "hit_relay_token",
		role              = .Agent,
	}

	relay := bridge.bridge_local_relay_instance_lifecycle("agent.instances.restart", "{\"instance_id\":\"inst_relay_test\"}", rec)
	check(relay.ok, "relay must succeed")
	check(relay.status == 200, "relay status must be 200 after retry")
	check(strings.contains(relay.body, "restarted"), "relay body must contain restarted")

	thread.join(server_thread)
	thread.destroy(server_thread)

	fmt.println("PASS: bridge_local_relay_instance_lifecycle restart retry succeeded")
}

test_idempotency_and_dedupe :: proc() {
	bridge.bridge_runtime_init()

	// 1. Command cache dedupe:
	// A duplicate launch command_id returns cached result and does NOT launch again.
	cmd_id := "cmd_launch_dedupe_test"
	initial_result := "{\"command_id\":\"cmd_launch_dedupe_test\",\"status\":\"succeeded\",\"runtime\":\"starting\"}"
	bridge.bridge_runtime_cache_command(cmd_id, initial_result)

	cached, found := bridge.bridge_runtime_cached_command(cmd_id)
	check(found, "command must be found in cache")
	check(cached == initial_result, "cached result must match")

	// 2. Launch registry replacement:
	// Retrying a launch or relaunch for the same instance_id replaces the launch record
	// in place, ensuring len(launches) for that instance is strictly 1 (no duplicate launch).
	inst_id := "inst_idempotent_test"
	launch_attempt1 := bridge.Bridge_Runtime_Launch{
		agent_instance_id = strings.clone(inst_id),
		command_id        = strings.clone("cmd_1"),
		run_dir           = "/tmp/run1",
		tmux_session      = "heimdall",
		tmux_window       = "w_inst_idempotent_test",
		pane_id           = "%10",
		wrapper_token     = "tok_w1",
		agent_token       = "tok_a1",
	}
	bridge.bridge_runtime_record_launch(launch_attempt1)

	l1, ok1 := bridge.bridge_runtime_get_launch(inst_id)
	check(ok1, "first launch record must exist")
	check(l1.pane_id == "%10", "pane_id must match attempt 1")

	// Simulated retry (attempt 2)
	launch_attempt2 := bridge.Bridge_Runtime_Launch{
		agent_instance_id = strings.clone(inst_id),
		command_id        = strings.clone("cmd_2"),
		run_dir           = "/tmp/run2",
		tmux_session      = "heimdall",
		tmux_window       = "w_inst_idempotent_test",
		pane_id           = "%11",
		wrapper_token     = "tok_w2",
		agent_token       = "tok_a2",
	}
	bridge.bridge_runtime_record_launch(launch_attempt2)

	l2, ok2 := bridge.bridge_runtime_get_launch(inst_id)
	check(ok2, "launch record must still exist after retry")
	check(l2.pane_id == "%11", "pane_id must be updated to attempt 2")
	check(l2.command_id == "cmd_2", "command_id must be updated")

	// Assert NO duplicate instance entries in bridge_runtime_launches
	inst_count := 0
	for l in bridge.bridge_runtime_launches {
		if l.agent_instance_id == inst_id do inst_count += 1
	}
	check(inst_count == 1, "exactly ONE launch record must exist for instance_id (no duplicate launch)")

	// 3. Scheduler wake dedupe / skip active instances
	bridge.bridge_runtime_set_status(inst_id, "running", "idle")
	inst_snap, snap_ok := bridge.bridge_runtime_instance_snapshot(inst_id)
	check(snap_ok, "snapshot should exist")
	check(bridge.bridge_runtime_status_active(inst_snap.runtime_status), "instance should be active")

	// bridge_task_wake_if_needed must return false for already active instance
	now := time.to_unix_nanoseconds(time.now()) / 1_000_000
	woken := bridge.bridge_task_wake_if_needed(inst_id, now)
	check(!woken, "bridge_task_wake_if_needed must not wake already active instance")

	fmt.println("PASS: launch dedupe and idempotency verified (no duplicate launch)")
}

main :: proc() {
	test_classifier()
	test_http_5xx_then_200_sequence()
	test_terminal_4xx_no_retry()
	test_relay_restart_with_retry()
	test_idempotency_and_dedupe()
	fmt.println("ALL BRIDGE LAUNCH RETRY TESTS PASSED")
}
