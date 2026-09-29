package ws

// REQ-SHELL-33 — the missing 64-bit length arm, the short-write case, and the typed
// result, tested without a PTY and without a browser.
//
// The framing tests are pure (server_frame_header takes a buffer, not a socket) and the
// socket tests use a loopback pair with ENLARGED buffers so a >64KB write completes
// without a draining peer. That is the opposite of lsp_session_send_timeout_test.odin,
// which deliberately stalls the peer — here the peer must NOT stall, because what is
// under test is that a large frame goes out intact.

import "core:net"
import "core:testing"
import "core:time"

@(private = "file")
Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

// 4 MiB each way: comfortably above the largest frame these tests write, so send never
// blocks on a peer that is not reading yet.
@(private = "file")
PAIR_BUFFER_BYTES :: 4 * 1024 * 1024

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
	_ = net.set_option(hub, .Send_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Timeout, 2 * time.Second)
	return Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
close_pair :: proc(p: ^Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

@(private = "file")
filler :: proc(n: int) -> string {
	b := make([]byte, n)
	for i in 0 ..< n do b[i] = 'x'
	return string(b)
}

// --- framing --------------------------------------------------------------------

@(test)
req33_header_uses_the_one_byte_arm_under_126 :: proc(t: ^testing.T) {
	out: [16]byte
	used := server_frame_header(out[:], 125)
	testing.expect_value(t, used, 2)
	testing.expect_value(t, out[0], byte(0x81))
	testing.expect_value(t, out[1], byte(125))
	testing.expect_value(t, server_frame_header_len(125), 2)
}

@(test)
req33_header_uses_the_16_bit_arm_up_to_65535 :: proc(t: ^testing.T) {
	out: [16]byte
	used := server_frame_header(out[:], WS_16BIT_MAX_PAYLOAD)
	testing.expect_value(t, used, 4)
	testing.expect_value(t, out[1], byte(126))
	testing.expect_value(t, out[2], byte(0xff))
	testing.expect_value(t, out[3], byte(0xff))
	testing.expect_value(t, server_frame_header_len(WS_16BIT_MAX_PAYLOAD), 4)
}

// The arm whose absence IS this defect. 65536 is the first length the 126 encoding
// cannot express, and every hub writer used to give up here.
@(test)
req33_header_uses_the_64_bit_arm_above_65535 :: proc(t: ^testing.T) {
	out: [16]byte
	n := 65536
	used := server_frame_header(out[:], n)
	testing.expect_value(t, used, 10)
	testing.expect_value(t, out[1], byte(127))
	testing.expect_value(t, server_frame_header_len(n), 10)
	decoded := 0
	for i in 0 ..< 8 do decoded = decoded << 8 | int(out[2 + i])
	testing.expect_value(t, decoded, n)
	// RFC 6455 requires the most significant bit of a 64-bit length to be 0.
	testing.expect(t, out[2] & 0x80 == 0, "the 64-bit length must not set the high bit")
}

// --- the typed result -----------------------------------------------------------

// A bridge-channel writer must still refuse >65535 — our own readers kill the
// connection on a 127 length (ws.odin take_text, bridge_ws_take_frame) — but it must
// refuse with Too_Large, which is a statement about the FRAME, not the peer.
@(test)
req33_16_bit_channel_refuses_oversize_as_too_large_not_peer_gone :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	text := filler(WS_16BIT_MAX_PAYLOAD + 1)
	defer delete(text)
	testing.expect_value(t, write_server_text(pair.hub, text, false), Text_Write_Result.Too_Large)
	// The socket is untouched: a frame that fits still goes out on it afterwards.
	testing.expect_value(t, write_server_text(pair.hub, "still alive", false), Text_Write_Result.Ok)
}

// The whole point: a payload the old writers dropped now reaches the peer, header and
// body intact.
@(test)
req33_browser_channel_writes_a_64_bit_frame_intact :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	n := 70_000
	text := filler(n)
	defer delete(text)
	testing.expect_value(t, write_server_text(pair.hub, text, true), Text_Write_Result.Ok)

	buf := make([]byte, 10 + n)
	defer delete(buf)
	got := 0
	for got < len(buf) {
		read, err := net.recv_tcp(pair.peer, buf[got:])
		if err != nil || read <= 0 do break
		got += read
	}
	testing.expect_value(t, got, len(buf))
	testing.expect_value(t, buf[0], byte(0x81))
	testing.expect_value(t, buf[1], byte(127))
	length := 0
	for i in 0 ..< 8 do length = length << 8 | int(buf[2 + i])
	testing.expect_value(t, length, n)
	testing.expect_value(t, buf[10], byte('x'))
	testing.expect_value(t, buf[len(buf) - 1], byte('x'))
}

// The 64-bit arm is bounded on purpose: the frame is one contiguous allocation, so
// "it fits in a u64" must not become an unbounded allocation driven by a pane size.
@(test)
req33_the_64_bit_arm_is_bounded :: proc(t: ^testing.T) {
	text := filler(WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(text)
	// No socket is needed and none is touched — the refusal happens before the frame
	// is built, which is exactly what makes Too_Large safe to treat as non-fatal.
	testing.expect_value(t, write_server_text(net.TCP_Socket(0), text, true), Text_Write_Result.Too_Large)
}

// A socket whose peer is gone must be reported as Peer_Gone and NOT confused with a
// frame we declined to encode.
@(test)
req33_a_dead_socket_is_peer_gone :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	// Half-close rather than close: a closed fd can be recycled by a concurrent test
	// and the write would then land on a healthy socket. See the twin note in
	// shell_session_req33_test.odin.
	_ = net.shutdown(pair.hub, .Send)
	testing.expect_value(t, write_server_text(pair.hub, "anyone there", true), Text_Write_Result.Peer_Gone)
}
