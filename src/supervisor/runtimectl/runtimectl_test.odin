package runtimectl

// The adapter against a fake runtime endpoint (unix and tcp), and stop_children against
// real processes (Linux, macOS, Windows).

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import local_socket "../../lib/local_socket"
import "../engine"
import "../procs"

Fake_Mode :: enum {
	Answer,
	Refuse, // ok:false (bad token)
	Silent, // never answers
}

Fake :: struct {
	mode:      Fake_Mode,
	conns:     int, // connections to serve before the thread exits
	token:     string,
	// sessions.end reply targets
	end_json:  string,
	mu:        sync.Mutex,
	methods:   [dynamic]string,
	tokens_ok: int,
	release:   sync.Sema, // Silent: closes the connection when posted
	unix:      local_socket.Socket,
	tcp:       net.TCP_Socket,
	is_tcp:    bool,
}

@(private = "file")
fake_reply :: proc(f: ^Fake, line: string) -> string {
	method := ""
	for m in ([]string{"supervisor.gate.count", "supervisor.admission.close", "supervisor.admission.open", "supervisor.sessions.end"}) {
		if strings.contains(line, fmt.tprintf(`"method":"%s"`, m)) do method = m
	}
	sync.mutex_lock(&f.mu)
	append(&f.methods, method) // a constant: no per-thread allocation to free
	if strings.contains(line, fmt.tprintf(`"token":"%s"`, f.token)) do f.tokens_ok += 1
	sync.mutex_unlock(&f.mu)
	if f.mode == .Refuse do return `{"v":1,"id":"sup","ok":false,"error":{"code":"unauthenticated","message":"x"}}` + "\n"
	switch method {
	case "supervisor.gate.count":
		return `{"v":1,"id":"sup","ok":true,"data":{"counted":true,"admission":"open","pty_sessions":2,"launches":1,"helpers":3}}` + "\n"
	case "supervisor.admission.close":
		return `{"v":1,"id":"sup","ok":true,"data":{"admission":"closed","launches":0}}` + "\n"
	case "supervisor.admission.open":
		return `{"v":1,"id":"sup","ok":true,"data":{"admission":"open"}}` + "\n"
	case "supervisor.sessions.end":
		return fmt.tprintf("{{\"v\":1,\"id\":\"sup\",\"ok\":true,\"data\":%s}}\n", f.end_json)
	}
	return `{"v":1,"id":"sup","ok":false,"error":{"code":"forbidden","message":"x"}}` + "\n"
}

@(private = "file")
fake_serve :: proc(f: ^Fake) {
	for _ in 0 ..< f.conns {
		c: local_socket.Socket
		if f.is_tcp {
			s, _, err := net.accept_tcp(f.tcp)
			if err != nil do return
			c = local_socket.Socket(s)
		} else {
			ok: bool
			c, ok = local_socket.accept(f.unix)
			if !ok do return
		}
		buf: [4096]byte
		got := make([dynamic]byte, context.temp_allocator)
		for !strings.contains(string(got[:]), "\n") {
			n := local_socket.recv(c, buf[:])
			if n <= 0 do break
			append(&got, ..buf[:n])
		}
		if f.mode == .Silent {
			sync.sema_wait(&f.release)
		} else {
			resp := fake_reply(f, string(got[:]))
			_ = local_socket.send(c, transmute([]byte)resp)
		}
		if f.is_tcp do net.close(net.TCP_Socket(c))
		else do local_socket.close(c)
	}
}

@(private = "file")
test_dir :: proc(t: ^testing.T, prefix: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, fmt.tprintf("%s-*", prefix), context.temp_allocator)
	testing.expect(t, err == nil, "make_directory_temp")
	return dir
}

// fake_start listens (unix socket in dir, or loopback tcp), writes the control file and
// starts the server thread.
@(private = "file")
fake_start :: proc(t: ^testing.T, f: ^Fake, dir: string, tcp := false) -> (control: string, th: ^thread.Thread) {
	endpoint := ""
	if tcp {
		sock, err := net.listen_tcp({net.IP4_Loopback, 0})
		testing.expect(t, err == nil, "listen tcp")
		ep, _ := net.bound_endpoint(sock)
		f.tcp = sock
		f.is_tcp = true
		endpoint = fmt.tprintf("tcp:127.0.0.1:%d", ep.port)
	} else {
		path := strings.concatenate({dir, "/r.sock"}, context.temp_allocator)
		s, ok := local_socket.listen(path)
		testing.expect(t, ok, "listen unix")
		f.unix = s
		endpoint = strings.concatenate({"unix:", path}, context.temp_allocator)
	}
	if f.token == "" do f.token = "tok123"
	control = strings.concatenate({dir, "/supervisor-control.json"}, context.temp_allocator)
	escaped, _ := strings.replace_all(endpoint, `\`, `\\`, context.temp_allocator)
	body := fmt.tprintf(`{{"v":1,"endpoint":"%s","token":"%s","pid":1}}`, escaped, f.token)
	testing.expect(t, os.write_entire_file(control, transmute([]byte)body) == nil, "write control file")
	// Preallocated: the server thread appends without allocating.
	f.methods = make([dynamic]string, 0, 16)
	th = thread.create_and_start_with_poly_data(f, fake_serve)
	return
}

@(private = "file")
fake_stop :: proc(f: ^Fake, th: ^thread.Thread) {
	thread.join(th)
	thread.destroy(th)
	if f.is_tcp do net.close(f.tcp)
	else do local_socket.close(f.unix)
}

@(test)
test_gate_hooks_over_unix_socket :: proc(t: ^testing.T) {
	dir := test_dir(t, "t14-rctl")
	defer os.remove_all(dir)
	f := Fake{conns = 3, end_json = `{"signalled":0,"targets":[]}`}
	control, th := fake_start(t, &f, dir)
	c: Client
	init(&c, control)
	defer destroy(&c)
	host: engine.Host
	install(&host, &c)
	b := host.gate_count(host.gate_user)
	testing.expect(t, b.counted, "counted")
	testing.expect_value(t, b, engine.Busy{counted = true, pty_sessions = 2, launches = 1, helpers = 3})
	testing.expect(t, host.close_admission(host.gate_user), "close confirmed")
	host.open_admission(host.gate_user)
	fake_stop(&f, th)
	defer delete(f.methods)
	testing.expect_value(t, f.tokens_ok, 3)
	testing.expect_value(t, len(f.methods), 3)
	if len(f.methods) == 3 {
		testing.expect_value(t, f.methods[0], "supervisor.gate.count")
		testing.expect_value(t, f.methods[1], "supervisor.admission.close")
		testing.expect_value(t, f.methods[2], "supervisor.admission.open")
	}
}

@(test)
test_gate_count_over_tcp :: proc(t: ^testing.T) {
	dir := test_dir(t, "t14-rctl-tcp")
	defer os.remove_all(dir)
	f := Fake{conns = 1}
	control, th := fake_start(t, &f, dir, tcp = true)
	c: Client
	init(&c, control)
	defer destroy(&c)
	b := count(&c)
	fake_stop(&f, th)
	delete(f.methods)
	testing.expect_value(t, b, engine.Busy{counted = true, pty_sessions = 2, launches = 1, helpers = 3})
	testing.expect_value(t, f.tokens_ok, 1)
}

// Fail closed: no control file, a refused token, a runtime that never answers.
@(test)
test_gate_count_fails_closed :: proc(t: ^testing.T) {
	dir := test_dir(t, "t14-rctl-closed")
	defer os.remove_all(dir)
	c: Client
	init(&c, strings.concatenate({dir, "/missing.json"}, context.temp_allocator), timeout_ms = 300)
	testing.expect(t, !count(&c).counted, "no control file")
	testing.expect(t, !close_admission(&c))
	destroy(&c)

	f := Fake{conns = 1, mode = .Refuse}
	control, th := fake_start(t, &f, dir)
	init(&c, control, timeout_ms = 300)
	testing.expect(t, !count(&c).counted, "refused")
	fake_stop(&f, th)
	delete(f.methods)
	destroy(&c)

	dir2 := test_dir(t, "t14-rctl-silent")
	defer os.remove_all(dir2)
	g := Fake{conns = 1, mode = .Silent}
	control2, th2 := fake_start(t, &g, dir2)
	init(&c, control2, timeout_ms = 300)
	start := time.tick_now()
	b := count(&c)
	took := time.tick_since(start)
	sync.sema_post(&g.release)
	fake_stop(&g, th2)
	delete(g.methods)
	destroy(&c)
	testing.expect(t, !b.counted, "silent runtime: not counted")
	testing.expectf(t, took < 3 * time.Second, "bounded by the timeout (%v)", took)
}

@(test)
test_read_control_is_strict :: proc(t: ^testing.T) {
	dir := test_dir(t, "t14-rctl-strict")
	defer os.remove_all(dir)
	p := strings.concatenate({dir, "/c.json"}, context.temp_allocator)
	cases := []string {
		`{"v":2,"endpoint":"unix:/x","token":"t"}`,
		`{"v":1,"endpoint":"","token":"t"}`,
		`{"v":1,"endpoint":"unix:/x"}`,
	}
	for body in cases {
		_ = os.write_entire_file(p, transmute([]byte)body)
		_, ok := read_control(p)
		testing.expectf(t, !ok, "rejected: %s", body)
	}
	_ = os.write_entire_file(p, transmute([]byte)string(`{"v":1,"endpoint":"unix:/x","token":"t","pid":3}`))
	ctl, ok := read_control(p)
	testing.expect(t, ok && ctl.endpoint == "unix:/x" && ctl.token == "t")
}

// sessions.end reports a PTY session (a real process leading its own group, like a setsid
// agent); stop_children stops it with the recorded targets and leaves another instance's
// session running.
@(test)
test_end_sessions_then_stop_children :: proc(t: ^testing.T) {
	dir := test_dir(t, "t14-rctl-stop")
	defer os.remove_all(dir)
	mine := spawn_session(t)
	other := spawn_session(t)
	defer cleanup_session(&other)
	defer cleanup_session(&mine)
	if !mine.ok || !other.ok do return
	f := Fake{conns = 1, end_json = fmt.tprintf(`{{"signalled":1,"targets":[{{"pid":%d,"start_time":%d}}]}}`, mine.id.pid, mine.id.start_time)}
	control, th := fake_start(t, &f, dir)
	c: Client
	init(&c, control)
	defer destroy(&c)
	n, ok := end_sessions(&c)
	fake_stop(&f, th)
	delete(f.methods)
	testing.expect(t, ok && n == 1, "sessions.end answered")
	testing.expect_value(t, len(c.sessions), 1)
	// The fake runtime did not really signal it: the grace passes, then procs.stop ends it.
	testing.expect(t, stop_children(&c, nil, grace_ms = 200, term_grace_ms = 500, wait_ms = 10_000), "stopped")
	testing.expect(t, !procs.alive(mine.id), "this instance's session is gone")
	testing.expect(t, procs.alive(other.id), "the other instance's session still runs")
	testing.expect_value(t, len(c.sessions), 0)
}
