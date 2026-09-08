package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

GATEWAY_HTML_PAGE :: `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Heimdall Cloudtop Gateway</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; padding: 2.5rem; max-width: 720px; margin: 0 auto; color: #202124; line-height: 1.6; }
    h1 { color: #1a73e8; margin-bottom: 0.5rem; }
    .badge { display: inline-block; background: #e8f0fe; color: #1a73e8; padding: 4px 10px; border-radius: 12px; font-size: 0.85em; font-weight: 600; }
    .card { background: #f8f9fa; border: 1px solid #dadce0; border-radius: 8px; padding: 16px; margin: 20px 0; }
    code { background: #e8eaed; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
    ul { padding-left: 20px; }
    li { margin: 8px 0; }
    a { color: #1a73e8; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <h1>Heimdall Cloudtop Gateway</h1>
  <span class="badge">Port 8989 Active</span>
  <div class="card">
    <p><strong>Cloudtop Edge Gateway is active</strong> and verifying caller LOAS identity.</p>
    <ul>
      <li><strong>Hub API Status:</strong> <a href="/api/v1/health">/api/v1/health</a></li>
      <li><strong>User Profile:</strong> <a href="/api/v1/me">/api/v1/me</a></li>
      <li><strong>Vite UI Server:</strong> <code>127.0.0.1:5173</code> (run <code>npm run dev</code> to launch frontend UI)</li>
    </ul>
  </div>
</body>
</html>`

main :: proc() {
	dev_proxy_gcert_init()
	config := default_dev_proxy_config()
	parse_args(&config)
	if len(os.args) > 1 && os.args[1] == "--print-config" {
		fmt.printfln("ham-dev-proxy listen=%s hub_url=%s default_user=%s", config.listen, config.hub_url, config.default_user)
		return
	}
	// DP-1 / DP-5: load the persisted dev-user roster + active selection from
	// the XDG/HEIMDALL_HOME data dir and merge with seed users. The persisted
	// `active` username becomes config.default_user (the select_dev_user
	// fallback); an existing ham_dev_user cookie still wins per request.
	store := new(Dev_Proxy_Store)
	data_dir, store_path, loaded := dev_proxy_store_init(store, &config)
	fmt.println("ham-dev-proxy data_dir", data_dir)
	fmt.printfln("ham-dev-proxy store_path=%s loaded=%v active=%s", store_path, loaded, config.default_user)

	// If proxy_secret is not explicitly passed, look for <data_dir>/proxy_secret
	if config.proxy_secret == "" {
		default_sec_path := fmt.tprintf("%s/proxy_secret", data_dir)
		if data, err := os.read_entire_file(default_sec_path, context.allocator); err == nil {
			config.proxy_secret = strings.clone(strings.trim_space(string(data)))
		}
	}

	// DP-7: management API/UI (/_dev/*) are served ONLY on a loopback bind.
	// A non-loopback --listen disables management routes (they 404) so the
	// dev-only identity manager is never exposed remotely.
	listen_host, _, _ := split_host_port(config.listen)
	config.management_enabled = is_loopback_host(listen_host)
	if !config.management_enabled {
		fmt.println("ham-dev-proxy: non-loopback bind; management routes disabled")
	}
	run_dev_proxy_server(config, store)
}

parse_args :: proc(config: ^Dev_Proxy_Config) {
	if v := os.get_env_alloc("HAM_DEV_PROXY_DEFAULT_USER", context.allocator); v != "" {
		config.default_user = v
	}
	if v := os.get_env_alloc("HEIMDALL_AUDIT_MODE", context.allocator); v == "1" || v == "true" {
		config.audit_mode = true
	}
	if v := os.get_env_alloc("HAM_PROXY_SECRET", context.allocator); v != "" {
		config.proxy_secret = v
	}
	if v := os.get_env_alloc("HAM_PROXY_SECRET_FILE", context.allocator); v != "" {
		if data, err := os.read_entire_file(v, context.allocator); err == nil {
			config.proxy_secret = strings.clone(strings.trim_space(string(data)))
		}
	}
	if v := os.get_env_alloc("HAM_DEV_PROXY_LISTEN", context.allocator); v != "" {
		config.listen = v
	}
	if v := os.get_env_alloc("HAM_VITE_URL", context.allocator); v != "" {
		config.vite_url = v
	}
	if v := os.get_env_alloc("HAM_STATIC_DIR", context.allocator); v != "" {
		config.static_dir = v
	}
	if v := os.get_env_alloc("HEIMDALL_CLOUDTOP", context.allocator); v == "1" || v == "true" {
		config.listen = "0.0.0.0:8989"
	}
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--listen" && i + 1 < len(os.args) {
			config.listen = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--hub-url" && i + 1 < len(os.args) {
			config.hub_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--vite-url" && i + 1 < len(os.args) {
			config.vite_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--static-dir" && i + 1 < len(os.args) {
			config.static_dir = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--cloudtop" {
			config.listen = "0.0.0.0:8989"
		} else if arg == "--default-user" && i + 1 < len(os.args) {
			config.default_user = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--audit-mode" {
			config.audit_mode = true
		} else if arg == "--proxy-secret" && i + 1 < len(os.args) {
			config.proxy_secret = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--proxy-secret-file" && i + 1 < len(os.args) {
			config.proxy_secret_file = strings.clone(os.args[i + 1])
			if data, err := os.read_entire_file(config.proxy_secret_file, context.allocator); err == nil {
				config.proxy_secret = strings.clone(strings.trim_space(string(data)))
			}
			i += 1
		}
	}
}

run_dev_proxy_server :: proc(config: Dev_Proxy_Config, store: ^Dev_Proxy_Store) -> bool {
	host, port, ok := split_host_port(config.listen)
	if !ok {
		fmt.eprintln("invalid --listen", config.listen)
		return false
	}
	address := net.IP4_Loopback
	if host != "127.0.0.1" {
		if parsed, parsed_ok := net.parse_ip4_address(host); parsed_ok do address = parsed
	}
	listener, err := net.listen_tcp({address, port})
	if err != nil {
		fmt.eprintln("ham-dev-proxy listen failed", config.listen, err)
		return false
	}
	defer net.close(listener)
	fmt.println("ham-dev-proxy listening", config.listen, "hub_url", config.hub_url)
	// Shared mutable config: one heap instance so management-API mutations
	// (create/delete/set-active) are visible to every connection thread. The
	// task-1 store mutex guards writes to the users slice + active selection.
	shared_config := new(Dev_Proxy_Config)
	shared_config^ = config
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		ctx := new(Dev_Proxy_Client_Context)
		ctx.config = shared_config
		ctx.store = store
		ctx.client = client
		thread.run_with_poly_data(ctx, handle_dev_proxy_client)
	}
}

Dev_Proxy_Client_Context :: struct {
	config: ^Dev_Proxy_Config,
	store: ^Dev_Proxy_Store,
	client: net.TCP_Socket,
}

is_origin_or_referer_allowed :: proc(origin_or_ref: string) -> bool {
	trimmed := strings.trim_space(origin_or_ref)
	if trimmed == "" do return true
	allowed_prefixes := [?]string{"http://127.0.0.1", "http://localhost", "http://[::1]", "https://127.0.0.1", "https://localhost", "https://[::1]"}
	for p in allowed_prefixes {
		if strings.has_prefix(trimmed, p) {
			rest := trimmed[len(p):]
			if len(rest) == 0 || rest[0] == ':' || rest[0] == '/' do return true
		}
	}
	return false
}

log_incoming_headers :: proc(headers: []contracts.HTTP_Header) {
	fmt.eprintln("[dev-proxy] Incoming headers on denial:")
	for h in headers {
		lower_name := strings.to_lower(h.name, context.temp_allocator)
		if ascii_equal_fold(h.name, "Authorization") {
			preview := h.value[:min(12, len(h.value))]
			fmt.eprintfln("[dev-proxy]   %s: %s... (masked, len=%d)", h.name, preview, len(h.value))
		} else if lower_name == "cookie" || lower_name == "set-cookie" {
			fmt.eprintfln("[dev-proxy]   %s: [REDACTED] (len=%d)", h.name, len(h.value))
		} else if strings.contains(lower_name, "secret") || strings.contains(lower_name, "token") {
			fmt.eprintfln("[dev-proxy]   %s: [REDACTED] (len=%d)", h.name, len(h.value))
		} else {
			fmt.eprintfln("[dev-proxy]   %s: %s", h.name, h.value)
		}
	}
}

handle_dev_proxy_client :: proc(ctx: ^Dev_Proxy_Client_Context) {
	defer free(ctx)
	client := ctx.client
	defer net.close(client)
	request, ok := read_http_request(client)
	if !ok do return
	method, target := request_method_target(request)
	path, query := split_target_query(target)

	// CT-3 / CT-7: Host & CSRF validation
	headers := parse_headers(request)
	defer free_headers(headers)

	// Extract caller identity from ÜberProxy headers if present
	caller_user, caller_email, has_uberproxy := extract_uberproxy_identity(headers)
	owner := get_cloudtop_owner(ctx.config)

	// Check for bridge bearer token (hbr_... runtime WS or hbe_... enrollment)
	auth_hdr := header_value(headers, "Authorization")
	is_bridge_bearer := false
	if strings.has_prefix(auth_hdr, "Bearer ") {
		token := strings.trim_space(auth_hdr[len("Bearer "):])
		if strings.has_prefix(token, "hbr_") || strings.has_prefix(token, "hbe_") {
			is_bridge_bearer = true
		}
	}

	host_hdr := header_value(headers, "Host")
	host_only := host_hdr
	if host_hdr != "" {
		h_only, _, h_ok := split_host_port(host_hdr)
		if h_ok do host_only = h_only
	}
	host_lower := strings.to_lower(host_only, context.temp_allocator)
	if host_hdr != "" && !is_allowed_host(host_lower) {
		fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 invalid host header", method, target, host_lower, caller_user, owner)
		log_incoming_headers(headers)
		write_response(client, 403, "Forbidden", "text/plain", "invalid host header")
		return
	}

	// CT-7 / CT-8 / CT-9: Cloudtop Owner & Bridge Bearer Verification Gate
	if is_bridge_bearer {
		// Authenticated via Hub-issued bridge token (hbr_... / hbe_...)
		fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 200 bridge token admitted", method, target, host_lower, "bridge", owner)
	} else if has_uberproxy {
		if caller_user != owner {
			fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 Access Denied: Caller identity does not match Cloudtop owner", method, target, host_lower, caller_user, owner)
			log_incoming_headers(headers)
			write_response(client, 403, "Forbidden", "text/plain", "Access Denied: Caller identity does not match Cloudtop owner")
			return
		}
		fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 200 owner admitted via ÜberProxy", method, target, host_lower, caller_user, owner)
	} else {
		// Non-loopback connections without ÜberProxy headers or bridge tokens are rejected
		if !is_loopback_host(host_lower) {
			fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 Access Denied: Caller identity does not match Cloudtop owner (non-loopback)", method, target, host_lower, caller_user, owner)
			log_incoming_headers(headers)
			write_response(client, 403, "Forbidden", "text/plain", "Access Denied: Caller identity does not match Cloudtop owner")
			return
		}
		fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 200 local caller admitted", method, target, host_lower, "loopback", owner)
	}

	// For mutating requests to /_dev/* check Sec-Fetch-Site and Origin/Referer to prevent CSRF
	if strings.has_prefix(path, "/_dev/") && method != "GET" && method != "HEAD" && method != "OPTIONS" {
		sec_fetch := header_value(headers, "Sec-Fetch-Site")
		if sec_fetch != "" && sec_fetch != "same-origin" && sec_fetch != "same-site" && sec_fetch != "none" {
			fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 cross-origin dev request rejected (Sec-Fetch-Site)", method, target, host_lower, caller_user, owner)
			log_incoming_headers(headers)
			write_response(client, 403, "Forbidden", "text/plain", "cross-origin dev request rejected")
			return
		}
		origin := header_value(headers, "Origin")
		if origin != "" && !is_origin_or_referer_allowed(origin) {
			fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 cross-origin dev request rejected (Origin)", method, target, host_lower, caller_user, owner)
			log_incoming_headers(headers)
			write_response(client, 403, "Forbidden", "text/plain", "cross-origin dev request rejected")
			return
		}
		referer := header_value(headers, "Referer")
		if referer != "" && !is_origin_or_referer_allowed(referer) {
			fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 cross-origin dev request rejected (Referer)", method, target, host_lower, caller_user, owner)
			log_incoming_headers(headers)
			write_response(client, 403, "Forbidden", "text/plain", "cross-origin dev request rejected")
			return
		}
	}

	// Security: Bridge auto-pairing and enrollment are sensitive operations and MUST NOT be reachable through dev-proxy
	// bridge enrollment/auto-pair forbidden through dev-proxy
	if strings.has_prefix(path, "/api/v1/bridges/auto-pair") {
		fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 bridge auto-pair forbidden through dev-proxy", method, target, host_lower, caller_user, owner)
		log_incoming_headers(headers)
		write_response(client, 403, "Forbidden", "text/plain", "bridge auto-pair forbidden through dev-proxy")
		return
	}
	if strings.has_prefix(path, "/api/v1/bridges/enroll") && !is_bridge_bearer {
		fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 403 bridge enrollment forbidden through dev-proxy (missing bearer token)", method, target, host_lower, caller_user, owner)
		log_incoming_headers(headers)
		write_response(client, 403, "Forbidden", "text/plain", "bridge enrollment forbidden through dev-proxy")
		return
	}

	if strings.has_prefix(path, "/_dev/") {
		// DP-7: hard loopback boundary for the entire management surface.
		if !ctx.config.management_enabled {
			write_response(client, 404, "Not Found", "text/plain", "management routes disabled on non-loopback bind")
			return
		}
		// Management routes are handled locally and NEVER forwarded (DP-6).
		if handle_dev_api_request(ctx, method, path, request_body(request)) do return
		if handle_dev_ui_request(client, path) do return
		if strings.has_prefix(path, "/_dev/login") {
			user := query_param(query, "user")
			if !dev_user_exists(ctx.config, user) {
				write_response(client, 400, "Bad Request", "text/plain", "unknown dev user")
				return
			}
			write_response_with_headers(client, 204, "No Content", "text/plain", "", []contracts.HTTP_Header{{name = "Set-Cookie", value = login_response_cookie(user)}})
			return
		}
		if path == "/_dev/logout" {
			write_response_with_headers(client, 204, "No Content", "text/plain", "", []contracts.HTTP_Header{{name = "Set-Cookie", value = logout_response_cookie()}})
			return
		}
		write_response(client, 404, "Not Found", "text/plain", "not found")
		return
	}

	// Ingress security: LOAS/gcert credential check before forwarding
	if valid, gcert_msg := dev_proxy_check_gcert(); !valid {
		fmt.eprintfln("[dev-proxy] %s %s Host=%q caller=%q owner=%q -> 401 %s", method, target, host_lower, caller_user, owner, gcert_msg)
		log_incoming_headers(headers)
		write_response(client, 401, "Unauthorized", "text/plain", gcert_msg)
		return
	}

	// CT-7: Dynamic owner identity resolution for Hub
	override_user := Dev_User{}
	if has_uberproxy {
		override_user = Dev_User{
			username = caller_user,
			display_name = caller_user,
			email = caller_email,
		}
	}

	// CT-7 / CT-11: Route API calls to Hub, and all UI/asset/static calls to static files or Vite dev server (or gateway HTML fallback)
	if strings.has_prefix(path, "/api/v1") {
		forward_request(client, ctx.config, request, method, target, override_user)
	} else {
		if ctx.config.static_dir != "" && serve_static_ui(client, ctx.config.static_dir, path, method) {
			return
		}
		forward_to_vite(client, ctx.config, request, method, target)
	}
}

forward_request :: proc(client: net.TCP_Socket, config: ^Dev_Proxy_Config, request, method, target: string, override_user: Dev_User = Dev_User{}) {
	incoming := parse_headers(request)
	defer free_headers(incoming)
	cookie := header_value(incoming, "Cookie")
	rewritten, ok := rewrite_headers_for_hub(config, incoming, cookie, override_user)
	if !ok {
		write_response(client, 400, "Bad Request", "text/plain", "unknown dev user")
		return
	}
	defer free_headers(rewritten)
	hub_host, hub_port, hub_ok := parse_base_url(config.hub_url)
	if !hub_ok {
		write_response(client, 502, "Bad Gateway", "text/plain", "invalid hub_url")
		return
	}
	upstream, dial_err := net.dial_tcp_from_hostname_with_port_override(hub_host, hub_port)
	if dial_err != nil {
		write_response(client, 502, "Bad Gateway", "text/plain", "hub unavailable")
		return
	}
	defer net.close(upstream)

	// WebSocket detection: a client requesting `Connection: Upgrade` +
	// `Upgrade: websocket` needs a persistent bidirectional tunnel, not the
	// one-shot request/response copy. We must FORWARD the upgrade headers to the
	// hub (unlike normal requests, where Connection is stripped and forced to
	// close), relay the `101`, then pump both directions with no read timeout
	// until either side closes.
	is_ws := ascii_equal_fold(header_value(incoming, "Upgrade"), "websocket")

	body := request_body(request)
	out := strings.builder_make()
	strings.write_string(&out, method); strings.write_string(&out, " "); strings.write_string(&out, target); strings.write_string(&out, " HTTP/1.1\r\n")
	strings.write_string(&out, "Host: "); strings.write_string(&out, hub_host); strings.write_string(&out, ":"); strings.write_string(&out, fmt.tprintf("%d", hub_port)); strings.write_string(&out, "\r\n")
	for h in rewritten {
		if ascii_equal_fold(h.name, "Host") || ascii_equal_fold(h.name, "Content-Length") || ascii_equal_fold(h.name, "Connection") do continue
		// For non-WS requests we drop any client-supplied Upgrade; for WS we keep
		// the Sec-WebSocket-* headers (they pass through the loop below) and add
		// our own Connection/Upgrade line explicitly.
		if is_ws && ascii_equal_fold(h.name, "Upgrade") do continue
		strings.write_string(&out, h.name); strings.write_string(&out, ": "); strings.write_string(&out, h.value); strings.write_string(&out, "\r\n")
	}
	if is_ws {
		strings.write_string(&out, "Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
	} else {
		strings.write_string(&out, fmt.tprintf("Content-Length: %d\r\nConnection: close\r\n\r\n", len(body)))
		strings.write_string(&out, body)
	}
	out_req := strings.to_string(out)
	_, send_err := net.send_tcp(upstream, transmute([]byte)out_req)
	if send_err != nil {
		write_response(client, 502, "Bad Gateway", "text/plain", "hub send failed")
		return
	}
	if is_ws {
		proxy_tunnel_bidirectional(client, upstream)
		return
	}
	proxy_copy_response(client, upstream)
}

forward_to_vite :: proc(client: net.TCP_Socket, config: ^Dev_Proxy_Config, request, method, target: string) {
	vite_host, vite_port, vite_ok := parse_base_url(config.vite_url)
	if !vite_ok {
		write_response(client, 502, "Bad Gateway", "text/plain", "invalid vite_url")
		return
	}
	upstream, dial_err := net.dial_tcp_from_hostname_with_port_override(vite_host, vite_port)
	if dial_err != nil {
		path, _ := split_target_query(target)
		if path == "" || path == "/" || strings.has_suffix(path, ".html") {
			write_response(client, 200, "OK", "text/html; charset=utf-8", GATEWAY_HTML_PAGE)
		} else {
			write_response(client, 502, "Bad Gateway", "text/plain", "Vite dev server unavailable on 127.0.0.1:5173")
		}
		return
	}
	defer net.close(upstream)

	incoming := parse_headers(request)
	defer free_headers(incoming)
	is_ws := ascii_equal_fold(header_value(incoming, "Upgrade"), "websocket")
	body := request_body(request)

	out := strings.builder_make()
	strings.write_string(&out, method); strings.write_string(&out, " "); strings.write_string(&out, target); strings.write_string(&out, " HTTP/1.1\r\n")
	strings.write_string(&out, "Host: "); strings.write_string(&out, vite_host); strings.write_string(&out, ":"); strings.write_string(&out, fmt.tprintf("%d", vite_port)); strings.write_string(&out, "\r\n")
	for h in incoming {
		if ascii_equal_fold(h.name, "Host") || ascii_equal_fold(h.name, "Content-Length") || ascii_equal_fold(h.name, "Connection") do continue
		if is_ws && ascii_equal_fold(h.name, "Upgrade") do continue
		strings.write_string(&out, h.name); strings.write_string(&out, ": "); strings.write_string(&out, h.value); strings.write_string(&out, "\r\n")
	}
	if is_ws {
		strings.write_string(&out, "Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
	} else {
		strings.write_string(&out, fmt.tprintf("Content-Length: %d\r\nConnection: close\r\n\r\n", len(body)))
		strings.write_string(&out, body)
	}
	out_req := strings.to_string(out)
	_, send_err := net.send_tcp(upstream, transmute([]byte)out_req)
	if send_err != nil {
		write_response(client, 502, "Bad Gateway", "text/plain", "vite send failed")
		return
	}
	if is_ws {
		proxy_tunnel_bidirectional(client, upstream)
		return
	}
	proxy_copy_response(client, upstream)
}

send_all_tcp :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	total := 0
	for total < len(data) {
		sent, err := net.send_tcp(sock, data[total:])
		if err != nil || sent <= 0 do return false
		total += sent
	}
	return true
}

write_bytes_response_with_headers :: proc(client: net.TCP_Socket, status: int, status_text, content_type: string, data: []byte, headers: []contracts.HTTP_Header = nil) {
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n", status, status_text, content_type, len(data)))
	for h in headers {
		strings.write_string(&b, h.name); strings.write_string(&b, ": "); strings.write_string(&b, h.value); strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "Connection: close\r\n\r\n")
	hdr := strings.to_string(b)
	if send_all_tcp(client, transmute([]byte)hdr) {
		if len(data) > 0 {
			_ = send_all_tcp(client, data)
		}
	}
}

get_static_mime_type :: proc(filename: string) -> string {
	ext := filepath.ext(filename)
	ext = strings.to_lower(ext, context.temp_allocator)
	switch ext {
	case ".html", ".htm": return "text/html; charset=utf-8"
	case ".js", ".mjs": return "text/javascript; charset=utf-8"
	case ".css": return "text/css; charset=utf-8"
	case ".json", ".webmanifest", ".map": return "application/json; charset=utf-8"
	case ".svg": return "image/svg+xml"
	case ".png": return "image/png"
	case ".jpg", ".jpeg": return "image/jpeg"
	case ".gif": return "image/gif"
	case ".ico": return "image/x-icon"
	case ".woff": return "font/woff"
	case ".woff2": return "font/woff2"
	case ".ttf": return "font/ttf"
	case ".wasm": return "application/wasm"
	case ".txt": return "text/plain; charset=utf-8"
	case: return "application/octet-stream"
	}
}

hex_digit_val :: proc(c: byte) -> int {
	switch c {
	case '0'..='9': return int(c - '0')
	case 'a'..='f': return int(c - 'a' + 10)
	case 'A'..='F': return int(c - 'A' + 10)
	}
	return -1
}

url_decode_path :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			h1 := hex_digit_val(s[i + 1])
			h2 := hex_digit_val(s[i + 2])
			if h1 >= 0 && h2 >= 0 {
				strings.write_byte(&b, byte((h1 << 4) | h2))
				i += 3
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

serve_static_ui :: proc(client: net.TCP_Socket, static_dir, raw_path, method: string) -> bool {
	clean_dir := strings.trim_right(static_dir, "/")
	if clean_dir == "" do return false
	if !os.exists(clean_dir) || !os.is_dir(clean_dir) do return false

	if method != "GET" && method != "HEAD" {
		write_response(client, 405, "Method Not Allowed", "text/plain", "method not allowed")
		return true
	}

	decoded := url_decode_path(raw_path)
	rel := strings.trim_left(decoded, "/")
	if q := strings.index_byte(rel, '?'); q >= 0 do rel = rel[:q]
	if rel == "" do rel = "index.html"

	// Security: Prevent path traversal, null bytes, and absolute bypass
	if strings.contains(rel, "\x00") || strings.contains(rel, "..") || strings.has_prefix(rel, "/") {
		write_response(client, 403, "Forbidden", "text/plain", "access denied")
		return true
	}

	// Canonical path comparison: target must reside strictly within static_dir
	clean_dir_norm, _ := filepath.clean(clean_dir, context.temp_allocator)
	target_path, _ := filepath.join({clean_dir_norm, rel}, context.temp_allocator)
	target_path_clean, _ := filepath.clean(target_path, context.temp_allocator)
	clean_prefix := clean_dir_norm
	if !strings.has_suffix(clean_prefix, "/") {
		clean_prefix = fmt.tprintf("%s/", clean_dir_norm)
	}
	if target_path_clean != clean_dir_norm && !strings.has_prefix(target_path_clean, clean_prefix) {
		write_response(client, 403, "Forbidden", "text/plain", "access denied")
		return true
	}

	// Direct static file hit
	if os.exists(target_path_clean) && !os.is_dir(target_path_clean) {
		data, err := os.read_entire_file(target_path_clean, context.allocator)
		if err == nil {
			defer delete(data)
			mime := get_static_mime_type(target_path_clean)
			headers: [1]contracts.HTTP_Header
			hdr_slice: []contracts.HTTP_Header = nil
			if strings.has_prefix(rel, "assets/") {
				headers[0] = contracts.HTTP_Header{name = "Cache-Control", value = "public, max-age=31536000, immutable"}
				hdr_slice = headers[:]
			} else if rel == "index.html" {
				headers[0] = contracts.HTTP_Header{name = "Cache-Control", value = "no-cache"}
				hdr_slice = headers[:]
			}
			if method == "HEAD" {
				write_bytes_response_with_headers(client, 200, "OK", mime, nil, hdr_slice)
			} else {
				write_bytes_response_with_headers(client, 200, "OK", mime, data, hdr_slice)
			}
			return true
		}
	}

	// 404 for missing static assets under /assets/
	if strings.has_prefix(rel, "assets/") {
		write_response(client, 404, "Not Found", "text/plain", "asset not found")
		return true
	}

	// SPA fallback: Serve index.html for client-side routing
	index_path := fmt.tprintf("%s/index.html", clean_dir)
	if os.exists(index_path) && !os.is_dir(index_path) {
		data, err := os.read_entire_file(index_path, context.allocator)
		if err == nil {
			defer delete(data)
			headers := [1]contracts.HTTP_Header{{name = "Cache-Control", value = "no-cache"}}
			if method == "HEAD" {
				write_bytes_response_with_headers(client, 200, "OK", "text/html; charset=utf-8", nil, headers[:])
			} else {
				write_bytes_response_with_headers(client, 200, "OK", "text/html; charset=utf-8", data, headers[:])
			}
			return true
		}
	}

	return false
}

// proxy_tunnel_bidirectional pumps raw bytes in both directions between the
// browser and the hub after a WebSocket upgrade. The hub's `101 Switching
// Protocols` response (and all subsequent frames) flow through the
// upstream->client direction; browser frames flow client->upstream. No receive
// timeout: the tunnel stays open until either side closes/errs, then both are
// torn down. This is what the one-shot `proxy_copy_response` (5s timeout) could
// not do, which caused the user-ws to drop every 5s and the UI to reconnect and
// refetch in a loop.
Proxy_Tunnel_Half :: struct { src: net.TCP_Socket, dst: net.TCP_Socket }

proxy_tunnel_bidirectional :: proc(client, upstream: net.TCP_Socket) {
	// No read timeouts on either socket for the life of the tunnel. A zero
	// Duration disables the timeout; the value must be a time.Duration (a bare
	// literal 0 panics set_option).
	_ = net.set_option(client, .Receive_Timeout, time.Duration(0))
	_ = net.set_option(upstream, .Receive_Timeout, time.Duration(0))
	// Pump upstream -> client on a worker thread (fire-and-forget, matching the
	// codebase's thread pattern). Each direction, when it ends, closes BOTH
	// sockets — so whichever side closes first also unblocks the peer direction's
	// blocking recv, and both halves exit. (Double-close of an fd microseconds
	// apart is harmless for this local dev tool; net.close on a closed socket is
	// a no-op error.) The deferred net.close(upstream) in forward_request is a
	// backstop for the same fd.
	half := new(Proxy_Tunnel_Half)
	half.src = upstream; half.dst = client
	thread.run_with_poly_data(half, proxy_tunnel_pump)
	// Pump client -> upstream on this thread until either side closes.
	proxy_tunnel_copy(client, upstream)
}

proxy_tunnel_pump :: proc(half: ^Proxy_Tunnel_Half) {
	src := half.src
	dst := half.dst
	free(half)
	proxy_tunnel_copy(src, dst)
}

proxy_tunnel_copy :: proc(src, dst: net.TCP_Socket) {
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(src, buf[:])
		if recv_err != nil || n <= 0 do break
		_, send_err := net.send_tcp(dst, buf[:n])
		if send_err != nil do break
	}
	// End of this direction: close both so the peer direction unblocks and exits.
	net.close(src)
	net.close(dst)
}

proxy_copy_response :: proc(client, upstream: net.TCP_Socket) {
	// The hub sends Connection: close + Content-Length and closes when done, so
	// this read loop terminates on EOF. The timeout is only a backstop against a
	// truly stuck upstream. It must be generous: some endpoints (e.g. the
	// provider test, which may sequentially launch cheap/normal/smart agents and
	// wait for start-success on each tier) can take several minutes to respond. A
	// short timeout drops those responses mid-flight, leaving the UI stuck in a
	// Testing state while the Bridge keeps running the tests.
	_ = net.set_option(upstream, .Receive_Timeout, 16 * time.Minute)
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(upstream, buf[:])
		if recv_err != nil || n <= 0 do break
		_, send_err := net.send_tcp(client, buf[:n])
		if send_err != nil do break
	}
}

read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [8192]byte
	data := make([dynamic]byte, 0, 8192)
	for {
		n, recv_err := net.recv_tcp(client, buf[:])
		if recv_err != nil || n <= 0 do return "", false
		append(&data, ..buf[:n])
		raw := string(data[:])
		if request_complete(raw) do return strings.clone(raw), true
		if len(data) > 1024 * 1024 do return "", false
	}
}

request_complete :: proc(raw: string) -> bool {
	idx := strings.index(raw, "\r\n\r\n")
	if idx < 0 do return false
	return len(raw[idx + 4:]) >= content_length(raw[:idx])
}

content_length :: proc(headers: string) -> int {
	text := headers
	for line in strings.split_lines_iterator(&text) {
		if ascii_has_prefix_fold(line, "Content-Length:") {
			if parsed, ok := strconv.parse_int(strings.trim_space(line[len("Content-Length:"):])); ok do return int(parsed)
		}
	}
	return 0
}

request_method_target :: proc(request: string) -> (string, string) {
	line_end := strings.index(request, "\r\n")
	if line_end < 0 do return "", ""
	parts := strings.split(request[:line_end], " ")
	defer delete(parts)
	if len(parts) < 2 do return "", ""
	return strings.clone(parts[0]), strings.clone(parts[1])
}

split_target_query :: proc(target: string) -> (string, string) {
	idx := strings.index_byte(target, '?')
	if idx < 0 do return target, ""
	return target[:idx], target[idx + 1:]
}

query_param :: proc(query, name: string) -> string {
	pairs := strings.split(query, "&")
	defer delete(pairs)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		if eq < 0 do continue
		if pair[:eq] == name do return strings.clone(pair[eq + 1:])
	}
	return ""
}

parse_headers :: proc(request: string) -> []contracts.HTTP_Header {
	out := make([dynamic]contracts.HTTP_Header)
	head_end := strings.index(request, "\r\n\r\n")
	if head_end < 0 do return out[:]
	head := request[:head_end]
	first := true
	for line in strings.split_lines_iterator(&head) {
		if first { first = false; continue }
		colon := strings.index_byte(line, ':')
		if colon <= 0 do continue
		append(&out, contracts.HTTP_Header{name = strings.clone(strings.trim_space(line[:colon])), value = strings.clone(strings.trim_space(line[colon + 1:]))})
	}
	return out[:]
}

request_body :: proc(request: string) -> string {
	idx := strings.index(request, "\r\n\r\n")
	if idx < 0 do return ""
	return request[idx + 4:]
}

parse_base_url :: proc(url: string) -> (string, int, bool) {
	trimmed := strings.trim_space(url)
	if strings.has_prefix(trimmed, "http://") do trimmed = trimmed[len("http://"):]
	slash := strings.index_byte(trimmed, '/')
	if slash >= 0 do trimmed = trimmed[:slash]
	colon := strings.last_index_byte(trimmed, ':')
	if colon < 0 do return strings.clone(trimmed), 80, true
	port_i, ok := strconv.parse_int(trimmed[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(trimmed[:colon]), int(port_i), true
}

// is_loopback_host reports whether a parsed --listen host is loopback
// (127.0.0.1, ::1, localhost, or empty which defaults to loopback binding).
// Used to gate the management API/UI surface (DP-7).
is_loopback_host :: proc(host: string) -> bool {
	return host == "127.0.0.1" || host == "::1" || host == "localhost" || host == ""
}

split_host_port :: proc(value: string) -> (string, int, bool) {
	colon := strings.last_index_byte(value, ':')
	if colon < 0 do return "", 0, false
	port_i, ok := strconv.parse_int(value[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(value[:colon]), int(port_i), true
}

dev_user_exists :: proc(config: ^Dev_Proxy_Config, username: string) -> bool {
	for user in config.users {
		if user.username == username do return true
	}
	return false
}

write_response :: proc(client: net.TCP_Socket, status: int, status_text, content_type, body: string) {
	write_response_with_headers(client, status, status_text, content_type, body, nil)
}

write_response_with_headers :: proc(client: net.TCP_Socket, status: int, status_text, content_type, body: string, headers: []contracts.HTTP_Header) {
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n", status, status_text, content_type, len(body)))
	for h in headers {
		strings.write_string(&b, h.name); strings.write_string(&b, ": "); strings.write_string(&b, h.value); strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "Connection: close\r\n\r\n")
	strings.write_string(&b, body)
	response := strings.to_string(b)
	_, _ = net.send_tcp(client, transmute([]byte)response)
}

ascii_has_prefix_fold :: proc(value, prefix: string) -> bool {
	if len(value) < len(prefix) do return false
	return ascii_equal_fold(value[:len(prefix)], prefix)
}
