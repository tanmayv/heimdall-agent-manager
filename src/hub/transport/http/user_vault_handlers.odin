package http

import "core:fmt"
import "core:strconv"
import "core:strings"
import auth_service "odin_test:hub/service/auth"
import domain "odin_test:hub/domain"
import user_vault_service "odin_test:hub/service/user_vault"

User_Vault_Handlers :: struct {
	auth:       ^auth_service.Auth_Service,
	user_vault: ^user_vault_service.User_Vault_Service,
}

write_user_vault_json :: proc(b: ^strings.Builder, v: domain.User_Vault) {
	strings.write_string(b, "{\"user_id\":\"")
	write_handler_json_string(b, string(v.user_id))
	strings.write_string(b, "\",\"configured\":true")
	strings.write_string(b, ",\"encrypted_vault_key\":\"")
	write_handler_json_string(b, v.encrypted_vault_key)
	strings.write_string(b, "\",\"vault_key_nonce\":\"")
	write_handler_json_string(b, v.vault_key_nonce)
	strings.write_string(b, "\",\"vault_key_tag\":\"")
	write_handler_json_string(b, v.vault_key_tag)
	strings.write_string(b, "\",\"kdf_algorithm\":\"")
	write_handler_json_string(b, v.kdf_algorithm)
	strings.write_string(b, "\",\"kdf_salt\":\"")
	write_handler_json_string(b, v.kdf_salt)
	strings.write_string(b, "\",\"kdf_iterations\":")
	strings.write_string(b, fmt.tprintf("%d", v.kdf_iterations))
	strings.write_string(b, ",\"recovery_encrypted_vault_key\":\"")
	write_handler_json_string(b, v.recovery_encrypted_vault_key)
	strings.write_string(b, "\",\"recovery_nonce\":\"")
	write_handler_json_string(b, v.recovery_nonce)
	strings.write_string(b, "\",\"recovery_tag\":\"")
	write_handler_json_string(b, v.recovery_tag)
	strings.write_string(b, "\",\"recovery_salt\":\"")
	write_handler_json_string(b, v.recovery_salt)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, v.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, v.updated_at)
	strings.write_string(b, "\"}")
}

parse_vault_int :: proc(body, key: string, default_val: int) -> int {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return default_val
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return default_val
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 do return default_val
	if rest[0] == '"' {
		end := 1
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
		if end <= 1 do return default_val
		if p, ok := strconv.parse_int(rest[1:end]); ok do return int(p)
		return default_val
	}
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
	if end == 0 do return default_val
	if p, ok := strconv.parse_int(rest[:end]); ok do return int(p)
	return default_val
}

parse_vault_field :: proc(body, key: string) -> string {
	v := json_string(body, key)
	if v != "" do return v
	v = json_object_string(body, "envelope", key)
	if v != "" do return v
	return json_object_string(body, "vault", key)
}

// get_user_vault_handler serves GET /api/v1/user/vault (auth).
// Returns 200 with envelope and configured:true if configured, or 404 not_configured.
get_user_vault_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Vault_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp

	vault, found, err := user_vault_service.get_vault(handlers.user_vault, domain.User_ID(auth_ctx.user_id))
	if !found {
		return respond_error(err, req.request_id)
	}

	builder := strings.builder_make()
	write_user_vault_json(&builder, vault)
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}

// set_user_vault_handler serves POST /api/v1/user/vault (auth).
// Validates and persists client-encrypted vault envelopes and KDF parameters.
set_user_vault_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Vault_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp

	encrypted_vault_key := parse_vault_field(req.body, "encrypted_vault_key")
	vault_key_nonce := parse_vault_field(req.body, "vault_key_nonce")
	vault_key_tag := parse_vault_field(req.body, "vault_key_tag")
	kdf_algorithm := parse_vault_field(req.body, "kdf_algorithm")
	kdf_salt := parse_vault_field(req.body, "kdf_salt")
	kdf_iterations := parse_vault_int(req.body, "kdf_iterations", 0)
	if kdf_iterations == 0 {
		kdf_iterations = parse_vault_int(req.body, "iterations", 0)
	}
	if kdf_algorithm == "" {
		kdf_algorithm = "PBKDF2-SHA256"
	}
	if kdf_iterations <= 0 {
		kdf_iterations = 100000
	}
	recovery_encrypted_vault_key := parse_vault_field(req.body, "recovery_encrypted_vault_key")
	recovery_nonce := parse_vault_field(req.body, "recovery_nonce")
	recovery_tag := parse_vault_field(req.body, "recovery_tag")
	recovery_salt := parse_vault_field(req.body, "recovery_salt")

	saved, saved_ok, err := user_vault_service.set_vault(handlers.user_vault, domain.Set_User_Vault_Input{
		user_id                      = domain.User_ID(auth_ctx.user_id),
		encrypted_vault_key          = encrypted_vault_key,
		vault_key_nonce              = vault_key_nonce,
		vault_key_tag                = vault_key_tag,
		kdf_algorithm                = kdf_algorithm,
		kdf_salt                     = kdf_salt,
		kdf_iterations               = kdf_iterations,
		recovery_encrypted_vault_key = recovery_encrypted_vault_key,
		recovery_nonce               = recovery_nonce,
		recovery_tag                 = recovery_tag,
		recovery_salt                = recovery_salt,
	})
	if !saved_ok {
		return respond_error(err, req.request_id)
	}

	builder := strings.builder_make()
	write_user_vault_json(&builder, saved)
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}
