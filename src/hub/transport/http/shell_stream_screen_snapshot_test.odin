package http

// REQ-SHELL-29 unit coverage for the late-join screen snapshot.
//
// The property that carries the revised AC3 is test_req29_screen_payload_is_an_absolute_repaint:
// the payload must START with erase-screen + cursor-home. That prefix is the whole reason
// duplication is structurally impossible rather than merely unlikely, so it is asserted on
// the decoded bytes rather than on the frame text.

import base64 "core:encoding/base64"
import "core:net"
import "core:strings"
import "core:testing"
import platform "odin_test:hub/platform"
import shell_session_svc "odin_test:hub/service/shell_session"

@(test)
test_req29_screen_payload_is_an_absolute_repaint :: proc(t: ^testing.T) {
	payload := shell_stream_screen_payload_b64("line one\nline two")
	defer delete(payload)

	decoded, err := base64.decode(payload)
	testing.expect(t, err == nil, "payload must be valid base64")
	defer delete(decoded)

	got := string(decoded)
	testing.expect(
		t,
		strings.has_prefix(got, "\x1b[2J\x1b[H"),
		"snapshot must begin with erase-screen + cursor-home so it overwrites whatever the client already drew",
	)
	testing.expect(t, strings.has_suffix(got, "line one\nline two"), "pane text follows the repaint prefix verbatim")
}

@(test)
test_req29_frame_uses_screen_b64_not_the_data_b64_fallback :: proc(t: ^testing.T) {
	frame := shell_stream_screen_frame_json("QUJD")
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"type\":\"screen\""), "frame type must be screen")
	testing.expect(t, strings.contains(frame, "\"screen_b64\":\"QUJD\""), "payload must ride on screen_b64")
	testing.expect(
		t,
		!strings.contains(frame, "data_b64"),
		"data_b64 is the OUTPUT path's key; the screen frame must not produce it so the consumers' fallback stays unused",
	)
}

// A terminal session answers get_pane locally with output:"" — there is no screen to
// repaint, and writing an erase-screen to a dead pane would blank real scrollback.
@(test)
test_req29_empty_pane_output_writes_no_frame :: proc(t: ^testing.T) {
	reply := "{\"ok\":true,\"status\":\"exited\",\"unchanged\":true,\"hash\":\"\",\"output\":\"\"}"
	testing.expect(
		t,
		!_shell_stream_write_screen_frame(net.TCP_Socket(0), reply),
		"an empty pane must write nothing at all",
	)
}

// The gate itself: viewer #1 is served by the bridge's pty-host catchup and must NOT be
// reported as a late join; viewer #2 triggers no bridge attach and must be.
@(test)
test_req29_attach_reports_late_join_only_for_extra_viewers :: proc(t: ^testing.T) {
	ids := platform.real_id_generator()
	svc := shell_session_svc.new_shell_session_service(ids = &ids)
	defer shell_session_svc.shell_session_service_free(&svc)

	// An EMPTY bridge_id keeps this test on the gate itself: no bridge command is
	// dispatched, so no command sink is needed and nothing here depends on the
	// attach/detach wire format that other tests already cover.
	session_id := "sh_req29_gate"
	bridge_id := ""
	sock1 := net.TCP_Socket(301)
	sock2 := net.TCP_Socket(302)

	testing.expect(
		t,
		!shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id),
		"0->1 is not a late join: the bridge attach it triggers produces the pty-host catchup",
	)
	testing.expect(
		t,
		shell_session_svc.shell_session_attach(&svc, session_id, sock2, bridge_id),
		"1->2 IS a late join: no bridge attach fires, so nothing repaints this viewer",
	)

	// Re-attaching an ALREADY PRESENT socket still reports late_join, because the session
	// genuinely has viewers — the dedup path must not be mistaken for a first viewer.
	testing.expect(
		t,
		shell_session_svc.shell_session_attach(&svc, session_id, sock2, bridge_id),
		"a duplicate attach on a watched session is still a late join",
	)

	shell_session_svc.shell_session_detach(&svc, session_id, sock1, bridge_id)
	shell_session_svc.shell_session_detach(&svc, session_id, sock2, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 0)

	testing.expect(
		t,
		!shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id),
		"once the last viewer leaves, the next one is a first viewer again",
	)
	shell_session_svc.shell_session_detach(&svc, session_id, sock1, bridge_id)
}

// Targeting: the frame reaches the ONE socket it was handed. This is what makes a late-join
// repaint possible without disturbing viewers that are already painted correctly.
@(test)
test_req29_screen_frame_is_written_to_the_given_socket :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	defer net.close(listener)
	endpoint, ep_err := net.bound_endpoint(listener)
	if ep_err != nil {
		testing.fail_now(t, "could not read bound endpoint")
	}
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil {
		testing.fail_now(t, "could not dial loopback")
	}
	defer net.close(client)
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		testing.fail_now(t, "could not accept loopback")
	}
	defer net.close(hub)

	reply := "{\"ok\":true,\"unchanged\":false,\"hash\":\"abc\",\"output\":\"hello pane\"}"
	testing.expect(t, _shell_stream_write_screen_frame(hub, reply), "write must succeed on a live socket")

	buf: [512]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	testing.expect(t, recv_err == nil && n > 0, "client must receive the screen frame")

	got := string(buf[:n])
	testing.expect(t, strings.contains(got, "\"type\":\"screen\""), "received frame is a screen frame")

	// Decode the payload actually delivered and prove the repaint prefix survived the wire.
	key := "\"screen_b64\":\""
	idx := strings.index(got, key)
	testing.expect(t, idx >= 0, "delivered frame carries screen_b64")
	if idx < 0 do return
	rest := got[idx + len(key):]
	end := strings.index_byte(rest, '"')
	testing.expect(t, end > 0, "screen_b64 is terminated")
	if end <= 0 do return

	decoded, dec_err := base64.decode(rest[:end])
	testing.expect(t, dec_err == nil, "delivered payload is valid base64")
	defer delete(decoded)
	testing.expect_value(t, string(decoded), "\x1b[2J\x1b[Hhello pane")
}
