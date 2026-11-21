#+build !windows
package main

// REQ-VOICE-6 — large request bodies through the bridge→hub proxy relay.
//
// A ~60 MB upload once queued its whole body (~80 MB of base64 frames) and the runtime
// loop then wrote all of it without reading, which deadlocked against the hub and
// dropped the Hub WebSocket. These tests pin the three parts of the fix without a hub:
// the outgoing queue's drain budget and producer wait, a 60 MiB upload streaming
// through bridge_proxy_serve_client under a bounded queue, and the fast 411/413
// refusals that never reach the hub.

import contracts "odin_test:contracts"
import local_socket "odin_test:lib/local_socket"
import "base:runtime"
import base64 "core:encoding/base64"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// The outgoing queue and the proxy table are process globals, and the test runner runs
// tests in parallel: every test here that touches them holds this lock.
proxy_flow_test_mu: sync.Mutex

proxy_flow_test_reset :: proc() {
	if bridge_proxy_streams == nil do bridge_proxy_init()
	sync.mutex_lock(&bridge_runtime_mutex)
	for item in bridge_tunnel_data_outgoing do delete(item.json, runtime.heap_allocator())
	// Retained process globals must not borrow a test rollback allocator.
	delete(bridge_tunnel_data_outgoing)
	bridge_tunnel_data_outgoing = make([dynamic]Bridge_Tunnel_Data_Outgoing, runtime.heap_allocator())
	bridge_tunnel_data_outgoing_bytes = 0
	sync.mutex_unlock(&bridge_runtime_mutex)
}

proxy_flow_test_frame :: proc(size: int) -> string {
	heap := runtime.heap_allocator()
	return strings.repeat("x", size, heap)
}

// ---- pure refusal decision -------------------------------------------------

@(test)
bridge_proxy_body_refusal_enforces_relay_limit :: proc(t: ^testing.T) {
	ok := bridge_proxy_body_refusal(Bridge_Proxy_Request{content_len = 60 * 1024 * 1024, ok = true})
	testing.expect_value(t, ok.status, 0)
	at_limit := bridge_proxy_body_refusal(Bridge_Proxy_Request{content_len = contracts.RELAY_MAX_REQUEST_BODY_BYTES, ok = true})
	testing.expect_value(t, at_limit.status, 0)
	over := bridge_proxy_body_refusal(Bridge_Proxy_Request{content_len = contracts.RELAY_MAX_REQUEST_BODY_BYTES + 1, ok = true})
	testing.expect_value(t, over.status, 413)
	testing.expect_value(t, over.message, "request_body_too_large")
	chunked := bridge_proxy_body_refusal(Bridge_Proxy_Request{chunked = true, ok = true})
	testing.expect_value(t, chunked.status, 411)
	testing.expect_value(t, chunked.message, "request_body_chunked")
}

@(test)
bridge_proxy_parse_detects_chunked_transfer_encoding :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	req := bridge_proxy_parse_request("POST /proxy/sh_1/up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, Chunked\r\n\r\n", heap)
	testing.expect(t, req.ok, "must parse")
	testing.expect(t, req.chunked, "chunked must be detected case-insensitively in a list")
	testing.expect(t, strings.contains(req.header_block, "Transfer-Encoding"), "header block intact after scan")
	plain := bridge_proxy_parse_request("POST /proxy/sh_1/up HTTP/1.1\r\nContent-Length: 3\r\n\r\n", heap)
	testing.expect(t, !plain.chunked, "no Transfer-Encoding is not chunked")
}

// ---- queue: drain budget and producer wait --------------------------------

@(test)
bridge_tunnel_outgoing_take_respects_budget_and_order :: proc(t: ^testing.T) {
	sync.mutex_lock(&proxy_flow_test_mu)
	defer sync.mutex_unlock(&proxy_flow_test_mu)
	proxy_flow_test_reset()
	defer proxy_flow_test_reset()

	// Five 30 KB frames against a 64 KB budget: whole frames, in order, until the
	// budget is reached — so three go out (90 KB) and two stay queued.
	for i in 0 ..< 5 {
		f := proxy_flow_test_frame(30 * 1024)
		(transmute([]byte)f)[0] = u8('0' + i)
		bridge_tunnel_outgoing_push(f)
	}
	testing.expect_value(t, bridge_tunnel_outgoing_queued_bytes(), 5 * 30 * 1024)

	items, more := bridge_tunnel_outgoing_take(BRIDGE_TUNNEL_DRAIN_BUDGET_BYTES)
	testing.expect_value(t, len(items), 3)
	testing.expect(t, more, "two frames must remain")
	for item, i in items {
		testing.expect_value(t, item.json[0], u8('0' + i))
		delete(item.json, runtime.heap_allocator())
	}
	delete(items, runtime.heap_allocator())
	testing.expect_value(t, bridge_tunnel_outgoing_queued_bytes(), 2 * 30 * 1024)

	// A single frame larger than the budget still goes out on its own.
	proxy_flow_test_reset()
	bridge_tunnel_outgoing_push(proxy_flow_test_frame(BRIDGE_TUNNEL_DRAIN_BUDGET_BYTES * 2))
	big, big_more := bridge_tunnel_outgoing_take(BRIDGE_TUNNEL_DRAIN_BUDGET_BYTES)
	testing.expect_value(t, len(big), 1)
	testing.expect(t, !big_more, "nothing left")
	for item in big do delete(item.json, runtime.heap_allocator())
	delete(big, runtime.heap_allocator())
	testing.expect_value(t, bridge_tunnel_outgoing_queued_bytes(), 0)

	empty, empty_more := bridge_tunnel_outgoing_take(BRIDGE_TUNNEL_DRAIN_BUDGET_BYTES)
	testing.expect(t, empty == nil && !empty_more, "empty queue yields nothing")
}

proxy_flow_test_alive :: proc(id: string) -> bool { return id == "alive" }

@(test)
bridge_tunnel_outgoing_wait_room_blocks_while_full :: proc(t: ^testing.T) {
	sync.mutex_lock(&proxy_flow_test_mu)
	defer sync.mutex_unlock(&proxy_flow_test_mu)
	proxy_flow_test_reset()
	defer proxy_flow_test_reset()

	testing.expect_value(t, bridge_tunnel_outgoing_wait_room(proxy_flow_test_alive, "alive"), Bridge_Tunnel_Room.Ok)

	bridge_tunnel_outgoing_push(proxy_flow_test_frame(BRIDGE_TUNNEL_OUTGOING_CAP_BYTES))
	// Full and the stream is gone: stop at once rather than wait out the stall.
	started := time.tick_now()
	testing.expect_value(t, bridge_tunnel_outgoing_wait_room(proxy_flow_test_alive, "dead"), Bridge_Tunnel_Room.Gone)
	testing.expect(t, time.tick_since(started) < time.Second, "a torn-down stream must not wait")
	// Full, alive, nothing draining: give up after the stall bound.
	testing.expect_value(t, bridge_tunnel_outgoing_wait_room(proxy_flow_test_alive, "alive", 50 * time.Millisecond), Bridge_Tunnel_Room.Stalled)
	// Drained: room again.
	items, _ := bridge_tunnel_outgoing_take(BRIDGE_TUNNEL_DRAIN_BUDGET_BYTES)
	for item in items do delete(item.json, runtime.heap_allocator())
	delete(items, runtime.heap_allocator())
	testing.expect_value(t, bridge_tunnel_outgoing_wait_room(proxy_flow_test_alive, "alive"), Bridge_Tunnel_Room.Ok)
}

// ---- a 60 MiB upload streams under a bounded queue -------------------------

Proxy_Flow_Body_Source :: struct {
	remaining: int,
	produced:  int,
}

proxy_flow_test_recv :: proc(ctx: rawptr, buf: []byte) -> int {
	src := (^Proxy_Flow_Body_Source)(ctx)
	if src.remaining <= 0 do return 0
	n := min(len(buf), src.remaining)
	for i in 0 ..< n do buf[i] = u8((src.produced + i) % 251)
	src.remaining -= n
	src.produced += n
	return n
}

Proxy_Flow_Upload :: struct {
	head:     string,
	source:   Proxy_Flow_Body_Source,
	proxy_id: string,
	ok:       bool,
}

proxy_flow_test_upload_worker :: proc(u: ^Proxy_Flow_Upload) {
	u.proxy_id, u.ok = bridge_proxy_serve_client(u.head, .TCP, net.TCP_Socket(0), local_socket.INVALID_SOCKET, proxy_flow_test_recv, rawptr(&u.source))
}

@(test)
bridge_proxy_large_upload_streams_under_bounded_queue :: proc(t: ^testing.T) {
	sync.mutex_lock(&proxy_flow_test_mu)
	defer sync.mutex_unlock(&proxy_flow_test_mu)
	proxy_flow_test_reset()
	defer proxy_flow_test_reset()
	heap := runtime.heap_allocator()

	BODY :: 60 * 1024 * 1024 // the size that dropped riverwood's Hub WebSocket
	u := new(Proxy_Flow_Upload, heap)
	defer free(u, heap)
	u.head = "POST /proxy/sh_big/v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Length: 62914560\r\n\r\n"
	u.source = Proxy_Flow_Body_Source{remaining = BODY}
	th := thread.create_and_start_with_poly_data(u, proxy_flow_test_upload_worker)

	// Act as the runtime loop: take one budget at a time, as slowly as a busy loop
	// would, and check the producer never runs ahead of the cap.
	opened := false
	frames := 0
	forwarded := 0
	saw_last := false
	expected_byte := 0
	corrupt := false
	max_queued := 0
	deadline := time.tick_now()
	for {
		queued := bridge_tunnel_outgoing_queued_bytes()
		if queued > max_queued do max_queued = queued
		items, _ := bridge_tunnel_outgoing_take(BRIDGE_TUNNEL_DRAIN_BUDGET_BYTES)
		for item in items {
			kind := extract_json_string(item.json, "type", "")
			switch kind {
			case "proxy_open":
				opened = true
			case "proxy_data":
				frames += 1
				data_b64 := extract_json_string(item.json, "data_b64", "")
				decoded, _ := base64.decode(data_b64)
				for b in decoded {
					if b != u8(expected_byte % 251) do corrupt = true
					expected_byte += 1
				}
				forwarded += len(decoded)
				if strings.contains(item.json, "\"last\":true") do saw_last = true
				delete(decoded)
				delete(data_b64)
			}
			delete(kind)
			delete(item.json, runtime.heap_allocator())
		}
		delete(items, heap)
		if items == nil && thread.is_done(th) do break
		if time.tick_since(deadline) > 120 * time.Second {
			testing.fail_now(t, "upload did not finish within 120s")
		}
	}
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, u.ok, "serve_client must succeed")
	testing.expect(t, opened, "proxy_open must be sent")
	testing.expect_value(t, forwarded, BODY)
	testing.expect(t, !corrupt, "body bytes must arrive in order, unmodified")
	testing.expect(t, saw_last, "the final proxy_data must carry last:true")
	testing.expect(t, frames > 1, "the body must be split into frames")
	// One frame of overshoot is allowed: a producer checks for room, then appends.
	testing.expectf(t, max_queued <= BRIDGE_TUNNEL_OUTGOING_CAP_BYTES + 64 * 1024,
		"queue must stay bounded, peaked at %d bytes", max_queued)

	if stream, removed := bridge_proxy_take(u.proxy_id); removed do bridge_proxy_free(stream)
	delete(u.proxy_id, heap)
}

// ---- oversized and chunked uploads are refused fast, locally ---------------

Proxy_Flow_Refusal_Server :: struct {
	listener: net.TCP_Socket,
	head:     string,
	ok:       bool,
	elapsed:  time.Duration,
}

proxy_flow_test_refusal_worker :: proc(s: ^Proxy_Flow_Refusal_Server) {
	client, _, err := net.accept_tcp(s.listener)
	if err != nil do return
	started := time.tick_now()
	ctx := Bridge_Proxy_Tcp_Ctx{sock = client}
	_, s.ok = bridge_proxy_serve_client(s.head, .TCP, client, local_socket.INVALID_SOCKET, bridge_proxy_recv_tcp, rawptr(&ctx))
	s.elapsed = time.tick_since(started)
	net.close(client)
}

proxy_flow_test_refusal :: proc(t: ^testing.T, head: string, want_status: string) {
	heap := runtime.heap_allocator()
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not bind loopback listener")
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)

	s := new(Proxy_Flow_Refusal_Server, heap)
	defer free(s, heap)
	s.listener = listener
	s.head = head
	th := thread.create_and_start_with_poly_data(s, proxy_flow_test_refusal_worker)

	conn, dial_err := net.dial_tcp_from_address_and_port(net.IP4_Loopback, bound.port)
	if dial_err != nil do testing.fail_now(t, "could not dial listener")
	defer net.close(conn)
	_ = net.set_option(conn, .Receive_Timeout, 5 * time.Second)
	// The caller keeps sending body bytes it was never asked to stop: the refusal must
	// still reach it intact (the bridge reads and discards rather than resetting).
	junk := make([]byte, 256 * 1024, heap)
	defer delete(junk, heap)
	_, _ = net.send_tcp(conn, junk)

	reply := strings.builder_make(heap)
	defer strings.builder_destroy(&reply)
	buf: [4096]byte
	for {
		n, err := net.recv_tcp(conn, buf[:])
		if err != nil || n <= 0 do break
		strings.write_bytes(&reply, buf[:n])
	}
	thread.join(th)
	thread.destroy(th)

	got := strings.to_string(reply)
	testing.expectf(t, strings.has_prefix(got, want_status), "want %q, got %q", want_status, got)
	testing.expect(t, !s.ok, "a refused request is not served")
	testing.expectf(t, s.elapsed < 3 * time.Second, "refusal must be fast, took %v", s.elapsed)
	testing.expect_value(t, bridge_tunnel_outgoing_queued_bytes(), 0)
}

@(test)
bridge_proxy_refuses_oversized_body_with_413_before_the_hub :: proc(t: ^testing.T) {
	sync.mutex_lock(&proxy_flow_test_mu)
	defer sync.mutex_unlock(&proxy_flow_test_mu)
	proxy_flow_test_reset()
	defer proxy_flow_test_reset()
	proxy_flow_test_refusal(t,
		"POST /proxy/sh_big/up HTTP/1.1\r\nHost: x\r\nContent-Length: 83886080\r\n\r\n",
		"HTTP/1.1 413 Content Too Large")
}

@(test)
bridge_proxy_refuses_chunked_body_with_411 :: proc(t: ^testing.T) {
	sync.mutex_lock(&proxy_flow_test_mu)
	defer sync.mutex_unlock(&proxy_flow_test_mu)
	proxy_flow_test_reset()
	defer proxy_flow_test_reset()
	proxy_flow_test_refusal(t,
		"POST /proxy/sh_big/up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
		"HTTP/1.1 411 Length Required")
}
