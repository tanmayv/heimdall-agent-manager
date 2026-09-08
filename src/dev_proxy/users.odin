package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

Dev_User :: struct {
	username: string,
	display_name: string,
	email: string,
}

Dev_Proxy_Config :: struct {
	listen: string,
	hub_url: string,
	username_header: string,
	display_name_header: string,
	email_header: string,
	default_user: string,
	users: []Dev_User,
	proxy_secret: string,
	proxy_secret_file: string,
	audit_mode: bool,
	// DP-7: management API/UI (/_dev/*) are served ONLY on a loopback bind.
	// Set in main() from the parsed --listen host; non-loopback binds get 404
	// on every /_dev/ route so management is never exposed remotely.
	management_enabled: bool,
}

default_dev_proxy_config :: proc() -> Dev_Proxy_Config {
	current_user := os.get_env("HAM_DEV_PROXY_DEFAULT_USER", context.allocator)
	if current_user == "" {
		current_user = os.get_env("USER", context.allocator)
	}
	if current_user == "" do current_user = "user"

	users := make([]Dev_User, 4)
	users[0] = Dev_User{username = current_user, display_name = current_user, email = fmt.tprintf("%s@google.com", current_user)}
	users[1] = Dev_User{username = "tanmay", display_name = "Tanmay", email = "tanmay@example.com"}
	users[2] = Dev_User{username = "tanmayvijay", display_name = "Tanmay Vijayvargiya", email = "tanmayvijay@google.com"}
	users[3] = Dev_User{username = "reviewer", display_name = "Reviewer User", email = "reviewer@example.com"}
	return Dev_Proxy_Config{
		listen = "127.0.0.1:8080",
		hub_url = "http://127.0.0.1:49322",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		default_user = current_user,
		users = users,
	}
}

select_dev_user :: proc(config: ^Dev_Proxy_Config, headers: []contracts.HTTP_Header, cookie_header: string) -> (Dev_User, bool) {
	selected := header_value(headers, "X-Dev-User")
	if selected == "" do selected = cookie_value(cookie_header, "ham_dev_user")
	if selected == "" {
		if config.audit_mode {
			selected = "reviewer"
		} else {
			selected = config.default_user
		}
	}
	for user in config.users {
		if user.username == selected do return user, true
	}
	// Fallback in audit mode if "reviewer" is not found in custom roster
	if config.audit_mode && len(config.users) > 0 {
		for user in config.users {
			if user.username == config.default_user do return user, true
		}
		return config.users[0], true
	}
	return Dev_User{}, false
}

cookie_value :: proc(cookie_header, name: string) -> string {
	parts := strings.split(cookie_header, ";")
	defer delete(parts)
	for part in parts {
		trimmed := strings.trim_space(part)
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 do continue
		if trimmed[:eq] == name do return strings.clone(trimmed[eq + 1:])
	}
	return ""
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if ascii_equal_fold(h.name, name) do return strings.trim_space(h.value)
	}
	return ""
}

ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' do ca += 32
		if cb >= 'A' && cb <= 'Z' do cb += 32
		if ca != cb do return false
	}
	return true
}
