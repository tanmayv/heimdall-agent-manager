package http_client

import "core:strings"
import "core:testing"

// build_http_request must emit exactly one Host header, and honor
// include_port_in_host so the Web Push client can match reference clients
// (RFC 7230: the default :443/:80 port is omitted from the authority).

@(test)
build_http_request_includes_port_by_default :: proc(t: ^testing.T) {
	req := build_http_request("POST", "web.push.apple.com", 443, "/push/v2/abc", "body", nil)
	defer delete(req)
	testing.expect(t, strings.contains(req, "\r\nHost: web.push.apple.com:443\r\n"),
		"default Host header must keep host:port (existing behavior)")
	// Exactly one Host header.
	testing.expect_value(t, strings.count(req, "\r\nHost:"), 1)
}

@(test)
build_http_request_omits_default_port_when_requested :: proc(t: ^testing.T) {
	req := build_http_request("POST", "web.push.apple.com", 443, "/push/v2/abc", "body", nil, false)
	defer delete(req)
	testing.expect(t, strings.contains(req, "\r\nHost: web.push.apple.com\r\n"),
		"Host must be the bare authority when include_port_in_host=false")
	testing.expect(t, !strings.contains(req, "web.push.apple.com:443"),
		"the :443 default port must not appear anywhere")
	testing.expect_value(t, strings.count(req, "\r\nHost:"), 1)
}

@(test)
build_http_request_request_line_and_single_content_type :: proc(t: ^testing.T) {
	// A caller-supplied Content-Type must not be duplicated by the default.
	hdrs := []Header{{name = "Content-Type", value = "application/octet-stream"}}
	req := build_http_request("POST", "web.push.apple.com", 443, "/p", "x", hdrs, false)
	defer delete(req)
	testing.expect(t, strings.has_prefix(req, "POST /p HTTP/1.1\r\n"))
	testing.expect_value(t, strings.count(req, "Content-Type:"), 1)
	testing.expect(t, strings.contains(req, "Content-Length: 1\r\n"))
}
