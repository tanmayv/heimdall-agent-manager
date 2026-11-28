package contracts

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"

BRIDGE_FEATURE_BOT_CHANNEL_VAULT_V1 :: "bot_channel_vault_v1"
BOT_CHANNEL_VAULT_REQUEST_FRAME :: "bot_channel_vault"
BOT_CHANNEL_VAULT_RESULT_FRAME :: "bot_channel_vault_result"
BOT_CHANNEL_VAULT_MAX_PLAINTEXT :: 16_384
BOT_CHANNEL_VAULT_MAX_TOKEN :: 24_576
BOT_CHANNEL_VAULT_MAX_FRAME :: 40_000
BOT_CHANNEL_VAULT_MAX_AGE_MS :: 5_000

// Body is padded standard base64. Seal accepts UTF-8 and returns an ordinary
// vault token. Open requires an ordinary vault token and its author-only proof.
Bot_Channel_Vault_Request :: struct {
	type, request_id, operation: string,
	owner_user_id, bridge_id, agent_instance_id, conversation_id: string,
	activation_generation, expires_at_ms: i64,
	vault_id: string,
	vault_epoch: u32,
	provider, provider_event_id, binding_id: string,
	binding_generation: i64,
	input_message_id, reply_message_id, source_proof, scope_digest, body: string,
}

Bot_Channel_Vault_Result :: struct {
	type, request_id, operation, status, scope_digest, body: string,
}

// Metadata-only correlation digest. The connection identity and waiter
// source checks still apply. This is not the secret authorship proof.
bot_channel_vault_scope_digest :: proc(req: Bot_Channel_Vault_Request, allocator := context.allocator) -> (string, bool) {
	metadata := req
	metadata.scope_digest, metadata.body = "", ""
	raw, err := json.marshal(metadata, allocator = context.temp_allocator)
	defer if len(raw) > 0 do crypto.zero_explicit(raw_data(raw), len(raw))
	if err != nil do return "", false
	return bot_channel_vault_sha256_hex(raw, allocator), true
}

bot_channel_vault_sha256_hex :: proc(data: []byte, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	digest: [32]byte
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:], allocator))
}
