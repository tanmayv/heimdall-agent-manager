package main

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// The production rollover effects (no Bridge_Rollover_Effects fakes): the
// Hub restart request built from the token store, the handoff request typed
// through the PTY runtime, and the saved handoff admitted as an unread input.

// One loopback HTTP exchange: the captured request and a fixed answer.
@(private = "file")
Roll_Http :: struct { listener: net.TCP_Socket, request: string, served: bool }

@(private = "file")
roll_http_serve :: proc(data: rawptr) {
	h := (^Roll_Http)(data)
	client, _, err := net.accept_tcp(h.listener)
	if err != nil do return
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
	got := make([dynamic]byte, runtime.heap_allocator())
	buf: [4096]byte
	// Read the head, then the body its Content-Length announces.
	for {
		n, rerr := net.recv_tcp(client, buf[:])
		if n <= 0 || rerr != nil do break
		append(&got, ..buf[:n])
		text := string(got[:])
		head_end := strings.index(text, "\r\n\r\n")
		if head_end < 0 do continue
		length := 0
		lower := strings.to_lower(text[:head_end], context.temp_allocator)
		if at := strings.index(lower, "content-length:"); at >= 0 {
			rest := strings.trim_left_space(lower[at + len("content-length:"):])
			for c in rest { if c < '0' || c > '9' do break; length = length * 10 + int(c - '0') }
		}
		if len(got) >= head_end + 4 + length do break
	}
	h.request = string(got[:])
	body := `{"data":{"instance":{"agent_instance_id":"inst_roll_restart"}}}`
	response := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
	_, _ = net.send_tcp(client, transmute([]byte)response)
	h.served = true
}

// RC1 (task_18ebe1fdc25cfe38): the restart record carries the stored
// run_count, so the generation fence passes and the Hub is asked, through
// its lifecycle path with reason context_rollover.
@(test)
test_rollover_restart_default_asks_hub_with_generation_and_reason :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	id := "inst_roll_restart"
	old_records := bridge_local_token_records
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, runtime.heap_allocator())
	append(&bridge_local_token_records, Bridge_Local_Agent_Token_Record{agent_instance_id = id, token_hash = "h", instance_token = "itok_roll", role = .Agent, run_count = 7})
	old_url, old_token := bridge_config.daemon_url, bridge_config.bridge_token
	old_up := sync.atomic_load(&bridge_hub_runtime_up)
	defer {
		delete(bridge_local_token_records); bridge_local_token_records = old_records
		bridge_config.daemon_url, bridge_config.bridge_token = old_url, old_token
		sync.atomic_store(&bridge_hub_runtime_up, old_up)
	}

	rec, ok := bridge_rollover_rec_for(id)
	testing.expect(t, ok)
	testing.expect_value(t, rec.run_count, 7)
	testing.expect_value(t, rec.instance_token, "itok_roll")
	delete(rec.instance_token)

	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, lerr == nil) do return
	defer net.close(listener)
	_ = net.set_option(listener, .Receive_Timeout, 3 * time.Second)
	bound, _ := net.bound_endpoint(listener)
	url := fmt.aprintf("http://127.0.0.1:%d", bound.port)
	defer delete(url)
	bridge_config.daemon_url = url
	bridge_config.bridge_token = "test-only"
	sync.atomic_store(&bridge_hub_runtime_up, true)

	// A stale generation is refused before any request is sent.
	testing.expect(t, !bridge_rollover_restart_default(id, 6))

	server := Roll_Http{listener = listener}
	worker := thread.create_and_start_with_data(&server, roll_http_serve)
	ok = bridge_rollover_restart_default(id, 7)
	thread.join(worker); thread.destroy(worker)
	defer delete(server.request, runtime.heap_allocator())
	testing.expect(t, server.served, "the Hub was asked")
	testing.expect(t, ok, server.request)
	req := server.request
	testing.expect(t, strings.has_prefix(req, "POST /api/v1/agent-instances/inst_roll_restart/restart"), req)
	testing.expect(t, strings.contains(req, `"expected_run_count":7`), req)
	testing.expect(t, strings.contains(req, `"reason":"context_rollover"`), req)
	testing.expect(t, strings.contains(strings.to_lower(req, context.temp_allocator), "x-heimdall-instance-token: itok_roll"), req)
}

// The handoff request is typed into the live PTY session at its trusted
// idle (deliver_line_default -> runtime handoff_request), and the saved
// handoff reaches the restarted session as an unread-messages notice.
@(test)
test_rollover_pty_default_effects_type_request_and_admit_handoff_unread :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("roll-effects"); defer pty_test_end(&env)
	id := "inst_pty_roll_effects"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_forget_typed(id)
	pty_test_activity(id, "idle", "pane_diff")

	testing.expect(t, bridge_rollover_deliver_line_default(id, "Context rollover: write your handoff"))
	testing.expect_value(t, pty_test_trace(), `"Context rollover: write your handoff" Enter Enter`)

	// A stopped session is never typed into.
	pty_test_reset()
	bridge_runtime_set_status(id, "stopped", "idle")
	testing.expect(t, !bridge_rollover_deliver_line_default(id, "late"))
	testing.expect_value(t, len(pty_test_ops), 0)

	// The restarted session: the handoff is admitted as an unread input and
	// typed as the unread-messages notice at its first trusted idle.
	pty_test_forget_typed(id)
	pty_test_activity(id, "active", "pane_diff")
	testing.expect(t, bridge_rollover_deliver_handoff_default(id, "msg_pctx_roll"))
	ids := pty_test_queued(id)
	testing.expect(t, len(ids) == 1 && ids[0] == "msg_pctx_roll", "the handoff is queued durably")
	testing.expect_value(t, len(pty_test_ops), 0)
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 10_000)
	testing.expect_value(t, pty_test_trace(), fmt.tprintf("%q Enter Enter", bridge_pty_host_unread_notice()))
	testing.expect_value(t, len(pty_test_queued(id)), 0)
}
