package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

// extract_uberproxy_identity extracts the caller username and email from ÜberProxy headers.
// Checks X-Goog-Authenticated-User-Email, X-Forwarded-User, and X-Remote-User.
extract_uberproxy_identity :: proc(headers: []contracts.HTTP_Header) -> (username: string, email: string, found: bool) {
	// 1. Check X-Goog-Authenticated-User-Email
	for h in headers {
		if ascii_equal_fold(h.name, "X-Goog-Authenticated-User-Email") {
			cleaned := strings.trim_space(h.value)
			if colon := strings.last_index_byte(cleaned, ':'); colon >= 0 {
				cleaned = cleaned[colon + 1:]
			}
			cleaned = strings.trim_space(cleaned)
			uname := cleaned
			if at := strings.index_byte(cleaned, '@'); at >= 0 {
				uname = cleaned[:at]
			}
			uname = strings.trim_space(uname)
			if uname == "" do continue
			em := cleaned
			if strings.index_byte(em, '@') < 0 {
				em = fmt.tprintf("%s@google.com", uname)
			}
			return strings.to_lower(uname, context.temp_allocator), strings.to_lower(em, context.temp_allocator), true
		}
	}

	// 2. Check X-Forwarded-User
	for h in headers {
		if ascii_equal_fold(h.name, "X-Forwarded-User") {
			cleaned := strings.trim_space(h.value)
			if colon := strings.last_index_byte(cleaned, ':'); colon >= 0 {
				cleaned = cleaned[colon + 1:]
			}
			cleaned = strings.trim_space(cleaned)
			uname := cleaned
			if at := strings.index_byte(cleaned, '@'); at >= 0 {
				uname = cleaned[:at]
			}
			uname = strings.trim_space(uname)
			if uname == "" do continue
			em := fmt.tprintf("%s@google.com", uname)
			return strings.to_lower(uname, context.temp_allocator), strings.to_lower(em, context.temp_allocator), true
		}
	}

	// 3. Check X-Remote-User
	for h in headers {
		if ascii_equal_fold(h.name, "X-Remote-User") {
			cleaned := strings.trim_space(h.value)
			if colon := strings.last_index_byte(cleaned, ':'); colon >= 0 {
				cleaned = cleaned[colon + 1:]
			}
			cleaned = strings.trim_space(cleaned)
			uname := cleaned
			if at := strings.index_byte(cleaned, '@'); at >= 0 {
				uname = cleaned[:at]
			}
			uname = strings.trim_space(uname)
			if uname == "" do continue
			em := fmt.tprintf("%s@google.com", uname)
			return strings.to_lower(uname, context.temp_allocator), strings.to_lower(em, context.temp_allocator), true
		}
	}

	return "", "", false
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

// is_allowed_host validates that the Host header matches loopback, Google internal domains,
// or verified ÜberProxy caller domains.
is_allowed_host :: proc(host_only: string, has_uberproxy: bool) -> bool {
	h := strings.to_lower(host_only, context.temp_allocator)
	if is_loopback_host(h) do return true
	if h == "0.0.0.0" do return true
	if strings.has_suffix(h, ".google.com") do return true
	if strings.has_suffix(h, ".googlers.com") do return true
	if has_uberproxy do return true
	if hostname := os.get_env("HOSTNAME", context.allocator); hostname != "" && h == strings.to_lower(hostname, context.temp_allocator) do return true
	return false
}
