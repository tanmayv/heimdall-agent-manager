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

// ---------------------------------------------------------------------------
// F1 / REQ-JSONX-2 regression guard for `ctl_decrypt_json_string`.
//
// These tests exist because the first F1 fix was incomplete and the existing tests
// COULD NOT SEE IT. `src/lib/jsonx` was made safe and every call site inside
// `jsonx.odin` was rerouted, but `ctl_decrypt_json_string` reached
// `core:encoding/json` on its own, so `artifact show --with-content` kept aborting at
// parser.odin:494/:507 while `odin test src/lib/jsonx` stayed green at 18/18.
//
// The lesson is the shape of the test, not the bug: exercising `jsonx` directly can
// never detect a path that BYPASSES jsonx. So these drive the CLI proc that the real
// command calls, with the byte patterns that actually broke it.

@(test)
test_ctl_decrypt_json_string_passes_invalid_utf8_through_verbatim :: proc(t: ^testing.T) {
	// No armor anywhere: the fast path must hand the bytes back untouched. Against the
	// pre-fix code this aborted the process inside core's `unquote_string`.
	blob := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 64 {
		for v in 0x80 ..< 0x100 do strings.write_byte(&blob, u8(v))
	}
	raw := strings.concatenate({`{"ok":true,"content":"`, strings.to_string(blob), `"}`}, context.temp_allocator)

	got := ctl_decrypt_json_string(raw, TEST_VAULT_KEY_HEX, true, context.temp_allocator)
	testing.expectf(
		t,
		got == raw,
		"unarmored response must be byte-identical: got %d bytes, want %d",
		len(got),
		len(raw),
	)
}

@(test)
test_ctl_decrypt_json_string_decrypts_armor_beside_invalid_utf8 :: proc(t: ^testing.T) {
	// THE case the first fix missed and the short-circuit alone does not cover: one
	// response carrying BOTH an armored field and invalid UTF-8. This is not synthetic
	// -- `artifact show --with-content art_18db52a612c4eb62` is exactly this shape, an
	// armored `name` beside 1.89M of jpeg, and it aborted until this was fixed.
	armored, enc_ok := vault_encrypt_text_hex("IMG_5494.jpeg", TEST_VAULT_KEY_HEX, context.temp_allocator)
	testing.expect(t, enc_ok, "fixture encryption must succeed")

	blob := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 32 {
		for v in 0x80 ..< 0x100 do strings.write_byte(&blob, u8(v))
	}
	binary := strings.to_string(blob)
	raw := strings.concatenate(
		{`{"ok":true,"name":"`, armored, `","content":"`, binary, `"}`},
		context.temp_allocator,
	)

	got := ctl_decrypt_json_string(raw, TEST_VAULT_KEY_HEX, true, context.temp_allocator)

	// 1. The armored field is decrypted and no ciphertext survives.
	testing.expect(t, strings.contains(got, `"name":"IMG_5494.jpeg"`), "armored name must be decrypted")
	testing.expect(t, !strings.contains(got, VAULT_ARMOR_PREFIX), "no armor may reach the output")

	// 2. The binary field is preserved VERBATIM. Not aborting is not enough -- core's
	//    marshal would have rewritten each invalid byte, so assert on the bytes.
	testing.expect(t, strings.contains(got, binary), "binary content must survive byte-for-byte")
	testing.expect(
		t,
		!strings.contains(got, "�"),
		"no byte may be replaced by U+FFFD",
	)
}

@(test)
test_ctl_decrypt_json_string_locked_state_keeps_binary_intact :: proc(t: ^testing.T) {
	// Locked vault (no key) beside invalid UTF-8: the armored field must fall back to
	// the named locked state and the binary must still come through untouched.
	armored, enc_ok := vault_encrypt_text_hex("secret-name", TEST_VAULT_KEY_HEX, context.temp_allocator)
	testing.expect(t, enc_ok, "fixture encryption must succeed")

	// Only bytes >= 0x20 plus high bytes: a RAW control byte inside a JSON string
	// literal is a separate (tokenizer-level) concern and not what this test is about.
	binary := "\x89PNG\xff\xfe\xfd\xfc\xfb"
	raw := strings.concatenate(
		{`{"ok":true,"name":"`, armored, `","content":"`, binary, `"}`},
		context.temp_allocator,
	)

	got := ctl_decrypt_json_string(raw, "", false, context.temp_allocator)
	testing.expect(t, strings.contains(got, "[Encrypted:"), "locked state must be named, not raw ciphertext")
	testing.expect(t, strings.contains(got, VAULT_HINT_NO_KEY), "locked state must carry the remedy hint")
	testing.expect(t, strings.contains(got, binary), "binary content must survive the locked path too")
}
