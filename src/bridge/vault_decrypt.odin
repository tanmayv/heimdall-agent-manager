package main

import "core:crypto"
import "core:crypto/aes"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:strings"

VAULT_ARMOR_PREFIX :: "vault:v1:"
VAULT_NONCE_BYTES  :: 12
VAULT_TAG_BYTES    :: 16
VAULT_KEY_BYTES    :: 32
VAULT_HEADER_BYTES :: VAULT_NONCE_BYTES + VAULT_TAG_BYTES // 28

bridge_is_valid_hex_key :: proc(key_hex: string) -> bool {
	if len(key_hex) != 64 do return false
	for i in 0 ..< len(key_hex) {
		c := key_hex[i]
		switch c {
		case '0'..='9', 'a'..='f', 'A'..='F':
		case:
			return false
		}
	}
	return true
}

bridge_decrypt_vault_ciphertext :: proc(armored: string, key_bytes: []u8, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if !strings.has_prefix(armored, VAULT_ARMOR_PREFIX) {
		return strings.clone(armored, allocator), true
	}
	if len(key_bytes) != VAULT_KEY_BYTES do return "", false

	b64 := strings.trim_space(armored[len(VAULT_ARMOR_PREFIX):])
	if len(b64) == 0 do return "", false

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

bridge_decrypt_vault_ciphertext_hex :: proc(armored: string, key_hex: string, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if !strings.has_prefix(armored, VAULT_ARMOR_PREFIX) {
		return strings.clone(armored, allocator), true
	}
	if !bridge_is_valid_hex_key(key_hex) do return "", false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
	return bridge_decrypt_vault_ciphertext(armored, raw_key, allocator)
}

// Encrypt plaintext string using 256-bit AES-GCM (matching src/ctl/vault_content.odin)
// Useful for tests and symmetrical bridge encryption if needed.
bridge_encrypt_vault_ciphertext :: proc(plaintext: string, key_bytes: []u8, allocator := context.allocator) -> (armored: string, ok: bool) {
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

bridge_encrypt_vault_ciphertext_hex :: proc(plaintext: string, key_hex: string, allocator := context.allocator) -> (armored: string, ok: bool) {
	if !bridge_is_valid_hex_key(key_hex) do return "", false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
	return bridge_encrypt_vault_ciphertext(plaintext, raw_key, allocator)
}

// bridge_decrypt_embedded_vault_tokens scans text for embedded 'vault:v1:<base64>' tokens,
// decrypting each with AES-256-GCM using the vault key read via bridge_read_vault_key().
// On success, the token is replaced with the decrypted plaintext.
// On decryption failure (e.g. invalid base64 or bad tag), the token is replaced with '[Encrypted]'.
// If the vault key is unconfigured or text contains no tokens, a copy of text is returned as-is.
// Caller owns the returned string.
bridge_decrypt_embedded_vault_tokens :: proc(text: string, allocator := context.allocator) -> string {
	if !strings.contains(text, VAULT_ARMOR_PREFIX) {
		return strings.clone(text, allocator)
	}

	key_hex, key_ok := bridge_read_vault_key()
	if !key_ok {
		return strings.clone(text, allocator)
	}
	defer delete(key_hex)

	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES {
		return strings.clone(text, allocator)
	}

	b := strings.builder_make(allocator)
	remaining := text
	for len(remaining) > 0 {
		idx := strings.index(remaining, VAULT_ARMOR_PREFIX)
		if idx < 0 {
			strings.write_string(&b, remaining)
			break
		}

		// Write prefix before token
		if idx > 0 {
			strings.write_string(&b, remaining[:idx])
		}

		// Scan token boundary: "vault:v1:" + base64 alphabet [A-Za-z0-9+/=]
		tok_start := idx
		tok_end := idx + len(VAULT_ARMOR_PREFIX)
		tok_loop: for tok_end < len(remaining) {
			switch remaining[tok_end] {
			case 'A'..='Z', 'a'..='z', '0'..='9', '+', '/', '=', '-', '_':
				tok_end += 1
			case:
				break tok_loop
			}
		}

		token := remaining[tok_start:tok_end]
		plaintext, dec_ok := bridge_decrypt_vault_ciphertext(token, raw_key, context.temp_allocator)
		if dec_ok {
			strings.write_string(&b, plaintext)
		} else {
			strings.write_string(&b, "[Encrypted]")
		}

		remaining = remaining[tok_end:]
	}

	return strings.to_string(b)
}
