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
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
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
// with a bare LF — bridge_pty_host_screen_to_output in src/bridge/pty_host_runtime.odin. A VT
// drops one row on LF and KEEPS the column, so the repaint drew every row starting where the
// previous one ended — a diagonal staircase on a viewer's FIRST render.
//
// WHY THE POLLED PANE IS SAFE ON THE SAME TEXT — CORRECTED BY REQ-SHELL-31. This comment used
// to say the polling pane "paints into the DOM, where bare LF is correct". THAT IS FALSE: the
// poller writes into xterm too (ShellTerminalPane.tsx:300 and :333,
// `term.write('\x1b[?25l' + output)`, fed by REST GET /shells/{id}/pane, which returns the
// bridge reply verbatim). Both paths feed a terminal. The poller is safe because xterm's OWN
// `convertEol` option performs the LF->CRLF conversion, and the code deliberately turns it OFF
// while streaming: `convertEol: !isStreamingActive` (ShellTerminalPane.tsx:229, kept in sync at
// :349; AgentPaneComposerPanel.tsx:263/:390 is the identical pair).
//
// The invariant is therefore about convertEol, NOT about "terminal vs DOM": the bare-LF text is
// safe in any consumer with convertEol ON and unsafe exactly where it is OFF. Anyone auditing
// for further instances should grep for the streaming paths / convertEol:false. The original
// framing sent two agents hunting for a non-terminal consumer that does not exist, and it missed
// the bridge's own catch-up emit (pty_host_stream_worker.odin), which REQ-SHELL-31 then had to
// fix as the SECOND staircase producer.
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

// _shell_screen_repaint_text builds the DECODED repaint: the erase+home prefix followed by
// the captured pane text with CRLF row separators. Caller owns the result.
//
// Split out from shell_stream_screen_payload_b64 because the chunked writer needs the
// repaint as bytes it can cut before encoding — base64 of the whole thing cannot be cut,
// since each frame must decode on its own.
_shell_screen_repaint_text :: proc(pane_output: string) -> string {
	body := _shell_screen_lf_to_crlf(pane_output)
	defer delete(body)
	return strings.concatenate({SHELL_SCREEN_REPAINT_PREFIX, body})
}

// shell_stream_screen_payload_b64 builds the base64 body of a single-frame `screen` payload.
// Caller owns the result.
shell_stream_screen_payload_b64 :: proc(pane_output: string) -> string {
	joined := _shell_screen_repaint_text(pane_output)
	defer delete(joined)
	return base64.encode(transmute([]byte)joined)
}

// SHELL_SCREEN_CHUNK_DECODED_BYTES is how much DECODED repaint text one `screen` frame
// carries. 32 KiB encodes to ~43.7 KB of base64 — base64's alphabet needs no JSON escaping,
// so the frame lands well inside even the 16-bit WebSocket length (65535). That is
// deliberate: a snapshot of any size now travels in frames that would survive a 16-bit-only
// writer, so this path can never again depend on a length arm being present to paint.
SHELL_SCREEN_CHUNK_DECODED_BYTES :: 32 * 1024

// _shell_screen_chunk_end picks where the chunk starting at `start` ends, preferring a ROW
// boundary (just past a '\n') so a chunk never splits an SGR escape run or a multi-byte
// rune. A single row longer than the budget — pathological, but a wide pane full of colour
// runs is what this ticket is about — falls back to the hard byte boundary, which is safe
// because xterm's parser is a STREAM parser: it carries escape and UTF-8 state across
// writes, and consecutive `screen` frames feed the same sink as incremental output
// (useShellStream.ts:221).
_shell_screen_chunk_end :: proc(s: string, start: int) -> int {
	if len(s) - start <= SHELL_SCREEN_CHUNK_DECODED_BYTES do return len(s)
	hard := start + SHELL_SCREEN_CHUNK_DECODED_BYTES
	for i := hard - 1; i > start; i -= 1 {
		if s[i] == '\n' do return i + 1
	}
	return hard
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

// _shell_stream_write_screen_frame turns a pane reply into one or more `screen` frames on
// ONE socket. An empty `output` writes nothing: a terminal session answers locally with
// output:"" and has no screen worth repainting.
//
// WHY THIS CHUNKS (REQ-SHELL-33). This is the one caller on this socket whose payload can
// exceed a WebSocket length arm: vt.rs's capture() writes SGR colour runs INLINE into every
// row, so a wide, fully-coloured pane produces a repaint far larger than its display area.
// Before this change that frame was silently dropped and the viewer saw a BLANK PANE —
// exactly the late-join repaint REQ-SHELL-29 exists to provide, failing where it matters
// most. A 64-bit length arm alone would not settle it: any cap, however generous, would
// turn the same case back into a blank pane, only with a log line. Cutting the repaint into
// ordered frames means a snapshot of ANY size paints.
//
// This is sound because the repaint is ABSOLUTE and SEQUENTIAL. The erase+home prefix leads
// the first chunk only; the rest continue where it left off, on the same socket, written in
// order by this proc, into a client that feeds every `screen` frame to the same terminal
// sink. Re-prefixing later chunks would erase the part already painted.
//
// ATOMICITY, not merely ordering. Chunking is only sound if NOTHING ELSE writes this
// socket mid-sequence. It is not enough that the chunks leave in order: the bridge-push
// path (shell_session_broadcast_output) writes the same viewer socket from another thread,
// and an `output` frame between two chunks moves the cursor, after which every remaining
// chunk — none of which carries erase+home or absolute positioning — paints from the wrong
// place. The whole sequence is therefore written under that session's viewer-write lock;
// see shell_session_viewer_write_lock for why the lock is per session and why concurrent
// writes were in fact never safe on this socket even at one frame each.
//
// A partial paint on a mid-sequence failure is deliberate and is not a regression: the
// alternative is the blank pane this replaces, and the next output or snapshot repaints
// absolutely.
// `sessions`/`stream_id` name the viewer-write lock this sequence must hold — see the
// ATOMICITY note above. They may be nil/"" only where there is no fan-out to race with,
// which in practice means tests; production callers always have both.
_shell_stream_write_screen_frame :: proc(
	sessions: ^shell_session_svc.Shell_Session_Service,
	stream_id: string,
	client: net.TCP_Socket,
	pane_reply: string,
) -> bool {
	output := json_string(pane_reply, "output")
	defer delete(output)
	if output == "" do return false

	repaint := _shell_screen_repaint_text(output)
	defer delete(repaint)

	// Held across EVERY chunk, not per chunk: an `output` frame landing between two
	// chunks would move the cursor and misposition all of them.
	// NOTE the shape. `defer` in Odin runs at the end of its ENCLOSING SCOPE, so putting
	// the unlock inside the `if` block releases the lock immediately — which is exactly
	// the bug req33_output_cannot_interleave_with_a_chunked_snapshot caught here. The
	// guarded `defer if` keeps the release at proc exit.
	write_mu := shell_session_svc.shell_session_viewer_write_lock(sessions, stream_id)
	if write_mu != nil do sync.mutex_lock(write_mu)
	defer if write_mu != nil do sync.mutex_unlock(write_mu)

	offset := 0
	for offset < len(repaint) {
		end := _shell_screen_chunk_end(repaint, offset)
		payload := base64.encode(transmute([]byte)repaint[offset:end])
		frame := shell_stream_screen_frame_json(payload)
		result := write_ws_text_frame_browser(client, frame)
		delete(payload)
		delete(frame)
		if result != .Ok {
			fmt.eprintfln(
				"ham-hub WARN shell screen snapshot frame not delivered result=%v offset=%d chunk_bytes=%d total_bytes=%d",
				result,
				offset,
				end - offset,
				len(repaint),
			)
			return false
		}
		offset = end
	}
	return true
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
	return _shell_stream_write_screen_frame(svc, session_id, client, reply)
}

// shell_stream_send_agent_screen_snapshot serves the agent pane. Same frame, same
// contract; only the pane source differs, because an agent instance has no shell_sessions
// row — agent_service.get_instance_pane is the twin of shell_session_get_pane and returns
// the identical payload shape.
// `sessions` is the shell-session service, NOT the pane source: an agent stream attaches
// its viewer socket through shell_session_attach exactly like a shell does
// (agent_instance_handlers.odin), so its writes share the same lock and the same fan-out.
shell_stream_send_agent_screen_snapshot :: proc(
	svc: ^agent_service.Agent_Service,
	sessions: ^shell_session_svc.Shell_Session_Service,
	auth: contracts.Auth_Context,
	instance_id: string,
	client: net.TCP_Socket,
	rows, cols: int,
) -> bool {
	if svc == nil || instance_id == "" || rows < 1 || cols < 1 do return false
	reply, ok, err := agent_service.get_instance_pane(svc, auth, instance_id, "", cols, rows)
	if !ok || err.code != .None do return false
	defer delete(reply)
	return _shell_stream_write_screen_frame(sessions, instance_id, client, reply)
}
