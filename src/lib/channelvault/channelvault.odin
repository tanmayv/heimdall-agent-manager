package channelvault

import "core:crypto"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

Reply_Scope :: struct {
	owner_user_id, agent_instance_id, conversation_id, provider, binding_id: string,
	binding_generation: i64,
	input_message_id, reply_message_id: string,
}

reply_scope :: proc(r: contracts.Bot_Channel_Vault_Request) -> Reply_Scope {
	return {r.owner_user_id, r.agent_instance_id, r.conversation_id, r.provider, r.binding_id,
		r.binding_generation, r.input_message_id, r.reply_message_id}
}

valid_id :: proc(id: string) -> bool {
	return len(id) > 0 && len(id) <= 192 && vault.valid_id_value(id)
}

@(private)
reply_scope_valid :: proc(s: Reply_Scope) -> bool {
	return valid_id(s.owner_user_id) &&
	       valid_id(s.agent_instance_id) &&
	       valid_id(s.conversation_id) &&
	       (s.provider == "telegram" || s.provider == "whatsapp") &&
	       valid_id(s.binding_id) && s.binding_generation > 0 &&
	       valid_id(s.input_message_id) &&
	       valid_id(s.reply_message_id) && s.input_message_id != s.reply_message_id
}

@(private)
proof_data :: proc(scope: Reply_Scope, token: string) -> ([]byte, bool) {
	record := struct {
		purpose: string,
		scope: Reply_Scope,
		token_sha256: string,
	}{
		"heimdall-bot-author-reply-v1",
		scope,
		contracts.bot_channel_vault_sha256_hex(transmute([]byte)token, context.temp_allocator),
	}
	raw, err := json.marshal(record, allocator = context.temp_allocator)
	return raw, err == nil
}

@(private)
proof_key :: proc(key: []byte) -> (derived: [32]byte) {
	label: string = "heimdall-bot-author-proof-key-v1"
	hmac.sum(.SHA256, derived[:], transmute([]byte)label, key)
	return
}

// For the trusted author path only, after it has resolved a consumed inbound
// row and immutable destination. This is not a Hub frame handler. Generate the
// ordinary chat envelope and the companion proof together, from authored text.
seal_authored :: proc(scope: Reply_Scope, plaintext: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (token, source_proof: string, ok: bool) {
	if !reply_scope_valid(scope) || kr == nil || !vault.keyring_validate(kr) ||
	   vault.keyring_user_id(kr) != scope.owner_user_id || len(plaintext) == 0 ||
	   len(plaintext) > contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT || !utf8.valid_string(plaintext) {return "", "", false}
	key, have_key := vault.keyring_current_key(kr)
	if !have_key do return "", "", false
	sealed, sealed_ok := vault.seal_string(plaintext, kr, allocator)
	if !sealed_ok do return "", "", false
	raw, data_ok := proof_data(scope, sealed)
	if !data_ok {delete(sealed, allocator); return "", "", false}
	tag: [32]byte
	defer crypto.zero_explicit(&tag, size_of(tag))
	derived := proof_key(key)
	defer crypto.zero_explicit(&derived, size_of(derived))
	hmac.sum(.SHA256, tag[:], raw, derived[:])
	return sealed, string(hex.encode(tag[:], allocator)), true
}

@(private)
metadata_valid :: proc(r: contracts.Bot_Channel_Vault_Request) -> bool {
	if r.type != contracts.BOT_CHANNEL_VAULT_REQUEST_FRAME ||
	   !valid_id(r.request_id) || !valid_id(r.bridge_id) ||
	   !valid_id(r.owner_user_id) || !valid_id(r.agent_instance_id) ||
	   !valid_id(r.conversation_id) || !valid_id(r.binding_id) ||
	   r.activation_generation < 1 || r.binding_generation < 1 || r.vault_epoch == 0 ||
	   (r.provider != "telegram" && r.provider != "whatsapp") {return false}
	switch r.operation {
	case "seal","seal_media":
		return len(r.provider_event_id) > 0 && len(r.provider_event_id) <= 512 &&
		       utf8.valid_string(r.provider_event_id) && r.reply_message_id == "" && r.source_proof == "" &&
		       ((r.operation=="seal" && r.input_message_id=="") || valid_id(r.input_message_id))
	case "open":
		return r.provider_event_id == "" && len(r.source_proof) == 64 &&
		       reply_scope_valid(reply_scope(r))
	case:
		return false
	}
}

// Hub never grants more than MAX_AGE_MS. Permit a small negative bridge
// clock skew for receipt, without accepting anything past its deadline.
@(private)
CLOCK_SKEW_MS :: 500

// Caller owns the returned body. Every error has a fixed label and no payload.
convert :: proc(r: contracts.Bot_Channel_Vault_Request, daemon_id: string, now_ms: i64, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (body, status: string) {
	if !metadata_valid(r) do return "", "invalid_request"
	digest, digest_ok := contracts.bot_channel_vault_scope_digest(r, context.temp_allocator)
	if !digest_ok || digest != r.scope_digest do return "", "invalid_request"
	if daemon_id == "" || r.bridge_id != daemon_id || r.expires_at_ms <= now_ms ||
	   r.expires_at_ms > now_ms + contracts.BOT_CHANNEL_VAULT_MAX_AGE_MS + CLOCK_SKEW_MS {return "", "stale_placement"}
	vid, vid_ok := vault.vault_id_from_hex(r.vault_id)
	if !vid_ok do return "", "invalid_request"
	if kr == nil || !vault.keyring_validate(kr) do return "", "vault_locked"
	if vault.keyring_user_id(kr) != r.owner_user_id || kr.vault_id != vid do return "", "owner_mismatch"
	if kr.current_epoch != r.vault_epoch do return "", "key_unavailable"
	max_body := contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT if contracts.bot_channel_vault_seals(r.operation) else contracts.BOT_CHANNEL_VAULT_MAX_TOKEN
	if len(r.body) == 0 || len(r.body) > ((max_body + 2) / 3) * 4 do return "", "invalid_request"
	decoded, decode_err := base64.decode(r.body, allocator = context.temp_allocator)
	defer wipe(string(decoded))
	if decode_err != nil || len(decoded) == 0 do return "", "invalid_request"

	if contracts.bot_channel_vault_seals(r.operation) {
		if len(decoded) > contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT || (r.operation=="seal" && !utf8.valid_string(string(decoded))) {
			return "", "invalid_request"
		}
		sealed, ok := vault.seal(decoded, kr, allocator)
		return sealed, "ok" if ok else "key_unavailable"
	}

	token := string(decoded)
	if len(token) > contracts.BOT_CHANNEL_VAULT_MAX_TOKEN do return "", "invalid_scope"
	token_vault, token_epoch, _, parsed := vault.envelope_header(token)
	if parsed != .Ok || token_vault != kr.vault_id do return "", "invalid_scope"
	key, have_key := vault.keyring_key_for_epoch(kr, token_epoch)
	if !have_key do return "", "key_unavailable"
	tag, decoded_tag := hex.decode(transmute([]byte)r.source_proof, context.temp_allocator)
	defer wipe(string(tag))
	if !decoded_tag || len(tag) != 32 do return "", "invalid_scope"
	record, proof_data_ok := proof_data(reply_scope(r), token)
	derived := proof_key(key)
	defer crypto.zero_explicit(&derived, size_of(derived))
	if !proof_data_ok || !hmac.verify(.SHA256, tag, record, derived[:]) do return "", "invalid_scope"
	plain, opened := vault.open(token, kr, allocator)
	if opened != .Ok || len(plain) == 0 || len(plain) > contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT || !utf8.valid_string(plain) {
		wipe(plain)
		delete(plain, allocator)
		return "", "invalid_scope"
	}
	return plain, "ok"
}

wipe :: proc(text: string) {
	if len(text) > 0 do crypto.zero_explicit(raw_data(text), len(text))
}
