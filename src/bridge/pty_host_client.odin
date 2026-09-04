package main

// BR-2: Odin client for the ham-pty-host multi-agent daemon (HOST-1).
//
// This speaks the daemon's instance-scoped wire protocol (tools/pty_host/src/
// dproto.rs) so the bridge can drive N agents over one unix socket instead of
// tmux. The framing is a u32 big-endian length prefix followed by a tagged
// payload; every data-plane frame carries an instance id. This module is a
// byte-for-byte port of the dproto codec plus a blocking request/response helper
// and a lazy daemon starter.
//
// Kept deliberately dependency-light (pure encode/decode + a posix unix-socket
// round-trip) so the codec is unit-testable without a live daemon; the launch
// path (bridge_runtime_launch_agent) calls the high-level host_* ops behind the
// PTY-host runtime flag.

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// ---- protocol tags (must match dproto.rs) -------------------------------

PTY_HOST_T_SPAWN :: 0x20
PTY_HOST_T_CLOSE :: 0x21
PTY_HOST_T_RESTART :: 0x22
PTY_HOST_T_LIST :: 0x23
PTY_HOST_T_ATTACH :: 0x30
PTY_HOST_T_INPUT :: 0x31
PTY_HOST_T_KEY :: 0x32
PTY_HOST_T_RESIZE :: 0x33
PTY_HOST_T_CAPTURE :: 0x34
PTY_HOST_T_DETACH :: 0x35
PTY_HOST_T_PING :: 0x36

PTY_HOST_T_SPAWNED :: 0xA0
PTY_HOST_T_CLOSED :: 0xA1
PTY_HOST_T_RESTARTED :: 0xA2
PTY_HOST_T_AGENTLIST :: 0xA3
PTY_HOST_T_OUTPUT :: 0xA4
PTY_HOST_T_SCREEN :: 0xA5
PTY_HOST_T_EXITED :: 0xA6
PTY_HOST_T_PONG :: 0xA7
PTY_HOST_T_ERROR :: 0xA8
// HOST-2 events (bridge decodes; never sent by the bridge).
PTY_HOST_T_STARTUP_READY :: 0xA9
PTY_HOST_T_STARTUP_BLOCKED :: 0xAA
PTY_HOST_T_SCREEN_CHANGED :: 0xAB

PTY_HOST_MAX_FRAME_BYTES :: 64 * 1024 * 1024

// ---- named keys (must match proto.rs NamedKey discriminants) ------------

Pty_Host_Key :: enum u8 {
	Enter          = 1,
	Esc            = 2,
	Ctrl_C         = 3,
	Tab            = 4,
	Up             = 5,
	Down           = 6,
	Left           = 7,
	Right          = 8,
	Backspace      = 9,
	Ctrl_D         = 10,
	Ctrl_Backslash = 11,
	Home           = 12,
	End            = 13,
	Page_Up        = 14,
	Page_Down      = 15,
	Delete         = 16,
}

// ---- request/reply value types ------------------------------------------

// Pty_Host_Spawn_Request is everything the daemon needs to (re-)spawn an agent.
// The daemon remembers this so Restart re-spawns the exact same command without
// the bridge re-plumbing it. env entries are (key,value) pairs; detect is the
// opaque startup-detection JSON (stored verbatim by HOST-1, parsed in HOST-2).
Pty_Host_Spawn_Request :: struct {
	instance: string,
	argv:     []string,
	cwd:      string, // "" => None on the wire
	env:      [][2]string,
	detect:   string, // "" => None on the wire
	has_cwd:  bool,
	has_detect: bool,
	rows:     u16,
	cols:     u16,
}

// Pty_Host_Agent_Info is one row of a List reply: an agent's live state.
Pty_Host_Agent_Info :: struct {
	instance_id:   string,
	program:       string,
	pid:           i32,
	alive:         bool,
	has_exit_code: bool,
	exit_code:     i32,
	rows:          u16,
	cols:          u16,
	started_at:    u64,
	last_activity: u64,
}

// Pty_Host_Reply is a decoded daemon->client message. kind selects the active
// fields; screen/agents/data are owned by the caller (see pty_host_reply_delete).
Pty_Host_Reply_Kind :: enum {
	Spawned,
	Closed,
	Restarted,
	Agent_List,
	Output,
	Screen,
	Child_Exited,
	Pong,
	Error,
	// HOST-2 events
	Startup_Ready,
	Startup_Blocked,
	Screen_Changed,
}

Pty_Host_Reply :: struct {
	kind:        Pty_Host_Reply_Kind,
	instance:    string,
	pid:         i32,
	code:        i32, // ChildExited code
	message:     string, // Error message / StartupBlocked safe_diagnostic
	reason_code: string, // StartupBlocked reason_code
	hash:        u64, // ScreenChanged content hash
	data:        []byte, // Output bytes
	screen:      Pty_Host_Screen,
	agents:      []Pty_Host_Agent_Info,
}

Pty_Host_Screen :: struct {
	rows:       u16,
	cols:       u16,
	cursor_row: u16,
	cursor_col: u16,
	lines:      []string,
}

// ---- primitive encoders (match dproto.rs put_*) -------------------------

pty_host_put_u16 :: proc(p: ^[dynamic]byte, v: u16) {
	append(p, byte(v >> 8), byte(v))
}

pty_host_put_i32 :: proc(p: ^[dynamic]byte, v: i32) {
	u := u32(v)
	append(p, byte(u >> 24), byte(u >> 16), byte(u >> 8), byte(u))
}

pty_host_put_u64 :: proc(p: ^[dynamic]byte, v: u64) {
	append(p, byte(v >> 56), byte(v >> 48), byte(v >> 40), byte(v >> 32), byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
}

pty_host_put_str :: proc(p: ^[dynamic]byte, s: string) {
	pty_host_put_u32(p, u32(len(s)))
	for i in 0..<len(s) do append(p, s[i])
}

pty_host_put_u32 :: proc(p: ^[dynamic]byte, v: u32) {
	append(p, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
}

pty_host_put_opt_str :: proc(p: ^[dynamic]byte, present: bool, s: string) {
	if present {
		append(p, 1)
		pty_host_put_str(p, s)
	} else {
		append(p, 0)
	}
}

// ---- primitive decoders (match dproto.rs get_*) -------------------------

pty_host_get_u16 :: proc(b: []byte, off: ^int) -> (u16, bool) {
	if off^ + 2 > len(b) do return 0, false
	v := u16(b[off^]) << 8 | u16(b[off^ + 1])
	off^ += 2
	return v, true
}

pty_host_get_u32 :: proc(b: []byte, off: ^int) -> (u32, bool) {
	if off^ + 4 > len(b) do return 0, false
	v := u32(b[off^]) << 24 | u32(b[off^ + 1]) << 16 | u32(b[off^ + 2]) << 8 | u32(b[off^ + 3])
	off^ += 4
	return v, true
}

pty_host_get_i32 :: proc(b: []byte, off: ^int) -> (i32, bool) {
	v, ok := pty_host_get_u32(b, off)
	return i32(v), ok
}

pty_host_get_u64 :: proc(b: []byte, off: ^int) -> (u64, bool) {
	if off^ + 8 > len(b) do return 0, false
	v: u64 = 0
	for i in 0..<8 do v = v << 8 | u64(b[off^ + i])
	off^ += 8
	return v, true
}

// pty_host_get_str returns a CLONED string (caller owns it).
pty_host_get_str :: proc(b: []byte, off: ^int) -> (string, bool) {
	length, ok := pty_host_get_u32(b, off)
	if !ok do return "", false
	n := int(length)
	if off^ + n > len(b) do return "", false
	s := strings.clone(string(b[off^ : off^ + n]))
	off^ += n
	return s, true
}

// ---- frame IO -----------------------------------------------------------

// pty_host_frame prepends the u32 BE length prefix to a payload, returning a new
// owned buffer.
pty_host_frame :: proc(payload: []byte) -> []byte {
	out := make([dynamic]byte, 0, 4 + len(payload))
	pty_host_put_u32(&out, u32(len(payload)))
	append(&out, ..payload)
	return out[:]
}

// ---- CtlMsg encoders ----------------------------------------------------

// pty_host_encode_spawn builds a framed Spawn control message. Caller owns result.
pty_host_encode_spawn :: proc(req: Pty_Host_Spawn_Request) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_SPAWN)
	pty_host_put_str(&p, req.instance)
	pty_host_put_u16(&p, u16(len(req.argv)))
	for a in req.argv do pty_host_put_str(&p, a)
	pty_host_put_opt_str(&p, req.has_cwd, req.cwd)
	pty_host_put_u16(&p, u16(len(req.env)))
	for kv in req.env {
		pty_host_put_str(&p, kv[0])
		pty_host_put_str(&p, kv[1])
	}
	pty_host_put_opt_str(&p, req.has_detect, req.detect)
	pty_host_put_u16(&p, req.rows)
	pty_host_put_u16(&p, req.cols)
	return pty_host_frame(p[:])
}

pty_host_encode_instance_only :: proc(tag: byte, instance: string) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, tag)
	pty_host_put_str(&p, instance)
	return pty_host_frame(p[:])
}

pty_host_encode_close :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_CLOSE, instance) }
pty_host_encode_restart :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_RESTART, instance) }
pty_host_encode_attach :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_ATTACH, instance) }
pty_host_encode_capture :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_CAPTURE, instance) }
pty_host_encode_detach :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_DETACH, instance) }

pty_host_encode_list :: proc() -> []byte {
	p := [?]byte{PTY_HOST_T_LIST}
	return pty_host_frame(p[:])
}

pty_host_encode_ping :: proc() -> []byte {
	p := [?]byte{PTY_HOST_T_PING}
	return pty_host_frame(p[:])
}

pty_host_encode_input :: proc(instance: string, data: []byte) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_INPUT)
	pty_host_put_str(&p, instance)
	append(&p, ..data)
	return pty_host_frame(p[:])
}

pty_host_encode_key :: proc(instance: string, key: Pty_Host_Key) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_KEY)
	pty_host_put_str(&p, instance)
	append(&p, byte(key))
	return pty_host_frame(p[:])
}

pty_host_encode_resize :: proc(instance: string, rows, cols: u16) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_RESIZE)
	pty_host_put_str(&p, instance)
	pty_host_put_u16(&p, rows)
	pty_host_put_u16(&p, cols)
	return pty_host_frame(p[:])
}

// ---- CtlReply decoder ---------------------------------------------------

// pty_host_decode_reply decodes one reply payload (tag byte + rest). On success
// the returned Pty_Host_Reply owns its heap fields (free with pty_host_reply_delete).
pty_host_decode_reply :: proc(payload: []byte) -> (Pty_Host_Reply, bool) {
	if len(payload) == 0 do return {}, false
	tag := payload[0]
	rest := payload[1:]
	off := 0
	r: Pty_Host_Reply
	switch tag {
	case PTY_HOST_T_SPAWNED:
		r.kind = .Spawned
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		pid, ok2 := pty_host_get_i32(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.pid = pid
	case PTY_HOST_T_CLOSED:
		r.kind = .Closed
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
	case PTY_HOST_T_RESTARTED:
		r.kind = .Restarted
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		pid, ok2 := pty_host_get_i32(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.pid = pid
	case PTY_HOST_T_AGENTLIST:
		r.kind = .Agent_List
		n, ok := pty_host_get_u16(rest, &off); if !ok do return {}, false
		agents := make([]Pty_Host_Agent_Info, int(n))
		for i in 0..<int(n) {
			a: Pty_Host_Agent_Info
			ai, aok := pty_host_get_str(rest, &off); if !aok { pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			prog, pok := pty_host_get_str(rest, &off); if !pok { delete(ai); pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			a.instance_id = ai; a.program = prog
			pid, _ := pty_host_get_i32(rest, &off); a.pid = pid
			if off >= len(rest) { pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			a.alive = rest[off] != 0; off += 1
			if off >= len(rest) { pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			has_code := rest[off]; off += 1
			if has_code == 1 { ec, _ := pty_host_get_i32(rest, &off); a.exit_code = ec; a.has_exit_code = true }
			a.rows, _ = pty_host_get_u16(rest, &off)
			a.cols, _ = pty_host_get_u16(rest, &off)
			a.started_at, _ = pty_host_get_u64(rest, &off)
			a.last_activity, _ = pty_host_get_u64(rest, &off)
			agents[i] = a
		}
		r.agents = agents
	case PTY_HOST_T_OUTPUT:
		r.kind = .Output
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
		r.data = make([]byte, len(rest) - off)
		copy(r.data, rest[off:])
	case PTY_HOST_T_SCREEN:
		r.kind = .Screen
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
		scr, sok := pty_host_get_screen(rest, &off); if !sok { delete(inst); return {}, false }
		r.screen = scr
	case PTY_HOST_T_EXITED:
		r.kind = .Child_Exited
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		code, ok2 := pty_host_get_i32(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.code = code
	case PTY_HOST_T_PONG:
		r.kind = .Pong
	case PTY_HOST_T_ERROR:
		r.kind = .Error
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		msg, ok2 := pty_host_get_str(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.message = msg
	case PTY_HOST_T_STARTUP_READY:
		r.kind = .Startup_Ready
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
	case PTY_HOST_T_STARTUP_BLOCKED:
		r.kind = .Startup_Blocked
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		rc, ok2 := pty_host_get_str(rest, &off); if !ok2 { delete(inst); return {}, false }
		diag, ok3 := pty_host_get_str(rest, &off); if !ok3 { delete(inst); delete(rc); return {}, false }
		r.instance = inst; r.reason_code = rc; r.message = diag
	case PTY_HOST_T_SCREEN_CHANGED:
		r.kind = .Screen_Changed
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		h, ok2 := pty_host_get_u64(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.hash = h
	case:
		return {}, false
	}
	return r, true
}

pty_host_get_screen :: proc(b: []byte, off: ^int) -> (Pty_Host_Screen, bool) {
	s: Pty_Host_Screen
	ok: bool
	s.rows, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	s.cols, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	s.cursor_row, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	s.cursor_col, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	n: u16
	n, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	lines := make([]string, int(n))
	for i in 0..<int(n) {
		line, lok := pty_host_get_str(b, off)
		if !lok {
			for j in 0..<i do delete(lines[j])
			delete(lines)
			return {}, false
		}
		lines[i] = line
	}
	s.lines = lines
	return s, true
}

pty_host_free_agents :: proc(agents: []Pty_Host_Agent_Info) {
	for a in agents {
		if a.instance_id != "" do delete(a.instance_id)
		if a.program != "" do delete(a.program)
	}
}

// pty_host_reply_delete frees an owned reply's heap fields.
pty_host_reply_delete :: proc(r: Pty_Host_Reply) {
	if r.instance != "" do delete(r.instance)
	if r.message != "" do delete(r.message)
	if r.reason_code != "" do delete(r.reason_code)
	if r.data != nil do delete(r.data)
	for l in r.screen.lines do delete(l)
	if r.screen.lines != nil do delete(r.screen.lines)
	pty_host_free_agents(r.agents)
	if r.agents != nil do delete(r.agents)
}

// ---- socket round-trip --------------------------------------------------

// pty_host_socket_path resolves the daemon's unix socket path for this bridge.
// Keyed on the bridge's local endpoint port so multiple bridges on one host do
// not share a daemon (mirrors bridge_runtime_tmux_session's per-bridge scoping).
pty_host_socket_path :: proc() -> string {
	base := strings.trim_right(bridge_config.local_endpoint_run_dir, "/")
	if base == "" do base = "/tmp/heimdall-bridge-local"
	return strings.concatenate({base, "/pty-host.sock"})
}

// pty_host_dial connects to the daemon unix socket, returning the fd or (-1,false).
pty_host_dial :: proc(socket_path: string) -> (posix.FD, bool) {
	path := strings.trim_prefix(socket_path, "unix:")
	if len(path) + 1 > len(posix.sockaddr_un{}.sun_path) do return -1, false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1, false
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

// pty_host_send_all writes every byte of buf to fd.
pty_host_send_all :: proc(fd: posix.FD, buf: []byte) -> bool {
	sent := 0
	for sent < len(buf) {
		remaining := len(buf) - sent
		n := posix.send(fd, raw_data(buf[sent:]), c.size_t(remaining), {})
		if n <= 0 do return false
		sent += int(n)
	}
	return true
}

// pty_host_read_frame reads one length-prefixed frame payload from fd. Returns
// (payload, true) or ({}, false) on EOF/error. Caller owns the payload.
pty_host_read_frame :: proc(fd: posix.FD) -> ([]byte, bool) {
	len_buf: [4]byte
	if !pty_host_read_exact(fd, len_buf[:]) do return {}, false
	length := u32(len_buf[0]) << 24 | u32(len_buf[1]) << 16 | u32(len_buf[2]) << 8 | u32(len_buf[3])
	if int(length) > PTY_HOST_MAX_FRAME_BYTES do return {}, false
	payload := make([]byte, int(length))
	if int(length) > 0 && !pty_host_read_exact(fd, payload) {
		delete(payload)
		return {}, false
	}
	return payload, true
}

pty_host_read_exact :: proc(fd: posix.FD, buf: []byte) -> bool {
	got := 0
	for got < len(buf) {
		remaining := len(buf) - got
		n := posix.recv(fd, raw_data(buf[got:]), c.size_t(remaining), {})
		if n <= 0 do return false
		got += int(n)
	}
	return true
}

// pty_host_request sends one framed message and reads exactly one reply frame.
// The control ops (Spawn/Close/Restart/List/Ping) are request/response; this is
// the blocking helper for them. Caller owns the returned reply.
pty_host_request :: proc(socket_path: string, request: []byte) -> (Pty_Host_Reply, bool) {
	fd, ok := pty_host_dial(socket_path)
	if !ok do return {}, false
	defer posix.close(fd)
	if !pty_host_send_all(fd, request) do return {}, false
	payload, pok := pty_host_read_frame(fd)
	if !pok do return {}, false
	defer delete(payload)
	return pty_host_decode_reply(payload)
}
