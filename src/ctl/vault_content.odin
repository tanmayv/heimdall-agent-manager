package main

import "core:crypto"
import "core:crypto/aes"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:strings"

// ── Reusable Content Cryptography Library (REQ-VAULT-CONTENT-LIB-1) ──────────
// Implements wire format 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>',
// transparent unarmored fallback, and cross-platform interoperability with WebCrypto.

VAULT_ARMOR_PREFIX :: "vault:v1:"
VAULT_NONCE_BYTES  :: 12
VAULT_TAG_BYTES    :: 16
VAULT_KEY_BYTES    :: 32
VAULT_HEADER_BYTES :: VAULT_NONCE_BYTES + VAULT_TAG_BYTES // 28

// Check if a string has the self-describing vault armor prefix.
is_vault_armored :: proc(text: string) -> bool {
	return strings.has_prefix(text, VAULT_ARMOR_PREFIX)
}

// Encrypt plaintext string using 256-bit AES-GCM and return armored envelope string:
// 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>'
vault_encrypt_text :: proc(plaintext: string, key_bytes: []u8, allocator := context.allocator) -> (armored: string, ok: bool) {
	if len(key_bytes) != VAULT_KEY_BYTES do return "", false

	plaintext_bytes := transmute([]byte)plaintext

	nonce: [VAULT_NONCE_BYTES]byte
	crypto.rand_bytes(nonce[:])

	ciphertext := make([]byte, len(plaintext_bytes), context.temp_allocator)
	tag: [VAULT_TAG_BYTES]byte

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key_bytes)
	defer aes.reset_gcm(&gcm)

	aes.seal_gcm(&gcm, ciphertext, tag[:], nonce[:], nil, plaintext_bytes)

	payload_len := VAULT_HEADER_BYTES + len(ciphertext)
	payload := make([]byte, payload_len, context.temp_allocator)
	copy(payload[0:VAULT_NONCE_BYTES], nonce[:])
	copy(payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES], tag[:])
	copy(payload[VAULT_HEADER_BYTES:], ciphertext)

	b64, err := base64.encode(payload, allocator = context.temp_allocator)
	if err != nil do return "", false

	res := strings.concatenate({VAULT_ARMOR_PREFIX, b64}, allocator)
	return res, true
}

// Encrypt plaintext using a 64-character hex key string.
vault_encrypt_text_hex :: proc(plaintext: string, key_hex: string, allocator := context.allocator) -> (armored: string, ok: bool) {
	if !is_valid_hex_key(key_hex) do return "", false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
	return vault_encrypt_text(plaintext, raw_key, allocator)
}

// Decrypt a vault armored string. If the string does not start with 'vault:v1:',
// returns a copy of the input string as-is with ok = true (transparent fallback).
vault_decrypt_text :: proc(armored: string, key_bytes: []u8, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if !is_vault_armored(armored) {
		return strings.clone(armored, allocator), true
	}

	if len(key_bytes) != VAULT_KEY_BYTES do return "", false

	b64 := strings.trim_space(armored[len(VAULT_ARMOR_PREFIX):])
	if len(b64) == 0 do return "", false

	// Validate base64 alphabet
	for i in 0 ..< len(b64) {
		c := b64[i]
		switch c {
		case 'A'..='Z', 'a'..='z', '0'..='9', '+', '/', '=':
		case:
			return "", false
		}
	}

	payload, err := base64.decode(b64, allocator = context.temp_allocator)
	if err != nil do return "", false

	if len(payload) < VAULT_HEADER_BYTES do return "", false

	nonce := payload[0:VAULT_NONCE_BYTES]
	tag := payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES]
	ciphertext := payload[VAULT_HEADER_BYTES:]

	dst := make([]byte, len(ciphertext), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key_bytes)
	defer aes.reset_gcm(&gcm)

	if !aes.open_gcm(&gcm, dst, nonce, nil, ciphertext, tag) {
		delete(dst, allocator)
		return "", false
	}

	return string(dst), true
}

// Decrypt a vault armored string using a 64-character hex key string.
vault_decrypt_text_hex :: proc(armored: string, key_hex: string, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if !is_vault_armored(armored) {
		return strings.clone(armored, allocator), true
	}
	if !is_valid_hex_key(key_hex) do return "", false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
	return vault_decrypt_text(armored, raw_key, allocator)
}
