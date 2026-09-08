package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

// extract_uberproxy_identity extracts the caller username and email from ÜberProxy headers.
//
// Security & Transport Boundary Note:
// In Google Cloudtop single-node deployments, port 8989 ingress strictly relies on the Cloudtop GCE Enforcer
// firewall and corp network VPC perimeter to ensure ingress on port 8989 only originates from ÜberProxy
// (or local loopback) and drops untrusted direct intra-VPC connections.
// Because the ÜberProxy UpTick cryptographic signature is not verified in userland, network-level perimeter
// enforcement by Cloudtop GCE Enforcer is required to prevent header spoofing from arbitrary network nodes.
// ÜberProxy strips client-supplied headers and injects authoritative identity headers
// (X-UberProxy-User, X-UberProxy-User-Email, X-UberProxy-UpTick, X-UberProxy-Signed-UpTick).
//
// Priority order:
// 1. X-UberProxy-User / X-UberProxy-User-Email (Google internal ÜberProxy PEN headers)
// 2. X-UberProxy-UpTick / X-UberProxy-Signed-UpTick (Google internal ÜberProxy UpTick protobuf headers)
// 3. X-Goog-Authenticated-User-Email (GCP Cloud IAP, supporting accounts.google.com: prefix)
// 4. X-Forwarded-User (Reverse proxy fallback)
extract_uberproxy_identity :: proc(headers: []contracts.HTTP_Header) -> (username: string, email: string, found: bool) {
	// 1. Priority: X-UberProxy-User and X-UberProxy-User-Email
	uber_user := ""
	uber_email := ""
	for h in headers {
		if ascii_equal_fold(h.name, "X-UberProxy-User") && uber_user == "" {
			uber_user = strings.trim_space(h.value)
		} else if ascii_equal_fold(h.name, "X-UberProxy-User-Email") && uber_email == "" {
			uber_email = strings.trim_space(h.value)
		}
	}
	if uber_user != "" {
		if u, em, ok := parse_user_and_email(uber_user); ok do return u, em, true
	}
	if uber_email != "" {
		if u, em, ok := parse_user_and_email(uber_email); ok do return u, em, true
	}

	// 2. Priority: X-UberProxy-UpTick and X-UberProxy-Signed-UpTick
	for h in headers {
		if ascii_equal_fold(h.name, "X-UberProxy-UpTick") || ascii_equal_fold(h.name, "X-UberProxy-Signed-UpTick") {
			if email_str, ok := decode_uptick_email(h.value); ok {
				if u, em, pok := parse_user_and_email(email_str); pok do return u, em, true
			}
		}
	}

	// 3. Priority: X-Goog-Authenticated-User-Email
	for h in headers {
		if ascii_equal_fold(h.name, "X-Goog-Authenticated-User-Email") {
			if u, em, ok := parse_user_and_email(h.value); ok do return u, em, true
		}
	}

	// 4. Priority: X-Forwarded-User
	for h in headers {
		if ascii_equal_fold(h.name, "X-Forwarded-User") {
			if u, em, ok := parse_user_and_email(h.value); ok do return u, em, true
		}
	}

	return "", "", false
}

// decode_uptick_email extracts the email field from an X-UberProxy-UpTick or
// X-UberProxy-Signed-UpTick header (<base64_proto> or <base64_proto>.<signature>).
// In the uberproxy_proto.UpTick protobuf, field 2 is `email: string` (wire type 2).
decode_uptick_email :: proc(header_val: string, allocator := context.temp_allocator) -> (string, bool) {
	trimmed := strings.trim_space(header_val)
	if trimmed == "" do return "", false

	dot_idx := strings.index_byte(trimmed, '.')
	b64_part := trimmed
	if dot_idx >= 0 {
		b64_part = trimmed[:dot_idx]
	}
	b64_part = strings.trim_space(b64_part)
	if b64_part == "" do return "", false

	// Normalize base64url (- and _) to standard (+ and /)
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	for r in b64_part {
		switch r {
		case '-': strings.write_byte(&b, '+')
		case '_': strings.write_byte(&b, '/')
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/': strings.write_rune(&b, r)
		case '=': // will re-pad below
		case:
			return "", false
		}
	}
	norm_str := strings.to_string(b)
	padding := (4 - (len(norm_str) % 4)) % 4
	for _ in 0 ..< padding {
		strings.write_byte(&b, '=')
	}

	decoded_bytes, err := base64.decode(strings.to_string(b), base64.DEC_TABLE, allocator)
	if err != nil || len(decoded_bytes) == 0 {
		return "", false
	}

	// Parse protobuf wire format for UpTick message:
	offset := 0
	for offset < len(decoded_bytes) {
		tag: u64 = 0
		shift: u32 = 0
		for offset < len(decoded_bytes) {
			if shift >= 64 do return "", false
			byte_val := decoded_bytes[offset]
			offset += 1
			tag |= (u64(byte_val & 0x7F) << shift)
			shift += 7
			if (byte_val & 0x80) == 0 do break
		}
		field_num := tag >> 3
		wire_type := tag & 0x07

		if field_num == 2 && wire_type == 2 {
			length: u64 = 0
			shift = 0
			for offset < len(decoded_bytes) {
				if shift >= 64 do return "", false
				byte_val := decoded_bytes[offset]
				offset += 1
				length |= (u64(byte_val & 0x7F) << shift)
				shift += 7
				if (byte_val & 0x80) == 0 do break
			}
			bytes_len := u64(len(decoded_bytes))
			if u64(offset) <= bytes_len && length <= bytes_len - u64(offset) {
				email_slice := decoded_bytes[offset : offset + int(length)]
				return string(email_slice), true
			}
			return "", false
		}

		bytes_len := u64(len(decoded_bytes))
		switch wire_type {
		case 0: // varint
			for offset < len(decoded_bytes) {
				byte_val := decoded_bytes[offset]
				offset += 1
				if (byte_val & 0x80) == 0 do break
			}
		case 1: // 64-bit
			if u64(offset) > bytes_len || bytes_len - u64(offset) < 8 do return "", false
			offset += 8
		case 2: // length-delimited
			length: u64 = 0
			shift = 0
			for offset < len(decoded_bytes) {
				if shift >= 64 do return "", false
				byte_val := decoded_bytes[offset]
				offset += 1
				length |= (u64(byte_val & 0x7F) << shift)
				shift += 7
				if (byte_val & 0x80) == 0 do break
			}
			if u64(offset) > bytes_len || length > bytes_len - u64(offset) do return "", false
			offset += int(length)
		case 5: // 32-bit
			if u64(offset) > bytes_len || bytes_len - u64(offset) < 4 do return "", false
			offset += 4
		case:
			return "", false
		}
	}

	return "", false
}

parse_user_and_email :: proc(raw: string) -> (username: string, email: string, ok: bool) {
	cleaned := strings.trim_space(raw)
	if colon := strings.last_index_byte(cleaned, ':'); colon >= 0 {
		cleaned = cleaned[colon + 1:]
	}
	cleaned = strings.trim_space(cleaned)
	if cleaned == "" do return "", "", false

	uname := cleaned
	if at := strings.index_byte(cleaned, '@'); at >= 0 {
		uname = cleaned[:at]
	}
	uname = strings.trim_space(uname)
	if uname == "" do return "", "", false

	u := strings.to_lower(uname, context.temp_allocator)
	em := fmt.tprintf("%s@google.com", u)
	return u, em, true
}

// get_cloudtop_owner resolves the authoritative Cloudtop owner LDAP.
get_cloudtop_owner :: proc(config: ^Dev_Proxy_Config) -> string {
	if v := os.get_env("HAM_CLOUDTOP_OWNER", context.allocator); v != "" do return strings.to_lower(v, context.temp_allocator)
	if v := os.get_env("HEIMDALL_OWNER", context.allocator); v != "" do return strings.to_lower(v, context.temp_allocator)
	owner := os.get_env("USER", context.allocator)
	if owner == "" do owner = config.default_user
	if owner == "" do owner = "tanmayvijay"
	return strings.to_lower(owner, context.temp_allocator)
}

// is_allowed_host strictly validates that the Host header matches loopback, Google internal domains
// (*.google.com, *.googlers.com, *.proxy.googlers.com), or the machine hostname.
is_allowed_host :: proc(host_only: string) -> bool {
	h := strings.to_lower(host_only, context.temp_allocator)
	if is_loopback_host(h) do return true
	if h == "0.0.0.0" do return true
	if h == "google.com" || strings.has_suffix(h, ".google.com") do return true
	if h == "googlers.com" || strings.has_suffix(h, ".googlers.com") do return true
	if h == "proxy.googlers.com" || strings.has_suffix(h, ".proxy.googlers.com") do return true
	if hostname := os.get_env("HOSTNAME", context.allocator); hostname != "" && h == strings.to_lower(hostname, context.temp_allocator) do return true
	return false
}
