package main

import "base:runtime"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

// Bridge_PTY_Stream_Worker holds state for one dedicated streaming socket worker (REQ-STREAM-IMPL-1).
// To isolate high-throughput PTY Output from the single-threaded WatchEvents control loop
// (permanently resolving BUG-10 / false agent reaper timeouts), each streaming session
// opens its own dedicated UNIX domain socket connection to ham-pty-host.
Bridge_PTY_Stream_Worker :: struct {
	session_id: string,
	shell_id:   string,
	fd:         posix.FD,
	active:     bool,
	conn:       ^ws.Connection,
}

Bridge_PTY_Stream_Outgoing :: struct {
	json: string,
}

Bridge_PTY_Stream_Map :: struct {
	mu:      sync.Mutex,
	workers: map[string]^Bridge_PTY_Stream_Worker, // keyed by session_id
}

bridge_pty_stream_map: Bridge_PTY_Stream_Map
bridge_pty_stream_outgoing_mu: sync.Mutex
bridge_pty_stream_outgoing: [dynamic]Bridge_PTY_Stream_Outgoing

// bridge_pty_stream_worker_start initiates an Attach-gated dedicated streaming worker.
// Dials a NEW, DEDICATED socket connection to ham-pty-host, sends CtlMsg::Attach,
// and spawns a lightweight reader thread that loops on CtlReply frames.
bridge_pty_stream_worker_start :: proc(session_id, shell_id: string, conn: ^ws.Connection) -> bool {
	sid := strings.trim_space(session_id)
	sh_id := strings.trim_space(shell_id)
	if sid == "" do return false
	if sh_id == "" do sh_id = sid

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	if bridge_pty_stream_map.workers == nil {
		bridge_pty_stream_map.workers = make(map[string]^Bridge_PTY_Stream_Worker, allocator = runtime.heap_allocator())
	}
	if existing, ok := bridge_pty_stream_map.workers[sid]; ok {
		if existing.active {
			existing.conn = conn
			sync.mutex_unlock(&bridge_pty_stream_map.mu)
			return true
		}
	}
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok do return false

	fd, dial_ok := pty_host_dial(socket)
	if !dial_ok do return false

	// Send CtlMsg::Attach on this dedicated socket
	attach_frame := pty_host_encode_attach(sh_id)
	defer delete(attach_frame)
	if !pty_host_send_all(fd, attach_frame) {
		posix.close(fd)
		return false
	}

	worker := new(Bridge_PTY_Stream_Worker, runtime.heap_allocator())
	worker.session_id = strings.clone(sid, runtime.heap_allocator())
	worker.shell_id = strings.clone(sh_id, runtime.heap_allocator())
	worker.fd = fd
	worker.active = true
	worker.conn = conn

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	bridge_pty_stream_map.workers[strings.clone(sid, runtime.heap_allocator())] = worker
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	thread.run_with_data(rawptr(worker), bridge_pty_stream_reader_worker)
	return true
}

// bridge_pty_stream_worker_detach detaches the streaming worker for session_id.
// Sends CtlMsg::Detach and shuts down / closes the dedicated socket descriptor.
bridge_pty_stream_worker_detach :: proc(session_id: string) -> bool {
	sid := strings.trim_space(session_id)
	if sid == "" do return false

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	worker: ^Bridge_PTY_Stream_Worker = nil
	key_to_delete := ""
	for k, w in bridge_pty_stream_map.workers {
		if k == sid {
			worker = w
			key_to_delete = k
			delete_key(&bridge_pty_stream_map.workers, k)
			break
		}
	}
	if worker == nil {
		sync.mutex_unlock(&bridge_pty_stream_map.mu)
		return true // already detached
	}
	worker.active = false
	fd := worker.fd
	sh_id := strings.clone(worker.shell_id, context.temp_allocator)
	delete(key_to_delete, runtime.heap_allocator())
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	// Send CtlMsg::Detach to daemon
	detach_frame := pty_host_encode_detach(sh_id)
	defer delete(detach_frame)
	_ = pty_host_send_all(fd, detach_frame)

	// Shutdown socket to unblock reader thread immediately
	_ = posix.shutdown(fd, .RDWR)
	return true
}

// _bridge_pty_stream_lf_to_crlf rewrites bare row separators into CRLF.
// Caller owns the result.
//
// WHY THIS IS NEEDED (REQ-SHELL-31). This is the SECOND staircase producer; REQ-SHELL-30 fixed
// the hub's snapshot builder and the terminal still staircased, because the bridge emits a
// catch-up paint of its own. The pty-host delivers a captured screen as one string PER GRID ROW
// (tools/pty_host/src/vt.rs capture()), and bridge_pty_host_screen_to_output joins those rows
// with a bare LF. A VT drops one row on LF and KEEPS the column, so every row began where the
// previous one ended.
//
// WHY THE RAW-BYTE DISTINCTION IS THE WHOLE POINT. The joiner has four non-test callers and only
// this one is wrong, which is why the join itself must not change. The decisive difference is
// xterm's `convertEol` option (ShellTerminalPane.tsx:229/349, AgentPaneComposerPanel.tsx:263/390):
// it is TRUE on the polled paths, where xterm converts LF->CRLF itself and bare LF is therefore
// correct, and FALSE while streaming. The .Screen frame below travels as `shell_pty_output`
// data_b64 — raw bytes on the streaming path — so it is the one place the conversion must happen
// in Odin. Fixing the shared joiner would instead rewrite the poller's text AND invalidate every
// stored since_hash (bridge_pty_host_pane_hash consumes it on the very next statement of
// bridge_pty_host_evaluate_pane), costing every client a full repaint.
//
// An LF that ALREADY has a CR before it is passed through untouched, so this can never produce
// "\r\r\n" should the pty-host ever start sending CRLF itself.
//
// NOTHING here measures width. vt.rs capture() writes SGR runs INLINE into each row, so a row's
// byte length is not its display width and must never be used as one. The separator is decided
// per LF byte, never per length.
_bridge_pty_stream_lf_to_crlf :: proc(s: string) -> string {
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

// bridge_pty_stream_screen_payload builds the byte payload of the bridge's catch-up screen
// frame: the captured rows joined, with CRLF row separators. Caller owns the result.
//
// This exists as a named seam rather than two statements inlined in the .Screen case so that
// the conversion is covered in the SAME composition the emit site uses. A test that called
// _bridge_pty_stream_lf_to_crlf directly would stay green if someone dropped the call from the
// emit site — it would guard the helper without detecting the regression this task fixes.
bridge_pty_stream_screen_payload :: proc(lines: []string) -> string {
	joined, _, _ := bridge_pty_host_screen_to_output(lines, 0)
	defer delete(joined)
	return _bridge_pty_stream_lf_to_crlf(joined)
}

// bridge_pty_stream_reader_worker runs on a dedicated background thread per active stream.
// It loops reading CtlReply frames from the dedicated UNIX socket and emits shell_pty_output.
bridge_pty_stream_reader_worker :: proc(data: rawptr) {
	worker := (^Bridge_PTY_Stream_Worker)(data)
	heap := runtime.heap_allocator()

	// Capture stack copies so we never dereference worker if deregistered concurrently
	local_fd := worker.fd
	local_session_id := strings.clone(worker.session_id, heap)
	defer delete(local_session_id, heap)
	local_shell_id := strings.clone(worker.shell_id, heap)
	defer delete(local_shell_id, heap)

	for {
		payload, pok := pty_host_read_frame(local_fd)
		if !pok do break

		reply, dok := pty_host_decode_reply(payload)
		delete(payload)
		if !dok do continue

		#partial switch reply.kind {
		case .Output:
			bridge_pty_stream_emit_frame(worker, local_session_id, reply.data)
		case .Screen:
			// Initial catchup snapshot delivered immediately upon Attach.
			// REQ-SHELL-31: the joiner separates rows with a bare LF, which is correct for the
			// polled panes (xterm's convertEol is on there) but not here — this frame reaches the
			// terminal as raw bytes, where a bare LF keeps the column and staircases the paint.
			// Converted at the emit site, never in the shared joiner: see the note above.
			content := bridge_pty_stream_screen_payload(reply.screen.lines)
			if len(content) > 0 {
				bridge_pty_stream_emit_frame(worker, local_session_id, transmute([]byte)content)
			}
			delete(content)
		case .Error:
			fmt.println("bridge pty stream error:", reply.message)
		}
		pty_host_reply_delete(reply)
	}

	// Teardown: send CtlMsg::Detach and close dedicated socket descriptor
	detach_frame := pty_host_encode_detach(local_shell_id)
	_ = pty_host_send_all(local_fd, detach_frame)
	delete(detach_frame)
	posix.close(local_fd)

	// Deregister worker from map if still present
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	for k, w in bridge_pty_stream_map.workers {
		if w == worker {
			delete_key(&bridge_pty_stream_map.workers, k)
			delete(k, heap)
			break
		}
	}
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	delete(worker.session_id, heap)
	delete(worker.shell_id, heap)
	free(worker, heap)
}

// bridge_pty_stream_emit_frame encodes data chunk to base64 and formats shell_pty_output JSON.
bridge_pty_stream_emit_frame :: proc(worker: ^Bridge_PTY_Stream_Worker, session_id: string, data: []byte) {
	if len(data) == 0 do return
	heap := runtime.heap_allocator()
	encoded := base64.encode(data, allocator = heap)
	defer delete(encoded, heap)

	b := strings.builder_make(heap)
	strings.write_string(&b, "{\"type\":\"shell_pty_output\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	bridge_runtime_write_json_string(&b, string(encoded))
	strings.write_string(&b, "\"}")
	frame := strings.to_string(b)

	sent := false
	if worker != nil && worker.active && worker.conn != nil && worker.conn.connected {
		sent = bridge_hub_send(worker.conn, frame)
	}
	if !sent {
		if worker != nil && !worker.active {
			delete(frame, heap)
		} else {
			sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
			append(&bridge_pty_stream_outgoing, Bridge_PTY_Stream_Outgoing{json = frame})
			sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
		}
	} else {
		delete(frame, heap)
	}
}

// bridge_pty_stream_drain_outgoing flushes queued shell_pty_output frames to the hub connection.
bridge_pty_stream_drain_outgoing :: proc(conn: ^ws.Connection) {
	if conn == nil || !conn.connected do return
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	if len(bridge_pty_stream_outgoing) == 0 {
		sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
		return
	}
	items := bridge_pty_stream_outgoing[:]
	bridge_pty_stream_outgoing = make([dynamic]Bridge_PTY_Stream_Outgoing, runtime.heap_allocator())
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)

	heap := runtime.heap_allocator()
	for item in items {
		_ = bridge_hub_send(conn, item.json)
		delete(item.json, heap)
	}
	delete(items)
}

// bridge_pty_stream_take_outgoing drains all queued outgoing frames without sending (for tests).
bridge_pty_stream_take_outgoing :: proc() -> [dynamic]string {
	heap := runtime.heap_allocator()
	out := make([dynamic]string, heap)
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	defer sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
	for item in bridge_pty_stream_outgoing {
		append(&out, item.json)
	}
	clear(&bridge_pty_stream_outgoing)
	return out
}

// bridge_pty_stream_worker_is_active checks if a worker is running for session_id.
bridge_pty_stream_worker_is_active :: proc(session_id: string) -> bool {
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	defer sync.mutex_unlock(&bridge_pty_stream_map.mu)
	if worker, ok := bridge_pty_stream_map.workers[session_id]; ok {
		return worker.active
	}
	return false
}

// bridge_pty_stream_reset clears all streaming workers and outgoing queue (for tests).
bridge_pty_stream_reset :: proc() {
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	heap := runtime.heap_allocator()
	for k, w in bridge_pty_stream_map.workers {
		w.active = false
		_ = posix.shutdown(w.fd, .RDWR)
		posix.close(w.fd)
		delete(w.session_id, heap)
		delete(w.shell_id, heap)
		free(w, heap)
		delete(k, heap)
	}
	clear(&bridge_pty_stream_map.workers)
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	for item in bridge_pty_stream_outgoing {
		delete(item.json, heap)
	}
	clear(&bridge_pty_stream_outgoing)
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
}
