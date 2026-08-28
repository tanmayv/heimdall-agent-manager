package hub_proxy

// ham-hub-proxy — a dumb, single-purpose TLS re-origination proxy.
//
// Purpose: let a ham-bridge that can only reach a LOCAL plaintext port talk to a
// remote HTTPS hub (e.g. hub.mundus.in) that is only reachable while an SSH
// tunnel is up. Run this on the machine that CAN reach the hub; SSH-reverse-forward
// the bridge's local port to it:
//
//   [vm] ham-bridge --hub http://127.0.0.1:8090
//        ssh -R 8090:127.0.0.1:8090 vm     (from this machine)
//   [this machine] ham-hub-proxy --listen 127.0.0.1:8090 --upstream https://hub.mundus.in
//        -> TLS + SNI to hub.mundus.in:443, rewriting Host: to hub.mundus.in
//
// Why not a pure TCP byte-pipe: the hub's edge vhost-matches on the Host header
// (a wrong hostname is rejected with 403; the port is ignored). So we must rewrite
// the FIRST request head's Host hostname to the upstream host. After that first
// head it is a transparent bidirectional byte pipe — which also carries the
// WebSocket upgrade (/api/v1/bridge-ws) and its framed traffic unchanged, because
// the ham-bridge HTTP client uses `Connection: close` (one request per connection)
// and the WS connection is a single long-lived stream.
//
// TLS is delegated to `openssl s_client` (same mechanism the bridge itself uses),
// so there is no in-process TLS stack and no extra dependency beyond openssl.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"

Config :: struct {
	listen:        string, // host:port to listen on (plaintext)
	upstream_host: string, // e.g. hub.mundus.in
	upstream_port: u16,    // e.g. 443
	verbose:       bool,
}

main :: proc() {
	config := Config{listen = "127.0.0.1:8090", upstream_host = "", upstream_port = 443}
	if !parse_args(&config) {
		print_usage()
		os.exit(2)
	}
	if strings.trim_space(config.upstream_host) == "" {
		fmt.eprintln("ham-hub-proxy: --upstream is required (e.g. https://hub.mundus.in)")
		print_usage()
		os.exit(2)
	}
	run_server(config)
}

print_usage :: proc() {
	fmt.eprintln("usage: ham-hub-proxy --upstream https://<host>[:port] [--listen 127.0.0.1:8090] [--verbose]")
	fmt.eprintln("  Forwards plaintext HTTP/WS from --listen to the HTTPS/WSS --upstream, rewriting the Host header.")
	fmt.eprintln("  TLS CA override: set HAM_TLS_CA_FILE=<path> (passed to openssl -CAfile).")
}

parse_args :: proc(config: ^Config) -> bool {
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		switch {
		case arg == "--listen" && i + 1 < len(os.args):
			config.listen = strings.clone(os.args[i + 1]); i += 1
		case arg == "--upstream" && i + 1 < len(os.args):
			host, port, ok := parse_upstream(os.args[i + 1])
			if !ok { fmt.eprintln("ham-hub-proxy: invalid --upstream", os.args[i + 1]); return false }
			config.upstream_host = host; config.upstream_port = port; i += 1
		case arg == "--verbose":
			config.verbose = true
		case arg == "-h" || arg == "--help":
			return false
		case:
			fmt.eprintln("ham-hub-proxy: unknown arg", arg); return false
		}
	}
	return true
}

// parse_upstream accepts https://host, https://host:port, host, or host:port.
// Defaults to TLS port 443. http:// is rejected (this proxy exists to ADD TLS).
parse_upstream :: proc(value: string) -> (host: string, port: u16, ok: bool) {
	v := strings.trim_space(value)
	if strings.has_prefix(v, "http://") {
		fmt.eprintln("ham-hub-proxy: --upstream must be https:// (this proxy terminates TLS to the hub)")
		return "", 0, false
	}
	if strings.has_prefix(v, "https://") do v = v[len("https://"):]
	v = strings.trim_right(v, "/")
	if slash := strings.index_byte(v, '/'); slash >= 0 do v = v[:slash]
	host_part := v
	port_val: u16 = 443
	if colon := strings.last_index_byte(v, ':'); colon >= 0 && strings.index_byte(v, ']') < colon {
		host_part = v[:colon]
		if p, pok := parse_u16(v[colon + 1:]); pok do port_val = p
	}
	if strings.trim_space(host_part) == "" do return "", 0, false
	return strings.clone(host_part), port_val, true
}

parse_u16 :: proc(s: string) -> (u16, bool) {
	n := 0
	if len(s) == 0 do return 0, false
	for ch in s {
		if ch < '0' || ch > '9' do return 0, false
		n = n * 10 + int(ch - '0')
		if n > 65535 do return 0, false
	}
	return u16(n), true
}

run_server :: proc(config: Config) {
	host, port, ok := split_host_port(config.listen)
	if !ok {
		fmt.eprintln("ham-hub-proxy: invalid --listen", config.listen)
		os.exit(2)
	}
	address := net.IP4_Loopback
	if host != "127.0.0.1" && host != "localhost" {
		if parsed, parsed_ok := net.parse_ip4_address(host); parsed_ok do address = parsed
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = address, port = int(port)})
	if lerr != nil {
		fmt.eprintln("ham-hub-proxy: listen failed", config.listen, lerr)
		os.exit(1)
	}
	fmt.printfln("ham-hub-proxy listening %s -> https://%s:%d (Host rewritten to %s)", config.listen, config.upstream_host, config.upstream_port, config.upstream_host)

	shared := new(Config); shared^ = config
	for {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil do continue
		ctx := new(Client_Ctx); ctx.config = shared; ctx.client = client
		thread.run_with_poly_data(ctx, handle_client)
	}
}

Client_Ctx :: struct {
	config: ^Config,
	client: net.TCP_Socket,
}

handle_client :: proc(ctx: ^Client_Ctx) {
	defer free(ctx)
	client := ctx.client
	defer net.close(client)
	cfg := ctx.config

	// 1) Read the request head (up to and including the blank line).
	head, body_tail, hok := read_request_head(client)
	if !hok do return
	defer delete(head)
	defer delete(body_tail)

	// 2) Rewrite the Host: header hostname to the upstream host.
	rewritten := rewrite_host_header(head, cfg.upstream_host)
	defer delete(rewritten)

	// 3) Start openssl s_client to the upstream (TLS + SNI to the real host).
	cmd := tls_client_command(cfg.upstream_host, cfg.upstream_port)
	defer delete(cmd)
	stdin_r, stdin_w, sperr := os.pipe()
	if sperr != nil do return
	stdout_r, stdout_w, soerr := os.pipe()
	if soerr != nil { _ = os.close(stdin_r); _ = os.close(stdin_w); return }
	process, prerr := os.process_start(os.Process_Desc{command = cmd, stdin = stdin_r, stdout = stdout_w, stderr = os.stderr})
	_ = os.close(stdin_r); _ = os.close(stdout_w)
	if prerr != nil { _ = os.close(stdin_w); _ = os.close(stdout_r); return }

	if cfg.verbose {
		fmt.printfln("ham-hub-proxy: %s", first_line(rewritten))
	}

	// 4) Send the rewritten head (+ any already-read body bytes) to the upstream.
	if !write_all_pipe(stdin_w, transmute([]byte)rewritten) {
		_ = os.close(stdin_w); _ = os.close(stdout_r); _ = os.process_kill(process); _, _ = os.process_wait(process); return
	}
	if len(body_tail) > 0 && !write_all_pipe(stdin_w, body_tail) {
		_ = os.close(stdin_w); _ = os.close(stdout_r); _ = os.process_kill(process); _, _ = os.process_wait(process); return
	}

	// 5) Transparent bidirectional pipe until either side closes. This carries the
	//    request body, the response, and (for /api/v1/bridge-ws) the WebSocket
	//    upgrade + all framed traffic, unchanged.
	up := new(Pump_Ctx); up.client = client; up.pipe_in = stdin_w
	pump := thread.create_and_start_with_poly_data(up, pump_client_to_upstream)

	// This thread pumps upstream (openssl stdout) -> client.
	buf: [16384]byte
	for {
		n, rerr := os.read(stdout_r, buf[:])
		if n > 0 {
			if !net_send_all(client, buf[:n]) do break
		}
		if rerr != nil || n <= 0 do break
	}

	// Upstream closed / errored: tear everything down.
	net.close(client)        // unblock the client->upstream pump's recv
	_ = os.close(stdin_w)    // EOF to openssl
	_ = os.close(stdout_r)
	_ = os.process_kill(process)
	_, _ = os.process_wait(process)
	if pump != nil { thread.join(pump); thread.destroy(pump) }
}

Pump_Ctx :: struct {
	client:  net.TCP_Socket,
	pipe_in: ^os.File,
}

// pump_client_to_upstream copies bytes from the plaintext client socket into the
// openssl stdin pipe (which encrypts + forwards to the hub).
pump_client_to_upstream :: proc(p: ^Pump_Ctx) {
	defer free(p)
	buf: [16384]byte
	for {
		n, rerr := net.recv_tcp(p.client, buf[:])
		if n > 0 {
			if !write_all_pipe(p.pipe_in, buf[:n]) do break
		}
		if rerr != nil || n <= 0 do break
	}
}

// --- helpers -------------------------------------------------------------

// read_request_head reads until the end of HTTP headers (\r\n\r\n). Returns the
// head (including the terminating blank line) and any bytes already read past it.
read_request_head :: proc(client: net.TCP_Socket) -> (head: string, tail: []byte, ok: bool) {
	data := make([dynamic]byte, 0, 8192)
	buf: [8192]byte
	for {
		n, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || n <= 0 { delete(data); return "", nil, false }
		append(&data, ..buf[:n])
		if idx := index_crlfcrlf(data[:]); idx >= 0 {
			head_end := idx + 4
			head_str := strings.clone(string(data[:head_end]))
			extra := make([]byte, len(data) - head_end)
			if len(extra) > 0 do copy(extra, data[head_end:])
			delete(data)
			return head_str, extra, true
		}
		if len(data) > 1024 * 1024 { delete(data); return "", nil, false }
	}
}

// rewrite_host_header replaces the value of the (case-insensitive) Host: header
// with `new_host`, preserving the request line and all other headers. If no Host
// header exists, one is inserted after the request line.
rewrite_host_header :: proc(head, new_host: string) -> string {
	lines := strings.split(head, "\r\n")
	defer delete(lines)
	b := strings.builder_make()
	wrote_host := false
	for line, i in lines {
		if i == 0 {
			strings.write_string(&b, line); strings.write_string(&b, "\r\n")
			continue
		}
		if !wrote_host && is_host_header(line) {
			strings.write_string(&b, "Host: "); strings.write_string(&b, new_host); strings.write_string(&b, "\r\n")
			wrote_host = true
			continue
		}
		if i == len(lines) - 1 {
			strings.write_string(&b, line)
		} else {
			strings.write_string(&b, line); strings.write_string(&b, "\r\n")
		}
	}
	result := strings.to_string(b)
	if !wrote_host {
		if nl := strings.index(result, "\r\n"); nl >= 0 {
			injected := fmt.aprintf("%sHost: %s\r\n%s", result[:nl + 2], new_host, result[nl + 2:])
			delete(b.buf)
			return injected
		}
	}
	return result
}

is_host_header :: proc(line: string) -> bool {
	if len(line) < 5 do return false
	return ascii_lower(line[0]) == 'h' && ascii_lower(line[1]) == 'o' && ascii_lower(line[2]) == 's' && ascii_lower(line[3]) == 't' && line[4] == ':'
}

ascii_lower :: proc(c: u8) -> u8 { return c + 32 if c >= 'A' && c <= 'Z' else c }

first_line :: proc(head: string) -> string {
	if nl := strings.index(head, "\r\n"); nl >= 0 do return head[:nl]
	return head
}

index_crlfcrlf :: proc(data: []byte) -> int {
	for i := 0; i + 3 < len(data); i += 1 {
		if data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n' do return i
	}
	return -1
}

// tls_client_command mirrors the bridge/http_client openssl invocation: verified
// TLS with SNI + hostname verification to the real upstream host.
tls_client_command :: proc(host: string, port: u16) -> []string {
	clean := host_trim_brackets(host)
	cmd := make([dynamic]string)
	append(&cmd, "openssl")
	append(&cmd, "s_client")
	append(&cmd, "-quiet")
	append(&cmd, "-verify_return_error")
	append(&cmd, "-servername"); append(&cmd, clean)
	append(&cmd, "-verify_hostname"); append(&cmd, clean)
	if ca := strings.trim_space(os.get_env("HAM_TLS_CA_FILE", context.temp_allocator)); ca != "" {
		append(&cmd, "-CAfile"); append(&cmd, ca)
	}
	append(&cmd, "-connect"); append(&cmd, fmt.tprintf("%s:%d", clean, port))
	return cmd[:]
}

host_trim_brackets :: proc(host: string) -> string {
	if len(host) >= 2 && host[0] == '[' && host[len(host) - 1] == ']' do return host[1:len(host) - 1]
	return host
}

write_all_pipe :: proc(f: ^os.File, data: []byte) -> bool {
	off := 0
	for off < len(data) {
		n, werr := os.write(f, data[off:])
		if werr != nil || n <= 0 do return false
		off += n
	}
	return true
}

net_send_all :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	off := 0
	for off < len(data) {
		n, serr := net.send_tcp(sock, data[off:])
		if serr != nil || n <= 0 do return false
		off += n
	}
	return true
}

split_host_port :: proc(hostport: string) -> (host: string, port: u16, ok: bool) {
	colon := strings.last_index_byte(hostport, ':')
	if colon < 0 do return "", 0, false
	host = hostport[:colon]
	p, pok := parse_u16(hostport[colon + 1:])
	if !pok do return "", 0, false
	if host == "" do host = "127.0.0.1"
	return host, p, true
}
