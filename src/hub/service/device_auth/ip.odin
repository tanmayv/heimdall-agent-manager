// Trusted-X-Forwarded-For client-IP resolver (ELDA-6).
//
// resolve_client_ip determines the real client IP for a request:
//   - If the TCP peer (remote_addr) is inside a trusted-proxy CIDR, the request
//     arrived via the trusted reverse proxy, so we trust X-Forwarded-For and
//     take its FIRST hop (the original client). This is how the dev proxy and
//     any configured outpost deliver the true client IP.
//   - Otherwise the TCP peer IS the client; X-Forwarded-For is attacker-
//     controlled and MUST be ignored (spoofing protection — AC4).
//
// The trusted-proxy check reuses auth_service.remote_addr_trusted / strip_port
// so CIDR matching stays consistent with the existing trusted-proxy auth path.

package device_auth

import "core:strings"
import auth_service "odin_test:hub/service/auth"

// resolve_client_ip returns the effective client IP for rate-limiting and grant
// attribution. `remote_addr` is the TCP peer ("host:port" or "host");
// `xff_header` is the raw X-Forwarded-For header value (may be empty);
// `trusted_cidrs` is the configured list of trusted-proxy CIDRs.
resolve_client_ip :: proc(remote_addr, xff_header: string, trusted_cidrs: []string) -> string {
	if remote_addr == "" do return ""
	// Only trust XFF when the TCP peer is itself a trusted proxy.
	if auth_service.remote_addr_trusted(remote_addr, trusted_cidrs) {
		first := first_xff_hop(xff_header)
		if first != "" do return first
	}
	// Untrusted peer (or no XFF): the peer is the client. Strip the port.
	return auth_service.strip_port(remote_addr)
}

// first_xff_hop returns the trimmed first entry of an X-Forwarded-For header
// (the leftmost, original client). Returns "" if the header is empty/blank.
// XFF format: "client, proxy1, proxy2" — we want "client".
first_xff_hop :: proc(xff_header: string) -> string {
	if xff_header == "" do return ""
	trimmed := strings.trim_space(xff_header)
	if trimmed == "" do return ""
	comma := strings.index_byte(trimmed, ',')
	if comma < 0 do return strings.trim_space(trimmed)
	return strings.trim_space(trimmed[:comma])
}
