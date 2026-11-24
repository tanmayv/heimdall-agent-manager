package testkit

// A minimal fake GitHub over HTTP/1.1 on loopback, for the e2e suite: the real
// ham-supervisor (a HEIMDALL_SUPERVISOR_TEST build) talks to it through libcurl with
// HEIMDALL_SUPERVISOR_TEST_ORIGIN=http://127.0.0.1:<port>, which maps
//   https://api.github.com/<p>  -> /api/<p>
//   https://github.com/<p>      -> /gh/<p>
// Routes: /api/repos/<repo>/releases/latest, /api/repos/<repo>/releases?per_page=N[&page=P]
// (newest first, GitHub's order, with a Link rel="next" header while more pages exist),
// /gh/<repo>/releases/download/<tag>/<asset>. One connection at a time, Connection: close.
//
// Failure injection (T15): `mode` makes it refuse to answer (.Offline: the connection is
// closed without a response) or answer every request 503 (.Unavailable); releases can be
// metadata-only stubs (no bytes served) and a published asset can be replaced in place.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../fetch"
import "../resolver"

Mode :: enum {
	Online,
	Offline, // accept, then close without a response (connection reset / empty reply)
	Unavailable, // HTTP 503 for every request
}

Fake_GitHub :: struct {
	mu:        sync.Mutex,
	mode:      Mode,
	missing_download: string, // tag whose bundle download answers 404 (list unchanged)
	pages:     int, // release-list pages served (page >= 2 counted in pages_2plus)
	pages_2plus: int,
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
	delete(g.missing_download)
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

// github_publish_stub lists a prerelease whose assets exist in the API (this target's
// bundle, manifest, signature) but whose bytes are never served: filler for the >100
// releases test. The resolver must not need them.
github_publish_stub :: proc(g: ^Fake_GitHub, tag: string) {
	r: Release
	r.tag = strings.clone(tag)
	r.version = strings.clone(tag[1:])
	r.asset = resolver.bundle_asset_name(fetch.TARGET, tag)
	r.bundle = make([]byte, 1024)
	r.manifest = strings.clone("{}")
	r.signature = strings.clone("x")
	r.sha256 = strings.clone("")
	r.tree = strings.clone("")
	r.stub = true
	github_publish(g, r, false)
}

// github_replace_bundle swaps the bytes of a published release's bundle asset and leaves
// its manifest and signature as they were (a mutated asset after publish).
github_replace_bundle :: proc(g: ^Fake_GitHub, tag: string, data: []byte) -> bool {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	for &r in g.releases {
		if r.tag != tag do continue
		delete(r.bundle)
		r.bundle = data
		return true
	}
	return false
}

// github_republish replaces the release with the same tag by `nr` (a re-built release of
// the same version: new digest, new correctly signed manifest), taking ownership of `nr`.
github_republish :: proc(g: ^Fake_GitHub, nr: Release) -> bool {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	for &r in g.releases {
		if r.tag != nr.tag do continue
		release_destroy(&r)
		r = nr
		return true
	}
	return false
}

// github_set_missing_download: the bundle of `tag` answers 404 while the API still lists
// it ("" = none).
github_set_missing_download :: proc(g: ^Fake_GitHub, tag: string) {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	delete(g.missing_download)
	g.missing_download = strings.clone(tag)
}

github_set_mode :: proc(g: ^Fake_GitHub, m: Mode) {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	g.mode = m
}

// github_requests: requests answered or refused so far.
github_requests :: proc(g: ^Fake_GitHub) -> int {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	return g.requests
}

github_pages_2plus :: proc(g: ^Fake_GitHub) -> int {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	return g.pages_2plus
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
	mode := g.mode
	status, body, ctype, link := 503, transmute([]byte)string(`{"message":"Service Unavailable"}`), "application/json", ""
	if mode == .Online do status, body, ctype, link = route(g, path)
	sync.mutex_unlock(&g.mu)
	if mode == .Offline do return

	extra := fmt.tprintf("Link: %s\r\n", link) if link != "" else ""
	hdr := fmt.tprintf("HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\n%sConnection: close\r\n\r\n", status, ctype, len(body), extra)
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
route :: proc(g: ^Fake_GitHub, path: string) -> (status: int, body: []byte, ctype: string, link: string) {
	api := strings.concatenate({"/api/repos/", fetch.REPO, "/releases"}, context.temp_allocator)
	dl := strings.concatenate({"/gh/", fetch.REPO, "/releases/download/"}, context.temp_allocator)
	ctype = "application/json"
	switch {
	case path == strings.concatenate({api, "/latest"}, context.temp_allocator):
		if g.latest < 0 do return 404, transmute([]byte)string(`{"message":"Not Found"}`), ctype, ""
		return 200, transmute([]byte)release_api_json_temp(g.releases[g.latest], false), ctype, ""
	case strings.has_prefix(path, api) && strings.contains(path, "per_page"):
		per_page := query_int(path, "per_page", 30)
		page := query_int(path, "page", 1)
		if per_page < 1 do per_page = 30
		if page < 1 do page = 1
		g.pages += 1
		if page >= 2 do g.pages_2plus += 1
		// Newest first, like GitHub.
		n := len(g.releases)
		first := (page - 1) * per_page
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for k := first; k < min(first + per_page, n); k += 1 {
			i := n - 1 - k
			if k > first do strings.write_byte(&b, ',')
			strings.write_string(&b, release_api_json_temp(g.releases[i], i != g.latest))
		}
		strings.write_byte(&b, ']')
		if first + per_page < n {
			link = fmt.tprintf(`<https://api.github.com/repos/%s/releases?per_page=%d&page=%d>; rel="next", <https://api.github.com/repos/%s/releases?per_page=%d&page=%d>; rel="last"`,
				fetch.REPO, per_page, page + 1, fetch.REPO, per_page, (n + per_page - 1) / per_page)
		}
		return 200, transmute([]byte)strings.to_string(b), ctype, link
	case strings.has_prefix(path, dl):
		rest := path[len(dl):]
		slash := strings.index_byte(rest, '/')
		if slash < 0 do break
		tag, name := rest[:slash], rest[slash + 1:]
		for r in g.releases {
			if r.tag != tag || r.stub do continue
			ctype = "application/octet-stream"
			switch name {
			case r.asset:
				if r.tag == g.missing_download do break
				return 200, r.bundle, ctype, ""
			case fetch.MANIFEST_ASSET:
				return 200, transmute([]byte)r.manifest, ctype, ""
			case fetch.SIGNATURE_ASSET:
				return 200, transmute([]byte)r.signature, ctype, ""
			}
		}
	}
	return 404, transmute([]byte)string(`{"message":"Not Found"}`), "application/json", ""
}

// query_int: the integer value of `name` in the query string of `path` (def if absent).
@(private)
query_int :: proc(path, name: string, def: int) -> int {
	q := strings.index_byte(path, '?')
	if q < 0 do return def
	rest := path[q + 1:]
	for kv in strings.split_iterator(&rest, "&") {
		eq := strings.index_byte(kv, '=')
		if eq < 0 || kv[:eq] != name do continue
		n := 0
		for c in transmute([]byte)kv[eq + 1:] {
			if c < '0' || c > '9' do return def
			n = n * 10 + int(c - '0')
		}
		return n
	}
	return def
}

@(private)
release_api_json_temp :: proc(r: Release, prerelease: bool) -> string {
	s := release_api_json(r, prerelease)
	t := strings.clone(s, context.temp_allocator)
	delete(s)
	return t
}
