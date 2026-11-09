package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// ── REQ-VAULT-CHAINS-1 Unit Tests for CLI Task Chains Encryption & Decryption ──

TEST_CHAIN_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

@(test)
test_chain_show_transparent_decryption :: proc(t: ^testing.T) {
	orig_title := "Zero-Knowledge Task Chain Integration"
	orig_desc  := "All sensitive chain fields are encrypted with local AES-GCM key."

	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	enc_desc, _  := vault_encrypt_text_hex(orig_desc, TEST_CHAIN_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"chain_id":"chain_123","title":"%s","description":"%s","status":"active"}}}}`,
		enc_title,
		enc_desc,
	)

	// Decrypt with valid key configured
	decrypted_json := ctl_decrypt_vault_json(raw_json, tkr(TEST_CHAIN_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted_json, orig_title), "decrypted json must contain original title")
	testing.expect(t, strings.contains(decrypted_json, orig_desc), "decrypted json must contain original description")
	testing.expect(t, !strings.contains(decrypted_json, "vault:v2:"), "decrypted json must not contain armor prefix")
}

@(test)
test_chain_unconfigured_fallback :: proc(t: ^testing.T) {
	orig_title := "Confidential Security Audit"
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_CHAIN_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"chain_id":"chain_999","title":"%s","status":"active"}}}}`,
		enc_title,
	)

	// Decrypt with key NOT configured (unlocked = false)
	fallback_json := ctl_decrypt_vault_json(raw_json, nil, false, context.temp_allocator)

	expected_fallback := fmt.tprintf("[Encrypted: %s]", enc_title)
	testing.expect(t, strings.contains(fallback_json, expected_fallback), "must format as [Encrypted: vault:v2:...]")
	testing.expect(t, !strings.contains(fallback_json, orig_title), "must not expose plaintext when unconfigured")
}

@(test)
test_chain_list_transparent_decryption :: proc(t: ^testing.T) {
	enc_title1, _ := vault_encrypt_text_hex("Secret Chain Alpha", TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	plain_title2  := "Public Legacy Chain Beta"

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":[{{"chain_id":"c1","title":"%s"}},{{"chain_id":"c2","title":"%s"}}]}}`,
		enc_title1,
		plain_title2,
	)

	// Decrypt list with valid key
	decrypted_json := ctl_decrypt_vault_json(raw_json, tkr(TEST_CHAIN_VAULT_KEY), true, context.temp_allocator)

	testing.expect(t, strings.contains(decrypted_json, "Secret Chain Alpha"), "must decrypt armored chain")
	testing.expect(t, strings.contains(decrypted_json, plain_title2), "must preserve legacy plaintext chain untouched")
}
