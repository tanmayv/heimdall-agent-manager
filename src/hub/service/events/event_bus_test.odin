package events

// REQ-SHELL-35 — one oversized event must not unsubscribe a browser from every event.
//
// No browser and no HTTP stack: a loopback pair stands in for a /user WebSocket, because
// what has to be true is a property of the BUS STATE after a write and of the BYTES that
// reach the peer, neither of which needs a real client.
//
// The assertions are deliberately PAIRED: for every case that must not remove the slot,
// the test also proves the slot is still USABLE afterwards (a following event arrives).
// Checking connected[i] alone would pass just as well if the fix had left a dead socket in
// the table, and checking delivery alone would pass if removal had simply been disabled —
// which is what req35_a_dead_peer_is_still_removed exists to rule out.

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import ws "odin_test:lib/ws"

@(private = "file")
Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
PAIR_BUFFER_BYTES :: 8 * 1024 * 1024

@(private = "file")
make_pair :: proc(t: ^testing.T) -> Pair {
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
	// A frame larger than the socket buffer would block the writer rather than
	// complete, so the buffers are enlarged to keep these tests about FRAMING.
	_ = net.set_option(hub, .Send_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Timeout, 500 * time.Millisecond)
	return Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
close_pair :: proc(p: ^Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

// drain reads until the peer goes quiet. Caller owns the result.
@(private = "file")
drain :: proc(sock: net.TCP_Socket) -> []byte {
	out := make([dynamic]byte)
	buf: [65536]byte
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&out, ..buf[:n])
	}
	return out[:]
}

// split_text_frames parses unmasked server->client text frames out of a byte stream,
// returning each frame's PAYLOAD. ok=false means the stream was malformed — which is a
// failure worth reporting in its own right, since a half-written frame is exactly the
// .Desynchronised condition. Payloads alias `raw`; the caller owns nothing.
@(private = "file")
split_text_frames :: proc(raw: []byte) -> (payloads: [dynamic]string, ok: bool) {
	payloads = make([dynamic]string)
	pos := 0
	for pos < len(raw) {
		if len(raw) - pos < 2 do return payloads, false
		if raw[pos] != 0x81 do return payloads, false
		n := int(raw[pos + 1] & 0x7f)
		header := 2
		if n == 126 {
			if len(raw) - pos < 4 do return payloads, false
			n = int(raw[pos + 2]) << 8 | int(raw[pos + 3])
			header = 4
		} else if n == 127 {
			if len(raw) - pos < 10 do return payloads, false
			n = 0
			for i in 0 ..< 8 do n = n << 8 | int(raw[pos + 2 + i])
			header = 10
		}
		if len(raw) - pos - header < n do return payloads, false
		append(&payloads, string(raw[pos + header:pos + header + n]))
		pos += header + n
	}
	return payloads, true
}

@(private = "file")
OWNER :: "usr_req35"

// AC1 — THE DEFECT. An event the hub cannot encode at all must cost that one event and
// nothing else. Sized past WS_MAX_SERVER_PAYLOAD so it is refused by the writer even with
// the 64-bit arm available, which is now the only way to reach a refusal.
@(test)
req35_oversized_event_keeps_the_client_subscribed :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	bus: User_Event_Bus
	idx := user_ws_add(&bus, OWNER, pair.hub)
	testing.expect_value(t, idx, 0)

	huge := strings.repeat("h", ws.WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(huge)
	publish_raw_to_user(&bus, OWNER, huge)

	// The slot survives, the table is untouched, and nothing was counted as a removal.
	testing.expect(t, bus.connected[idx], "an event the hub could not encode must NOT unsubscribe the client")
	testing.expect_value(t, bus.owner_user_ids[idx], OWNER)
	testing.expect_value(t, bus.client_count, 1)
	testing.expect_value(t, bus.sockets_removed, 0)
	// AC4 — the drop is counted, not silent.
	testing.expect_value(t, bus.oversized_events_dropped, 1)

	// Still SUBSCRIBED, not merely still marked connected: the next event arrives, and it
	// arrives as the only thing on the wire — no fragment of the refused frame preceded it.
	publish_raw_to_user(&bus, OWNER, `{"type":"after"}`)
	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the stream must be well-formed — a refusal must not put bytes on the wire")
	testing.expect_value(t, len(frames), 1)
	testing.expect_value(t, frames[0], `{"type":"after"}`)
}

// AC2 — DELIVERY, not survival. 80 KB is the size the old writer returned false for (and
// therefore unsubscribed on); with the 64-bit arm it is simply sent. Read back off the wire
// as ONE well-formed 127-length frame, because "the call returned Ok" is not the claim.
@(test)
req35_event_over_65535_is_actually_delivered :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	bus: User_Event_Bus
	idx := user_ws_add(&bus, OWNER, pair.hub)
	testing.expect_value(t, idx, 0)

	// A realistic shape rather than 80 KB of filler: the field that is actually unbounded
	// on this bus is a summary string riding a resource_changed event.
	long_name := strings.repeat("n", 80_000)
	defer delete(long_name)
	summary := strings.concatenate({`{"display_name":"`, long_name, `"}`})
	defer delete(summary)
	publish_resource_changed(&bus, OWNER, "agent_instance", "ain_req35", "status_changed", summary)

	testing.expect(t, bus.connected[idx], "a large but encodable event must not unsubscribe the client")
	testing.expect_value(t, bus.oversized_events_dropped, 0)
	testing.expect_value(t, bus.sockets_removed, 0)

	raw := drain(pair.peer)
	defer delete(raw)
	testing.expect(t, len(raw) > ws.WS_16BIT_MAX_PAYLOAD, "the whole payload must have reached the peer")
	// The 127 arm, spelled out: the old writer had no 8-byte length case at all.
	testing.expect_value(t, raw[0], 0x81)
	testing.expect_value(t, raw[1] & 0x7f, 127)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the frame must be well-formed")
	testing.expect_value(t, len(frames), 1)
	testing.expect(t, strings.contains(frames[0], long_name), "the payload must arrive intact, not truncated")
}

// The other half of AC1, and the reason it is a TYPE and not a relaxed bool: a peer that is
// genuinely gone must STILL be removed. Without this, "stop unsubscribing on write failure"
// would pass as a fix while leaking every dead slot in a fixed 128-entry table.
@(test)
req35_a_dead_peer_is_still_removed :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	bus: User_Event_Bus
	idx := user_ws_add(&bus, OWNER, pair.hub)
	testing.expect_value(t, idx, 0)

	// SHUT_WR on the hub end, NOT net.close. Two reasons, both learned the hard way:
	//
	//  1. DETERMINISM. Closing only the remote end is not enough on loopback — the first
	//     send after a peer close usually succeeds and only the second sees EPIPE, which
	//     would make this test depend on TCP timing rather than on the removal rule.
	//     A shutdown for sending fails the very next send_tcp, every time.
	//  2. IT DOES NOT RELEASE THE DESCRIPTOR. Closing the hub socket and then writing to
	//     it writes to a FREED fd number, and the test runner runs packages on 4 threads:
	//     another test's freshly-accepted socket takes that number and receives this
	//     event. That is not hypothetical — it is what this test did before, and it made
	//     two unrelated tests in this file fail with each other's payloads.
	net.shutdown(net.Any_Socket(pair.hub), .Send)

	publish_raw_to_user(&bus, OWNER, `{"type":"to_a_dead_peer"}`)

	testing.expect(t, !bus.connected[idx], "a peer that is gone MUST be removed")
	testing.expect_value(t, bus.owner_user_ids[idx], "")
	testing.expect_value(t, bus.sockets_removed, 1)
	// A dead peer is not an encoding refusal and must not be counted as one.
	testing.expect_value(t, bus.oversized_events_dropped, 0)
	// Nor is it a desynchronised stream. A closed tab is the ORDINARY removal and must not
	// land in the counter that exists to make a half-written frame findable — if it did,
	// the alarming case would be permanently hidden inside everyday traffic.
	testing.expect_value(t, bus.desynchronised_removals, 0)
}

// Fan-out is per-connection: one client's refused event must not disturb another's. The
// old code removed on the same bool for every socket in the loop, so a single oversized
// event unsubscribed EVERY connection the user had.
@(test)
req35_one_refused_event_does_not_disturb_the_users_other_connections :: proc(t: ^testing.T) {
	a := make_pair(t)
	defer close_pair(&a)
	b := make_pair(t)
	defer close_pair(&b)
	bus: User_Event_Bus
	testing.expect_value(t, user_ws_add(&bus, OWNER, a.hub), 0)
	testing.expect_value(t, user_ws_add(&bus, OWNER, b.hub), 1)

	huge := strings.repeat("h", ws.WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(huge)
	publish_raw_to_user(&bus, OWNER, huge)

	testing.expect(t, bus.connected[0], "connection 0 must stay subscribed")
	testing.expect(t, bus.connected[1], "connection 1 must stay subscribed")
	testing.expect_value(t, bus.client_count, 2)
	testing.expect_value(t, bus.sockets_removed, 0)
	// Counted once per CONNECTION the event could not reach, which is what an operator
	// reading the warn line sees.
	testing.expect_value(t, bus.oversized_events_dropped, 2)

	publish_raw_to_user(&bus, OWNER, `{"type":"both"}`)
	for sock in ([]net.TCP_Socket{a.peer, b.peer}) {
		raw := drain(sock)
		defer delete(raw)
		frames, parse_ok := split_text_frames(raw)
		defer delete(frames)
		testing.expect(t, parse_ok, "each stream must be well-formed")
		testing.expect_value(t, len(frames), 1)
		testing.expect_value(t, frames[0], `{"type":"both"}`)
	}
}

// AC3 — nothing bespoke is left. The control-frame wrapper and the fan-out path must agree
// on the arm, or the handshake and the events would disagree about what a browser can be
// sent. Asserted through the wrapper the /user upgrade actually calls.
@(test)
req35_the_control_frame_wrapper_uses_the_browser_arm :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	big := strings.repeat("r", ws.WS_16BIT_MAX_PAYLOAD + 1)
	defer delete(big)
	testing.expect(t, write_ws_text_frame(pair.hub, big), "the user socket is a browser: the 64-bit arm applies here too")

	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the frame must be well-formed")
	testing.expect_value(t, len(frames), 1)
	testing.expect_value(t, len(frames[0]), ws.WS_16BIT_MAX_PAYLOAD + 1)
}

// The decision table itself, all four arms, exhaustively. REQ-SHELL-35.
//
// This exists because the counter tests above can only prove the arms they can REACH. An
// oversized frame and a shut-down socket are easy to stage; a genuine .Desynchronised — the
// hub getting a partial write onto the wire — needs a socket buffer filled to the byte and
// would be a flaky test if written that way. So the reachable arms are asserted end-to-end
// through publish_raw_to_user above, and the decision is ALSO pinned here directly, where
// .Desynchronised costs nothing to express.
//
// Asserting it as a table rather than case-by-case is deliberate: the defect this task
// fixed was a two-valued answer to a four-valued question, and a table is the shape that
// makes a future fifth arm a visible omission instead of a silent fallthrough.
@(test)
req35_the_removal_decision_covers_every_result_arm :: proc(t: ^testing.T) {
	// "Can the hub not encode this?" -> keep the client. "Is the peer finished?" -> drop it.
	testing.expect(t, !_publish_write_removes_socket(.Ok), "a successful write must never remove the socket")
	testing.expect(t, !_publish_write_removes_socket(.Too_Large), "an unencodable frame says NOTHING about the peer — this is the defect")
	testing.expect(t, _publish_write_removes_socket(.Peer_Gone), "a peer that is gone must be removed")
	testing.expect(t, _publish_write_removes_socket(.Desynchronised), "half a frame on the wire must end the connection, not be retried on it")
}
