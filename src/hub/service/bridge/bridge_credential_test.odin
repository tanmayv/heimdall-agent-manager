// Tests for the bridge credential format, generation and verification
// (REQ-IMPL-1). These are the FIRST direct coverage of the hub's credential
// hashing path — the proc they replace (`hash_token`) had none, which is how an
// unsalted non-cryptographic placeholder survived to be found by an audit.
package bridge

import "core:strings"
import "core:testing"
import platform "odin_test:hub/platform"

// A path that cannot be opened, used to simulate an unavailable OS CSPRNG.
NO_ENTROPY_SOURCE :: "/nonexistent/heimdall-test/urandom"

// AC5: the same secret hashed twice yields DIFFERENT stored values, because the
// salt is per-credential and random. This is the property the old FNV-1a
// placeholder lacked: identical tokens produced identical stored values, so one
// cracked row cracked every row that shared a token.
@(test)
test_credential_same_secret_different_salts :: proc(t: ^testing.T) {
	secret := "the-same-secret-both-times"
	first, first_ok := hash_credential_secret(secret)
	second, second_ok := hash_credential_secret(secret)
	testing.expect(t, first_ok && second_ok, "both hashes were produced")
	testing.expect(t, first != second, "same secret with different salts must not produce the same stored value")
	testing.expect(t, strings.has_prefix(first, CREDENTIAL_HASH_PREFIX), "stored value carries the versioned prefix")

	// Both must still verify against the one secret, despite differing.
	testing.expect(t, verify_credential(first, secret), "first stored value verifies")
	testing.expect(t, verify_credential(second, secret), "second stored value verifies")
}

// AC5: the right secret verifies and a wrong one does not.
@(test)
test_credential_verify_right_and_wrong :: proc(t: ^testing.T) {
	token, stored, ok := issue_credential(BRIDGE_TOKEN_PREFIX, "brg_test_verify")
	testing.expect(t, ok, "credential issued")

	record_id, secret, split_ok := split_credential(BRIDGE_TOKEN_PREFIX, token)
	testing.expect(t, split_ok, "token splits")
	testing.expect_value(t, record_id, "brg_test_verify")
	testing.expect(t, verify_credential(stored, secret), "the issued secret verifies")

	testing.expect(t, !verify_credential(stored, "wrong-secret"), "a wrong secret must not verify")
	// A near-miss: the correct secret with one character changed.
	mutated := strings.concatenate({secret[:len(secret) - 1], "f" if secret[len(secret) - 1] != 'f' else "e"}, context.temp_allocator)
	testing.expect(t, !verify_credential(stored, mutated), "a secret differing in one character must not verify")
	// Truncation must not pass: a prefix of the secret is not the secret.
	testing.expect(t, !verify_credential(stored, secret[:len(secret) - 1]), "a truncated secret must not verify")
}

// AC5: a tampered stored value must not verify, whichever field was touched.
@(test)
test_credential_tampered_stored_value_fails :: proc(t: ^testing.T) {
	secret := "secret-under-test"
	stored, ok := hash_credential_secret(secret)
	testing.expect(t, ok, "hashed")

	// Flip the final digest character.
	last := stored[len(stored) - 1]
	flipped := strings.concatenate({stored[:len(stored) - 1], "0" if last != '0' else "1"}, context.temp_allocator)
	testing.expect(t, !verify_credential(flipped, secret), "a modified digest must not verify")

	// Swap the salt for a different one, leaving the digest intact.
	body := stored[len(CREDENTIAL_HASH_PREFIX):]
	sep := strings.index(body, ":")
	testing.expect(t, sep > 0, "stored value has a salt field")
	other_salt := strings.concatenate({"ff", body[2:sep]}, context.temp_allocator) if !strings.has_prefix(body[:sep], "ff") else strings.concatenate({"00", body[2:sep]}, context.temp_allocator)
	resalted := strings.concatenate({CREDENTIAL_HASH_PREFIX, other_salt, body[sep:]}, context.temp_allocator)
	testing.expect(t, !verify_credential(resalted, secret), "a substituted salt must not verify")
}

// The stored format is versioned, and anything that is not `sha256:v1:` is
// REJECTED rather than guessed at. Two cases matter in production:
//   - "" is the `bridges.bridge_token_hash` column default, so a row that never
//     received a token must not be authenticable (F4-class).
//   - "h_xxxxxxxxxxxxxxxx" is a legacy FNV-1a value; those bridges re-enrol.
@(test)
test_credential_rejects_unversioned_and_empty_stored_values :: proc(t: ^testing.T) {
	testing.expect(t, !verify_credential("", "any-secret"), "an empty stored hash must never verify")
	testing.expect(t, !verify_credential("h_0123456789abcdef", "any-secret"), "a legacy FNV-1a stored value must not verify")
	testing.expect(t, !verify_credential("sha256:v2:aa:bb", "any-secret"), "an unknown format version must not verify")
	testing.expect(t, !verify_credential("sha256:v1:", "any-secret"), "a truncated stored value must not verify")
	testing.expect(t, !verify_credential("sha256:v1:aabb", "any-secret"), "a stored value with no digest field must not verify")
	// An empty secret must never verify, even against a well-formed stored value.
	stored, ok := hash_credential_secret("real-secret")
	testing.expect(t, ok, "hashed")
	testing.expect(t, !verify_credential(stored, ""), "an empty secret must never verify")
}

// Malformed tokens are rejected at the split, BEFORE any repository lookup.
@(test)
test_credential_split_rejects_malformed_tokens :: proc(t: ^testing.T) {
	_, _, no_sep := split_credential(BRIDGE_TOKEN_PREFIX, "hbr_brg_nodot")
	testing.expect(t, !no_sep, "a token with no separator is malformed")

	_, _, empty_secret := split_credential(BRIDGE_TOKEN_PREFIX, "hbr_brg_x.")
	testing.expect(t, !empty_secret, "a token with an empty secret is malformed")

	_, _, empty_id := split_credential(BRIDGE_TOKEN_PREFIX, "hbr_.secret")
	testing.expect(t, !empty_id, "a token with an empty record id is malformed")

	_, _, wrong_prefix := split_credential(BRIDGE_TOKEN_PREFIX, "hbe_benr_x.secret")
	testing.expect(t, !wrong_prefix, "an enrollment token must not split as a bridge token")

	_, _, bare := split_credential(BRIDGE_TOKEN_PREFIX, "")
	testing.expect(t, !bare, "an empty token is malformed")

	// The id is carried VERBATIM: the inner `brg_` prefix is preserved, not
	// stripped, so it can be handed straight to the repository.
	id, secret, ok := split_credential(BRIDGE_TOKEN_PREFIX, "hbr_brg_19fa3d.deadbeef")
	testing.expect(t, ok, "a well-formed token splits")
	testing.expect_value(t, id, "brg_19fa3d")
	testing.expect_value(t, secret, "deadbeef")
}

// AC5 (regression test for the defect this task was really about): two
// credentials minted back to back must be UNRELATED.
//
// The old generator was `platform.generate_id`, i.e. prefix + unix-nanoseconds.
// Two tokens issued in the same moment shared a long common prefix and differed
// only in their low-order nanosecond digits, so knowing roughly WHEN a bridge
// enrolled was enough to enumerate its token. This test fails loudly if anyone
// reintroduces a timestamp-derived secret.
@(test)
test_credential_secrets_are_unrelated_not_sequential :: proc(t: ^testing.T) {
	token_a, stored_a, ok_a := issue_credential(BRIDGE_TOKEN_PREFIX, "brg_same_id")
	token_b, stored_b, ok_b := issue_credential(BRIDGE_TOKEN_PREFIX, "brg_same_id")
	testing.expect(t, ok_a && ok_b, "both credentials issued")

	_, secret_a, split_a := split_credential(BRIDGE_TOKEN_PREFIX, token_a)
	_, secret_b, split_b := split_credential(BRIDGE_TOKEN_PREFIX, token_b)
	testing.expect(t, split_a && split_b, "both tokens split")

	testing.expect(t, secret_a != secret_b, "two secrets must never be equal")
	testing.expect(t, stored_a != stored_b, "two stored values must never be equal")

	// 256 bits hex-encoded.
	testing.expect_value(t, len(secret_a), CREDENTIAL_SECRET_BYTES * 2)
	testing.expect_value(t, len(secret_b), CREDENTIAL_SECRET_BYTES * 2)

	// The real assertion: no shared leading run. Two nanosecond timestamps from
	// the same instant share almost every leading character; two CSPRNG draws
	// share a handful by chance. A threshold of 8 of 64 hex chars is ~2^-32
	// under chance, and the old generator would have blown straight past it.
	shared := 0
	for shared < len(secret_a) && shared < len(secret_b) && secret_a[shared] == secret_b[shared] {
		shared += 1
	}
	testing.expect(t, shared < 8, "two secrets must not share a long common prefix (timestamp-derived regression)")

	// Each secret must be hex, with no structural prefix to anchor a guess on.
	for c in secret_a {
		testing.expect(t, strings.contains(platform.HEX_DIGITS, string([]byte{byte(c)})), "secret is lower-case hex")
	}
	testing.expect(t, !strings.contains(secret_a, "_"), "the secret carries no id-style prefix")
}

// AC5: generation FAILS CLOSED when the entropy source is unavailable. It must
// deny the credential, never fall back to a predictable source.
@(test)
test_credential_fails_closed_without_entropy :: proc(t: ^testing.T) {
	token, stored, ok := issue_credential(BRIDGE_TOKEN_PREFIX, "brg_no_entropy", NO_ENTROPY_SOURCE)
	testing.expect(t, !ok, "issuing a credential without entropy must fail")
	testing.expect_value(t, token, "")
	testing.expect_value(t, stored, "")

	hash, hash_ok := hash_credential_secret("some-secret", NO_ENTROPY_SOURCE)
	testing.expect(t, !hash_ok, "hashing without a salt source must fail")
	testing.expect_value(t, hash, "")

	// And the platform primitive underneath reports the failure rather than
	// returning a zero-filled buffer.
	buf: [16]byte
	testing.expect(t, !platform.random_bytes(buf[:], NO_ENTROPY_SOURCE), "random_bytes must report an unavailable source")
	hex, hex_ok := platform.random_hex(16, context.temp_allocator, NO_ENTROPY_SOURCE)
	testing.expect(t, !hex_ok, "random_hex must report an unavailable source")
	testing.expect_value(t, hex, "")

	// The real source still works, so the test above proves fail-closed rather
	// than a permanently broken helper.
	testing.expect(t, platform.random_bytes(buf[:]), "the real entropy source is available")
}

// Guard rails on issue_credential's inputs.
@(test)
test_credential_issue_rejects_bad_inputs :: proc(t: ^testing.T) {
	_, _, no_prefix := issue_credential("", "brg_x")
	testing.expect(t, !no_prefix, "an empty prefix is rejected")
	_, _, no_id := issue_credential(BRIDGE_TOKEN_PREFIX, "")
	testing.expect(t, !no_id, "an empty record id is rejected")
	// An id containing the separator would make the token ambiguous to split.
	_, _, dotted := issue_credential(BRIDGE_TOKEN_PREFIX, "brg_has.dot")
	testing.expect(t, !dotted, "a record id containing the separator is rejected")
}

// The miss path (row not found) must behave exactly like a wrong secret: same
// false result, same hash-and-compare work. Its purpose is to stop the public
// lookup id from becoming an existence oracle, so it must not short-circuit.
@(test)
test_credential_miss_path_matches_wrong_secret :: proc(t: ^testing.T) {
	testing.expect(t, !verify_credential_miss("any-presented-secret"), "the miss path never verifies")
	testing.expect(t, !verify_credential_miss(""), "the miss path never verifies an empty secret")
	// The dummy must itself be a well-formed stored value, or the miss path
	// would exit early at the format check and do less work than a real compare.
	testing.expect(t, strings.has_prefix(CREDENTIAL_DUMMY_HASH, CREDENTIAL_HASH_PREFIX), "the dummy carries the versioned prefix")
	body := CREDENTIAL_DUMMY_HASH[len(CREDENTIAL_HASH_PREFIX):]
	sep := strings.index(body, ":")
	testing.expect(t, sep > 0, "the dummy has a salt field")
	testing.expect_value(t, len(body[:sep]), CREDENTIAL_SALT_BYTES * 2)
	testing.expect_value(t, len(body[sep + 1:]), 64)
}
