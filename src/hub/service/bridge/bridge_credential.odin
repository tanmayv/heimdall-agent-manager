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
//   hba_brg_19fa3d....<64 hex chars>      bridge access token (expiring)
//   hbf_brg_19fa3d....<64 hex chars>      bridge refresh token (single-use)
//
// `hbr_` had this same shape and was the non-expiring bridge token; it is no
// longer issued or accepted. There was also a one-time `benr_` enrolment token,
// deleted with the flow that used it.
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
// memory here would leak at every `issue_credential` call site.
package bridge

import "core:crypto"
import "core:crypto/sha2"
import "core:strings"
import platform "odin_test:hub/platform"

// BRIDGE_TOKEN_PREFIX is the LEGACY non-expiring bridge credential. Nothing mints
// one any more — REQ-IMPL-6 deleted that flow — and nothing authenticates one.
//
// THE CONSTANT SURVIVES ON PURPOSE, for recognition rather than acceptance:
// verify_bridge_token matches this prefix so a bridge still carrying a pre-device-
// flow credential is told to re-enroll instead of being handed a bare "invalid"
// (see BRIDGE_LEGACY_CREDENTIAL_MESSAGE). Delete it only once old credentials can
// no longer plausibly be in the field.
//
// ENROLLMENT_TOKEN_PREFIX is GONE with the one-time enrollment token it
// named. There is no enrollment secret to prefix any more: enrollment is approved
// in a browser and the credential is delivered to the bridge directly.
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
//
// DO NOT MAKE THIS ALLOCATION-FREE WITHOUT READING verify_credential_miss FIRST.
// The two context.temp_allocator allocations below (hex_encode and
// strings.concatenate) are what make this function — and therefore every caller,
// including verify_credential and verify_credential_miss — impossible for the
// compiler to eliminate. Allocating through the context's opaque allocator
// pointer is an observable side effect, so LLVM cannot delete these calls even
// when a caller discards the result.
//
// Rewriting this to use a stack buffer and a fixed-size array looks like a pure,
// obviously-correct optimisation. It would make the whole chain pure — and
// every PRODUCTION call site of verify_credential_miss discards its result with
// `_ =` (the unit tests assert the returned bool instead, which is why a green
// suite is no protection here).
// A pure call whose result is unused is exactly what dead-code elimination
// removes once it is inlined — and if that happens the miss path stops burning
// the dummy hash, the timing difference between "no such row" and "wrong secret"
// returns, and the bridge-existence oracle reopens. Silently: no test fails,
// because the tests assert the returned bool and not that the work was done.
//
// If you need to make this allocation-free, give verify_credential_miss a real
// data dependency (or @(optimization_mode="none")) in the same change, and verify
// the result in the built binary rather than by reasoning. Find the call sites
// and the surviving work without assuming how many there are:
//
//   grep -rn '_ = verify_credential_mis[s]' src/       # every discarding caller
//   nix develop --command \
//     odin build src/hub -collection:odin_test=src -out=/tmp/hub   # as flake.nix does
//   A=$(strings -t x /tmp/hub | grep -m1 'sha256:v1:0\{32\}:0\{64\}' | awk '{print $1}')
//   objdump -d /tmp/hub | grep "# *$A"                 # refs to the dummy hash
//
// Run it inside `nix develop`: outside it the build fails at LINK time with
// `cannot find -lsqlite3`, which looks like your mistake and is not.
//
// HOW TO READ THE RESULT. Expect at least one reference somewhere. Do NOT expect
// one per call site, and do not treat any ratio of refs to greps as the invariant:
// LLVM tail-merges the identical dummy-hash block across sibling error paths
// within a proc, so FEWER REFERENCES THAN CALL SITES IS NORMAL and is not a
// regression — the single merged block still executes on every path that reaches
// it. The ratio also moves on its own as callers are added and as the inliner's
// decisions change, which is why it is not the thing to check.
// ZERO references is the only failure signal: that means the work is gone.
// At the default level the proc is not inlined at all and the one reference sits
// inside verify_credential_miss itself.
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
	// `expected` is bound only to reject a stored value with an empty digest half;
	// it is deliberately NOT what gets compared. The comparison below covers the
	// WHOLE stored string (prefix + salt + digest), which is strictly stronger —
	// this is not an unused-variable bug.
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
// It always returns false, and every PRODUCTION call site discards the result
// with `_ =`; the unit tests are the exception and consume the bool inside
// `testing.expect`, which is consistent with the note below that those tests
// assert the return value rather than that the hashing work was done.
// Do not rely on a count here: the set of callers keeps growing (run
// `grep -rn '_ = verify_credential_mis[s]' src/` for the current set — the
// bracket keeps these comments out of their own results).
//
// WHAT ACTUALLY KEEPS THIS CALL ALIVE — and it is NOT the return value. A
// dropped result does not stop dead-code elimination; a pure call whose value
// is unused is exactly what LLVM may delete once it inlines. This call survives
// because the chain is NOT pure: verify_credential -> hash_credential_secret_with_salt
// ALLOCATES (strings.concatenate and hex_encode, both into context.temp_allocator,
// reached through an opaque function pointer in Odin's implicit context). That is
// an observable side effect, so the call is not DCE-eligible however its result
// is treated. Measured on odin dev-2026-09 (the nix store path is named
// odin-dev-2026-07a and the binary inside reports dev-2026-09 — one toolchain,
// two labels), at every optimisation level the compiler offers:
//   - NO -o: FLAG. This is what flake.nix's `odin build` invocation uses, and
//     therefore what every shipped binary is built at. Here the proc is NOT
//     inlined, so there is exactly one copy of its body and the dummy hash is
//     referenced from exactly one place — inside verify_credential_miss —
//     however many callers exist. What appears at the call sites is the CALL to
//     this proc, not the dummy hash. At this level, do not look for the dummy
//     hash at the callers; look for the call.
//   - -o:minimal: same as the default.
//   - -o:size / -o:speed / -o:aggressive: the proc IS inlined (its symbol is
//     gone), and its body — dummy pointer, length 107, direct call to
//     verify_credential — reappears at the call sites. Not necessarily once
//     each: LLVM tail-merges the identical block across sibling error paths in
//     the same proc, so there are legitimately fewer references than call sites.
// Never eliminated at any level.
//
// THEREFORE THIS PROTECTION IS CONDITIONAL — read this before "optimising" the
// hash. If hash_credential_secret_with_salt is ever made allocation-free (a stack
// buffer and a fixed-size array are the obvious change, and it looks like a pure
// refactor), this chain becomes pure, the dropped result becomes eliminable, and
// the existence oracle below silently reopens WITH EVERY TEST STILL PASSING,
// because the tests assert the return value and not that the work was performed.
// No automated test protects this invariant. If you make that change, re-verify
// the miss path in the built binary rather than by reasoning — see the recipe in
// the hash_credential_secret_with_salt header, which locates the surviving
// references without assuming which procs or how many call sites exist — or give
// this proc a real data dependency instead.
//
// DOES NOT DEFEND AGAINST: the database half of the same oracle. This equalises
// the salted hash and the constant-time compare — microseconds — but a miss still
// skips the successful SQLite row fetch and column decode that a hit performs, and
// that is plausibly the larger timing signal. The oracle is NARROWED, NOT CLOSED.
// Closing it needs the lookup cost equalised too (e.g. a dummy query), which is a
// larger change with its own risks and is not attempted here. Do not read this
// proc as making enrolment-id enumeration infeasible.
verify_credential_miss :: proc(secret: string) -> bool {
	return verify_credential(CREDENTIAL_DUMMY_HASH, secret)
}
