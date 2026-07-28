package auth

import "core:crypto/legacy/sha1"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import user_service "odin_test:hub/service/user"

Trusted_Proxy_Config :: struct {
	username_header: string,
	display_name_header: string,
	email_header: string,
	trusted_proxy_cidrs: []string,
	auto_provision_users: bool,
	login_url: string,
	logout_url: string,
}

Auth_Service :: struct {
	config: Trusted_Proxy_Config,
	users: ^user_service.User_Service,
	user_tokens: ^iface.User_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
}

Issue_User_API_Token_Input :: struct {
	owner_user_id: domain.User_ID,
	label: string,
	expires_at: string,
}

Issue_User_API_Token_Result :: struct {
	token: domain.User_API_Token,
	plaintext: string,
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

new_auth_service_with_tokens :: proc(config: Trusted_Proxy_Config, users: ^user_service.User_Service, user_tokens: ^iface.User_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Auth_Service {
	return Auth_Service{config = config, users = users, user_tokens = user_tokens, clock = clock, ids = ids}
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
		if strings.has_prefix(token, "hut_") do return verify_user_api_token(service, token)
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "unsupported bearer token")
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

issue_user_api_token :: proc(service: ^Auth_Service, input: Issue_User_API_Token_Input) -> (Issue_User_API_Token_Result, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.user_tokens == nil || service.clock == nil || service.ids == nil do return Issue_User_API_Token_Result{}, false, domain.domain_error(.Internal_Error, "user token service is not configured")
	owner_id := domain.User_ID(user_service.normalize_user_id(string(input.owner_user_id)))
	if string(owner_id) == "" do return Issue_User_API_Token_Result{}, false, domain.domain_error(.Validation_Failed, "user_id is required")
	// Explicit user creation: token issuance no longer auto-creates users. The
	// user must already exist (created via `ham-hub users create` or trusted-proxy
	// provisioning); otherwise issue fails with a clear error.
	_, user_ok, user_err := user_service.get_user(service.users, owner_id)
	if !user_ok do return Issue_User_API_Token_Result{}, false, user_err
	// Multiple active user tokens are allowed. Each Electron/device install can keep
	// its own token and be revoked independently.
	plaintext := platform.generate_id(service.ids, "hut_")
	now := platform.clock_now(service.clock)
	token := domain.User_API_Token{token_id = platform.generate_id(service.ids, "utok_"), owner_user_id = owner_id, label = strings.trim_space(input.label), token_hash = hash_user_api_token(plaintext), created_at = now, updated_at = now, expires_at = input.expires_at, created_from = "operator"}
	saved, saved_ok, save_err := iface.user_token_save(service.user_tokens, token)
	if !saved_ok do return Issue_User_API_Token_Result{}, false, save_err
	return Issue_User_API_Token_Result{token = saved, plaintext = plaintext}, true, domain.Domain_Error{}
}

// issue_device_authorization_token issues a user API token via the device
// authorization flow (ELDA-4). Like manual user-token issuance, it imposes no
// per-user cap, so a user can authorize multiple devices and keep all their
// tokens active. It stamps created_from='device_authorization' and records the
// device_label for provenance. `owner` is the Auth_Context.user_id bound at
// approve time (never client-supplied). Returns (token, plaintext, ok, err).
issue_device_authorization_token :: proc(service: ^Auth_Service, owner: domain.User_ID, device_label: string) -> (domain.User_API_Token, string, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.user_tokens == nil || service.clock == nil || service.ids == nil do return domain.User_API_Token{}, "", false, domain.domain_error(.Internal_Error, "user token service is not configured")
	owner_id := domain.User_ID(user_service.normalize_user_id(string(owner)))
	if string(owner_id) == "" do return domain.User_API_Token{}, "", false, domain.domain_error(.Validation_Failed, "user_id is required")
	// The owner must already exist (trusted-proxy provisioned or `users create`).
	_, user_ok, user_err := user_service.get_user(service.users, owner_id)
	if !user_ok do return domain.User_API_Token{}, "", false, user_err
	// Intentionally NO revoke_active_user_tokens here: multiple device tokens
	// per user are allowed (ELDA-4 no-cap).
	plaintext := platform.generate_id(service.ids, "hut_")
	now := platform.clock_now(service.clock)
	token := domain.User_API_Token{
		token_id = platform.generate_id(service.ids, "utok_"),
		owner_user_id = owner_id,
		label = strings.trim_space(device_label),
		token_hash = hash_user_api_token(plaintext),
		created_at = now,
		updated_at = now,
		created_from = "device_authorization",
		device_label = strings.trim_space(device_label),
	}
	saved, saved_ok, save_err := iface.user_token_save(service.user_tokens, token)
	if !saved_ok do return domain.User_API_Token{}, "", false, save_err
	return saved, plaintext, true, domain.Domain_Error{}
}

// revoke_active_user_tokens revokes every non-revoked token owned by user_id.
// Kept for administrative cleanup flows; normal issuance allows multiple active
// user/device tokens per user.
revoke_active_user_tokens :: proc(service: ^Auth_Service, owner_id: domain.User_ID) {
	if service == nil || service.user_tokens == nil || service.clock == nil do return
	tokens, list_err := iface.user_token_list_by_owner(service.user_tokens, owner_id)
	if list_err.code != .None do return
	now := platform.clock_now(service.clock)
	for i in 0..<len(tokens) {
		if tokens[i].revoked_at != "" do continue
		tokens[i].revoked_at = now
		tokens[i].updated_at = now
		_, _, _ = iface.user_token_save(service.user_tokens, tokens[i])
	}
}

list_user_api_tokens :: proc(service: ^Auth_Service, owner_user_id: domain.User_ID) -> ([]domain.User_API_Token, domain.Domain_Error) {
	if service == nil || service.user_tokens == nil do return nil, domain.domain_error(.Internal_Error, "user token service is not configured")
	owner_id := domain.User_ID(user_service.normalize_user_id(string(owner_user_id)))
	if string(owner_id) == "" do return nil, domain.domain_error(.Validation_Failed, "user_id is required")
	return iface.user_token_list_by_owner(service.user_tokens, owner_id)
}

revoke_user_api_token :: proc(service: ^Auth_Service, token_id: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	if service == nil || service.user_tokens == nil || service.clock == nil do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "user token service is not configured")
	token, ok, err := iface.user_token_get_by_id(service.user_tokens, token_id)
	if !ok do return domain.User_API_Token{}, false, err
	if token.revoked_at != "" do return token, true, domain.Domain_Error{}
	now := platform.clock_now(service.clock)
	token.revoked_at = now
	token.updated_at = now
	return iface.user_token_save(service.user_tokens, token)
}

revoke_user_api_token_for_owner :: proc(service: ^Auth_Service, owner_user_id: domain.User_ID, token_id: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	if service == nil || service.user_tokens == nil || service.clock == nil do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "user token service is not configured")
	owner_id := domain.User_ID(user_service.normalize_user_id(string(owner_user_id)))
	if string(owner_id) == "" do return domain.User_API_Token{}, false, domain.domain_error(.Validation_Failed, "user_id is required")
	token, ok, err := iface.user_token_get_by_id(service.user_tokens, token_id)
	if !ok do return domain.User_API_Token{}, false, err
	if token.owner_user_id != owner_id do return domain.User_API_Token{}, false, domain.domain_error(.Not_Found, "user token not found")
	if token.revoked_at != "" do return token, true, domain.Domain_Error{}
	now := platform.clock_now(service.clock)
	token.revoked_at = now
	token.updated_at = now
	return iface.user_token_save(service.user_tokens, token)
}

verify_user_api_token :: proc(service: ^Auth_Service, plaintext: string) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.user_tokens == nil do return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "user bearer tokens are not configured")
	token, token_ok, token_err := iface.user_token_get_by_hash(service.user_tokens, hash_user_api_token(plaintext))
	if !token_ok {
		_ = token_err
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "user bearer token is invalid")
	}
	if token.revoked_at != "" do return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "user bearer token is revoked")
	now := ""
	if service.clock != nil do now = platform.clock_now(service.clock)
	if token.expires_at != "" && now != "" && token.expires_at <= now do return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "user bearer token has expired")
	user, user_ok, user_err := user_service.get_user(service.users, token.owner_user_id)
	if !user_ok {
		_ = user_err
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "user bearer token owner is unavailable")
	}
	if user.status == .Disabled do return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "user is disabled")
	if now != "" {
		token.last_used_at = now
		token.updated_at = now
		_, _, _ = iface.user_token_save(service.user_tokens, token)
	}
	return contracts.Auth_Context{kind = .User_Token, user_id = string(user.user_id), name = user.name, display_name = user.display_name, email = user.email}, true, domain.Domain_Error{}
}

hash_user_api_token :: proc(token: string) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)token)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	builder := strings.builder_make()
	strings.write_string(&builder, "sha1:")
	for b in digest do write_hex_byte(&builder, b)
	return strings.to_string(builder)
}

write_hex_byte :: proc(builder: ^strings.Builder, value: byte) {
	strings.write_byte(builder, hex_digit(value >> 4))
	strings.write_byte(builder, hex_digit(value & 0x0f))
}

hex_digit :: proc(n: byte) -> byte {
	if n < 10 do return '0' + n
	return 'a' + (n - 10)
}

login_url :: proc(service: ^Auth_Service) -> string {
	if service == nil do return ""
	return service.config.login_url
}

logout_url :: proc(service: ^Auth_Service) -> string {
	if service == nil do return ""
	return service.config.logout_url
}

token_in_query_or_body :: proc(query, body: string) -> bool {
	if query_param_present(query, "token") || query_param_present(query, "access_token") || query_param_present(query, "agent_token") || query_param_present(query, "user_token") || query_param_present(query, "client_token") do return true
	if json_key_present(body, "token") || json_key_present(body, "access_token") || json_key_present(body, "agent_token") || json_key_present(body, "user_token") || json_key_present(body, "client_token") do return true
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
