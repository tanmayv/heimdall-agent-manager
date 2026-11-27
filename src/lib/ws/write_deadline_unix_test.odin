#+build !windows
package ws

import "core:net"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:time"
import tls "../tls_stream"

// The Unix TLS transport is a relay subprocess behind a pipe; these drive its
// writer directly through a bare pipe.

@(test)
tls_pipe_write_obeys_total_deadline :: proc(t: ^testing.T) {
	r, w, err := os.pipe()
	testing.expect(t, err == nil)
	defer os.close(r)
	defer os.close(w)
	stream := tls.Stream{stdin_w = w}
	data := make([]byte, 1024 * 1024)
	defer delete(data)
	before := send_timeouts()
	started := time.tick_now()
	ok := send_all_tls(&stream, data)
	elapsed := time.tick_since(started)
	testing.expect(t, !ok, "a full undrained pipe must fail")
	testing.expect(t, elapsed >= WRITE_DEADLINE && elapsed < WRITE_DEADLINE + time.Second)
	testing.expect(t, send_timeouts() > before, "TLS timeout must be observable")
}

@(test)
tls_pipe_small_write_is_exact :: proc(t: ^testing.T) {
	r, w, err := os.pipe()
	testing.expect(t, err == nil)
	defer os.close(r)
	defer os.close(w)
	stream := tls.Stream{stdin_w = w}
	payload := "payload"
	testing.expect(t, send_all_tls(&stream, transmute([]byte)payload))
	data: [7]byte
	n, read_err := os.read(r, data[:])
	testing.expect(t, read_err == nil)
	testing.expect_value(t, n, 7)
	testing.expect_value(t, string(data[:]), "payload")
}

// A non-reading Bridge must not be disconnected just because optional input
// arrives while its TCP send queue is full.
@(test)
optional_write_drops_without_touching_saturated_connection :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK) do return
	hub, peer := net.TCP_Socket(fds[0]), net.TCP_Socket(fds[1])
	defer net.close(hub)
	defer net.close(peer)
	if !testing.expect(t, net.set_option(hub, .Send_Buffer_Size, 4096) == nil) do return
	if !testing.expect(t, net.set_option(peer, .Receive_Timeout, time.Second) == nil) do return
	filler_bytes := make([]byte, 8 * 1024 * 1024)
	defer delete(filler_bytes)
	filled, complete := send_socket_bytes(hub, filler_bytes, 100 * time.Millisecond, record_timeout = false)
	if !testing.expectf(t, !complete && filled > 0, "fixture must fill the socket before input: sent=%d complete=%t", filled, complete) do return

	input := [4]byte{0x81, 2, 'i', 'n'}
	started := time.tick_now()
	sent, ok := send_socket_bytes(hub, input[:], record_timeout = false, start_timeout = 10 * time.Millisecond)
	testing.expect(t, !ok && sent == 0, "drop without starting the frame")
	if !testing.expect(t, time.tick_since(started) < time.Second, "admission must not wait for the normal deadline") do return

	buf: [8192]byte
	remaining := filled
	for remaining > 0 {
		n, err := net.recv_tcp(peer, buf[:min(remaining, len(buf))])
		if !testing.expect(t, n > 0 && err == nil) do return
		remaining -= n
	}

	if !testing.expect_value(t, write_server_text(hub, "still connected", false), Text_Write_Result.Ok) do return
	expected := "\x81\x0fstill connected"
	frame: [17]byte
	for got := 0; got < len(frame); {
		n, err := net.recv_tcp(peer, frame[got:])
		if !testing.expect(t, n > 0 && err == nil) do return
		got += n
	}
	testing.expect_value(t, string(frame[:]), expected)
}

// A write that has already started must survive the short admission deadline,
// even if its peer stops reading. Only the normal deadline can cut it short.
@(test)
optional_write_promotes_deadline_after_first_bytes :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK) do return
	hub, peer := net.TCP_Socket(fds[0]), net.TCP_Socket(fds[1])
	defer net.close(hub)
	defer net.close(peer)
	if !testing.expect(t, net.set_option(hub, .Send_Buffer_Size, 4096) == nil) do return
	data := make([]byte, 8 * 1024 * 1024)
	defer delete(data)
	budget := 150 * time.Millisecond
	started := time.tick_now()
	sent, ok := send_socket_bytes(hub, data, budget, record_timeout = false, start_timeout = 10 * time.Millisecond)
	testing.expectf(t, !ok && sent > 0 && sent < len(data), "fixture must stall partway through the write: sent=%d complete=%t elapsed=%v", sent, ok, time.tick_since(started))
	testing.expect(t, time.tick_since(started) >= budget, "progress must switch the writer to the normal deadline")
}
