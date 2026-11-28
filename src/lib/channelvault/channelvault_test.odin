package channelvault

import "core:encoding/base64"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

BOT_CHANNEL_VAULT_TEST_NOW :: 1_000_000

bot_channel_vault_test_keyring :: proc(t: ^testing.T, owner := "owner_test") -> vault.Vault_Keyring {
	id := vault.Vault_Id{}
	id[0] = 77
	secret: [32]byte
	secret[11] = 234
	kr, ok := vault.keyring_from_single_key(owner, id, 1, secret[:])
	testing.expect(t, ok)
	return kr
}

bot_channel_vault_test_request :: proc(kr: ^vault.Vault_Keyring, operation, body: string) -> contracts.Bot_Channel_Vault_Request {
	id_buf: [vault.VAULT_ID_HEX_CHARS]byte
	encoded, _ := base64.encode(transmute([]byte)body, allocator = context.temp_allocator)
	r := contracts.Bot_Channel_Vault_Request{
		type = contracts.BOT_CHANNEL_VAULT_REQUEST_FRAME, request_id = "test_request_01", operation = operation,
		owner_user_id = "owner_test", bridge_id = "bridge_test", agent_instance_id = "inst_test",
		conversation_id = "chat_test", activation_generation = 2, expires_at_ms = BOT_CHANNEL_VAULT_TEST_NOW + 1000,
		vault_id = strings.clone(vault.vault_id_hex(kr.vault_id, id_buf[:]), context.temp_allocator),
		vault_epoch = kr.current_epoch, provider = "whatsapp", binding_id = "binding_test", binding_generation = 3,
		body = encoded,
	}
	if operation == "seal" {
		r.provider_event_id = "wamid.fake-123"
	} else {
		r.input_message_id, r.reply_message_id = "msg_input", "msg_reply"
	}
	return r
}

bot_channel_vault_test_convert :: proc(t: ^testing.T, req: contracts.Bot_Channel_Vault_Request, kr: ^vault.Vault_Keyring, expected: string, daemon := "bridge_test") -> string {
	r := req
	ok: bool
	r.scope_digest, ok = contracts.bot_channel_vault_scope_digest(r, context.temp_allocator)
	testing.expect(t, ok)
	body, status := convert(r, daemon, BOT_CHANNEL_VAULT_TEST_NOW, kr, context.temp_allocator)
	testing.expect_value(t, status, expected)
	if expected != "ok" do testing.expect_value(t, body, "")
	return body
}

@(test)
test_bot_channel_vault_seal_checks_live_key_owner_placement_and_epoch :: proc(t: ^testing.T) {
	kr := bot_channel_vault_test_keyring(t)
	defer vault.keyring_wipe(&kr)
	r := bot_channel_vault_test_request(&kr, "seal", "synthetic provider text\n🌏")
	sealed := bot_channel_vault_test_convert(t, r, &kr, "ok")
	plain, opened := vault.open(sealed, &kr, context.temp_allocator)
	defer wipe(plain)
	testing.expect(t, opened == .Ok)
	testing.expect_value(t, plain, "synthetic provider text\n🌏")
	_ = bot_channel_vault_test_convert(t, r, nil, "vault_locked")
	other := bot_channel_vault_test_keyring(t, "other_owner")
	defer vault.keyring_wipe(&other)
	_ = bot_channel_vault_test_convert(t, r, &other, "owner_mismatch")
	_ = bot_channel_vault_test_convert(t, r, &kr, "stale_placement", "wrong_bridge")
	expired := r
	expired.expires_at_ms = BOT_CHANNEL_VAULT_TEST_NOW
	_ = bot_channel_vault_test_convert(t, expired, &kr, "stale_placement")
	future := r
	future.expires_at_ms = BOT_CHANNEL_VAULT_TEST_NOW + contracts.BOT_CHANNEL_VAULT_MAX_AGE_MS + 250
	_ = bot_channel_vault_test_convert(t, future, &kr, "ok")
	future.expires_at_ms += 1000
	_ = bot_channel_vault_test_convert(t, future, &kr, "stale_placement")
	stale := r
	stale.vault_epoch += 1
	_ = bot_channel_vault_test_convert(t, stale, &kr, "key_unavailable")
	missing_event := r
	missing_event.provider_event_id = ""
	_ = bot_channel_vault_test_convert(t, missing_event, &kr, "invalid_request")

	r.scope_digest, _ = contracts.bot_channel_vault_scope_digest(r, context.temp_allocator)
	r.binding_generation += 1
	wire, status := convert(r, "bridge_test", BOT_CHANNEL_VAULT_TEST_NOW, &kr, context.temp_allocator)
	testing.expect_value(t, status, "invalid_request")
	testing.expect_value(t, wire, "")
}

@(test)
test_bot_channel_vault_open_requires_exact_authored_token_and_source_after_rotation :: proc(t: ^testing.T) {
	kr := bot_channel_vault_test_keyring(t)
	defer vault.keyring_wipe(&kr)
	r := bot_channel_vault_test_request(&kr, "open", "")
	scope := reply_scope(r)
	token, proof, authored := seal_authored(scope, "synthetic reply", &kr, context.temp_allocator)
	if !testing.expect(t, authored) do return
	r.source_proof = proof
	r.body, _ = base64.encode(transmute([]byte)token, allocator = context.temp_allocator)
	original, ordinary := vault.open(token, &kr, context.temp_allocator)
	defer wipe(original)
	testing.expect(t, ordinary == .Ok)
	testing.expect_value(t, original, "synthetic reply")
	plain := bot_channel_vault_test_convert(t, r, &kr, "ok")
	defer wipe(plain)
	testing.expect_value(t, plain, original)
	// The receiver may recompute the nonsecret scope digest on a modified
	// request, but that cannot change the source proof or body commitment.
	for mutation in 0 ..< 7 {
		altered := r
		switch mutation {
		case 0: altered.binding_id = "other_binding"
		case 1: altered.binding_generation += 1
		case 2: altered.conversation_id = "other_chat"
		case 3: altered.provider = "telegram"
		case 4: altered.input_message_id = "other_input"
		case 5: altered.reply_message_id = "other_reply"
		case 6: altered.agent_instance_id = "other_instance"
		}
		_ = bot_channel_vault_test_convert(t, altered, &kr, "invalid_scope")
	}
	unrelated, _ := vault.seal_string("unrelated ordinary token", &kr, context.temp_allocator)
	swapped := r
	swapped.body, _ = base64.encode(transmute([]byte)unrelated, allocator = context.temp_allocator)
	_ = bot_channel_vault_test_convert(t, swapped, &kr, "invalid_scope")
	r.request_id = "retry_after_lost_response"
	kr.count = 2
	kr.current_epoch = 2
	kr.entries[1].epoch = 2
	kr.entries[1].key[8] = 89
	_ = bot_channel_vault_test_convert(t, r, &kr, "key_unavailable")
	r.vault_epoch = 2
	rotated := bot_channel_vault_test_convert(t, r, &kr, "ok")
	defer wipe(rotated)
	testing.expect_value(t, rotated, original)
	without_old := kr
	defer vault.keyring_wipe(&without_old)
	without_old.entries[0] = without_old.entries[1]
	without_old.entries[1] = {}
	without_old.count = 1
	_ = bot_channel_vault_test_convert(t, r, &without_old, "key_unavailable")
}
