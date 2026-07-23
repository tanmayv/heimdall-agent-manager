package main

import "core:strings"
import contracts "odin_test:contracts"

rewrite_headers_for_hub :: proc(config: ^Dev_Proxy_Config, incoming: []contracts.HTTP_Header, cookie_header: string) -> ([]contracts.HTTP_Header, bool) {
	user, ok := select_dev_user(config, incoming, cookie_header)
	if !ok do return nil, false
	out := make([dynamic]contracts.HTTP_Header)
	// Forward everything except spoofable trusted/dev selector headers unchanged, including Authorization: Bearer ...
	for header in incoming {
		if is_client_control_header(header.name, config) do continue
		append(&out, contracts.HTTP_Header{name = strings.clone(header.name), value = strings.clone(header.value)})
	}
	append(&out, contracts.HTTP_Header{name = strings.clone(config.username_header), value = strings.clone(user.username)})
	append(&out, contracts.HTTP_Header{name = strings.clone(config.display_name_header), value = strings.clone(user.display_name)})
	append(&out, contracts.HTTP_Header{name = strings.clone(config.email_header), value = strings.clone(user.email)})
	return out[:], true
}

free_headers :: proc(headers: []contracts.HTTP_Header) {
	for h in headers {
		delete(h.name)
		delete(h.value)
	}
	delete(headers)
}

is_client_control_header :: proc(name: string, config: ^Dev_Proxy_Config) -> bool {
	if ascii_equal_fold(name, config.username_header) do return true
	if ascii_equal_fold(name, config.display_name_header) do return true
	if ascii_equal_fold(name, config.email_header) do return true
	if ascii_equal_fold(name, "X-Dev-User") do return true
	return false
}

login_response_cookie :: proc(username: string) -> string {
	return strings.concatenate({"ham_dev_user=", username, "; Path=/; SameSite=Lax"})
}

logout_response_cookie :: proc() -> string {
	return "ham_dev_user=; Path=/; Max-Age=0; SameSite=Lax"
}
