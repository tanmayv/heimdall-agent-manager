package domain

import "core:fmt"
import "core:strings"

// ── Armor-aware length caps for vault-encrypted text fields (REQ-VCAP-1/2/3) ──
//
// Content encryption in Heimdall is CLIENT-SIDE and the Hub is zero-knowledge:
// ctl encrypts a title/description before sending it, so what reaches a Hub
// length check is the ARMORED envelope, never the plaintext. Comparing len() of
// that envelope against a plaintext cap rejects callers far below the documented
// limit (iss_18d940db15f9accb).
//
// Armor overhead, derived from src/ctl/vault_content.odin:15-56:
//
//	armored = "vault:v1:" + base64(12B nonce || 16B GCM tag || ciphertext)
//
// AES-GCM is a stream mode, so len(ciphertext) == len(plaintext), and Odin's
// base64.encode emits PADDED output (4 chars per 3 input bytes, rounded up).
// Hence for a plaintext of n bytes:
//
//	armored_len(n) = len("vault:v1:") + 4*ceil((n + 28) / 3)
//	armored_len(4000) = 9 + 4*1343 = 5381
//	armored_len(120)  = 9 + 4*50   = 209
//
// The Hub CANNOT verify the plaintext length of an armored value — that is
// inherent to the zero-knowledge design and is accepted. These caps are a
// STORAGE bound, not a precise character count; ctl enforces the real plaintext
// budget locally before encrypting (REQ-VCAP-4).

// VAULT_ARMOR_PREFIX is the self-describing wire marker for an encrypted value.
// Must stay in sync with VAULT_ARMOR_PREFIX in src/ctl/vault_content.odin:15.
VAULT_ARMOR_PREFIX :: "vault:v1:"

// VAULT_HEADER_BYTES is the per-value nonce+tag overhead carried inside the
// base64 payload (12B nonce + 16B GCM tag). See src/ctl/vault_content.odin:16-19.
VAULT_HEADER_BYTES :: 28

// is_vault_armored reports whether a value is an encrypted vault envelope.
//
// This deliberately uses has_prefix, matching is_vault_armored in
// src/ctl/vault_content.odin:22 (the producer of the format). Note that the
// Hub's PREVIEW/redaction helpers instead ask strings.contains(s, "vault:v1:")
// — correct there, because redaction should fail safe if the marker appears
// anywhere — but wrong for a length cap, where `contains` would let any caller
// bypass the plaintext cap by embedding the marker mid-string.
is_vault_armored :: proc(text: string) -> bool {
	return strings.has_prefix(text, VAULT_ARMOR_PREFIX)
}

// vault_armored_max_bytes returns the storage budget for a vault-armored value
// whose plaintext is capped at plaintext_max bytes, i.e. armored_len(plaintext_max)
// using the derivation above. The `+ 2) / 3` is the integer ceiling of /3.
vault_armored_max_bytes :: proc(plaintext_max: int) -> int {
	if plaintext_max < 0 do return len(VAULT_ARMOR_PREFIX)
	return len(VAULT_ARMOR_PREFIX) + 4 * ((plaintext_max + VAULT_HEADER_BYTES + 2) / 3)
}

// text_cap_limit_bytes returns the effective byte limit to enforce against
// value: the inflated armored budget when value is encrypted, else the
// plaintext cap itself.
text_cap_limit_bytes :: proc(value: string, plaintext_max: int) -> int {
	if is_vault_armored(value) do return vault_armored_max_bytes(plaintext_max)
	return plaintext_max
}

// validate_capped_text enforces an armor-aware byte cap on a text field and
// returns a Validation_Failed error naming BOTH the actual length and the
// effective limit (REQ-VCAP-3) — an error without numbers gives the caller no
// hint how much to cut. label is the field phrase, e.g. "chain description".
// Returns a zero Domain_Error (code .None) when the value fits.
//
// The message is built with fmt.tprintf, the established convention for dynamic
// domain error messages in this tree; the string is consumed while rendering the
// current request's response, so temp-allocator lifetime is sufficient.
validate_capped_text :: proc(label: string, value: string, plaintext_max: int) -> Domain_Error {
	limit := text_cap_limit_bytes(value, plaintext_max)
	if len(value) <= limit do return Domain_Error{}
	if is_vault_armored(value) {
		return domain_error(.Validation_Failed, fmt.tprintf(
			"%s is too long: %d bytes, limit %d (encrypted; ~%d plaintext)",
			label, len(value), limit, plaintext_max,
		))
	}
	return domain_error(.Validation_Failed, fmt.tprintf(
		"%s is too long: %d bytes, limit %d", label, len(value), limit,
	))
}
