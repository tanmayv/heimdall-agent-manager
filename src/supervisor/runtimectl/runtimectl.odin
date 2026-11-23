// Package runtimectl: the supervisor's side of the agent gate (docs/specs/
// bridge-supervisor-engine.md §12, §12.2; T14). It talks to the running runtime
// (ham-bridge) over its local endpoint and implements the engine's gate hooks:
//
//   engine.Host.gate_count       supervisor.gate.count
//   engine.Host.close_admission  supervisor.admission.close
//   engine.Host.open_admission   supervisor.admission.open
//   engine.Host.end_sessions     supervisor.sessions.end  (captures every PTY session's
//                                (pid, start_time) before the runtime signals it)
//
// and `stop_children`, which T13b's Host.stop_children calls with the processes the
// supervisor recorded itself (runtime, PTY host): it adds the captured sessions, gives
// them the §12 grace to end, then procs.stop()s every target. PTY sessions call setsid, so
// the runtime's and the PTY host's process groups do not contain them; each session is its
// own group target.
//
// The runtime writes the endpoint and a control token to
// <run_dir>/supervisor-control.json (src/bridge/supervisor_gate.odin). The file is
// re-read for every request: a restarted runtime has a new token. Every request is one
// JSONL line on a fresh connection with a deadline, so a hung runtime costs the
// supervisor's tick at most `timeout_ms` and reads as "not counted" (busy, fail closed).
//
// Usage (T13b):
//
//   ctl: runtimectl.Client
//   runtimectl.init(&ctl, control_path)
//   runtimectl.install(&host, &ctl)            // gate hooks + gate_user
//   ... Host.stop_children = { runtimectl.stop_children(&ctl, recorded[:]) }
//   runtimectl.destroy(&ctl)
package runtimectl

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import local_socket "../../lib/local_socket"
import "../engine"
import "../procs"

DEFAULT_TIMEOUT_MS :: 2_000
MAX_RESPONSE_BYTES :: 1 << 20

Client :: struct {
	control_path: string, // owned
	timeout_ms:   int,
	// PTY sessions captured by end_sessions, stopped by stop_children. Heap-owned.
	sessions:     [dynamic]procs.Target,
}

init :: proc(c: ^Client, control_path: string, timeout_ms := DEFAULT_TIMEOUT_MS) {
	c.control_path = strings.clone(control_path)
	c.timeout_ms = timeout_ms
	c.sessions = make([dynamic]procs.Target)
}

destroy :: proc(c: ^Client) {
	delete(c.control_path)
	delete(c.sessions)
	c^ = {}
}

// install points the engine's gate hooks at this client.
install :: proc(h: ^engine.Host, c: ^Client) {
	h.gate_user = c
	h.gate_count = proc(u: rawptr) -> engine.Busy {return count((^Client)(u))}
	h.close_admission = proc(u: rawptr) -> bool {return close_admission((^Client)(u))}
	h.open_admission = proc(u: rawptr) {_ = open_admission((^Client)(u))}
	h.end_sessions = proc(u: rawptr) {_, _ = end_sessions((^Client)(u))}
}

// count: counted = false when the runtime is unreachable or answers with an error.
count :: proc(c: ^Client) -> (b: engine.Busy) {
	data, ok := request(c, "supervisor.gate.count")
	if !ok do return
	counted, _ := data["counted"].(json.Boolean)
	if !counted do return
	b.pty_sessions = get_int(data, "pty_sessions") or_else -1
	b.launches = get_int(data, "launches") or_else -1
	b.helpers = get_int(data, "helpers") or_else -1
	if b.pty_sessions < 0 || b.launches < 0 || b.helpers < 0 do return engine.Busy{}
	b.counted = true
	return
}

close_admission :: proc(c: ^Client) -> bool {
	data, ok := request(c, "supervisor.admission.close")
	return ok && get_string(data, "admission") == "closed"
}

open_admission :: proc(c: ^Client) -> bool {
	data, ok := request(c, "supervisor.admission.open")
	return ok && get_string(data, "admission") == "open"
}

// end_sessions asks the runtime to end every PTY session and keeps the identities it
// reports for stop_children. ok = false: the runtime did not answer (stop_children then
// stops only what the caller recorded; the PTY host's own stop ends its sessions).
end_sessions :: proc(c: ^Client) -> (signalled: int, ok: bool) {
	data: json.Object
	data, ok = request(c, "supervisor.sessions.end")
	if !ok do return
	signalled = get_int(data, "signalled") or_else 0
	arr, _ := data["targets"].(json.Array)
	for v in arr {
		o, is_obj := v.(json.Object)
		if !is_obj do continue
		pid, pid_ok := get_int(o, "pid")
		st, st_ok := get_u64(o, "start_time")
		if !pid_ok || !st_ok || pid <= 0 do continue
		add_target(&c.sessions, procs.Target{id = procs.Id{pid, st}, group = true})
	}
	return
}

// stop_children: §12 stopping for the runtime started from one tree. `recorded` are the
// supervisor's own children (runtime, PTY host, each leading its group). The PTY sessions
// captured by end_sessions get the grace to end on their own (they were asked to); then
// every target still running is stopped by procs.stop (SIGTERM -> term_grace -> SIGKILL;
// Windows TerminateProcess) and waited for up to wait_ms. false = a survivor (stop_timeout).
stop_children :: proc(
	c: ^Client,
	recorded: []procs.Target,
	grace_ms := procs.DEFAULT_GRACE_MS,
	term_grace_ms := 2_000,
	wait_ms := procs.DEFAULT_WAIT_MS,
) -> bool {
	all := make([dynamic]procs.Target, 0, len(recorded) + len(c.sessions), context.temp_allocator)
	for t in c.sessions do add_target(&all, t)
	if len(all) > 0 do procs.wait_all(all[:], grace_ms)
	for t in recorded do add_target(&all, t)
	r := procs.stop(all[:], term_grace_ms, wait_ms)
	clear(&c.sessions)
	return r.survivors == 0
}

@(private)
add_target :: proc(list: ^[dynamic]procs.Target, t: procs.Target) {
	for x in list do if x.id == t.id do return
	append(list, t)
}

// ---- control file ----

Control :: struct {
	endpoint: string,
	token:    string,
}

// read_control parses <run_dir>/supervisor-control.json strictly.
read_control :: proc(path: string, allocator := context.temp_allocator) -> (ctl: Control, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil do return
	v, perr := json.parse(data, json.Specification.JSON, true, allocator)
	if perr != nil do return
	o, is_obj := v.(json.Object)
	if !is_obj do return
	if (get_int(o, "v") or_else 0) != 1 do return
	ctl.endpoint = get_string(o, "endpoint")
	ctl.token = get_string(o, "token")
	return ctl, ctl.endpoint != "" && ctl.token != ""
}

// ---- transport ----

// request sends one supervisor.* request and returns the response's `data` (temp-allocated).
request :: proc(c: ^Client, method: string) -> (data: json.Object, ok: bool) {
	ctl, cok := read_control(c.control_path)
	if !cok do return
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, `{"v":1,"id":"sup","token":`)
	json_string(&line, ctl.token)
	strings.write_string(&line, `,"method":`)
	json_string(&line, method)
	strings.write_string(&line, `,"params":{}}`)
	strings.write_byte(&line, '\n')
	resp, rok := roundtrip(ctl.endpoint, transmute([]byte)strings.to_string(line), c.timeout_ms if c.timeout_ms > 0 else DEFAULT_TIMEOUT_MS)
	if !rok do return
	v, perr := json.parse(resp, json.Specification.JSON, true, context.temp_allocator)
	if perr != nil do return
	o, is_obj := v.(json.Object)
	if !is_obj do return
	if okv, _ := o["ok"].(json.Boolean); !okv do return
	data, ok = o["data"].(json.Object)
	return
}

// roundtrip: dial `unix:<path>` or `tcp:<host>:<port>`, send `msg`, read one line.
@(private)
roundtrip :: proc(endpoint: string, msg: []byte, timeout_ms: int) -> (line: []byte, ok: bool) {
	s: local_socket.Socket
	is_tcp := false
	switch {
	case strings.has_prefix(endpoint, "unix:"):
		s, ok = local_socket.dial(endpoint[5:])
		if !ok do return
	case strings.has_prefix(endpoint, "tcp:"):
		ep, eok := net.parse_endpoint(endpoint[4:])
		if !eok do return nil, false
		sock, err := net.dial_tcp(ep)
		if err != nil do return nil, false
		s = local_socket.Socket(sock)
		is_tcp = true
	case:
		return nil, false
	}
	defer {
		if is_tcp do net.close(net.TCP_Socket(s))
		else do local_socket.close(s)
	}
	sent := 0
	for sent < len(msg) {
		n := local_socket.send(s, msg[sent:])
		if n <= 0 do return nil, false
		sent += n
	}
	deadline := time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	buf := make([dynamic]byte, 0, 4096, context.temp_allocator)
	chunk: [4096]byte
	for {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return nil, false
		ready, pok := local_socket.poll_readable(s, max(int(left / time.Millisecond), 1))
		if !pok do return nil, false
		if !ready do continue
		n, rerr := local_socket.recv_ex(s, chunk[:])
		if rerr == .Would_Block || rerr == .Interrupted do continue
		if rerr != .None || n <= 0 do return nil, false
		append(&buf, ..chunk[:n])
		if i := index_byte(buf[:], '\n'); i >= 0 do return buf[:i], true
		if len(buf) > MAX_RESPONSE_BYTES do return nil, false
	}
}

@(private)
index_byte :: proc(b: []byte, c: byte) -> int {
	for x, i in b do if x == c do return i
	return -1
}

// ---- JSON helpers ----

@(private)
get_int :: proc(o: json.Object, key: string) -> (int, bool) {
	#partial switch v in o[key] {
	case json.Integer:
		return int(v), true
	}
	return 0, false
}

@(private)
get_u64 :: proc(o: json.Object, key: string) -> (u64, bool) {
	#partial switch v in o[key] {
	case json.Integer:
		if v >= 0 do return u64(v), true
	case json.Float:
		// start_time above 2^63 (Windows FILETIME never is; kept for safety) comes as text.
		return 0, false
	case json.String:
		return strconv.parse_u64(v)
	}
	return 0, false
}

@(private)
get_string :: proc(o: json.Object, key: string) -> string {
	s, _ := o[key].(json.String)
	return s
}

@(private)
json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case 0 ..< 0x20:
			fmt.sbprintf(b, `\u%04x`, r)
		case:
			strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}
