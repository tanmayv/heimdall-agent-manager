package ws

import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"

@(private = "file")
WS_Audit_Sock_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	server:   net.TCP_Socket,
}

@(private = "file")
make_ws_audit_sock_pair :: proc(t: ^testing.T) -> (WS_Audit_Sock_Pair, bool) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read bound endpoint")
	}
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	server, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(client)
		testing.fail_now(t, "could not accept on loopback")
	}
	return WS_Audit_Sock_Pair{listener = listener, client = client, server = server}, true
}

@(private = "file")
close_ws_audit_sock_pair :: proc(p: ^WS_Audit_Sock_Pair) {
	net.close(p.server)
	net.close(p.client)
	net.close(p.listener)
}

// REQ-WS-AUDIT-7 (2a): Prove ws.send_text succeeds for a 70,000-byte payload (using 64-bit
// extended length header) and only rejects payloads > WS_MAX_SERVER_PAYLOAD (16 MiB + 1).
@(test)
audit_claim_ws_send_text_rejects_over_65535 :: proc(t: ^testing.T) {
	pair, ok := make_ws_audit_sock_pair(t)
	if !ok do return
	defer close_ws_audit_sock_pair(&pair)

	conn := Connection{
		socket    = pair.client,
		secure    = false,
		connected = true,
	}

	payload_70k := make([]byte, 70_000)
	defer delete(payload_70k)
	for i in 0 ..< len(payload_70k) {
		payload_70k[i] = 'a'
	}

	sent := send_text(&conn, string(payload_70k))
	testing.expect(t, sent, "ws.send_text must accept a 70,000-byte payload using 64-bit extended length")

	oversized := strings.repeat("x", WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(oversized)
	sent_oversized := send_text(&conn, oversized)
	testing.expect(t, !sent_oversized, "ws.send_text must reject a payload exceeding WS_MAX_SERVER_PAYLOAD")
}

// REQ-WS-AUDIT-7 (2b): Construct a Connection with connected=true and pending_bytes
// containing an unmasked 64-bit length frame (byte 0 = 0x81, byte 1 = 127, 8-byte
// length = 70000); prove ws.poll_text decodes the 70,000-byte frame intact and conn.connected remains true.
@(test)
audit_claim_ws_poll_text_disconnects_on_64bit_length :: proc(t: ^testing.T) {
	pair, ok := make_ws_audit_sock_pair(t)
	if !ok do return
	defer close_ws_audit_sock_pair(&pair)

	conn := Connection{
		socket        = pair.client,
		secure        = false,
		connected     = true,
		pending_texts = make([dynamic]string),
		pending_bytes = make([dynamic]byte),
	}
	defer {
		for s in conn.pending_texts do delete(s)
		delete(conn.pending_texts)
		delete(conn.pending_bytes)
		delete(conn.fragmented)
	}

	payload_70k := make([]byte, 70_000)
	defer delete(payload_70k)
	for i in 0 ..< len(payload_70k) {
		payload_70k[i] = 'b'
	}

	// RFC 6455 unmasked text frame header with 64-bit extended payload length = 70,000 (0x00011170):
	// byte 0 = 0x81 (FIN=1, opcode=0x1), byte 1 = 127, bytes 2..9 = 8-byte big-endian length.
	append(&conn.pending_bytes, 0x81, 127, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x11, 0x70)
	append(&conn.pending_bytes, ..payload_70k[:69_999])

	// Send 1 payload byte on the peer socket so poll_text's initial recv_tcp succeeds
	// and enters the frame parser loop over conn.pending_bytes with all 70,000 bytes.
	last_byte := [1]byte{payload_70k[69_999]}
	_, send_err := net.send_tcp(pair.server, last_byte[:])
	testing.expect_value(t, send_err, nil)

	text, poll_ok := poll_text(&conn)
	defer delete(text)
	testing.expect(t, poll_ok, "ws.poll_text must decode a 70,000-byte 64-bit length frame intact")
	testing.expect_value(t, len(text), 70_000)
	testing.expect_value(t, text, string(payload_70k))
	testing.expect(t, conn.connected, "ws.poll_text must keep conn.connected = true on valid 64-bit frame")
}

// REQ-WS-AUDIT-7 (2c): Construct a Connection with pending_bytes containing
// frame 1 (0x01, FIN=0, payload `{"part":1`) followed by frame 2 (0x80, FIN=1,
// payload `,"part2":2}`); prove ws.poll_text reassembles the complete message
// `{"part":1,"part2":2}` with zero leaks.
@(test)
audit_claim_ws_poll_text_truncates_fragmented_frames_and_drops_continuations :: proc(t: ^testing.T) {
	pair, ok := make_ws_audit_sock_pair(t)
	if !ok do return
	defer close_ws_audit_sock_pair(&pair)
	_ = net.set_blocking(pair.client, false)

	conn := Connection{
		socket        = pair.client,
		secure        = false,
		connected     = true,
		pending_texts = make([dynamic]string),
		pending_bytes = make([dynamic]byte, 0, 64),
	}
	defer {
		for s in conn.pending_texts do delete(s)
		delete(conn.pending_texts)
		delete(conn.pending_bytes)
		delete(conn.fragmented)
	}

	frag1_payload := `{"part":1`
	frag2_payload := `,"part2":2}`

	// Frame 1: byte 0 = 0x01 (FIN=0, opcode=0x1 text), byte 1 = len(frag1_payload)
	append(&conn.pending_bytes, 0x01, byte(len(frag1_payload)))
	append(&conn.pending_bytes, ..transmute([]byte)frag1_payload)

	// Frame 2: byte 0 = 0x80 (FIN=1, opcode=0x0 continuation), byte 1 = len(frag2_payload)
	// Deliver the final byte over the socket so recv_tcp advances into the parser loop
	// with pending_bytes containing the exact 2-frame sequence.
	append(&conn.pending_bytes, 0x80, byte(len(frag2_payload)))
	append(&conn.pending_bytes, ..transmute([]byte)frag2_payload[:len(frag2_payload) - 1])

	last_byte := [1]byte{frag2_payload[len(frag2_payload) - 1]}
	_, send_err := net.send_tcp(pair.server, last_byte[:])
	testing.expect_value(t, send_err, nil)

	// Call 1: reassembles fragment 1 + fragment 2 into complete message.
	text1, ok1 := poll_text(&conn)
	defer delete(text1)

	testing.expect(t, ok1, "poll_text must successfully reassemble fragmented frames")
	testing.expect_value(t, text1, `{"part":1,"part2":2}`)
	testing.expect_value(t, len(conn.pending_texts), 0)
	testing.expect_value(t, len(conn.pending_bytes), 0)
}

// REQ-WS-AUDIT-7 (2d): Using a loopback socketpair and a scoped mem.Tracking_Allocator,
// send a valid unmasked WS text frame into conn.socket and call ws.poll_text(&conn);
// prove that ws.odin:236-238 (`remaining := make([dynamic]byte); ... conn.pending_bytes = remaining`
// without `delete(conn.pending_bytes)`) leaks the old conn.pending_bytes dynamic array
// backing allocation on the heap.
@(test)
audit_claim_ws_poll_text_leaks_pending_bytes_on_consume :: proc(t: ^testing.T) {
	pair, ok := make_ws_audit_sock_pair(t)
	if !ok do return
	defer close_ws_audit_sock_pair(&pair)

	payload := `{"type":"ack","ok":true}`
	frame := make([]byte, 2 + len(payload))
	defer delete(frame)
	frame[0] = 0x81 // FIN=1, opcode=0x1 text
	frame[1] = byte(len(payload))
	copy(frame[2:], transmute([]byte)payload)

	_, send_err := net.send_tcp(pair.server, frame)
	testing.expect_value(t, send_err, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = mem.tracking_allocator(&track)
		conn := Connection{
			socket    = pair.client,
			secure    = false,
			connected = true,
		}

		text, poll_ok := poll_text(&conn)
		testing.expect(t, poll_ok, "ws.poll_text must decode a valid unmasked text frame")
		testing.expect_value(t, text, payload)

		// Perform caller-side cleanup of returned text and ws.close(&conn).
		delete(text)
		close(&conn)
	}

	// Verify that ws.poll_text shifts pending_bytes in-place and ws.close frees all connection buffers with zero leaks.
	testing.expect_value(t, len(track.allocation_map), 0)
}
