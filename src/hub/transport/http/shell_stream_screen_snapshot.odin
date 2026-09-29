package http

// REQ-SHELL-29: screen snapshot on stream attach for LATE-JOINING viewers.
//
// WHY THIS EXISTS. Both terminal consumers already understand a `screen` frame
// (useShellStream.ts:221, useAgentStream.ts:225) and feed its payload into the same
// sink as incremental output. What was missing is a producer for a viewer that joins a
// session ALREADY being watched.
//
// The pty-host does emit a catchup screen on Attach, and the bridge forwards it
// (pty_host_stream_worker.odin:149-156) — but only on the hub's 0->1 viewer transition
// (shell_session_service.odin:140), and it travels as `shell_pty_output`, which the hub
// BROADCASTS to every viewer. So it cannot serve viewer #2 without repainting viewer #1.
// That 0->1 path is deliberately left byte-exact here; this serves late joiners only.
//
// ORDERING (REQ-SHELL-29 AC3, as revised). The snapshot travels the command/reply
// channel while incremental output is a bridge->hub push, so the two have NO
// protocol-level ordering. Rather than pretend otherwise, the payload is prefixed with
// erase-screen + cursor-home, making it an ABSOLUTE REPAINT: it discards whatever the
// client already drew, so DUPLICATION IS STRUCTURALLY IMPOSSIBLE.
//
// The residual, stated precisely: output produced between the pty-host's capture and the
// reply landing (one bridge->hub hop) is painted over and does not reappear until the
// program next writes. This is NOT a no-loss guarantee and must not be described as one.
// For the case that motivates the task — switching back to an idle shell sitting at a
// prompt — no output is in flight, so the repaint is exact.

import base64 "core:encoding/base64"
import "core:net"
import "core:strings"
import contracts "odin_test:contracts"
import agent_service "odin_test:hub/service/agent"
import shell_session_svc "odin_test:hub/service/shell_session"

// SHELL_SCREEN_REPAINT_PREFIX erases the screen and homes the cursor. It is what makes
// the snapshot idempotent against anything already rendered — see the ordering note above.
SHELL_SCREEN_REPAINT_PREFIX :: "\x1b[2J\x1b[H"

// _shell_screen_lf_to_crlf rewrites the pane's bare row separators into CRLF.
// Caller owns the result.
//
// WHY THIS IS NEEDED (REQ-SHELL-30). The pane text arrives as one string PER GRID ROW joined
// with a bare LF — bridge_pty_host_screen_to_output in src/bridge/pty_host_runtime.odin. For
// the polling pane, which paints into the DOM, bare LF is correct. For a VT it is not: LF drops
// one row and KEEPS the column, so the repaint drew every row starting where the previous one
// ended — a diagonal staircase on a viewer's FIRST render.
//
// WHY THE FIX LIVES HERE AND NOT AT THE JOIN. bridge_pty_host_screen_to_output is also the input
// to bridge_pty_host_pane_hash (the very next statement in bridge_pty_host_evaluate_pane), so
// changing the join would not merely alter the poller's text — it would invalidate every stored
// since_hash at once and cost every client a full repaint. This builder is the WS/terminal-only
// seam, and it is already the thing that speaks VT: it prepends erase-screen + cursor-home.
//
// An LF that ALREADY has a CR in front of it is passed through untouched, so this can never
// produce "\r\r\n" should a pane source ever start sending CRLF itself.
//
// NOTHING here measures width. vt.rs capture() writes SGR runs INLINE into each row, so a row's
// byte length is not its display width and must never be used as one. The separator is decided
// per LF byte, never per length.
_shell_screen_lf_to_crlf :: proc(s: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\n' && (i == 0 || s[i - 1] != '\r') {
			strings.write_byte(&b, '\r')
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// shell_stream_screen_payload_b64 builds the base64 body of a `screen` frame: the repaint
// prefix followed by the captured pane text with CRLF row separators. Caller owns the result.
shell_stream_screen_payload_b64 :: proc(pane_output: string) -> string {
	body := _shell_screen_lf_to_crlf(pane_output)
	defer delete(body)
	joined := strings.concatenate({SHELL_SCREEN_REPAINT_PREFIX, body})
	defer delete(joined)
	return base64.encode(transmute([]byte)joined)
}

// shell_stream_screen_frame_json wraps a base64 payload in the frame both consumers parse.
// `screen_b64` is sent, not `data_b64`: both hooks accept either, but only one key is
// produced so the fallback is never load-bearing. Caller owns the result.
shell_stream_screen_frame_json :: proc(screen_b64: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"screen\",\"screen_b64\":\"")
	write_handler_json_string(&b, screen_b64)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// _shell_stream_write_screen_frame turns a pane reply into a `screen` frame on ONE socket.
// An empty `output` writes nothing: a terminal session answers locally with output:"" and
// has no screen worth repainting.
_shell_stream_write_screen_frame :: proc(client: net.TCP_Socket, pane_reply: string) -> bool {
	output := json_string(pane_reply, "output")
	defer delete(output)
	if output == "" do return false

	payload := shell_stream_screen_payload_b64(output)
	defer delete(payload)
	frame := shell_stream_screen_frame_json(payload)
	defer delete(frame)
	return write_ws_text_frame(client, frame)
}

// shell_stream_send_shell_screen_snapshot serves the shells terminal pane.
// `cols`/`rows` come from the client's own resize frame so the capture is rendered at the
// width the viewer actually has; capturing at a guessed 80 would deliver a correct picture
// of the wrong layout.
shell_stream_send_shell_screen_snapshot :: proc(
	svc: ^shell_session_svc.Shell_Session_Service,
	auth: contracts.Auth_Context,
	session_id: string,
	client: net.TCP_Socket,
	rows, cols: int,
) -> bool {
	if svc == nil || session_id == "" || rows < 1 || cols < 1 do return false
	reply, ok, err := shell_session_svc.shell_session_get_pane(svc, auth, session_id, "", cols, rows)
	if !ok || err.code != .None do return false
	defer delete(reply)
	return _shell_stream_write_screen_frame(client, reply)
}

// shell_stream_send_agent_screen_snapshot serves the agent pane. Same frame, same
// contract; only the pane source differs, because an agent instance has no shell_sessions
// row — agent_service.get_instance_pane is the twin of shell_session_get_pane and returns
// the identical payload shape.
shell_stream_send_agent_screen_snapshot :: proc(
	svc: ^agent_service.Agent_Service,
	auth: contracts.Auth_Context,
	instance_id: string,
	client: net.TCP_Socket,
	rows, cols: int,
) -> bool {
	if svc == nil || instance_id == "" || rows < 1 || cols < 1 do return false
	reply, ok, err := agent_service.get_instance_pane(svc, auth, instance_id, "", cols, rows)
	if !ok || err.code != .None do return false
	defer delete(reply)
	return _shell_stream_write_screen_frame(client, reply)
}
