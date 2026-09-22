package http

// REQ-LSP-RLY-1: Hub WS relay for LSP sessions.
//
// Carries JSON-RPC between the browser and the bridge's LSP session
// (src/bridge/lsp_session.odin, REQ-LSP-BR-1). Modelled on
// shell_session_stream_handler in shell_session_handlers.odin — same ticket auth,
// same upgrade, same relay shape — with three deliberate differences, each decided
// by the coordinator on the task and recorded here so the next reader does not
// "fix" them back:
//
//  1. NO PERSISTED SESSION. A shell session is a row in shell_sessions and the
//     shell handler checks ownership by reading it. An LSP session has no table and
//     no migration: it is bound to a live socket AND a live process in the bridge's
//     own in-memory map, so a row would outlive both and need reaper logic. You
//     reattach to a terminal; you do not reattach to a language server. The socket
//     dying is the session ending.
//  2. OWNERSHIP IS STRUCTURAL, NOT A CHECK. The registry is keyed by
//     (owner_user_id, session_id), so two users who pick the same session id string
//     occupy different entries and cannot reach each other's. There is no
//     owner_user_id comparison to forget. The URL segment is therefore a plain
//     client-supplied id and needs no unguessability — it is namespaced by the
//     authenticated user.
//  3. START PARAMETERS ARRIVE AS A FRAME, NOT QUERY PARAMS. The browser sends
//     {"type":"start","bridge_id":..,"language":..,"file_path":..} after the
//     upgrade. THE BROWSER NEVER SUPPLIES cmd OR args: the Hub resolves those from
//     the operator's stored config (REQ-LSP-CFG-1). A browser-supplied cmd would be
//     arbitrary code execution on the bridge host, which is the security boundary
//     of this whole feature. file_path also changes as the user opens files, and a
//     query param would fix it at connect time and force a reconnect per file.

import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"

// LSP_EXPERIMENT_KEY gates the whole feature (REQ-EXP-1).
LSP_EXPERIMENT_KEY :: "lsp"

// LSP_IDLE_TIMEOUT bounds a silent socket. It is far longer than the shell
// stream's 120s because an editor can legitimately sit idle with a language
// server attached and no traffic in either direction, whereas a terminal that
// silent is usually gone. Clients that want to hold a session open past this
// send {"type":"ping"} and get {"type":"pong"} back.
LSP_IDLE_TIMEOUT :: 15 * time.Minute

// --- session registry --------------------------------------------------------

Lsp_Session_Entry :: struct {
	owner_user_id: string, // owned
	session_id:    string, // owned; the client-supplied id
	wire_id:       string, // owned; the id used on the bridge wire
	bridge_id:     string, // owned; empty until "start" succeeds
	// The two map keys, owned by the entry. Odin's delete_key removes the slot
	// but hands back no allocation, so the entry keeps the exact strings that
	// were inserted and frees them itself on release.
	owner_key:     string,
	wire_key:      string,
	socket:        net.TCP_Socket,
	started:       bool,
	// closing marks the session dead: the relay must unwind and release it. It is
	// set by the bridge-disconnect teardown AND by a failed write (REQ-LSP-RLY-2).
	closing:       bool,
	// bridge_gone narrows that to "the BRIDGE is what went away", which is the
	// only case where the language server process died on its own. It must stay
	// distinct from closing: the relay's teardown skips send_lsp_stop on it, so
	// setting it for a merely-dead session would strand a live language server on
	// the bridge host. See lsp_should_stop_on_bridge.
	bridge_gone:   bool,
}

// Lsp_Session_Registry holds the live relays. Two indexes over the same entries:
// by wire id (what bridge frames carry) and by owner+session id (what the browser
// names and what makes cross-user access structurally impossible).
Lsp_Session_Registry :: struct {
	mu:       sync.Mutex,
	by_wire:  map[string]^Lsp_Session_Entry,
	by_owner: map[string]^Lsp_Session_Entry,
	// send_timeout overrides LSP_SEND_TIMEOUT for sockets claimed on this
	// registry; zero (the production value — nothing ever sets it) means use the
	// constant. It lives HERE rather than in a package-level variable on purpose:
	// `odin test` runs tests in parallel, so a mutable global would let one test's
	// override leak into another's socket and make both flaky. A per-registry
	// field is private to whoever owns the registry, which in tests is one test.
	send_timeout: time.Duration,
}

// lsp_owner_key namespaces a client session id by its owner. The NUL separator
// cannot occur in either half of a JSON string value that reached us as a path
// segment, so distinct pairs cannot collide into one key.
lsp_owner_key :: proc(owner_user_id, session_id: string, allocator := context.allocator) -> string {
	return strings.concatenate({owner_user_id, "\x00", session_id}, allocator)
}

// lsp_registry_claim reserves (owner, session_id) and returns the new entry.
// ok=false means that pair is already live: a second socket for it is a conflict,
// never a silent replacement, or a duplicate browser tab would kill a working
// session out from under the first one.
lsp_registry_claim :: proc(reg: ^Lsp_Session_Registry, owner_user_id, session_id, wire_id: string, socket: net.TCP_Socket) -> (^Lsp_Session_Entry, bool) {
	if reg == nil do return nil, false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)

	key := lsp_owner_key(owner_user_id, session_id)
	if _, exists := reg.by_owner[key]; exists {
		delete(key)
		return nil, false
	}

	entry := new(Lsp_Session_Entry)
	entry.owner_user_id = strings.clone(owner_user_id)
	entry.session_id    = strings.clone(session_id)
	entry.wire_id       = strings.clone(wire_id)
	entry.bridge_id     = ""
	entry.owner_key     = key
	entry.wire_key      = strings.clone(wire_id)
	entry.socket        = socket
	entry.started       = false
	entry.closing       = false
	entry.bridge_gone   = false

	// Bound writes on this socket against a NON-PROGRESSING peer (REQ-LSP-RLY-2).
	// Claim is the one choke point: every frame the Hub ever writes to this browser
	// goes to entry.socket, and claim happens before the upgrade response, so
	// nothing is written before the bound is in place. SO_SNDTIMEO touches ONLY the
	// send side, so the relay thread's parked recv and its own .Receive_Timeout are
	// unaffected — the reader remains the socket's sole closer.
	//
	// KNOW WHAT THIS DOES AND DOES NOT GUARANTEE. SO_SNDTIMEO bounds each send()
	// SYSCALL, not the frame. Linux socket(7): a blocked send returns a partial
	// count, or EWOULDBLOCK if nothing was sent. core/net _send_tcp only exits its
	// loop on an errno, so a partial count with NO error loops into a FRESH timeout
	// window. Therefore:
	//   - a peer making NO progress (the wedged tab this ticket is about) is bounded
	//     at one timeout, which is the defect being fixed;
	//   - a peer that TRICKLES is bounded by its own throughput, not by this value.
	//     A browser absorbing 500KB at 10KB/s holds the lock ~50s without the
	//     timeout ever firing.
	// The trickling case is NOT addressed here and is not this ticket's subject.
	send_timeout := reg.send_timeout
	if send_timeout <= 0 do send_timeout = LSP_SEND_TIMEOUT
	_ = net.set_option(socket, .Send_Timeout, send_timeout)

	if reg.by_wire == nil do reg.by_wire = make(map[string]^Lsp_Session_Entry)
	if reg.by_owner == nil do reg.by_owner = make(map[string]^Lsp_Session_Entry)
	reg.by_wire[entry.wire_key]   = entry
	reg.by_owner[entry.owner_key] = entry
	return entry, true
}

// lsp_registry_release removes an entry and frees everything it owns. Safe to call
// for a wire id that is already gone.
lsp_registry_release :: proc(reg: ^Lsp_Session_Registry, wire_id: string) {
	if reg == nil do return
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)

	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return

	delete_key(&reg.by_owner, entry.owner_key)
	delete_key(&reg.by_wire, entry.wire_key)

	delete(entry.owner_user_id)
	delete(entry.session_id)
	delete(entry.wire_id)
	// bridge_id is "" until a "start" succeeds, and that empty value was never
	// allocated — only free what was actually cloned.
	if entry.bridge_id != "" do delete(entry.bridge_id)
	delete(entry.owner_key)
	delete(entry.wire_key)
	free(entry)
}

// lsp_registry_mark_started records the bridge the session was started on. The
// relay needs it again at teardown to send lsp_stop.
lsp_registry_mark_started :: proc(reg: ^Lsp_Session_Registry, wire_id, bridge_id: string) {
	if reg == nil do return
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return
	if entry.bridge_id != "" do delete(entry.bridge_id)
	entry.bridge_id = strings.clone(bridge_id)
	entry.started = true
}

// lsp_registry_mark_stopped records that the client stopped the server itself.
// Without this the entry stays "started" and a later bridge disconnect would tear
// down a session the user had already stopped and might be about to restart.
lsp_registry_mark_stopped :: proc(reg: ^Lsp_Session_Registry, wire_id: string) {
	if reg == nil do return
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return
	if entry.bridge_id != "" do delete(entry.bridge_id)
	entry.bridge_id = ""
	entry.started = false
}

// lsp_should_stop_on_bridge reports whether the relay's teardown must still tell
// the bridge to stop the language server.
//
// This is the predicate the teardown defer consumes, named and separated so it can
// be tested directly. It keys on bridge_gone, NOT on closing: a session killed for
// a failed write (REQ-LSP-RLY-2) is dead, but its bridge is alive and its language
// server is still running, so the stop MUST go out or the process outlives the
// socket that owned it — one orphaned server per wedged tab.
//
// An unknown wire_id answers true, preserving the pre-existing behaviour that a
// released entry still gets its stop sent.
lsp_should_stop_on_bridge :: proc(reg: ^Lsp_Session_Registry, wire_id: string) -> bool {
	if reg == nil do return true
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return true
	return !entry.bridge_gone
}

// lsp_session_closing reports whether this session has been marked dead, by either
// the bridge-disconnect teardown or a failed write. Read under the lock: the flag
// is set from the bridge WS thread.
lsp_session_closing :: proc(reg: ^Lsp_Session_Registry, wire_id: string) -> bool {
	if reg == nil do return false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return false
	return entry.closing
}

// lsp_registry_wake_bridge_sessions is the bridge-disconnect teardown. For every
// live session started on bridge_id it tells the browser why the session ended and
// then WAKES that session's relay thread so it unwinds and releases the entry.
//
// It deliberately does NOT close the socket and does NOT release the entry. Per
// AGENTS.md "Socket lifetime across threads" — a rule this codebase has paid for
// five times — the thread parked in recv is the socket's SOLE closer on every exit
// path; any other thread may only shutdown(.Receive) to wake it. A close from here
// would either leave the parked recv sleeping forever (it holds the struct file, so
// the socket is merely orphaned) or, if the reader were between recv calls, let its
// next recv re-resolve an fd NUMBER a new connection already owns and read a
// stranger's bytes under this session's id.
//
// Returns how many sessions were woken, so the caller can log it and tests can
// assert on it.
lsp_registry_wake_bridge_sessions :: proc(reg: ^Lsp_Session_Registry, bridge_id: string) -> int {
	if reg == nil || bridge_id == "" do return 0
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)

	woken := 0
	for _, entry in reg.by_wire {
		if entry == nil || !entry.started do continue
		if entry.bridge_id != bridge_id do continue
		entry.closing = true
		// The bridge is what went away, so the server process died with it. This
		// is the ONLY place this may be set — see lsp_should_stop_on_bridge.
		entry.bridge_gone = true
		// Last word to the browser while the socket is still writable: the send
		// side is untouched by shutdown(.Receive), so this frame goes out.
		//
		// This loop holds reg.mu across EVERY matching session, so with WEDGED tabs
		// the ordinary LSP_SEND_TIMEOUT would cost N x 5s of lock hold on the one
		// path whose whole purpose is recovering from a wedged peer — bounded, but a
		// weaker version of the bug this ticket is about. So the teardown write gets
		// its own much shorter bound (REQ-LSP-RLY-2 item A). N x 100ms is the bound
		// for NON-PROGRESSING peers; a trickling peer is still bounded only by its
		// own throughput (see lsp_registry_claim).
		// That is sound precisely here and nowhere else: this frame is a COURTESY,
		// the actual recovery is the shutdown below, and a browser that cannot take
		// ~60 bytes in 100ms has a full send buffer, i.e. is exactly the wedged peer
		// we are recovering from. It still learns the session ended — by the socket
		// closing when the relay unwinds.
		_ = net.set_option(entry.socket, .Send_Timeout, LSP_TEARDOWN_SEND_TIMEOUT)
		frame := lsp_error_frame(entry.session_id, "bridge disconnected")
		_ = lsp_write_ws_text_frame(entry.socket, frame)
		delete(frame)
		// Wake the parked reader; it owns the close.
		_ = net.shutdown(entry.socket, .Receive)
		woken += 1
	}
	return woken
}

// lsp_registry_deliver writes one already-built frame to the browser socket for
// wire_id. The write happens under the registry lock so a bridge thread's frame
// can never interleave with another thread's into a corrupt frame, and so the
// socket cannot be released underneath the write.
lsp_registry_deliver :: proc(reg: ^Lsp_Session_Registry, wire_id, text: string) -> bool {
	if reg == nil do return false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return false
	sent, ok := lsp_write_ws_text_frame_counted(entry.socket, text)
	if ok do return true

	// The write did not complete: either the peer is wedged (sent == 0, the send
	// timeout expired having moved nothing) or, worse, half a frame is already on
	// the wire (sent > 0) and this browser's stream can never resynchronise. Both
	// end the session. A dead session is visible to the user and to the relay; a
	// desynchronised one looks alive and serves corruption.
	//
	// We do NOT close the socket here. Per AGENTS.md "Socket lifetime across
	// threads", the thread parked in recv is the sole closer on every exit path;
	// this thread may only mark the session and wake that reader, exactly as
	// lsp_registry_wake_bridge_sessions does.
	entry.closing = true
	_ = net.shutdown(entry.socket, .Receive)
	return false
}

// --- WebSocket framing for the browser socket --------------------------------
//
// The shared write_ws_text_frame (bridge_handlers.odin) and the shell service's
// _write_ws_text both REFUSE any payload over 65535 bytes, because everything
// they carry is small or pre-chunked. LSP is not: a single JSON-RPC response —
// a completion list, semantic tokens, document symbols for a large file —
// routinely exceeds 64KB, and there it would be dropped on a `false` return that
// no caller inspects. So the LSP socket gets its own writer with the 64-bit
// length path. Nothing else uses it and no existing writer changes behaviour.

// lsp_ws_frame_header writes the server->client frame header for a payload of n
// bytes into out, returning how many bytes it used. Split out from the socket
// write so the three length encodings — and especially the 64-bit one, which no
// other writer in this codebase produces — are testable without a socket.
lsp_ws_frame_header :: proc(out: []byte, n: int) -> int {
	out[0] = 0x81 // FIN + text opcode
	switch {
	case n <= 125:
		out[1] = byte(n)
		return 2
	case n <= 65535:
		out[1] = 126
		out[2] = byte((n >> 8) & 0xff)
		out[3] = byte(n & 0xff)
		return 4
	case:
		out[1] = 127
		// 64-bit big-endian length. The high bit must be 0 per RFC 6455, which
		// holds here because n came out of a single allocation.
		for i in 0 ..< 8 {
			out[2 + i] = byte((u64(n) >> uint(8 * (7 - i))) & 0xff)
		}
		return 10
	}
}

lsp_ws_header_len :: proc(n: int) -> int {
	switch {
	case n <= 125:   return 2
	case n <= 65535: return 4
	case:            return 10
	}
}

// LSP_SEND_TIMEOUT bounds how long one send() syscall to a browser socket may
// block on a peer that is not draining, and therefore how long the registry lock
// can be held against a wedged peer (REQ-LSP-RLY-2). It is NOT a bound on total
// frame time for a peer that trickles — see lsp_registry_claim. Five seconds:
// a browser that has not accepted a single byte for five seconds is wedged, not
// merely slow — loopback and LAN writes complete in microseconds, and the only
// thing that stalls them this long is a tab that has stopped draining its socket
// entirely. Tuning this DOWN starts killing healthy clients on a slow link;
// tuning it UP weakens the bound on the teardown path, which is the recovery
// mechanism this defect was about. It is not an arbitrary constant.
LSP_SEND_TIMEOUT :: 5 * time.Second

// LSP_TEARDOWN_SEND_TIMEOUT bounds the courtesy frame on the bridge-disconnect
// path, which writes to every affected session under one lock hold. See
// lsp_registry_wake_bridge_sessions for why this path may be far stricter than
// LSP_SEND_TIMEOUT.
LSP_TEARDOWN_SEND_TIMEOUT :: 100 * time.Millisecond

// lsp_write_ws_text_frame_counted writes one frame and reports HOW MUCH of it went
// out, which the plain bool cannot express and the kill decision requires.
//
// net.send_tcp does NOT retry: core/net/socket_linux.odin _send_tcp returns on the
// first errno with a possibly NON-ZERO total_written. So when SO_SNDTIMEO expires
// mid-frame the result is a PARTIAL WebSocket frame on the wire, and a browser
// that has read half a frame misparses that frame and every byte after it — the
// stream is desynchronised permanently. A caller that only sees `err != nil`
// cannot tell that apart from "nothing was sent" and would leave the session up in
// a silently corrupt state, which is worse than ending it.
//
// ok is true only when the WHOLE frame went out. sent > 0 with ok=false is the
// desynchronised case specifically.
lsp_write_ws_text_frame_counted :: proc(client: net.TCP_Socket, text: string) -> (sent: int, ok: bool) {
	n := len(text)
	header_len := lsp_ws_header_len(n)
	frame := make([]byte, header_len + n)
	defer delete(frame)
	lsp_ws_frame_header(frame[:header_len], n)
	copy(frame[header_len:], transmute([]byte)text)
	written, err := net.send_tcp(client, frame)
	// NOTE: a send timeout arrives as .Would_Block (EAGAIN), NOT as .Timeout —
	// core/net/errors_linux.odin _tcp_send_error never produces .Timeout on Linux.
	// Do NOT "tidy" this into a check for .Timeout: it would compile, read as
	// correct, and silently never fire. The test for both conditions at once —
	// no error AND the full length — is deliberately error-kind-agnostic.
	return written, err == nil && written == len(frame)
}

lsp_write_ws_text_frame :: proc(client: net.TCP_Socket, text: string) -> bool {
	_, ok := lsp_write_ws_text_frame_counted(client, text)
	return ok
}

// Lsp_WS_Reader mirrors Bridge_WS_Reader but accepts the 64-bit length the shared
// reader rejects as fatal (bridge_handlers.odin: "64-bit lengths are not used on
// this control channel"). A textDocument/didOpen carrying a large file is exactly
// such a frame, so on this socket it must be read, not treated as a protocol error.
Lsp_WS_Reader :: struct {
	socket:  net.TCP_Socket,
	pending: [dynamic]byte,
}

lsp_ws_reader_make :: proc(socket: net.TCP_Socket) -> Lsp_WS_Reader {
	return Lsp_WS_Reader{socket = socket}
}

lsp_ws_reader_destroy :: proc(reader: ^Lsp_WS_Reader) {
	if reader != nil do delete(reader.pending)
}

// lsp_ws_take_frame pulls ONE complete masked text frame off the front of
// reader.pending. ok=false with fatal=false means "need more bytes"; fatal=true
// means the stream is unusable. Close (0x8) is reported as fatal so a browser
// closing its socket ends the relay rather than looking like a short read.
lsp_ws_take_frame :: proc(reader: ^Lsp_WS_Reader) -> (text: string, ok: bool, fatal: bool) {
	b := reader.pending[:]
	if len(b) < 2 do return "", false, false
	opcode := b[0] & 0x0f
	if opcode != 0x1 do return "", false, true // text frames only; close/binary end it

	masked := (b[1] & 0x80) != 0
	payload_len := int(b[1] & 0x7f)
	header_len := 2
	switch payload_len {
	case 126:
		if len(b) < 4 do return "", false, false
		payload_len = int(b[2]) << 8 | int(b[3])
		header_len = 4
	case 127:
		if len(b) < 10 do return "", false, false
		length: u64 = 0
		for i in 0 ..< 8 {
			length = length << 8 | u64(b[2 + i])
		}
		// Refuse a length this process could not hold anyway rather than
		// truncating it into an int.
		if length > u64(max(int) / 2) do return "", false, true
		payload_len = int(length)
		header_len = 10
	}

	data_off := header_len
	mask_key: [4]byte
	if masked {
		if len(b) < header_len + 4 do return "", false, false
		mask_key = {b[header_len], b[header_len + 1], b[header_len + 2], b[header_len + 3]}
		data_off = header_len + 4
	}
	frame_end := data_off + payload_len
	if len(b) < frame_end do return "", false, false

	payload := make([]byte, payload_len)
	copy(payload, b[data_off:frame_end])
	if masked {
		for i in 0 ..< payload_len do payload[i] = payload[i] ~ mask_key[i % 4]
	}
	remaining := len(reader.pending) - frame_end
	if remaining > 0 do copy(reader.pending[:], reader.pending[frame_end:])
	resize(&reader.pending, remaining)
	return string(payload), true, false
}

lsp_read_ws_text_blocking :: proc(reader: ^Lsp_WS_Reader, timeout: time.Duration) -> (string, bool) {
	if text, ok, fatal := lsp_ws_take_frame(reader); fatal {
		return "", false
	} else if ok {
		return text, true
	}
	_ = net.set_option(reader.socket, .Receive_Timeout, timeout)
	buf: [8192]byte
	for {
		n, err := net.recv_tcp(reader.socket, buf[:])
		if err != nil || n <= 0 do return "", false
		append(&reader.pending, ..buf[:n])
		if text, ok, fatal := lsp_ws_take_frame(reader); fatal {
			return "", false
		} else if ok {
			return text, true
		}
	}
}

// --- bridge -> browser fan-out ----------------------------------------------

// lsp_forward_bridge_frame rewrites one bridge frame for the browser and delivers
// it. The session_id on the wire is the Hub's opaque wire id; the browser only
// ever knows the id IT chose, so the field is translated rather than passed
// through. Returns false when no live session owns the frame (a late frame from a
// session whose socket already went away) — the caller drops it.
//
// Called from the bridge WS thread (bridge_handlers.odin), not a request thread,
// so nothing here may rely on the per-request arena.
lsp_forward_bridge_frame :: proc(reg: ^Lsp_Session_Registry, frame_type, text: string) -> bool {
	if reg == nil do return false
	wire_id := json_string(text, "session_id")
	defer delete(wire_id)
	if wire_id == "" do return false

	client_session_id, found := lsp_client_session_id(reg, wire_id)
	if !found do return false
	defer delete(client_session_id)

	out := lsp_bridge_frame_for_client(frame_type, text, client_session_id)
	defer delete(out)
	return lsp_registry_deliver(reg, wire_id, out)
}

// lsp_bridge_frame_for_client rebuilds one bridge frame with the browser's own
// session id in place of the wire id, carrying across only the fields that
// direction defines. Pure, so the translation is testable on its own.
lsp_bridge_frame_for_client :: proc(frame_type, text, client_session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"")
	write_handler_json_string(&b, frame_type)
	strings.write_string(&b, "\",\"session_id\":\"")
	write_handler_json_string(&b, client_session_id)
	strings.write_byte(&b, '"')

	switch frame_type {
	case "lsp_data":
		message := json_string(text, "message")
		defer delete(message)
		strings.write_string(&b, ",\"message\":\"")
		write_handler_json_string(&b, message)
		strings.write_byte(&b, '"')
	case "lsp_error":
		reason := json_string(text, "reason")
		defer delete(reason)
		strings.write_string(&b, ",\"reason\":\"")
		write_handler_json_string(&b, reason)
		strings.write_string(&b, "\",\"exit_code\":")
		strings.write_int(&b, json_int(text, "exit_code", 0))
	case "lsp_started":
		ok_val := json_bool_value(text, "ok")
		strings.write_string(&b, ",\"ok\":")
		strings.write_string(&b, "true" if ok_val else "false")
		if !ok_val {
			err_msg := json_string(text, "error")
			defer delete(err_msg)
			strings.write_string(&b, ",\"error\":\"")
			write_handler_json_string(&b, err_msg)
			strings.write_byte(&b, '"')
		}
	case "lsp_stopped":
	// no payload beyond the type and session id
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// lsp_client_session_id maps a wire id back to the id the browser chose. The
// returned string is a clone the caller frees, so it cannot dangle if the entry
// is released the moment the lock drops.
lsp_client_session_id :: proc(reg: ^Lsp_Session_Registry, wire_id: string) -> (string, bool) {
	if reg == nil do return "", false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return "", false
	return strings.clone(entry.session_id), true
}

// --- handler -----------------------------------------------------------------

Lsp_Session_Stream_Handlers :: struct {
	ws_tickets:          ^User_WS_Ticket_Store,
	bridges:             ^bridge_service.Bridge_Service,
	experiments:         ^iface.Experiment_Repository,
	lsp_configs:         ^iface.Lsp_Server_Config_Repository,
	sessions:            ^Lsp_Session_Registry,
	ids:                 ^platform.ID_Generator,
	bridge_command_sink: project_service.Bridge_Command_Sink,
}

// lsp_experiment_enabled reports the "lsp" flag for this user. The experiment
// repository exposes only set and list_by_owner — there is no get-by-key — so the
// owner's flags are listed and scanned. Absent means off.
lsp_experiment_enabled :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) -> bool {
	exps, err := iface.experiment_list_by_owner(repo, owner_user_id)
	if err.code != .None do return false
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}
	for exp in exps {
		if exp.key == LSP_EXPERIMENT_KEY do return exp.enabled
	}
	return false
}

// lsp_resolve_server picks the configured server for (bridge, language, file_path)
// using the REQ-LSP-CFG-1 resolver. Returns a config whose strings the caller must
// free with domain.lsp_server_config_destroy.
//
// This runs on the relay thread, which is NOT covered by the per-request arena, so
// the intermediate list is an explicit allocation rather than temp_allocator.
lsp_resolve_server :: proc(repo: ^iface.Lsp_Server_Config_Repository, owner_user_id, bridge_id, language, file_path: string) -> (domain.Lsp_Server_Config, bool) {
	all_configs, err := iface.lsp_server_config_list_by_bridge(repo, owner_user_id, bridge_id)
	if err.code != .None do return domain.Lsp_Server_Config{}, false
	defer domain.lsp_server_configs_destroy(all_configs)

	lang_configs := make([dynamic]domain.Lsp_Server_Config)
	defer delete(lang_configs)
	for c in all_configs {
		if c.language == language do append(&lang_configs, c)
	}

	cfg, found := domain.lsp_server_config_resolve(lang_configs[:], file_path)
	if !found do return domain.Lsp_Server_Config{}, false
	// The resolved config aliases strings owned by all_configs, which is freed on
	// return — hand back a deep copy instead.
	return lsp_server_config_clone(cfg), true
}

lsp_server_config_clone :: proc(c: domain.Lsp_Server_Config) -> domain.Lsp_Server_Config {
	return domain.Lsp_Server_Config{
		config_id       = strings.clone(c.config_id),
		owner_user_id   = strings.clone(c.owner_user_id),
		bridge_id       = strings.clone(c.bridge_id),
		language        = strings.clone(c.language),
		cmd             = strings.clone(c.cmd),
		args            = strings.clone(c.args),
		file_extensions = strings.clone(c.file_extensions),
		root_markers    = strings.clone(c.root_markers),
		dir_prefix      = strings.clone(c.dir_prefix),
		created_at      = strings.clone(c.created_at),
		updated_at      = strings.clone(c.updated_at),
	}
}

// lsp_working_dir chooses the language server's cwd: the config's dir_prefix when
// the operator set one (that is exactly "this server serves this tree"), otherwise
// the directory holding the file.
//
// root_markers is deliberately NOT consulted here, and it cannot be: this proc runs in
// the Hub and resolves the cwd by pure string manipulation, but the files live on the
// BRIDGE host. Walking upward for a marker from here would search the Hub's own
// filesystem — the wrong machine — and could pick a stray .git as a nonsense root.
// Root detection therefore belongs in src/bridge/lsp_session.odin, where the process is
// spawned and the filesystem is the right one, which also means root_markers must first
// be added to the lsp_start wire payload (it is not on the wire today).
// Resolved by REQ-LSP-CFG-4: the column and its round-trip stay, the Settings > LSP field
// is hidden until something reads it, and the bridge-side implementation is deferred
// until the relay has run end to end (REQ-LSP-E2E-1). No open question here.
lsp_working_dir :: proc(cfg: domain.Lsp_Server_Config, file_path: string) -> string {
	if strings.trim_space(cfg.dir_prefix) != "" do return strings.clone(cfg.dir_prefix)
	slash := strings.last_index_byte(file_path, '/')
	if slash <= 0 do return strings.clone("")
	return strings.clone(file_path[:slash])
}

lsp_simple_frame :: proc(frame_type, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"")
	write_handler_json_string(&b, frame_type)
	strings.write_string(&b, "\",\"session_id\":\"")
	write_handler_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

lsp_error_frame :: proc(session_id, reason: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_error\",\"session_id\":\"")
	write_handler_json_string(&b, session_id)
	strings.write_string(&b, "\",\"reason\":\"")
	write_handler_json_string(&b, reason)
	strings.write_string(&b, "\",\"exit_code\":0}")
	return strings.to_string(b)
}

// GET /api/v1/lsp/{session_id}/stream — WS upgrade carrying JSON-RPC both ways.
//
// Refusals happen BEFORE the upgrade and as plain HTTP errors: a socket that
// upgrades and then closes tells the client nothing about why.
lsp_session_stream_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Lsp_Session_Stream_Handlers)(ctx)

	ticket := query_value(req.query, "ticket")
	if ticket == "" {
		write_http_response(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket required for lsp stream"), req.request_id))
		return
	}
	auth_ctx, auth_ok := user_ws_ticket_store_consume(h.ws_tickets, ticket)
	if !auth_ok {
		write_http_response(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket is invalid or expired"), req.request_id))
		return
	}

	// Experiment gate (REQ-EXP-1): with the flag off the route refuses outright.
	if !lsp_experiment_enabled(h.experiments, auth_ctx.user_id) {
		write_http_response(client, respond_error(domain.domain_error(.Forbidden, "the lsp experiment is not enabled for this user"), req.request_id))
		return
	}

	session_id := path_part(req.path, 4)
	if session_id == "" || strings.contains(session_id, "/") {
		write_http_response(client, respond_error(domain.domain_error(.Validation_Failed, "session id is required"), req.request_id))
		return
	}

	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" {
		write_http_response(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id))
		return
	}

	// The wire id is what the bridge keys its session map by. It is generated
	// here, never taken from the client, so two users who both pick session id
	// "main" get two different language servers instead of one shared one.
	// platform.generate_id returns fmt.tprintf memory — a TEMP-ALLOCATOR string.
	// It must be cloned onto the heap for two independent reasons:
	//   1. delete() on a temp string frees it against context.allocator, which is
	//      a bad free (the same defect the tracking allocator reports elsewhere in
	//      this tree).
	//   2. wire_id lives for the whole session and is read on every frame. The
	//      per-thread temp ring wraps as a long-lived relay keeps allocating, and
	//      once it wraps it reuses those bytes IN PLACE — silently corrupting the
	//      session id in every frame sent after that point. shell_session_handlers
	//      hit exactly this and documents it around its stream_id.
	generated := ""
	if h.ids != nil do generated = platform.generate_id(h.ids, "lsp_")
	if generated == "" {
		write_http_response(client, respond_error(domain.domain_error(.Internal_Error, "could not allocate an lsp session id"), req.request_id))
		return
	}
	wire_id := strings.clone(generated)
	defer delete(wire_id)

	entry, claimed := lsp_registry_claim(h.sessions, auth_ctx.user_id, session_id, wire_id, client)
	if !claimed {
		write_http_response(client, respond_error(domain.domain_error(.Conflict, "an lsp session with this id is already open"), req.request_id))
		return
	}
	// From here the entry owns its strings; release frees them and unregisters.
	defer lsp_registry_release(h.sessions, wire_id)

	if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) do return

	ready := lsp_simple_frame("ready", session_id)
	_ = lsp_write_ws_text_frame(client, ready)
	delete(ready)

	reader := lsp_ws_reader_make(client)
	defer lsp_ws_reader_destroy(&reader)

	// Teardown: a session that was started must be stopped on the bridge, or the
	// language server outlives the socket that owned it. bridge_id is read from
	// the entry because "start" may have set it after the claim.
	started_bridge_id := ""
	defer {
		if started_bridge_id != "" {
			// Skip the stop ONLY when the bridge itself is what went away: the
			// server process died with it, and send_lsp_stop would only fail an
			// offline bridge lookup. Any other death — including a session killed
			// for a failed write — leaves a live server that must be stopped.
			if lsp_should_stop_on_bridge(h.sessions, wire_id) {
				bridge_service.send_lsp_stop(h.bridges, auth_ctx, started_bridge_id, wire_id, h.bridge_command_sink)
			}
			delete(started_bridge_id)
		}
	}

	for {
		text, ok := lsp_read_ws_text_blocking(&reader, LSP_IDLE_TIMEOUT)
		if !ok do return
		defer delete(text)

		frame_type := json_string(text, "type")
		defer delete(frame_type)

		switch frame_type {
		case "start":
			if started_bridge_id != "" {
				frame := lsp_error_frame(session_id, "session is already started")
				_ = lsp_write_ws_text_frame(client, frame)
				delete(frame)
				continue
			}
			bridge_id := json_string(text, "bridge_id")
			language  := json_string(text, "language")
			file_path := json_string(text, "file_path")
			defer {
				delete(bridge_id)
				delete(language)
				delete(file_path)
			}
			if strings.trim_space(bridge_id) == "" || strings.trim_space(language) == "" {
				frame := lsp_error_frame(session_id, "start requires bridge_id and language")
				_ = lsp_write_ws_text_frame(client, frame)
				delete(frame)
				continue
			}

			cfg, resolved := lsp_resolve_server(h.lsp_configs, auth_ctx.user_id, bridge_id, language, file_path)
			if !resolved {
				frame := lsp_error_frame(session_id, "no lsp server is configured for this language and path")
				_ = lsp_write_ws_text_frame(client, frame)
				delete(frame)
				continue
			}
			defer domain.lsp_server_config_destroy(cfg)

			cwd := lsp_working_dir(cfg, file_path)
			defer delete(cwd)

			sent, send_err := bridge_service.send_lsp_start(
				h.bridges, auth_ctx, bridge_id, wire_id,
				language, cfg.cmd, cfg.args, cwd, auth_ctx.user_id,
				h.bridge_command_sink,
			)
			if !sent {
				frame := lsp_error_frame(session_id, send_err.message)
				_ = lsp_write_ws_text_frame(client, frame)
				delete(frame)
				continue
			}
			started_bridge_id = strings.clone(bridge_id)
			lsp_registry_mark_started(h.sessions, wire_id, bridge_id)
			_ = entry

		case "send":
			if started_bridge_id == "" {
				frame := lsp_error_frame(session_id, "session is not started")
				_ = lsp_write_ws_text_frame(client, frame)
				delete(frame)
				continue
			}
			message := json_string(text, "message")
			defer delete(message)
			if message == "" do continue
			bridge_service.send_lsp_message(h.bridges, auth_ctx, started_bridge_id, wire_id, message, h.bridge_command_sink)

		case "stop":
			if started_bridge_id == "" do continue
			bridge_service.send_lsp_stop(h.bridges, auth_ctx, started_bridge_id, wire_id, h.bridge_command_sink)
			delete(started_bridge_id)
			started_bridge_id = ""
			lsp_registry_mark_stopped(h.sessions, wire_id)

		case "ping":
			frame := lsp_simple_frame("pong", session_id)
			_ = lsp_write_ws_text_frame(client, frame)
			delete(frame)
		}
	}
}

// auth_ctx is carried by value into the teardown defer above; this reference keeps
// the contracts import honest when the file is read in isolation.
_ :: contracts
