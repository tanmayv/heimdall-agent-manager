package testkit

// A minimal fake GitHub over HTTP/1.1 on loopback, for the e2e suite: the real
// ham-supervisor (a HEIMDALL_SUPERVISOR_TEST build) talks to it through libcurl with
// HEIMDALL_SUPERVISOR_TEST_ORIGIN=http://127.0.0.1:<port>, which maps
//   https://api.github.com/<p>  -> /api/<p>
//   https://github.com/<p>      -> /gh/<p>
// Routes: /api/repos/<repo>/releases/latest, /api/repos/<repo>/releases?per_page=100,
// /gh/<repo>/releases/download/<tag>/<asset>. One connection at a time, Connection: close.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../fetch"

Fake_GitHub :: struct {
	mu:        sync.Mutex,
	releases:  [dynamic]Release, // owned
	latest:    int, // index of the stable release, -1 = none
	listener:  net.TCP_Socket,
	port:      int,
	stop:      bool,
	th:        ^thread.Thread,
	requests:  int,
}

github_start :: proc(g: ^Fake_GitHub) -> bool {
	g.latest = -1
	g.releases = make([dynamic]Release)
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil do return false
	ep, eerr := net.bound_endpoint(sock)
	if eerr != nil do return false
	g.listener = sock
	g.port = ep.port
	net.set_blocking(sock, false)
	g.th = thread.create_and_start_with_data(g, proc(data: rawptr) {
		g := (^Fake_GitHub)(data)
		for !sync.atomic_load(&g.stop) {
			c, _, aerr := net.accept_tcp(g.listener)
			if aerr != nil {
				time.sleep(5 * time.Millisecond)
				continue
			}
			net.set_blocking(c, true)
			serve_one(g, c)
			net.close(c)
			free_all(context.temp_allocator)
		}
	})
	return true
}

github_stop :: proc(g: ^Fake_GitHub) {
	sync.atomic_store(&g.stop, true)
	if g.th != nil {
		thread.join(g.th)
		thread.destroy(g.th)
	}
	net.close(g.listener)
	for &r in g.releases do release_destroy(&r)
	delete(g.releases)
}

github_origin :: proc(g: ^Fake_GitHub, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("http://127.0.0.1:%d", g.port, allocator = allocator)
}

// github_publish adds a release (taking ownership); stable = it becomes /releases/latest.
github_publish :: proc(g: ^Fake_GitHub, r: Release, stable := true) {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	append(&g.releases, r)
	if stable do g.latest = len(g.releases) - 1
}

@(private)
serve_one :: proc(g: ^Fake_GitHub, c: net.TCP_Socket) {
	buf := make([dynamic]byte, 0, 4096, context.temp_allocator)
	chunk: [4096]byte
	deadline := time.tick_now()
	for {
		n, err := net.recv_tcp(c, chunk[:])
		if err != nil || n <= 0 do return
		append(&buf, ..chunk[:n])
		if strings.contains(string(buf[:]), "\r\n\r\n") do break
		if len(buf) > 64 * 1024 || time.tick_since(deadline) > 10 * time.Second do return
	}
	head := string(buf[:])
	line_end := strings.index(head, "\r\n")
	parts := strings.split(head[:line_end], " ", context.temp_allocator)
	if len(parts) < 2 do return
	path := parts[1]

	sync.mutex_lock(&g.mu)
	g.requests += 1
	status, body, ctype := route(g, path)
	sync.mutex_unlock(&g.mu)

	hdr := fmt.tprintf("HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", status, ctype, len(body))
	send_all(c, transmute([]byte)hdr)
	send_all(c, body)
}

@(private)
send_all :: proc(c: net.TCP_Socket, data: []byte) {
	rest := data
	for len(rest) > 0 {
		n, err := net.send_tcp(c, rest)
		if err != nil || n <= 0 do return
		rest = rest[n:]
	}
}

@(private)
route :: proc(g: ^Fake_GitHub, path: string) -> (status: int, body: []byte, ctype: string) {
	api := strings.concatenate({"/api/repos/", fetch.REPO, "/releases"}, context.temp_allocator)
	dl := strings.concatenate({"/gh/", fetch.REPO, "/releases/download/"}, context.temp_allocator)
	ctype = "application/json"
	switch {
	case path == strings.concatenate({api, "/latest"}, context.temp_allocator):
		if g.latest < 0 do return 404, transmute([]byte)string(`{"message":"Not Found"}`), ctype
		return 200, transmute([]byte)release_api_json_temp(g.releases[g.latest], false), ctype
	case strings.has_prefix(path, api) && strings.contains(path, "per_page"):
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for r, i in g.releases {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, release_api_json_temp(r, i != g.latest))
		}
		strings.write_byte(&b, ']')
		return 200, transmute([]byte)strings.to_string(b), ctype
	case strings.has_prefix(path, dl):
		rest := path[len(dl):]
		slash := strings.index_byte(rest, '/')
		if slash < 0 do break
		tag, name := rest[:slash], rest[slash + 1:]
		for r in g.releases {
			if r.tag != tag do continue
			ctype = "application/octet-stream"
			switch name {
			case r.asset:
				return 200, r.bundle, ctype
			case fetch.MANIFEST_ASSET:
				return 200, transmute([]byte)r.manifest, ctype
			case fetch.SIGNATURE_ASSET:
				return 200, transmute([]byte)r.signature, ctype
			}
		}
	}
	return 404, transmute([]byte)string(`{"message":"Not Found"}`), "application/json"
}

@(private)
release_api_json_temp :: proc(r: Release, prerelease: bool) -> string {
	s := release_api_json(r, prerelease)
	t := strings.clone(s, context.temp_allocator)
	delete(s)
	return t
}
