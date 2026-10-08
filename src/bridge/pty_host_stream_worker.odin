package main

import "base:runtime"
import "core:crypto"
import "core:crypto/aes"
import base64 "core:encoding/base64"
import "core:encoding/hex"
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
	session_id:            string,
	shell_id:              string,
	fd:                    posix.FD,
	active:                bool,
	conn:                  ^ws.Connection,
	salt:                  [4]byte,
	seq:                   u64,
	locked_banner_emitted: bool,
}

bridge_pty_stream_fallback_mu: sync.Mutex
bridge_pty_stream_fallback_salt: [4]byte
bridge_pty_stream_fallback_seq: u64
bridge_pty_stream_fallback_inited: bool

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

// _bridge_pty_stream_outgoing_bind_heap pins the outgoing queue's BACKING ARRAY to the heap
// allocator, and must be called with bridge_pty_stream_outgoing_mu held before any append.
//
// WHY THIS EXISTS — IT IS THE FIX FOR A HARD SEGFAULT, NOT A TIDINESS MEASURE (REQ-SHELL-40).
// `bridge_pty_stream_outgoing` is a package-level `[dynamic]` declared with NO allocator, so its
// allocator field is nil until something appends. Odin's __dynamic_array_* then binds it to
// `context.allocator` AT THE MOMENT OF THE FIRST APPEND and keeps that binding forever.
//
// In production that is harmless by luck: the first append happens on a bridge worker whose
// context carries the default heap allocator, and the queue lives for the process's lifetime.
//
// UNDER THE TEST RUNNER IT IS FATAL. Each test runs with its OWN tracking allocator installed in
// the context, and the runner tears that allocator down when the test ends. So the first test to
// append bound this global's backing to an allocator that then died, and every later test appended
// through a DANGLING backing pointer. The reads come back as whatever now occupies that memory —
// which is how `delete(item.json)` in bridge_pty_stream_stop_all_for_reconnect came to be handed
// 0x5f68730a00000035, a pointer-shaped view of the ASCII bytes "_hs\n5". Confirmed under gdb:
//   #3 runtime::delete_string
//   #4 main::bridge_pty_stream_stop_all_for_reconnect (pty_host_stream_worker.odin)
//   #5 main::t40_stop_all_for_reconnect_detaches_every_worker
//
// It was invisible at the default thread count and DETERMINISTIC at -define:ODIN_TEST_THREADS=1,
// because what matters is which test appends FIRST and whether its allocator is already dead when
// the next one appends — test ORDER, not concurrency. More threads reordered it into hiding.
// REQ-SHELL-48 owns the invocation standard that let that stay hidden.
//
// Binding the ALLOCATOR FIELD rather than calling make() is deliberate: it allocates nothing, so it
// is safe to call on every locked path, and it cannot itself be the first binding done from a
// transient context.
_bridge_pty_stream_outgoing_bind_heap :: proc() {
	if bridge_pty_stream_outgoing.allocator.procedure == nil {
		bridge_pty_stream_outgoing.allocator = runtime.heap_allocator()
	}
}

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
	crypto.rand_bytes(worker.salt[:])
	worker.seq = 0

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

// bridge_pty_stream_stop_all_for_reconnect detaches EVERY live streaming worker, and is
// the bridge half of REQ-SHELL-40's convergence: no stream worker may outlive the hub
// connection it was created for.
//
// WHY A BLANKET TEARDOWN RATHER THAN A REAPER. A worker holds `conn`, a POINTER to the
// `ws.Connection` that `bridge_hub_runtime_worker` declares as a STACK LOCAL INSIDE its
// reconnect loop (hub_runtime_client.odin). The moment that loop iterates, the pointer is
// dangling — and worse than merely dangling, because the next iteration refills the same
// stack slot with the NEW connection, so an orphaned worker silently begins aliasing a
// socket it was never attached to. Output appearing to survive a WS blip today is that
// accident, not a design. Nothing here can be made safe by reaping later; the pointer has
// to stop existing before the slot is reused, which is what this does.
//
// IT ALSO CLOSES A REAL UNBOUNDED LEAK. Hub->bridge runtime commands are fire-and-forget
// over the live socket (bridge_runtime.send_runtime_command returns .Bridge_Offline and
// DROPS the frame), and the hub replays kill intents on reconnect but not detaches. So a
// viewer that closed its pane while the bridge was away left its `shell_stream_detach`
// discarded and its worker running forever, appending every byte the shell produced to the
// unbounded `bridge_pty_stream_outgoing` queue for a session nobody was watching.
//
// WHAT RE-ESTABLISHES THE STREAM. Nothing here — deliberately. The hub re-issues
// `shell_stream_attach` for every still-viewed live session out of its inventory
// convergence (shell_session_inventory.odin), and the fresh Attach earns a fresh Screen
// catch-up frame from the pty-host, so the pane repaints rather than resuming mid-scroll.
// Losing the bytes produced during the outage is correct: they are off-screen history the
// viewer never saw, and the repaint shows the screen as it actually is now.
//
// CALL IT BEFORE ws.close, NOT AFTER. That ordering is the whole answer to "what happens to
// a worker that is mid-write when the socket closes". ws.close does not take the send mutex
// REQ-SHELL-32 added, so a writer CAN be inside bridge_hub_send when the fd goes away; after
// this returns, no worker is eligible to write at all, so the window shrinks instead of
// growing. A worker already inside a send finishes against a closing fd, gets false back,
// and — because `active` is now false — has its frame DELETED by
// bridge_pty_stream_emit_frame rather than queued, so a wedged writer costs neither a hang
// nor a queue entry.
//
// Detaching is idempotent (bridge_pty_stream_worker_detach returns true for an already
// detached session), so a reconnect storm running this repeatedly is harmless.
bridge_pty_stream_stop_all_for_reconnect :: proc() -> int {
	heap := runtime.heap_allocator()

	// Snapshot the ids under the lock and detach OUTSIDE it: worker_detach takes the
	// same mutex, and it also writes to the pty-host socket, which must never happen
	// with the worker map held.
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	ids := make([dynamic]string, 0, len(bridge_pty_stream_map.workers), heap)
	for k in bridge_pty_stream_map.workers {
		append(&ids, strings.clone(k, heap))
	}
	sync.mutex_unlock(&bridge_pty_stream_map.mu)
	defer {
		for id in ids do delete(id, heap)
		delete(ids)
	}

	for id in ids {
		_ = bridge_pty_stream_worker_detach(id)
	}

	// Frames queued by workers that are now gone can never be delivered to anyone: the
	// sessions they belong to have no attachment until the hub re-attaches, and a
	// re-attach is answered by a fresh Screen frame that supersedes them. Dropping them
	// here is what keeps the queue from carrying a burst of pre-outage bytes that would
	// paint over the catch-up snapshot.
	//
	// THIS IS A DELIBERATE DROP AND IT IS NOT DATA LOSS, which is the only reason it is
	// acceptable — the reason is not self-evident, so it is written down rather than
	// left to a reviewer to reconstruct:
	//   - The bytes are still on disk. The pty-host tees every chunk to the session's
	//     tee file INDEPENDENTLY of subscribers — tools/pty_host/src/daemon.rs
	//     pump_output writes the tee AFTER the subscriber loop and outside it, so a
	//     session with no attached stream still records everything — and the bridge sets
	//     has_tee_path unconditionally for shell spawns (hub_runtime_client.odin:2540).
	//     `shell log` serves that file under REQ-SHELL-8 retention. So this is a
	//     live-view recovery choice, not a loss of output.
	//   - For a `server` kind streaming build output, the catch-up repaint shows the
	//     CURRENT tail, which is what a human watching actually wants — a delayed burst
	//     of pre-outage scrollback arriving after the reconnect is strictly less useful.
	//
	// AND IT IS LOGGED, because this chain has catalogued several defects that survived
	// only because something was dropped without a word. A deliberate drop must be at
	// least as visible as an accidental one.
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	_bridge_pty_stream_outgoing_bind_heap()
	dropped_frames := len(bridge_pty_stream_outgoing)
	dropped_bytes := 0
	for item in bridge_pty_stream_outgoing {
		dropped_bytes += len(item.json)
		delete(item.json, heap)
	}
	clear(&bridge_pty_stream_outgoing)
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)

	if len(ids) > 0 || dropped_frames > 0 {
		// Session ids in full: a count alone cannot tell an operator WHICH pane went
		// quiet, which is the first question asked when one does.
		joined := strings.join(ids[:], ",", context.temp_allocator)
		fmt.println(
			"bridge pty stream: detached workers for hub reconnect",
			"reason=", "hub_ws_reconnect",
			"workers=", len(ids),
			"sessions=", joined,
			"dropped_frames=", dropped_frames,
			"dropped_bytes=", dropped_bytes,
			"(bytes remain in the session tee file; the hub re-attach earns a fresh screen repaint)",
		)
	}

	return len(ids)
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

// _bridge_pty_stream_trim_trailing_blank_rows strips non-informative trailing blank/whitespace
// rows from pane text while preserving trailing spaces on non-blank prompt lines.
// Intermediate blank lines are preserved. Returns an empty string if all lines are blank.
// Caller owns the result.
_bridge_pty_stream_trim_trailing_blank_rows :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 do return strings.clone("", allocator)

	last_non_blank_end := -1
	line_start := 0
	line_has_content := false

	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\n' {
			if line_has_content {
				end := i
				if end > line_start && s[end - 1] == '\r' do end -= 1
				last_non_blank_end = end
			}
			line_start = i + 1
			line_has_content = false
		} else if c != ' ' && c != '\t' && c != '\r' {
			line_has_content = true
		}
	}

	if line_has_content {
		end := len(s)
		if end > line_start && s[end - 1] == '\r' do end -= 1
		last_non_blank_end = end
	}

	if last_non_blank_end <= 0 do return strings.clone("", allocator)
	return strings.clone(s[:last_non_blank_end], allocator)
}

// bridge_pty_stream_screen_payload builds the byte payload of the bridge's catch-up screen
// frame: the captured rows joined, with trailing blank rows trimmed and CRLF row separators.
// Caller owns the result.
//
// This exists as a named seam rather than two statements inlined in the .Screen case so that
// the conversion is covered in the SAME composition the emit site uses. A test that called
// _bridge_pty_stream_lf_to_crlf directly would stay green if someone dropped the call from the
// emit site — it would guard the helper without detecting the regression this task fixes.
bridge_pty_stream_screen_payload :: proc(lines: []string) -> string {
	joined, _, _ := bridge_pty_host_screen_to_output(lines, 0)
	defer delete(joined)
	trimmed := _bridge_pty_stream_trim_trailing_blank_rows(joined)
	defer delete(trimmed)
	return _bridge_pty_stream_lf_to_crlf(trimmed)
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

	saw_stream_closed := false

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
		case .Stream_Ready:
			bridge_pty_stream_emit_lifecycle_event(worker, "shell_pty_stream_ready", local_session_id, local_shell_id)
		case .Stream_Closed:
			saw_stream_closed = true
			bridge_pty_stream_emit_lifecycle_event(worker, "shell_pty_stream_closed", local_session_id, local_shell_id, reply.has_code, reply.code)
		case .Error:
			fmt.println("bridge pty stream error:", reply.message)
		}
		pty_host_reply_delete(reply)
	}

	if !saw_stream_closed {
		bridge_pty_stream_emit_lifecycle_event(worker, "shell_pty_stream_closed", local_session_id, local_shell_id, false, 0)
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

// bridge_pty_stream_encrypt_chunk encrypts PTY output using AES-256-GCM with a 12-byte nonce
// composed of a 4-byte session salt and 8-byte big-endian sequence counter (NIST SP 800-38D).
// Emits enc_b64 containing base64-encoded nonce(12B) + auth_tag(16B) + ciphertext.
bridge_pty_stream_encrypt_chunk :: proc(
	data: []byte,
	salt: [4]byte,
	seq: u64,
	key_hex: string,
	allocator := context.allocator,
) -> (enc_b64: string, ok: bool) {
	if !bridge_is_valid_hex_key(key_hex) do return "", false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false

	nonce: [VAULT_NONCE_BYTES]byte
	nonce[0] = salt[0]
	nonce[1] = salt[1]
	nonce[2] = salt[2]
	nonce[3] = salt[3]
	nonce[4] = byte(seq >> 56)
	nonce[5] = byte(seq >> 48)
	nonce[6] = byte(seq >> 40)
	nonce[7] = byte(seq >> 32)
	nonce[8] = byte(seq >> 24)
	nonce[9] = byte(seq >> 16)
	nonce[10] = byte(seq >> 8)
	nonce[11] = byte(seq)

	ciphertext := make([]byte, len(data), context.temp_allocator)
	tag: [VAULT_TAG_BYTES]byte

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, raw_key)
	defer aes.reset_gcm(&gcm)

	aes.seal_gcm(&gcm, ciphertext, tag[:], nonce[:], nil, data)

	payload_len := VAULT_HEADER_BYTES + len(ciphertext)
	payload := make([]byte, payload_len, context.temp_allocator)
	copy(payload[0:VAULT_NONCE_BYTES], nonce[:])
	copy(payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES], tag[:])
	copy(payload[VAULT_HEADER_BYTES:], ciphertext)

	b64, err := base64.encode(payload, allocator = allocator)
	if err != nil do return "", false
	return string(b64), true
}

// bridge_pty_stream_decrypt_chunk decrypts enc_b64 containing base64(nonce(12B) + auth_tag(16B) + ciphertext)
// using AES-256-GCM and verifies authenticity against the provided vault key.
bridge_pty_stream_decrypt_chunk :: proc(
	enc_b64: string,
	key_hex: string,
	allocator := context.allocator,
) -> (plaintext: []byte, ok: bool) {
	if !bridge_is_valid_hex_key(key_hex) do return nil, false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return nil, false

	clean_b64 := strings.trim_space(enc_b64)
	if strings.has_prefix(clean_b64, VAULT_ARMOR_PREFIX) {
		clean_b64 = clean_b64[len(VAULT_ARMOR_PREFIX):]
	}
	if len(clean_b64) == 0 do return nil, false

	payload, err := base64.decode(clean_b64, allocator = context.temp_allocator)
	if err != nil do return nil, false
	if len(payload) < VAULT_HEADER_BYTES do return nil, false

	nonce := payload[0:VAULT_NONCE_BYTES]
	tag := payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES]
	ciphertext := payload[VAULT_HEADER_BYTES:]

	dst := make([]byte, len(ciphertext), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, raw_key)
	defer aes.reset_gcm(&gcm)

	if !aes.open_gcm(&gcm, dst, nonce, nil, ciphertext, tag) {
		delete(dst, allocator)
		return nil, false
	}
	return dst, true
}

_bridge_pty_stream_deliver_or_queue :: proc(worker: ^Bridge_PTY_Stream_Worker, frame: string, heap: runtime.Allocator) {
	sent := false
	if worker != nil && worker.active && worker.conn != nil && worker.conn.connected {
		sent = bridge_hub_send(worker.conn, frame)
	}
	if !sent {
		if worker != nil && !worker.active {
			delete(frame, heap)
		} else {
			sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
			_bridge_pty_stream_outgoing_bind_heap()
			append(&bridge_pty_stream_outgoing, Bridge_PTY_Stream_Outgoing{json = frame})
			sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
		}
	} else {
		delete(frame, heap)
	}
}

// bridge_pty_stream_emit_frame encodes data chunk to base64 and formats shell_pty_output JSON.
// When vault status is Locked, it emits a locked warning banner and suppresses raw stream bytes.
// When Unlocked, it encrypts the chunk with AES-256-GCM using a monotonic counter nonce emitting enc_b64.
// When Disabled (or unconfigured fallback), it emits plaintext data_b64 without encryption or delay.
bridge_pty_stream_emit_frame :: proc(worker: ^Bridge_PTY_Stream_Worker, session_id: string, data: []byte) {
	if len(data) == 0 do return
	heap := runtime.heap_allocator()

	status := bridge_vault_status()
	#partial switch status {
	case .Locked:
		if worker != nil {
			if worker.locked_banner_emitted do return
			worker.locked_banner_emitted = true
		}
		banner := "\r\n\x1b[33m[Vault locked: terminal stream is suspended. Unlock bridge vault to continue.]\x1b[0m\r\n"
		encoded := base64.encode(transmute([]byte)banner, allocator = heap)
		defer delete(encoded, heap)

		b := strings.builder_make(heap)
		strings.write_string(&b, "{\"type\":\"shell_pty_output\",\"session_id\":\"")
		bridge_runtime_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"data_b64\":\"")
		bridge_runtime_write_json_string(&b, string(encoded))
		strings.write_string(&b, "\"}")
		frame := strings.to_string(b)
		_bridge_pty_stream_deliver_or_queue(worker, frame, heap)
		return

	case .Unlocked:
		if worker != nil {
			worker.locked_banner_emitted = false
		}
		key_hex, vault_active := bridge_read_vault_key()
		defer if vault_active do delete(key_hex)
		if vault_active {
			salt: [4]byte
			seq: u64
			if worker != nil {
				worker.seq += 1
				seq = worker.seq
				salt = worker.salt
			} else {
				sync.mutex_lock(&bridge_pty_stream_fallback_mu)
				if !bridge_pty_stream_fallback_inited {
					crypto.rand_bytes(bridge_pty_stream_fallback_salt[:])
					bridge_pty_stream_fallback_inited = true
				}
				bridge_pty_stream_fallback_seq += 1
				seq = bridge_pty_stream_fallback_seq
				salt = bridge_pty_stream_fallback_salt
				sync.mutex_unlock(&bridge_pty_stream_fallback_mu)
			}

			if enc_b64, ok := bridge_pty_stream_encrypt_chunk(data, salt, seq, key_hex, context.temp_allocator); ok {
				armored := strings.concatenate({VAULT_ARMOR_PREFIX, enc_b64}, context.temp_allocator)
				b := strings.builder_make(heap)
				strings.write_string(&b, "{\"type\":\"shell_pty_output\",\"session_id\":\"")
				bridge_runtime_write_json_string(&b, session_id)
				strings.write_string(&b, "\",\"data_b64\":\"")
				bridge_runtime_write_json_string(&b, armored)
				strings.write_string(&b, "\",\"enc_b64\":\"")
				bridge_runtime_write_json_string(&b, enc_b64)
				strings.write_string(&b, "\"}")
				frame := strings.to_string(b)
				_bridge_pty_stream_deliver_or_queue(worker, frame, heap)
				return
			}
		}
	}

	// Plaintext fallback (e.g. Disabled status): zero encryption overhead or blocking
	encoded := base64.encode(data, allocator = heap)
	defer delete(encoded, heap)

	b := strings.builder_make(heap)
	strings.write_string(&b, "{\"type\":\"shell_pty_output\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	bridge_runtime_write_json_string(&b, string(encoded))
	strings.write_string(&b, "\"}")
	frame := strings.to_string(b)
	_bridge_pty_stream_deliver_or_queue(worker, frame, heap)
}

// bridge_pty_stream_format_lifecycle_event formats shell_pty_stream_ready or shell_pty_stream_closed JSON.
bridge_pty_stream_format_lifecycle_event :: proc(
	event_type: string,
	session_id: string,
	shell_id: string,
	has_exit_code := false,
	exit_code: i32 = 0,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"type\":\"")
	bridge_runtime_write_json_string(&b, event_type)
	strings.write_string(&b, "\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	bridge_runtime_write_json_string(&b, shell_id)
	strings.write_string(&b, "\"")
	if has_exit_code {
		fmt.sbprintf(&b, ",\"exit_code\":%d", exit_code)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// bridge_pty_stream_emit_lifecycle_event formats and emits shell_pty_stream_ready or shell_pty_stream_closed JSON to Hub (REQ-STREAM-EVENT-2).
bridge_pty_stream_emit_lifecycle_event :: proc(
	worker: ^Bridge_PTY_Stream_Worker,
	event_type: string,
	session_id: string,
	shell_id: string,
	has_exit_code := false,
	exit_code: i32 = 0,
) {
	heap := runtime.heap_allocator()
	frame := bridge_pty_stream_format_lifecycle_event(event_type, session_id, shell_id, has_exit_code, exit_code, heap)
	_bridge_pty_stream_deliver_or_queue(worker, frame, heap)
}

// bridge_pty_stream_drain_outgoing flushes queued shell_pty_output frames to the hub connection.
bridge_pty_stream_drain_outgoing :: proc(conn: ^ws.Connection) {
	if conn == nil || !conn.connected do return
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	_bridge_pty_stream_outgoing_bind_heap()
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
	// `items` aliases the OLD backing array, which the bind above guarantees came from the heap.
	// Naming the allocator explicitly matters here: a bare delete() would free it through
	// context.allocator, which is the mismatched-free that made this queue crash in the first place.
	delete(items, heap)
}

// bridge_pty_stream_take_outgoing drains all queued outgoing frames without sending (for tests).
bridge_pty_stream_take_outgoing :: proc() -> [dynamic]string {
	heap := runtime.heap_allocator()
	out := make([dynamic]string, heap)
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	defer sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
	_bridge_pty_stream_outgoing_bind_heap()
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

// bridge_pty_stream_worker_get_active_conn checks if an active streaming worker exists for session_id and retrieves its connection.
bridge_pty_stream_worker_get_active_conn :: proc(session_id: string) -> (conn: ^ws.Connection, active: bool) {
	sid := strings.trim_space(session_id)
	if sid == "" do return nil, false

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	defer sync.mutex_unlock(&bridge_pty_stream_map.mu)

	if bridge_pty_stream_map.workers == nil do return nil, false
	if worker, ok := bridge_pty_stream_map.workers[sid]; ok {
		if worker != nil && worker.active {
			return worker.conn, true
		}
	}
	return nil, false
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
	_bridge_pty_stream_outgoing_bind_heap()
	for item in bridge_pty_stream_outgoing {
		delete(item.json, heap)
	}
	clear(&bridge_pty_stream_outgoing)
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)

	sync.mutex_lock(&bridge_pty_stream_fallback_mu)
	bridge_pty_stream_fallback_seq = 0
	bridge_pty_stream_fallback_inited = false
	sync.mutex_unlock(&bridge_pty_stream_fallback_mu)
}
