package http

import "core:fmt"
import "core:net"
import "core:testing"
import "core:time"

// REQ-SHELL-41 AC6: DEMONSTRATION, NOT JUST PRESENCE.
//
// This task is about observability, so "the code is there" is not evidence. Each test
// below drives a REAL loopback socket into one of the teardown conditions, asserts the
// reason the reader derives from it, and PRINTS the actual log line the hub would emit.
// Run it with -define:ODIN_TEST_NAMES=... to read the lines; the assertions make it a
// regression test rather than a one-off demo.

@(private = "file")
Demo_Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket, // stands in for the bridge
	hub:      net.TCP_Socket, // the side the hub reads
}

@(private = "file")
demo_pair :: proc(t: ^testing.T) -> Demo_Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read the bound endpoint")
	}
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(peer)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Demo_Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
close_demo_pair :: proc(p: ^Demo_Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

// emit prints the connect/disconnect pair for one scenario exactly as the hub would,
// with a plausible connection lifetime, so AC6 shows real output rather than a mock.
@(private = "file")
emit :: proc(bridge_id: string, reason: Bridge_WS_Disconnect_Reason, duration_ms: i64, cascaded: bool) {
	bridge_ws_log_limiter.slots = {} // each scenario gets a fresh budget
	bridge_ws_log_connect(bridge_id, "127.0.0.1:54321", 7, false)
	bridge_ws_log_disconnect(bridge_id, reason, 7, duration_ms, cascaded)
}

// The bridge sends a WS close frame: an orderly goodbye.
@(test)
demo_disconnect_reason_clean_close :: proc(t: ^testing.T) {
	p := demo_pair(t)
	defer close_demo_pair(&p)
	reader := bridge_ws_reader_make(p.hub)
	defer bridge_ws_reader_destroy(&reader)

	_, _ = net.send_tcp(p.peer, []byte{0x88, 0x80, 0x00, 0x00, 0x00, 0x00}) // masked close
	_, ok, reason := bridge_ws_read_frame(&reader, 2 * time.Second)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, Bridge_WS_Disconnect_Reason.Clean_Close)
	emit("brg_demo_close", reason, 43_912, true)
}

// The bridge vanishes without a close frame — a graceful TCP FIN. core:net reports this
// as `0, nil`, which the previous reader lumped into its error arm.
@(test)
demo_disconnect_reason_peer_fin :: proc(t: ^testing.T) {
	p := demo_pair(t)
	defer close_demo_pair(&p)
	reader := bridge_ws_reader_make(p.hub)
	defer bridge_ws_reader_destroy(&reader)

	net.close(p.peer)
	_, ok, reason := bridge_ws_read_frame(&reader, 2 * time.Second)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, Bridge_WS_Disconnect_Reason.Clean_Close)
	emit("brg_demo_fin", reason, 1_204, true)
}

// Nothing arrives before the deadline. THIS is the 120s case in the runtime loop; the
// test uses a short deadline so the suite stays fast.
@(test)
demo_disconnect_reason_read_deadline :: proc(t: ^testing.T) {
	p := demo_pair(t)
	defer close_demo_pair(&p)
	reader := bridge_ws_reader_make(p.hub)
	defer bridge_ws_reader_destroy(&reader)

	start := time.now()
	_, ok, reason := bridge_ws_read_frame(&reader, 150 * time.Millisecond)
	elapsed := time.since(start)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, Bridge_WS_Disconnect_Reason.Read_Deadline)
	// It really waited rather than failing instantly for some other cause.
	testing.expect(t, elapsed >= 100 * time.Millisecond, "the deadline was not actually awaited")
	emit("brg_demo_deadline", reason, 120_037, true)
}

// A 64-bit payload length desyncs the reader: unusable stream, not a goodbye. This is
// the case REQ-SHELL-32 needed to observe and could not.
@(test)
demo_disconnect_reason_fatal_desync :: proc(t: ^testing.T) {
	p := demo_pair(t)
	defer close_demo_pair(&p)
	reader := bridge_ws_reader_make(p.hub)
	defer bridge_ws_reader_destroy(&reader)

	_, _ = net.send_tcp(p.peer, []byte{0x81, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	_, ok, reason := bridge_ws_read_frame(&reader, 2 * time.Second)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, Bridge_WS_Disconnect_Reason.Fatal_Frame)
	emit("brg_demo_desync", reason, 8_775, true)
}

// A healthy frame must NOT produce a teardown reason — the control that keeps the four
// cases above from being vacuous.
@(test)
demo_healthy_frame_is_not_a_teardown :: proc(t: ^testing.T) {
	p := demo_pair(t)
	defer close_demo_pair(&p)
	reader := bridge_ws_reader_make(p.hub)
	defer bridge_ws_reader_destroy(&reader)

	frame := masked_heartbeat_frame()
	defer delete(frame)
	_, _ = net.send_tcp(p.peer, frame[:])
	text, ok, reason := bridge_ws_read_frame(&reader, 2 * time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, reason, Bridge_WS_Disconnect_Reason.None)
	delete(text)
}

@(private = "file")
masked_heartbeat_frame :: proc() -> [dynamic]byte {
	text := "{\"type\":\"bridge_heartbeat\"}"
	mask := [4]byte{0x11, 0x22, 0x33, 0x44}
	out := make([dynamic]byte)
	append(&out, 0x81, byte(0x80 | len(text)))
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< len(text) do append(&out, text[i] ~ mask[i % 4])
	return out
}

// AC5, demonstrated rather than asserted: what a flapping bridge actually looks like in
// the log. Prints the admitted lines and the suppression notice.
@(test)
demo_reconnect_storm_is_bounded :: proc(t: ^testing.T) {
	bridge_ws_log_limiter.slots = {}
	defer bridge_ws_log_limiter.slots = {}
	fmt.println("--- REQ-SHELL-41 AC5: 50 reconnects inside one window ---")
	for i in 0 ..< 50 {
		bridge_ws_log_connect("brg_demo_flap", "127.0.0.1:54321", i, true)
		bridge_ws_log_disconnect("brg_demo_flap", .Read_Deadline, i, 1_000, true)
	}
	fmt.println("--- window rolls over; the backlog is reported, not lost ---")
	// Simulate the next window by ageing the slot back past the window length.
	for i in 0 ..< BRIDGE_WS_LOG_SLOTS {
		s := &bridge_ws_log_limiter.slots[i]
		if s.id_len > 0 do s.window_start_ns -= i64(BRIDGE_WS_LOG_WINDOW)
	}
	bridge_ws_log_connect("brg_demo_flap", "127.0.0.1:54321", 99, true)
	fmt.println("--- end AC5 demonstration ---")
}
