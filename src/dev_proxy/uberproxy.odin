package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

// extract_uberproxy_identity extracts the caller username and email from ÜberProxy headers.
// Priority order:
// 1. X-UberProxy-User / X-UberProxy-User-Email (Google internal ÜberProxy PEN headers)
// 2. X-Goog-Authenticated-User-Email (GCP Cloud IAP, supporting accounts.google.com: prefix)
// 3. X-Forwarded-User (Reverse proxy fallback)
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

	// 2. Priority: X-Goog-Authenticated-User-Email
	for h in headers {
		if ascii_equal_fold(h.name, "X-Goog-Authenticated-User-Email") {
			if u, em, ok := parse_user_and_email(h.value); ok do return u, em, true
		}
	}

	// 3. Priority: X-Forwarded-User
	for h in headers {
		if ascii_equal_fold(h.name, "X-Forwarded-User") {
			if u, em, ok := parse_user_and_email(h.value); ok do return u, em, true
		}
	}

	return "", "", false
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
