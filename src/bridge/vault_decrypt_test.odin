package main

import "core:os"
import "core:strings"
import "core:testing"

TEST_VAULT_KEY_HEX :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

@(test)
test_bridge_vault_encrypt_decrypt_roundtrip :: proc(t: ^testing.T) {
	plaintext := "Secret Task Title for Agents"
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(plaintext, TEST_VAULT_KEY_HEX)
	testing.expect(t, enc_ok, "encryption must succeed")
	defer delete(armored)
	testing.expect(t, strings.has_prefix(armored, "vault:v1:"), "armored string must start with vault:v1:")

	decrypted, dec_ok := bridge_decrypt_vault_ciphertext_hex(armored, TEST_VAULT_KEY_HEX)
	testing.expect(t, dec_ok, "decryption must succeed")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, plaintext)
}

@(test)
test_bridge_vault_decrypt_wrong_key_fails :: proc(t: ^testing.T) {
	plaintext := "Top Secret"
	armored, _ := bridge_encrypt_vault_ciphertext_hex(plaintext, TEST_VAULT_KEY_HEX)
	defer delete(armored)

	wrong_key := "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
	decrypted, ok := bridge_decrypt_vault_ciphertext_hex(armored, wrong_key)
	defer if ok do delete(decrypted)
	testing.expect(t, !ok, "decryption with wrong key must fail")
}

@(test)
test_bridge_vault_decrypt_unarmored_fallback :: proc(t: ^testing.T) {
	raw := "Plain unarmored task title"
	decrypted, ok := bridge_decrypt_vault_ciphertext_hex(raw, TEST_VAULT_KEY_HEX)
	testing.expect(t, ok, "unarmored text must pass through")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, raw)
}

@(test)
test_bridge_vault_embedded_decryption_suite :: proc(t: ^testing.T) {
	os.set_env("HEIMDALL_VAULT_KEY", TEST_VAULT_KEY_HEX)
	defer os.unset_env("HEIMDALL_VAULT_KEY")

	// 1. Embedded vault tokens in notices
	{
		title_plaintext := "Implement Feature X"
		armored_title, _ := bridge_encrypt_vault_ciphertext_hex(title_plaintext, TEST_VAULT_KEY_HEX)
		defer delete(armored_title)

		comment_plaintext := "All tests green!"
		armored_comment, _ := bridge_encrypt_vault_ciphertext_hex(comment_plaintext, TEST_VAULT_KEY_HEX)
		defer delete(armored_comment)

		notice := strings.concatenate({`[Comment] @Alice commented on "`, armored_title, `" (task_42): "`, armored_comment, `"`})
		defer delete(notice)

		decrypted := bridge_decrypt_embedded_vault_tokens(notice)
		defer delete(decrypted)

		expected := `[Comment] @Alice commented on "Implement Feature X" (task_42): "All tests green!"`
		testing.expect_value(t, decrypted, expected)
	}

	// 2. Corrupted token fallback
	{
		corrupted := `[Review Requested] @coder submitted "vault:v1:invalid_base64_payload==" (task_1)`
		decrypted := bridge_decrypt_embedded_vault_tokens(corrupted)
		defer delete(decrypted)

		expected := `[Review Requested] @coder submitted "[Encrypted]" (task_1)`
		testing.expect_value(t, decrypted, expected)
	}

	// 3. Bootstrap header decryption & coordinator display name
	{
		chain_title := "Confidential Chain"
		armored_title, _ := bridge_encrypt_vault_ciphertext_hex(chain_title, TEST_VAULT_KEY_HEX)
		defer delete(armored_title)

		d := Bridge_Bootstrap_Descriptor{
			instance_id              = "inst_worker_1",
			agent_name               = "heimdall-engineer",
			role                     = "worker",
			chain_id                 = "chain_abc",
			chain_title              = armored_title,
			coordinator_id           = "inst_coord_1",
			coordinator_display_name = "Coordinator Agent #1",
		}

		header := bridge_bootstrap_render_header(d)
		defer delete(header)

		testing.expect(t, strings.contains(header, "Task chain: Confidential Chain (chain_abc)"), "header must have decrypted chain title")
		testing.expect(t, strings.contains(header, "Coordinator: Coordinator Agent #1 (inst_coord_1)"), "header must have coordinator display name and ID")
	}
}

