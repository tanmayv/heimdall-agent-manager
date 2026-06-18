package router_envelope

import "core:fmt"
import "core:strings"

Crypto_Result :: struct {
	ok: bool,
	message: string,
	key_id: string,
	payload_json: string,
	encrypted_payload_json: string,
}

// Boundary stub: daemon-side code calls this before handing payloads to a router.
// It is intentionally separate from router auth; replace with real user-token-derived encryption later.
encrypt_payload_for_router :: proc(payload_json, user_token: string) -> Crypto_Result {
	if user_token == "" {
		return Crypto_Result{ok = false, message = "missing user token"}
	}
	return Crypto_Result {
		ok = true,
		message = "encrypted with stub crypto boundary",
		key_id = crypto_stub_key_id(user_token),
		encrypted_payload_json = strings.clone(fmt.tprintf("stub-v1:%s", xor_hex(payload_json, user_token))),
	}
}

// Boundary stub: daemon-side code calls this after receiving an opaque router payload.
decrypt_payload_from_router :: proc(encrypted_payload_json, user_token: string) -> Crypto_Result {
	if user_token == "" {
		return Crypto_Result{ok = false, message = "missing user token"}
	}
	prefix :: "stub-v1:"
	if !strings.has_prefix(encrypted_payload_json, prefix) {
		return Crypto_Result{ok = false, message = "unsupported encrypted payload format"}
	}
	payload, ok := xor_hex_decode(encrypted_payload_json[len(prefix):], user_token)
	if !ok {
		return Crypto_Result{ok = false, message = "invalid encrypted payload"}
	}
	return Crypto_Result {
		ok = true,
		message = "decrypted with stub crypto boundary",
		key_id = crypto_stub_key_id(user_token),
		payload_json = payload,
		encrypted_payload_json = encrypted_payload_json,
	}
}

crypto_stub_key_id :: proc(user_token: string) -> string {
	return strings.clone(fmt.tprintf("stub-user-key-len-%d", len(user_token)))
}

xor_hex :: proc(value, key: string) -> string {
	builder := strings.builder_make()
	for i in 0..<len(value) {
		encoded := value[i] ~ key[i % len(key)]
		strings.write_string(&builder, fmt.tprintf("%02x", encoded))
	}
	return strings.to_string(builder)
}

xor_hex_decode :: proc(value, key: string) -> (string, bool) {
	if len(value) % 2 != 0 do return "", false
	result := make([]byte, len(value) / 2)
	for i in 0..<len(result) {
		hi, ok_hi := hex_value(value[i * 2])
		lo, ok_lo := hex_value(value[i * 2 + 1])
		if !ok_hi || !ok_lo do return "", false
		result[i] = byte((hi << 4) | lo) ~ key[i % len(key)]
	}
	return string(result), true
}

hex_value :: proc(ch: byte) -> (byte, bool) {
	if ch >= '0' && ch <= '9' do return ch - '0', true
	if ch >= 'a' && ch <= 'f' do return ch - 'a' + 10, true
	if ch >= 'A' && ch <= 'F' do return ch - 'A' + 10, true
	return 0, false
}
