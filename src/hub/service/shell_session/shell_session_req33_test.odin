package shell_session

// REQ-SHELL-33 (b) — the serious half.
//
// shell_session_broadcast_output used to treat ANY falsey write as a dead peer and
// call shell_session_detach. A frame the hub could not encode therefore SILENTLY
// UNSUBSCRIBED a live, healthy viewer: no error frame, no log line, no status change,
// and output simply stopped for a client that still believed it was attached — the
// state disagreement the convergence invariant forbids.
//
// These tests pin the distinction as behaviour: too-large keeps the viewer, a genuinely
// dead socket still removes it. No PTY, no browser; the viewer is a loopback socket.

import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

@(private = "file")
Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

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
	return Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
close_pair :: proc(p: ^Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}


// A payload past the 64-bit arm's bound, so the write is refused at the encode step —
// the only way to reach Too_Large now that the 65535 hole is closed.
@(private = "file")
over_cap_payload :: proc() -> string {
	n := ws.WS_MAX_SERVER_PAYLOAD + 1
	b := make([]byte, n)
	for i in 0 ..< n do b[i] = 'A'
	return string(b)
}

// THE REGRESSION. The write fails on SIZE; the socket is untouched and healthy; the
// viewer must still be attached afterwards.
@(test)
req33_a_too_large_output_frame_must_not_detach_a_live_viewer :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_big", pair.hub)
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_big"), 1)

	payload := over_cap_payload()
	defer delete(payload)
	shell_session_broadcast_output(&svc, "sh_big", payload)

	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_big"), 1)
}

// The status broadcaster had the identical bug and is fixed the same way. It is not
// cited in the ticket; it is the same three lines twenty lines further down.
@(test)
req33_a_too_large_status_frame_must_not_detach_a_live_viewer :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_status", pair.hub)
	payload := over_cap_payload()
	defer delete(payload)
	shell_session_broadcast_status(&svc, "sh_status", payload, 0, false)

	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_status"), 1)
}

// The other half of the distinction, and the reason this cannot be fixed by simply
// never detaching: a peer that IS gone must still be removed.
@(test)
req33_a_dead_viewer_is_still_detached :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_dead", pair.hub)
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_dead"), 1)

	// Half-close the SEND side rather than closing the socket. Closing it frees the
	// fd, and with the test runner on four threads another test can be handed the
	// same number before this write lands — the write then succeeds on somebody
	// else's socket and the viewer is never detached. shutdown(.Send) makes every
	// further send fail with EPIPE deterministically and keeps the fd ours.
	_ = net.shutdown(pair.hub, .Send)

	shell_session_broadcast_output(&svc, "sh_dead", "aGk=")
	pane_test_wait_writer(t, &svc, pair.hub)
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_dead"), 0)
}

// A healthy viewer receiving a frame it can take must simply stay.
@(test)
req33_a_healthy_viewer_stays_attached :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_ok", pair.hub)
	shell_session_broadcast_output(&svc, "sh_ok", "aGVsbG8=")
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_ok"), 1)
}

// --- the fan-out must write under the session write lock ---------------------------

// The snapshot writer holds this lock across a whole multi-frame sequence, which only
// keeps the repaint intact if the OTHER writer honours it too. Proven directly: hold the
// lock, and a broadcast must not complete until it is released.
@(private = "file")
Blocked_Broadcast :: struct {
	svc:  ^Shell_Session_Service,
	done: bool,
}

@(private = "file")
broadcast_worker :: proc(raw: rawptr) {
	b := (^Blocked_Broadcast)(raw)
	shell_session_broadcast_output(b.svc, "sh_lock", "QUJD")
	sync.atomic_store(&b.done, true)
}

@(test)
req33_the_fan_out_writes_under_the_session_write_lock :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)
	shell_session_attach(&svc, "sh_lock", pair.hub)

	write_mu := shell_session_viewer_write_lock(&svc, "sh_lock")
	testing.expect(t, write_mu != nil, "an attached session must have a write lock")
	sync.mutex_lock(write_mu)

	blocked := Blocked_Broadcast{svc = &svc}
	th := thread.create_and_start_with_data(rawptr(&blocked), broadcast_worker)
	defer thread.destroy(th)

	time.sleep(100 * time.Millisecond)
	testing.expect(
		t,
		!sync.atomic_load(&blocked.done),
		"the fan-out completed while the session write lock was held — it is not taking it, so a chunked snapshot can be split by an output frame",
	)

	sync.mutex_unlock(write_mu)
	shell_session_viewer_write_release(&svc, "sh_lock")
	thread.join(th)
	testing.expect(t, sync.atomic_load(&blocked.done), "the fan-out must proceed once the lock is released")
}
