package main

import "core:encoding/base64"
import "core:encoding/hex"
import "core:strings"
import "core:testing"

// ── Tests for vault_content.odin (REQ-VAULT-CONTENT-LIB-1) ───────────────────

TEST_VAULT_KEY_HEX :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_VAULT_KEY_HEX  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_vault_armor_detection :: proc(t: ^testing.T) {
	testing.expect(t, is_vault_armored("vault:v1:"), "vault:v1: prefix must return true")
	testing.expect(t, is_vault_armored("vault:v1:AQIDBAUGBw=="), "vault:v1: with payload must return true")
	testing.expect(t, !is_vault_armored("vault:v2:payload"), "vault:v2: prefix must return false")
	testing.expect(t, !is_vault_armored("vault:"), "prefix without version must return false")
	testing.expect(t, !is_vault_armored(""), "empty string must return false")
	testing.expect(t, !is_vault_armored("plain text content"), "unarmored text must return false")
}

@(test)
test_vault_content_roundtrip_and_randomized_nonces :: proc(t: ^testing.T) {
	key_bytes, hex_ok := hex.decode(transmute([]byte)string(TEST_VAULT_KEY_HEX), context.temp_allocator)
	testing.expect(t, hex_ok, "test key hex decode must succeed")
	testing.expect(t, len(key_bytes) == 32, "test key must be 32 bytes")

	// 1. Basic text round-trip
	plaintext := "High-rigor autonomous agent task execution instructions."
	armored1, ok1 := vault_encrypt_text(plaintext, key_bytes, context.temp_allocator)
	testing.expect(t, ok1, "encryption 1 must succeed")
	testing.expect(t, is_vault_armored(armored1), "armored string must start with vault:v1:")

	armored2, ok2 := vault_encrypt_text(plaintext, key_bytes, context.temp_allocator)
	testing.expect(t, ok2, "encryption 2 must succeed")
	testing.expect(t, armored1 != armored2, "two encryptions must have randomized nonces")

	dec1, dec_ok1 := vault_decrypt_text(armored1, key_bytes, context.temp_allocator)
	testing.expect(t, dec_ok1, "decryption 1 must succeed")
	testing.expect_value(t, dec1, plaintext)

	dec2, dec_ok2 := vault_decrypt_text(armored2, key_bytes, context.temp_allocator)
	testing.expect(t, dec_ok2, "decryption 2 must succeed")
	testing.expect_value(t, dec2, plaintext)

	// 2. Empty string round-trip
	armored_empty, ok_empty := vault_encrypt_text("", key_bytes, context.temp_allocator)
	testing.expect(t, ok_empty, "empty string encryption must succeed")
	dec_empty, dec_ok_empty := vault_decrypt_text(armored_empty, key_bytes, context.temp_allocator)
	testing.expect(t, dec_ok_empty, "empty string decryption must succeed")
	testing.expect_value(t, dec_empty, "")

	// 3. UTF-8 multi-byte characters
	utf8_text := "🔐 Zero-Knowledge Heimdall: 🚀 🤖 日本語 • 中文 • Español"
	armored_utf8, ok_utf8 := vault_encrypt_text(utf8_text, key_bytes, context.temp_allocator)
	testing.expect(t, ok_utf8, "utf-8 encryption must succeed")
	dec_utf8, dec_ok_utf8 := vault_decrypt_text(armored_utf8, key_bytes, context.temp_allocator)
	testing.expect(t, dec_ok_utf8, "utf-8 decryption must succeed")
	testing.expect_value(t, dec_utf8, utf8_text)

	// 4. Hex helper methods round-trip
	armored_hex, ok_hex := vault_encrypt_text_hex(plaintext, TEST_VAULT_KEY_HEX, context.temp_allocator)
	testing.expect(t, ok_hex, "hex encryption must succeed")
	dec_hex, dec_ok_hex := vault_decrypt_text_hex(armored_hex, TEST_VAULT_KEY_HEX, context.temp_allocator)
	testing.expect(t, dec_ok_hex, "hex decryption must succeed")
	testing.expect_value(t, dec_hex, plaintext)
}

@(test)
test_vault_content_transparent_fallback :: proc(t: ^testing.T) {
	key_bytes, _ := hex.decode(transmute([]byte)string(TEST_VAULT_KEY_HEX), context.temp_allocator)

	unarmored := "This is legacy unarmored plaintext content."
	dec, ok := vault_decrypt_text(unarmored, key_bytes, context.temp_allocator)
	testing.expect(t, ok, "fallback must succeed with ok = true")
	testing.expect_value(t, dec, unarmored)

	empty_dec, empty_ok := vault_decrypt_text("", key_bytes, context.temp_allocator)
	testing.expect(t, empty_ok, "empty fallback must succeed with ok = true")
	testing.expect_value(t, empty_dec, "")
}

@(test)
test_vault_content_tamper_detection_and_validation :: proc(t: ^testing.T) {
	key_bytes, _ := hex.decode(transmute([]byte)string(TEST_VAULT_KEY_HEX), context.temp_allocator)
	alt_key, _ := hex.decode(transmute([]byte)string(ALT_VAULT_KEY_HEX), context.temp_allocator)

	plaintext := "Authentic content for security testing."
	armored, enc_ok := vault_encrypt_text(plaintext, key_bytes, context.temp_allocator)
	testing.expect(t, enc_ok, "encryption must succeed")

	// 1. Decrypt with wrong key
	_, wrong_key_ok := vault_decrypt_text(armored, alt_key, context.temp_allocator)
	testing.expect(t, !wrong_key_ok, "decryption with wrong key must fail")

	// 2. Tampered ciphertext byte
	b64 := armored[len(VAULT_ARMOR_PREFIX):]
	payload, _ := base64.decode(b64, allocator = context.temp_allocator)

	tampered_payload := make([]byte, len(payload), context.temp_allocator)
	copy(tampered_payload, payload)
	tampered_payload[len(tampered_payload) - 1] ~= 0x01 // flip last byte

	tampered_b64, _ := base64.encode(tampered_payload, allocator = context.temp_allocator)
	tampered_armored := strings.concatenate({VAULT_ARMOR_PREFIX, tampered_b64}, context.temp_allocator)

	_, tamper_ok := vault_decrypt_text(tampered_armored, key_bytes, context.temp_allocator)
	testing.expect(t, !tamper_ok, "tampered ciphertext must fail authentication")

	// 3. Tampered auth tag byte (index 15)
	copy(tampered_payload, payload)
	tampered_payload[15] ~= 0x42
	tampered_b64_tag, _ := base64.encode(tampered_payload, allocator = context.temp_allocator)
	tampered_armored_tag := strings.concatenate({VAULT_ARMOR_PREFIX, tampered_b64_tag}, context.temp_allocator)

	_, tag_ok := vault_decrypt_text(tampered_armored_tag, key_bytes, context.temp_allocator)
	testing.expect(t, !tag_ok, "tampered tag must fail authentication")

	// 4. Truncated payload (<28 bytes)
	short_payload := make([]byte, 10, context.temp_allocator)
	short_b64, _ := base64.encode(short_payload, allocator = context.temp_allocator)
	short_armored := strings.concatenate({VAULT_ARMOR_PREFIX, short_b64}, context.temp_allocator)

	_, short_ok := vault_decrypt_text(short_armored, key_bytes, context.temp_allocator)
	testing.expect(t, !short_ok, "short payload must be rejected")

	// 5. Malformed base64
	bad_b64_armored := strings.concatenate({VAULT_ARMOR_PREFIX, "not_valid_b64!!!"}, context.temp_allocator)
	_, bad_ok := vault_decrypt_text(bad_b64_armored, key_bytes, context.temp_allocator)
	testing.expect(t, !bad_ok, "invalid base64 must be rejected")
}

@(test)
test_vault_content_webcrypto_interoperability :: proc(t: ^testing.T) {
	// Pre-computed vector generated with WebCrypto AES-GCM 256:
	// Key: TEST_VAULT_KEY_HEX
	// Plaintext: "Hello, Heimdall Zero-Knowledge Vault!"
	// Nonce: 0102030405060708090a0b0c
	precomputed_armored := "vault:v1:AQIDBAUGBwgJCgsM2Ed9QrWXWA/eSrkLieecc4/Y9yN6j/zgFPZJ0LLE5YuYHQC++IdmUyTVIwWlu20gv78kDuk="

	decrypted, ok := vault_decrypt_text_hex(precomputed_armored, TEST_VAULT_KEY_HEX, context.temp_allocator)
	testing.expect(t, ok, "decryption of WebCrypto test vector must succeed")
	testing.expect_value(t, decrypted, "Hello, Heimdall Zero-Knowledge Vault!")
}
