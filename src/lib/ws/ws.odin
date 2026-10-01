package ws

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

WS_KEY :: "dGhlIHNhbXBsZSBub25jZQ=="

Connection :: struct {
	socket: net.TCP_Socket,
	secure: bool,
	process: os.Process,
	stdin_w: ^os.File,
	stdout_r: ^os.File,
	connected: bool,
	pending_texts: [dynamic]string,
	pending_bytes: [dynamic]byte,
	fragmented:    [dynamic]byte,
	fragmenting:   bool,

	// REQ-SHELL-32: serialises WRITES on this connection. It lives here, with the
	// socket it protects, rather than at a caller, because caller-side discipline is
	// exactly what failed: the bridge added a send mutex inside bridge_hub_send
	// (src/bridge/main.odin) for its background PTY stream threads, but the
	// hub-runtime loop thread kept calling send_text directly
	// (hub_runtime_client.odin:252/281/3391/3412). A lock only one party takes
	// serialises nothing, so a loop-thread heartbeat could land its bytes inside a
	// stream worker's half-written frame and desync the peer's WS reader.
	//
	// Guarding the write here cannot be bypassed by a future caller. Note the mutex
	// is zero-valued and Connection is returned BY VALUE from connect() — copying an
	// unlocked mutex is fine; do not copy a Connection once writers are running.
	send_mu: sync.Mutex,
}

connect :: proc(ws_url: string) -> (Connection, bool) {
	return connect_with_bearer(ws_url, "")
}

connect_with_bearer :: proc(ws_url, bearer_token: string) -> (Connection, bool) {
	host, port, path, secure, ok := parse_ws_url(ws_url)
	if !ok do return {}, false
	if secure do return connect_tls_with_bearer(host, port, path, bearer_token)

	socket, err := net.dial_tcp_from_hostname_with_port_override(host, int(port))
	if err != nil do return {}, false

	auth_header := ""
	if strings.trim_space(bearer_token) != "" {
		auth_header = fmt.tprintf("Authorization: Bearer %s\r\n", bearer_token)
	}
	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n",
		path,
		host,
		port,
		WS_KEY,
		auth_header,
	)
	_, send_err := net.send_tcp(socket, transmute([]byte)request)
	if send_err != nil {
		net.close(socket)
		return {}, false
	}

	buf: [4096]byte
	n, recv_err := net.recv_tcp(socket, buf[:])
	if recv_err != nil || n <= 0 {
		net.close(socket)
		return {}, false
	}

	response := string(buf[:n])
	if !(strings.has_prefix(response, "HTTP/1.1 101") || strings.has_prefix(response, "HTTP/1.0 101")) {
		net.close(socket)
		return {}, false
	}

	pending_bytes := make([dynamic]byte)
	if header_end := strings.index(response, "\r\n\r\n"); header_end >= 0 {
		extra_start := header_end + 4
		if extra_start < n do append(&pending_bytes, ..buf[extra_start:n])
	}
	_ = net.set_blocking(socket, false)
	return Connection{socket = socket, secure = false, connected = true, pending_texts = make([dynamic]string), pending_bytes = pending_bytes}, true
}

connect_tls_with_bearer :: proc(host: string, port: u16, path, bearer_token: string) -> (Connection, bool) {
	stdin_r, stdin_w, stdin_err := os.pipe()
	if stdin_err != nil do return {}, false
	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil { _ = os.close(stdin_r); _ = os.close(stdin_w); return {}, false }
	cmd := tls_client_command(host, port)
	process, start_err := os.process_start(os.Process_Desc{command = cmd, stdin = stdin_r, stdout = stdout_w})
	_ = os.close(stdin_r)
	_ = os.close(stdout_w)
	if start_err != nil { _ = os.close(stdin_w); _ = os.close(stdout_r); return {}, false }

	auth_header := ""
	if strings.trim_space(bearer_token) != "" {
		auth_header = fmt.tprintf("Authorization: Bearer %s\r\n", bearer_token)
	}
	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n",
		path,
		host,
		port,
		WS_KEY,
		auth_header,
	)
	_, send_err := os.write(stdin_w, transmute([]byte)request)
	if send_err != nil {
		_ = os.close(stdin_w)
		_ = os.close(stdout_r)
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		return {}, false
	}

	data := make([dynamic]byte)
	defer delete(data)
	buf: [4096]byte
	deadline := time.to_unix_nanoseconds(time.now()) + i64(5 * time.Second)
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if ready, pipe_err := os.pipe_has_data(stdout_r); pipe_err != nil {
			break
		} else if ready {
			n, read_err := os.read(stdout_r, buf[:])
			if read_err != nil || n <= 0 do break
			append(&data, ..buf[:n])
			if strings.contains(string(data[:]), "\r\n\r\n") do break
		} else {
			time.sleep(10 * time.Millisecond)
		}
	}
	response := string(data[:])
	if !(strings.has_prefix(response, "HTTP/1.1 101") || strings.has_prefix(response, "HTTP/1.0 101")) {
		_ = os.close(stdin_w)
		_ = os.close(stdout_r)
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		return {}, false
	}
	pending_bytes := make([dynamic]byte)
	if header_end := strings.index(response, "\r\n\r\n"); header_end >= 0 {
		extra_start := header_end + 4
		if extra_start < len(data) do append(&pending_bytes, ..data[extra_start:])
	}
	return Connection{secure = true, process = process, stdin_w = stdin_w, stdout_r = stdout_r, connected = true, pending_texts = make([dynamic]string), pending_bytes = pending_bytes}, true
}

close :: proc(conn: ^Connection) {
	for s in conn.pending_texts do delete(s)
	delete(conn.pending_texts)
	conn.pending_texts = nil
	delete(conn.pending_bytes)
	conn.pending_bytes = nil
	delete(conn.fragmented)
	conn.fragmented = nil
	conn.fragmenting = false

	if conn.connected {
		if conn.secure {
			if conn.stdin_w != nil do _ = os.close(conn.stdin_w)
			if conn.stdout_r != nil do _ = os.close(conn.stdout_r)
			_ = os.process_terminate(conn.process)
			_, _ = os.process_wait(conn.process, 250 * time.Millisecond)
		} else {
			net.close(conn.socket)
		}
		conn.connected = false
	}
}

poll_text :: proc(conn: ^Connection) -> (text: string, ok: bool) {
	if !conn.connected do return "", false
	if len(conn.pending_texts) > 0 {
		text = conn.pending_texts[0]
		ordered_remove(&conn.pending_texts, 0)
		return text, true
	}

	buf: [131072]byte
	n := 0
	if conn.secure {
		if ready, pipe_err := os.pipe_has_data(conn.stdout_r); pipe_err != nil {
			conn.connected = false
			return "", false
		} else if !ready {
			return "", false
		}
		read_n, read_err := os.read(conn.stdout_r, buf[:])
		if read_err != nil || read_n <= 0 {
			conn.connected = false
			return "", false
		}
		n = read_n
	} else {
		read_n, err := net.recv_tcp(conn.socket, buf[:])
		if err != nil {
			if err == .Would_Block do return "", false
			conn.connected = false
			return "", false
		}
		if read_n == 0 {
			conn.connected = false
			return "", false
		}
		n = read_n
	}
	append(&conn.pending_bytes, ..buf[:n])

	first_text := ""
	for {
		opcode, fin, payload, has_frame, ok := take_one_frame_from_pending(
			&conn.pending_bytes,
			allow_64bit = true,
			max_buffer_bytes = WS_READER_DEFAULT_MAX_BUFFER_BYTES,
		)
		if !ok {
			if first_text != "" do delete(first_text)
			conn.connected = false
			return "", false
		}
		if !has_frame do break

		// Control frames ((opcode & 0x08) != 0)
		if (opcode & 0x08) != 0 {
			if !fin {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", false
			}
			if opcode == 0x8 {
				delete(payload)
				conn.connected = false
				return "", false
			}
			if opcode == 0x9 {
				if !conn.secure && conn.socket != 0 {
					pong := [2]byte{0x8A, 0x00}
					_, _ = net.send_tcp(conn.socket, pong[:])
				}
				delete(payload)
				continue
			}
			if opcode == 0xA {
				delete(payload)
				continue
			}
			delete(payload)
			if first_text != "" do delete(first_text)
			conn.connected = false
			return "", false
		}

		switch opcode {
		case 0x1:
			if conn.fragmenting {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", false
			}
			if fin {
				if first_text == "" {
					first_text = payload
				} else {
					append(&conn.pending_texts, payload)
				}
			} else {
				conn.fragmenting = true
				clear(&conn.fragmented)
				append(&conn.fragmented, ..transmute([]byte)payload)
				delete(payload)
			}
		case 0x0:
			if !conn.fragmenting {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", false
			}
			if len(conn.fragmented) + len(payload) > WS_CONTINUATION_DEFAULT_MAX_BYTES {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", false
			}
			append(&conn.fragmented, ..transmute([]byte)payload)
			delete(payload)
			if fin {
				conn.fragmenting = false
				assembled := strings.clone(string(conn.fragmented[:]))
				clear(&conn.fragmented)
				if first_text == "" {
					first_text = assembled
				} else {
					append(&conn.pending_texts, assembled)
				}
			}
		case:
			delete(payload)
			if first_text != "" do delete(first_text)
			conn.connected = false
			return "", false
		}
	}

	if first_text == "" do return "", false
	return first_text, true
}

// send_text writes one WS text frame. SERIALISED per connection (see send_mu):
// concurrent callers may not interleave their bytes on the wire.
//
// BOUNDED (REQ-SHELL-32): the lock is held across the write, so a writer that cannot
// make progress must not hold it forever or it starves every other writer on the
// socket — including the bridge's hub heartbeats, whose loss would make the hub
// declare the bridge offline and reconnect, a more visible failure than the one this
// serialisation fixes. The bound is send_all_tcp's WRITE_DEADLINE (5s). The socat/TLS
// path (send_all_file) writes a BLOCKING fd with no retry loop, so it cannot spin; it
// can only block on a peer that has stopped draining, which is already bounded by the
// hub's 120s read deadline.
//
// A timeout is OBSERVABLE, not silent: it increments send_timeouts. This whole defect
// survived because a drop said nothing.
send_text :: proc(conn: ^Connection, text: string) -> bool {
	if !conn.connected do return false
	n := len(text)
	if n > WS_MAX_SERVER_PAYLOAD do return false
	sync.mutex_lock(&conn.send_mu)
	defer sync.mutex_unlock(&conn.send_mu)
	// Re-check under the lock: a writer that blocked here may have been waiting on a
	// peer another writer has since found dead.
	if !conn.connected do return false
	header: [WS_MAX_HEADER_BYTES]byte
	header_len := server_frame_header(header[:], n)
	frame := make([]byte, header_len + n)
	// REQ-SHELL-52A: send_all_tcp/send_all_file BORROW this slice and free nothing on any
	// exit, so without this every frame leaked header_len+len(text) bytes on the heap.
	defer delete(frame)
	copy(frame[:header_len], header[:header_len])
	copy(frame[header_len:], transmute([]byte)text)
	if conn.secure do return send_all_file(conn.stdin_w, frame)
	return send_all_tcp(conn.socket, frame)
}

// WRITE_DEADLINE caps ONE send_text call, and therefore caps how long one stuck
// writer can hold send_mu. See the note on send_text for why an unbounded retry here
// would trade a byte-interleaving bug for a heartbeat-starvation bug.
WRITE_DEADLINE :: 5 * time.Second

// send_timeouts counts writes abandoned at WRITE_DEADLINE. A nonzero value means
// frames were dropped.
//
// >>> IT IS STRUCTURALLY ALWAYS ZERO ON ANY TLS DEPLOYMENT. DO NOT READ ZERO AS HEALTH. <<<
// It is incremented only in send_all_tcp, and send_text reaches send_all_tcp only when
// conn.secure == false — i.e. plain ws:// only. BOTH TLS backends (socat by default,
// openssl s_client when HAM_TLS_BACKEND=s_client) go through connect_tls_with_bearer,
// which returns secure=true with a PIPE to a child process, so they write via
// send_all_file — which has no deadline, and therefore nothing to count. Every real
// deployment is wss.
//
// So on the transport that matters this counter cannot observe anything, and a reader
// who calls it and gets 0 learns nothing while appearing to learn that no writes were
// abandoned. A metric that is guaranteed uninformative is worse than an absent one,
// because zero looks like evidence. Write-abandonment observability on the pipe path
// would have to be instrumented in send_all_file and needs a deadline to abandon at
// first: that is a design question, not plumbing. REQ-SHELL-41 owns it.
@(private)
_send_timeouts: u64

send_timeouts :: proc() -> u64 { return sync.atomic_load(&_send_timeouts) }

// @(private): send_text is the ONLY door to this socket, and F1's whole thesis is
// that a second unlocked door is what produced REQ-SHELL-32. Unexported so the
// bypass is unrepresentable rather than merely absent today — anything reaching a
// Connection's fd without taking send_mu reintroduces the byte-interleaving bug.
@(private)
send_all_tcp :: proc(socket: net.TCP_Socket, bytes: []byte) -> bool {
	sent := 0
	deadline := time.to_unix_nanoseconds(time.now()) + i64(WRITE_DEADLINE)
	for sent < len(bytes) {
		if time.to_unix_nanoseconds(time.now()) > deadline {
			sync.atomic_add(&_send_timeouts, 1)
			return false
		}
		n, err := net.send_tcp(socket, bytes[sent:])
		if err != nil {
			if err == .Would_Block { time.sleep(10 * time.Millisecond); continue }
			return false
		}
		if n <= 0 do return false
		sent += n
	}
	return true
}

// @(private) for the same reason as send_all_tcp. NOTE the asymmetry: this path has
// NO deadline and no retry arm, because the fd is BLOCKING — it cannot spin, it can
// only block on a peer that has stopped draining. See the bound note on send_text.
@(private)
send_all_file :: proc(file: ^os.File, bytes: []byte) -> bool {
	sent := 0
	for sent < len(bytes) {
		n, err := os.write(file, bytes[sent:])
		if err != nil || n <= 0 do return false
		sent += n
	}
	return true
}

// tls_client_command builds the argv for the subprocess that terminates TLS for
// the bridge->hub wss:// control channel. The transport is selected by the
// HAM_TLS_BACKEND env toggle:
//   - "s_client"      -> legacy `openssl s_client` (kept as an instant, no-rebuild
//                        fallback; suffers the 16 KB multi-read teardown).
//   - anything else   -> `socat OPENSSL-CONNECT` (the DEFAULT: a purpose-built
//     (default socat)   full-duplex relay that does not tear down on multi-read
//                        bursts, which is what unblocks large FS reads/artifacts).
// SHARED CONTRACT: the exact same rule ("s_client" == legacy, else socat) is
// duplicated in src/lib/http_client/http_client.odin and in the bridge's
// bridge_tls_backend_is_socat (src/bridge/fs_management.odin) — keep them in sync.
tls_client_command :: proc(host: string, port: u16) -> []string {
	clean_host := host
	if len(clean_host) >= 2 && clean_host[0] == '[' && clean_host[len(clean_host)-1] == ']' {
		clean_host = clean_host[1:len(clean_host)-1]
	}
	ca_file := strings.trim_space(os.get_env("HAM_TLS_CA_FILE", context.temp_allocator))
	backend := strings.to_lower(strings.trim_space(os.get_env("HAM_TLS_BACKEND", context.temp_allocator)))
	if backend == "s_client" {
		return openssl_s_client_command(clean_host, port, ca_file)
	}
	return socat_openssl_command(clean_host, port, ca_file)
}

// openssl_s_client_command is the legacy fallback transport (HAM_TLS_BACKEND=s_client).
openssl_s_client_command :: proc(clean_host: string, port: u16, ca_file: string) -> []string {
	cmd := make([dynamic]string)
	append(&cmd, "openssl")
	append(&cmd, "s_client")
	append(&cmd, "-quiet")
	append(&cmd, "-verify_return_error")
	append(&cmd, "-servername")
	append(&cmd, clean_host)
	append(&cmd, "-verify_hostname")
	append(&cmd, clean_host)
	if ca_file != "" {
		append(&cmd, "-CAfile")
		append(&cmd, ca_file)
	}
	append(&cmd, "-connect")
	append(&cmd, fmt.tprintf("%s:%d", clean_host, port))
	return cmd[:]
}

// socat_openssl_command is the default transport. It relays STDIO <-> an OpenSSL
// TLS connection. TLS verification is EQUIVALENT to the s_client path and MUST NOT
// be weakened:
//   - verify=1        : require + verify the peer certificate chain (fail closed).
//   - commonname=<h>  : check the cert's CN/SAN against the intended host — this is
//                       the hostname verification (mirrors s_client -verify_hostname).
//   - snihost=<h>     : send SNI so the server presents the right cert (mirrors
//                       s_client -servername).
//   - cafile=<ca>     : trust anchor when HAM_TLS_CA_FILE is set; when unset, socat
//                       uses OpenSSL's default CA store, exactly like s_client with
//                       no -CAfile. NEVER emit verify=0.
socat_openssl_command :: proc(clean_host: string, port: u16, ca_file: string) -> []string {
	opts := strings.builder_make()
	fmt.sbprintf(&opts, "OPENSSL-CONNECT:%s:%d", clean_host, port)
	fmt.sbprintf(&opts, ",snihost=%s", clean_host)
	strings.write_string(&opts, ",verify=1")
	fmt.sbprintf(&opts, ",commonname=%s", clean_host)
	if ca_file != "" {
		fmt.sbprintf(&opts, ",cafile=%s", ca_file)
	}
	cmd := make([dynamic]string)
	append(&cmd, "socat")
	append(&cmd, "STDIO")
	append(&cmd, strings.to_string(opts))
	return cmd[:]
}

parse_ws_url :: proc(ws_url: string) -> (host: string, port: u16, path: string, secure: bool, ok: bool) {
	url := ws_url
	default_port: u16 = 80
	if strings.has_prefix(url, "wss://") {
		url = url[len("wss://"):]
		default_port = 443
		secure = true
	} else if strings.has_prefix(url, "ws://") {
		url = url[len("ws://"):]
		default_port = 80
	}

	slash := strings.index_byte(url, '/')
	if slash < 0 do return "", 0, "", false, false

	host_port := url[:slash]
	path = url[slash:]
	colon := strings.last_index_byte(host_port, ':')
	if colon < 0 {
		host = host_port
		return host, default_port, path, secure, strings.trim_space(host) != ""
	}

	host = host_port[:colon]
	port_s := host_port[colon + 1:]
	port_i, port_ok := strconv.parse_int(port_s)
	if !port_ok do return "", 0, "", false, false

	return host, u16(port_i), path, secure, true
}
