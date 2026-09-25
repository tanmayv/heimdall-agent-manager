package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ── REQ-VAULT-CHAT-1 CLI Specification Unit Tests ────────────────────────────

TEST_CHAT_VAULT_KEY_SPEC :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_CHAT_VAULT_KEY_SPEC  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_chat_send_encryption_with_vault_key_spec :: proc(t: ^testing.T) {
	orig_to := "inst_coordinator_1"
	orig_body := "Confidential coordination message: all cryptographic primitives operational."

	args := []string{
		"--vault-key", TEST_CHAT_VAULT_KEY_SPEC,
	}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"to":"inst_coordinator_1"`), "to must be preserved in plaintext")
	testing.expect(t, !strings.contains(out, orig_body), "chat body must not leak plaintext")
	testing.expect(t, strings.contains(out, `"body":"vault:v1:`), "chat body must be armored with vault:v1:")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_body := string(obj["body"].(json.String))
	dec_body, db_ok := vault_decrypt_text_hex(enc_body, TEST_CHAT_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, db_ok, "body must decrypt successfully")
	testing.expect_value(t, dec_body, orig_body)
}

@(test)
test_chat_set_title_encryption_with_vault_key_spec :: proc(t: ^testing.T) {
	orig_title := "Zero-Knowledge Vault Operations Thread"

	args := []string{
		"--vault-key", TEST_CHAT_VAULT_KEY_SPEC,
	}

	out := ctl_agentmode_chat_set_title_params(orig_title, args)

	testing.expect(t, !strings.contains(out, orig_title), "title must not leak plaintext")
	testing.expect(t, strings.contains(out, `"title":"vault:v1:`), "title must be armored with vault:v1:")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_CHAT_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)
}

@(test)
test_chat_read_transparent_decryption_spec :: proc(t: ^testing.T) {
	orig_msg_1 := "Message one: initial vault bootstrap."
	orig_msg_2 := "Message two: operational key distribution."
	orig_title := "Encrypted Operations Thread"
	orig_preview := "Preview: initial vault bootstrap."

	enc_msg_1, _ := vault_encrypt_text_hex(orig_msg_1, TEST_CHAT_VAULT_KEY_SPEC, context.temp_allocator)
	enc_msg_2, _ := vault_encrypt_text_hex(orig_msg_2, TEST_CHAT_VAULT_KEY_SPEC, context.temp_allocator)
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_CHAT_VAULT_KEY_SPEC, context.temp_allocator)
	enc_preview, _ := vault_encrypt_text_hex(orig_preview, TEST_CHAT_VAULT_KEY_SPEC, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"conversation":{{"title":"%s","last_message_preview":"%s"}},"messages":[{{"id":"msg_1","body":"%s"}},{{"id":"msg_2","body":"%s"}}]}}}}`,
		enc_title, enc_preview, enc_msg_1, enc_msg_2,
	)

	decrypted := ctl_decrypt_json_string(raw_json, TEST_CHAT_VAULT_KEY_SPEC, true, context.temp_allocator)

	testing.expect(t, strings.contains(decrypted, orig_msg_1), "decrypted json must contain msg 1")
	testing.expect(t, strings.contains(decrypted, orig_msg_2), "decrypted json must contain msg 2")
	testing.expect(t, strings.contains(decrypted, orig_title), "decrypted json must contain title")
	testing.expect(t, strings.contains(decrypted, orig_preview), "decrypted json must contain preview")
	testing.expect(t, !strings.contains(decrypted, "vault:v1:"), "decrypted json must not contain vault armor")
}

@(test)
test_chat_read_fallback_when_vault_locked_spec :: proc(t: ^testing.T) {
	orig_msg := "Secret confidential directive."
	enc_msg, _ := vault_encrypt_text_hex(orig_msg, TEST_CHAT_VAULT_KEY_SPEC, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"messages":[{{"id":"msg_1","body":"%s"}}]}}}}`,
		enc_msg,
	)

	fallback := ctl_decrypt_json_string(raw_json, "", false, context.temp_allocator)

	testing.expect(t, !strings.contains(fallback, orig_msg), "must not leak plaintext when locked")
	testing.expect(t, strings.contains(fallback, "[Encrypted: vault:v1:"), "must wrap armored body in [Encrypted: vault:v1:...]")
}
