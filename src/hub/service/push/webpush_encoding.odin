package push

// WP-CRYPTO-3: base64url (unpadded) helpers and P-256 uncompressed-point
// encode/decode used across the Web Push crypto stack.
//
// The browser's `PushSubscription` keys, the VAPID keys in config, and every
// value that travels in an `aes128gcm` header are unpadded base64url per
// RFC 4648 Section 5. `core:encoding/base64` speaks base64url via the URL
// tables but always emits/consumes `=` padding, so we wrap it here to strip
// and re-add padding at the boundary.

import "core:encoding/base64"
import "core:strings"

// P-256 uncompressed public point: 0x04 || X(32) || Y(32).
EC_P256_POINT_SIZE :: 65
EC_P256_COORD_SIZE :: 32
EC_UNCOMPRESSED_PREFIX :: 0x04

// base64url_encode returns the unpadded base64url encoding of data.
// The caller owns the returned string and must `delete` it.
base64url_encode :: proc(data: []byte, allocator := context.allocator) -> string {
	padded := base64.encode(data, base64.ENC_URL_TABLE, allocator)
	defer delete(padded, allocator)
	trimmed := strings.trim_right(padded, "=")
	return strings.clone(trimmed, allocator)
}

// base64url_decode decodes an unpadded (or padded) base64url string. It
// returns the decoded bytes and true on success; on any malformed input it
// returns (nil, false). The caller owns the returned slice on success.
base64url_decode :: proc(encoded: string, allocator := context.allocator) -> ([]byte, bool) {
	// Reject characters outside the base64url alphabet up front so we never
	// silently decode standard-base64 (`+`/`/`) or stray padding as data.
	for r in encoded {
		switch r {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '=':
		case:
			return nil, false
		}
	}

	// Re-pad to a multiple of four so the underlying decoder is happy.
	padding := (4 - len(encoded) % 4) % 4
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, encoded)
	for _ in 0 ..< padding {
		strings.write_byte(&builder, '=')
	}

	decoded, err := base64.decode(strings.to_string(builder), base64.DEC_URL_TABLE, allocator)
	if err != nil {
		if decoded != nil {
			delete(decoded, allocator)
		}
		return nil, false
	}
	return decoded, true
}

// p256_point_is_valid reports whether b is a well-formed uncompressed P-256
// point (65 bytes prefixed with 0x04). It does not perform on-curve
// validation; the crypto primitives reject off-curve points when the point is
// actually used.
p256_point_is_valid :: proc(b: []byte) -> bool {
	return len(b) == EC_P256_POINT_SIZE && b[0] == EC_UNCOMPRESSED_PREFIX
}
