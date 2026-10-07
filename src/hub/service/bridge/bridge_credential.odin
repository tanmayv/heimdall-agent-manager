// Bridge credential issuance, storage format and verification (REQ-IMPL-1).
//
// Replaces the former `hash_token` placeholder (unsalted, non-cryptographic
// FNV-1a over ~64 bits) that used to live in bridge_service.odin. Two separate
// defects were fixed together, because fixing either alone is worthless:
//
//   1. STORAGE. The stored value is now salted SHA-256 with a per-credential
//      CSPRNG salt, verified with a constant-time comparison.
//   2. GENERATION. The secret is now 256 bits of CSPRNG output. It used to be
//      `platform.generate_id`, i.e. a prefix plus a unix-nanosecond timestamp —
//      no secret entropy at all. Upgrading the hash over a guessable secret
//      would have left the credential just as forgeable; an attacker never
//      attacks the hash when they can enumerate the token directly.
//
// TOKEN FORMAT: `<prefix><record_id>.<secret_hex>`
//
//   hbe_benr_19fa3c....<64 hex chars>     enrolment token
//   hbr_brg_19fa3d....<64 hex chars>      bridge token
//
// The record id is PUBLIC and is the lookup key; only the secret after the "."
// is confidential. This shape is the reason a random salt is possible at all:
// verification used to be an SQL equality on the hash column
// (`WHERE token_hash = ?`), which forced the stored value to be a deterministic
// function of the token and therefore unsaltable. The row is now found by its
// primary key and the secret is compared in constant time.
//
// It also gives REQ-ENROLL-13 what it needs: single-use refresh rotation and
// family revocation require a row IDENTITY that is independent of the secret,
// which hash-as-lookup-key cannot provide.
//
// STORED FORMAT: `sha256:v1:<salt_hex>:<digest_hex>`
//
//   digest = SHA-256(salt_hex || ":" || secret)
//
// The salt is hashed as its hex TEXT, exactly as stored, so verification needs
// no decoding step; ":" is not in [0-9a-f], so the two fields cannot be confused
// however they are sized. The `v1` is a format version: a stored value that does
// not carry this exact prefix is REJECTED rather than guessed at, which is what
// retires the old `h_xxxxxxxx` values and — importantly — what makes the empty
// string (the `bridges.bridge_token_hash` column default) unverifiable instead
// of a wildcard.
//
// WHY SHA-256 AND NOT argon2id, even though core:crypto offers it: under this
// format the secret is 256 bits of CSPRNG output, so it is not guessable and
// there is no dictionary to stretch. Argon2id's work factor buys nothing against
// an unguessable secret and would add real latency to EVERY authenticated bridge
// request, which is exactly what REQ-ENROLL-12 (auth off the hot path) is trying
// to avoid. The versioned prefix keeps argon2id available if a low-entropy
// secret is ever introduced — if you are reading this because you want password
// hashing, that is the case where you add `v2`, not a reason to change `v1`.
//
// ALLOCATION: the procs here return temp-allocator memory, matching the
// `fmt.tprintf` lifetime of the `hash_token`/`generate_id` values they replace.
// Every value is consumed within the request that produced it — written to
// SQLite (which copies via bind_text) or serialised into a response — and no
// call site frees it. This is deliberate, not an oversight: returning heap
// memory here would leak at all four call sites.
package bridge

import "core:crypto"
import "core:crypto/sha2"
import "core:strings"
import platform "odin_test:hub/platform"

// ENROLLMENT_TOKEN_PREFIX / BRIDGE_TOKEN_PREFIX are load-bearing beyond
// cosmetics: enroll_bridge_handler rejects any bearer token that does not start
// with "hbe_" before the service is ever called.
ENROLLMENT_TOKEN_PREFIX :: "hbe_"
BRIDGE_TOKEN_PREFIX :: "hbr_"

// CREDENTIAL_SECRET_BYTES = 32 => 256 bits, hex-encoded to 64 chars.
CREDENTIAL_SECRET_BYTES :: 32
// CREDENTIAL_SALT_BYTES = 16 => 128 bits. The salt is not secret; it only has to
// be unique per credential, which 128 bits of CSPRNG makes overwhelmingly likely.
CREDENTIAL_SALT_BYTES :: 16

CREDENTIAL_HASH_PREFIX :: "sha256:v1:"
CREDENTIAL_SECRET_SEPARATOR :: "."
CREDENTIAL_FIELD_SEPARATOR :: ":"

// CREDENTIAL_DUMMY_HASH is a well-formed stored value whose secret nobody knows.
// It exists so a lookup MISS can still perform the same salted hash and the same
// constant-time comparison as a lookup HIT — see verify_credential_miss.
CREDENTIAL_DUMMY_HASH :: "sha256:v1:00000000000000000000000000000000:0000000000000000000000000000000000000000000000000000000000000000"

// issue_credential mints a fresh credential for the record identified by
// record_id.
//
// THIS IS THE ONLY SANCTIONED WAY TO MINT A BRIDGE CREDENTIAL. The former
// `hash_token` is deleted and must not come back, and a credential secret must
// never be produced by `platform.generate_id` — that is a unix-nanosecond
// timestamp, not a secret (see the GENERATION note at the top of this file).
// Both the classic enrolment path and the device-grant path go through here.
//
// Returns (token, stored_hash, true) on success, where `token` is handed to the
// bridge exactly once and `stored_hash` is what goes in the database. Returns
// ("", "", false) if the OS entropy source is unavailable — the caller MUST then
// deny the operation rather than issue a weaker credential.
// `entropy_source` is a test seam (see platform.random_bytes); production
// callers leave it at the default.
issue_credential :: proc(prefix, record_id: string, entropy_source := platform.RANDOM_SOURCE) -> (token: string, stored_hash: string, ok: bool) {
	if prefix == "" || record_id == "" do return "", "", false
	// A record id containing the separator would make the token ambiguous to
	// split. Hub ids never do, but assert it rather than trust it.
	if strings.contains(record_id, CREDENTIAL_SECRET_SEPARATOR) do return "", "", false
	secret, secret_ok := platform.random_hex(CREDENTIAL_SECRET_BYTES, context.temp_allocator, entropy_source)
	if !secret_ok do return "", "", false
	hash, hash_ok := hash_credential_secret(secret, entropy_source)
	if !hash_ok do return "", "", false
	token = strings.concatenate({prefix, record_id, CREDENTIAL_SECRET_SEPARATOR, secret}, context.temp_allocator)
	return token, hash, true
}

// hash_credential_secret produces the stored representation of a secret with a
// fresh random salt: `sha256:v1:<salt_hex>:<digest_hex>`.
//
// Called once per credential at issue time. Because the salt is random, hashing
// the same secret twice yields two different stored values — which is the whole
// point, and the reason this can never be used as a lookup key.
hash_credential_secret :: proc(secret: string, entropy_source := platform.RANDOM_SOURCE) -> (string, bool) {
	if secret == "" do return "", false
	salt, salt_ok := platform.random_hex(CREDENTIAL_SALT_BYTES, context.temp_allocator, entropy_source)
	if !salt_ok do return "", false
	return hash_credential_secret_with_salt(salt, secret), true
}

// hash_credential_secret_with_salt is the deterministic core, split out so the
// verify path and the tests can reproduce a digest from a known salt.
hash_credential_secret_with_salt :: proc(salt_hex, secret: string) -> string {
	digest: [sha2.DIGEST_SIZE_256]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	separator := CREDENTIAL_FIELD_SEPARATOR
	sha2.update(&ctx, transmute([]byte)salt_hex)
	sha2.update(&ctx, transmute([]byte)separator)
	sha2.update(&ctx, transmute([]byte)secret)
	sha2.final(&ctx, digest[:])
	return strings.concatenate({
		CREDENTIAL_HASH_PREFIX,
		salt_hex,
		":",
		platform.hex_encode(digest[:], context.temp_allocator),
	}, context.temp_allocator)
}

// split_credential splits `<prefix><record_id>.<secret>` into its two parts.
//
// Returns ok=false for anything malformed — wrong prefix, no separator, or an
// empty id or secret. An empty secret must never reach the verify path; see
// verify_credential.
split_credential :: proc(prefix, token: string) -> (record_id: string, secret: string, ok: bool) {
	if prefix == "" do return "", "", false
	if !strings.has_prefix(token, prefix) do return "", "", false
	body := token[len(prefix):]
	// Split on the FIRST separator and carry both halves verbatim: the id goes
	// straight to the repository and the inner `benr_`/`brg_` prefix is never
	// stripped, re-added or validated here. Reconstruction is where parsing bugs
	// live, and a mis-split that yields an empty secret is an F4-class failure
	// (an empty secret must never reach the verify path), so every malformed
	// shape is rejected HERE, before any lookup happens.
	idx := strings.index(body, CREDENTIAL_SECRET_SEPARATOR)
	if idx <= 0 do return "", "", false
	record_id = body[:idx]
	secret = body[idx + len(CREDENTIAL_SECRET_SEPARATOR):]
	if record_id == "" || secret == "" do return "", "", false
	return record_id, secret, true
}

// verify_credential reports whether `secret` is the secret behind `stored_hash`.
//
// Fails closed on every malformed input. Two cases are worth naming because they
// used to be exploitable or silently permissive:
//   - stored_hash == "" (the column default for a bridge row that never received
//     a token) can never verify, so an empty or absent secret authorises nothing.
//   - a legacy `h_xxxxxxxx` value does not carry the versioned prefix and is
//     rejected outright; those bridges re-enrol, which REQ-IMPL-6 assumes anyway.
//
// The digest comparison is crypto.compare_constant_time, so a caller cannot
// learn a correct digest prefix by timing repeated attempts.
verify_credential :: proc(stored_hash, secret: string) -> bool {
	if stored_hash == "" || secret == "" do return false
	if !strings.has_prefix(stored_hash, CREDENTIAL_HASH_PREFIX) do return false
	body := stored_hash[len(CREDENTIAL_HASH_PREFIX):]
	sep := strings.index(body, ":")
	if sep <= 0 do return false
	salt_hex := body[:sep]
	expected := body[sep + 1:]
	if salt_hex == "" || expected == "" do return false
	recomputed := hash_credential_secret_with_salt(salt_hex, secret)
	// Compare the full stored strings so the salt and the version prefix are
	// covered too, not just the digest.
	if len(recomputed) != len(stored_hash) do return false
	return crypto.compare_constant_time(transmute([]byte)recomputed, transmute([]byte)stored_hash) == 1
}

// verify_credential_miss burns the same work as a failed verify_credential on a
// row that does not exist.
//
// WHY THIS IS NOT DEAD CODE: lookup is keyed on a PUBLIC id, and hub ids are
// timestamps (F7), so an attacker can enumerate plausible `brg_`/`benr_` values.
// If a missing row returned faster than a wrong secret, that timing difference
// would reveal WHICH BRIDGES EXIST — an oracle that did not exist back when the
// whole token was the lookup key. Callers must run this on the not-found path
// instead of returning early, and must return the identical error either way.
//
// It always returns false; the result exists only so the call cannot be
// optimised away.
verify_credential_miss :: proc(secret: string) -> bool {
	return verify_credential(CREDENTIAL_DUMMY_HASH, secret)
}
