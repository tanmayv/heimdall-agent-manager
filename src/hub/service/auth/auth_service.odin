package auth

import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import user_service "odin_test:hub/service/user"

Trusted_Proxy_Config :: struct {
	username_header: string,
	display_name_header: string,
	email_header: string,
	trusted_proxy_cidrs: []string,
	auto_provision_users: bool,
	logout_url: string,
}

Auth_Service :: struct {
	config: Trusted_Proxy_Config,
	users: ^user_service.User_Service,
}

Auth_Request :: struct {
	remote_addr: string,
	query: string,
	body: string,
	headers: []contracts.HTTP_Header,
}

new_auth_service :: proc(config: Trusted_Proxy_Config, users: ^user_service.User_Service) -> Auth_Service {
	return Auth_Service{config = config, users = users}
}

resolve_auth :: proc(service: ^Auth_Service, req: Auth_Request) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	if service == nil || service.users == nil {
		return contracts.Auth_Context{}, false, domain.domain_error(.Internal_Error, "auth service is not configured")
	}
	if token_in_query_or_body(req.query, req.body) {
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bearer tokens must use the Authorization header")
	}
	authz := header_value(req.headers, "Authorization")
	if authz != "" && strings.has_prefix(authz, "Bearer ") {
		token := strings.trim_space(authz[len("Bearer "):])
		if strings.has_prefix(token, "hbr_") do return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "bridge token cannot call user APIs")
		if strings.has_prefix(token, "hbe_") do return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "enrollment token cannot call user APIs")
		// User API token storage/scopes are post-v1 for this phase. The important
		// HBR-7 property is that tokens are accepted only from this header path.
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "user bearer tokens are not configured")
	}
	if !remote_addr_trusted(req.remote_addr, service.config.trusted_proxy_cidrs) {
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "request did not come from a trusted proxy")
	}
	username := header_value(req.headers, service.config.username_header)
	if strings.trim_space(username) == "" {
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "trusted proxy username header is missing")
	}
	display_name := header_value(req.headers, service.config.display_name_header)
	email := header_value(req.headers, service.config.email_header)
	user, ok, err := user_service.ensure_user_from_auth(service.users, username, display_name, email, service.config.auto_provision_users)
	if !ok do return contracts.Auth_Context{}, false, err
	return contracts.Auth_Context{
		kind = .Trusted_Proxy,
		user_id = string(user.user_id),
		name = user.name,
		display_name = user.display_name,
		email = user.email,
	}, true, domain.Domain_Error{}
}

logout_url :: proc(service: ^Auth_Service) -> string {
	if service == nil do return ""
	return service.config.logout_url
}

token_in_query_or_body :: proc(query, body: string) -> bool {
	if query_param_present(query, "token") || query_param_present(query, "access_token") || query_param_present(query, "agent_token") do return true
	if json_key_present(body, "token") || json_key_present(body, "access_token") || json_key_present(body, "agent_token") do return true
	return false
}

query_param_present :: proc(query, name: string) -> bool {
	if query == "" do return false
	pairs := strings.split(query, "&")
	defer delete(pairs)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		key := pair
		if eq >= 0 do key = pair[:eq]
		if key == name do return true
	}
	return false
}

json_key_present :: proc(body, key: string) -> bool {
	if body == "" do return false
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	return strings.contains(body, needle)
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if ascii_equal_fold(h.name, name) do return strings.trim_space(h.value)
	}
	return ""
}

remote_addr_trusted :: proc(remote_addr: string, cidrs: []string) -> bool {
	ip := strip_port(remote_addr)
	if ip == "" do return false
	for cidr in cidrs {
		if cidr_matches(ip, strings.trim_space(cidr)) do return true
	}
	return false
}

strip_port :: proc(remote_addr: string) -> string {
	addr := strings.trim_space(remote_addr)
	if addr == "" do return ""
	colon := strings.last_index_byte(addr, ':')
	if colon > 0 && count_byte(addr, ':') == 1 {
		return addr[:colon]
	}
	return addr
}

count_byte :: proc(value: string, needle: byte) -> int {
	count := 0
	for ch in value {
		if ch == rune(needle) do count += 1
	}
	return count
}

cidr_matches :: proc(ip, cidr: string) -> bool {
	if cidr == "" do return false
	slash := strings.index_byte(cidr, '/')
	if slash < 0 do return ip == cidr
	base := cidr[:slash]
	prefix_len_i, ok := strconv.parse_int(cidr[slash + 1:])
	if !ok do return false
	prefix_len := int(prefix_len_i)
	ip_num, ip_ok := ipv4_to_u32(ip)
	base_num, base_ok := ipv4_to_u32(base)
	if !ip_ok || !base_ok || prefix_len < 0 || prefix_len > 32 do return false
	if prefix_len == 0 do return true
	mask := u32(0xffffffff) << u32(32 - prefix_len)
	return (ip_num & mask) == (base_num & mask)
}

ipv4_to_u32 :: proc(ip: string) -> (u32, bool) {
	parts := strings.split(ip, ".")
	defer delete(parts)
	if len(parts) != 4 do return 0, false
	result: u32 = 0
	for part in parts {
		value_i, ok := strconv.parse_int(part)
		if !ok || value_i < 0 || value_i > 255 do return 0, false
		result = (result << 8) | u32(value_i)
	}
	return result, true
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
