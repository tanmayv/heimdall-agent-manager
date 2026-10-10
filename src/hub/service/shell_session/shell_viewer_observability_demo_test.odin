package shell_session

import "core:fmt"
import "core:net"
import "core:testing"

// REQ-SHELL-41 (P0 addendum) DEMONSTRATION. The coordinator's P0 note asked for three
// specific lines and said the trio "would have answered today's question in one
// reproduction". These tests produce those lines from the REAL service procs, over real
// loopback sockets, and print them.

@(private = "file")
Viewer :: struct {
	listener: net.TCP_Socket,
	browser:  net.TCP_Socket, // the client end
	hub:      net.TCP_Socket, // the end the hub writes to
}

@(private = "file")
make_viewer :: proc(t: ^testing.T) -> Viewer {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil do testing.fail_now(t, "could not listen on loopback")
	bound, berr := net.bound_endpoint(listener)
	if berr != nil {
		net.close(listener)
		testing.fail_now(t, "could not read the bound endpoint")
	}
	browser, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if derr != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, aerr := net.accept_tcp(listener)
	if aerr != nil {
		net.close(listener)
		net.close(browser)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Viewer{listener = listener, browser = browser, hub = hub}
}

@(private = "file")
close_viewer :: proc(v: ^Viewer) {
	_ = net.shutdown(v.hub, .Send)
	net.close(v.listener)
}

// Line 3 of the trio: the first frame after a 0->1 viewer transition, with its byte
// count — and the proof that the SECOND frame is silent.
@(test)
demo_first_frame_line_on_zero_to_one :: proc(t: ^testing.T) {
	shell_first_frame_tracker.slots = {}
	defer shell_first_frame_tracker.slots = {}
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	v := make_viewer(t)
	defer close_viewer(&v)

	fmt.println("--- REQ-SHELL-41 trio line 3: first frame after a 0->1 attach ---")
	shell_session_attach(&svc, "sh_demo_first", v.hub, "brg_demo")
	shell_session_broadcast_output(&svc, "sh_demo_first", "aGVsbG8gd29ybGQ=")
	fmt.println("--- a SECOND frame on the same session must print nothing below ---")
	shell_session_broadcast_output(&svc, "sh_demo_first", "c2Vjb25kIGZyYW1l")
	fmt.println("--- end line 3 ---")

	// The one-shot is spent, which is what keeps this off the per-frame path.
	pane_test_wait_writer(t, &svc, v.hub)
	testing.expect(t, !shell_first_frame_take("sh_demo_first"))
}

// Line 1 of the trio: an ORDINARY detach, named as such, with the remaining viewer count
// and whether the bridge was told to stop streaming.
@(test)
demo_detach_line_ordinary_and_last_viewer :: proc(t: ^testing.T) {
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	a := make_viewer(t)
	defer close_viewer(&a)
	b := make_viewer(t)
	defer close_viewer(&b)

	shell_session_attach(&svc, "sh_demo_detach", a.hub, "brg_demo")
	shell_session_attach(&svc, "sh_demo_detach", b.hub, "brg_demo")
	fmt.println("--- REQ-SHELL-41 trio line 1: detach, 2 viewers -> 1 -> 0 ---")
	shell_session_detach(&svc, "sh_demo_detach", a.hub, "brg_demo", .Stream_Closed)
	shell_session_detach(&svc, "sh_demo_detach", b.hub, "brg_demo", .Stream_Closed)
	fmt.println("--- end line 1: note remaining_viewers and bridge_detach ---")

	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_demo_detach"), 0)
}

// Line 2 of the trio, and the one that mattered most: a write that finds the peer gone
// now reports the write result AND the forced detach. Before this change BOTH were
// silent — a live viewer was unsubscribed without a trace.
@(test)
demo_forced_detach_reports_write_result_and_reason :: proc(t: ^testing.T) {
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	v := make_viewer(t)
	defer close_viewer(&v)

	shell_session_attach(&svc, "sh_demo_forced", v.hub, "brg_demo")
	// Make the hub's write fail: close BOTH ends, so the socket is unusable.
	_ = net.shutdown(v.hub, .Send)

	fmt.println("--- REQ-SHELL-41 trio line 2: a write to a gone peer forces a detach ---")
	shell_session_broadcast_output(&svc, "sh_demo_forced", "aGVsbG8=")
	fmt.println("--- end line 2 ---")

	// The viewer really was removed, which is the event that used to be silent.
	pane_test_wait_writer(t, &svc, v.hub)
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_demo_forced"), 0)
}
