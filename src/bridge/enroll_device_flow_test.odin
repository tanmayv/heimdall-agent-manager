// Tests for the browser-approval enrollment flow (REQ-IMPL-4).
//
// These are @(test) in `package main` because the flow is package-main code and a
// separate test binary cannot import package main.
//
// WHAT IS ASSERTED HERE VERSUS WHAT NEEDS THE LIVE STACK. Everything in this file
// is a property of the bridge's own output: the URL it emits, what it will and will
// not accept on the callback, the shape of what it writes to disk, and when it
// schedules a refresh. The end-to-end ceremony against a real Hub is the local
// stack's job, and the handoff carries that transcript separately. The split
// matters because the two highest-value properties in this task — the key is in
// the fragment, the callback carries no secret — are decided entirely by the
// emitted string, so a unit test pins them more precisely than a stack run can.
package main

import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:sync"
import "core:testing"

// A fixed, well-formed uncompressed P-256 point: 0x04 then bytes 1..64. Its
// fingerprint and base64url encoding below were computed INDEPENDENTLY in python
// (sha256 of the decoded point, first 8 bytes as hex quads), not read back out of
// this implementation — a test that derives its expectation from the code under
// test proves only self-consistency.
TEST_PUBKEY_HEX :: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
TEST_PUBKEY_FINGERPRINT :: "0ed3 a6ab 957f f6f5"


// bridge_enroll_test_mode reads a path's permission bits as an octal integer via
// stat(2). os.File_Info.mode is a Permissions bit_set in this toolchain, which
// cannot be masked with an octal literal, and the repo already reads modes this
// way (see the vault-key permission checks in main.odin).
bridge_enroll_test_mode :: proc(path: string) -> (int, bool) {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK do return 0, false
	mode := 0
	bits := [?]struct{flag: posix.mode_t, value: int}{
		{{.IRUSR}, 0o400}, {{.IWUSR}, 0o200}, {{.IXUSR}, 0o100},
		{{.IRGRP}, 0o040}, {{.IWGRP}, 0o020}, {{.IXGRP}, 0o010},
		{{.IROTH}, 0o004}, {{.IWOTH}, 0o002}, {{.IXOTH}, 0o001},
	}
	for b in bits {
		if (st.st_mode & b.flag) == b.flag do mode |= b.value
	}
	return mode, true
}

bridge_enroll_test_rmdir :: proc(path: string) {
	posix.rmdir(strings.clone_to_cstring(path, context.temp_allocator))
}

// ===== Property 1: the public key is in the FRAGMENT, never the query string =====

@(test)
enroll_approval_url_puts_the_key_in_the_fragment :: proc(t: ^testing.T) {
	url := bridge_enroll_approval_url("https://heimdall.example.com", "KRJT-9FMQ", TEST_PUBKEY_HEX, 0, "")
	defer delete(url)

	hash_at := strings.index_byte(url, '#')
	testing.expect(t, hash_at > 0, "the approval URL must carry a fragment")
	before := url[:hash_at]
	fragment := url[hash_at + 1:]

	// The key is present, as the 130-char hex the rest of the system speaks, AFTER
	// the '#'. Hex rather than base64url is the coordinator's Q2 ruling: one encoding
	// end to end, so no new parser can be silently missing at the vault unlock.
	testing.expect(t, strings.contains(fragment, TEST_PUBKEY_HEX), "the fragment must carry the hex public key")
	testing.expect(t, strings.contains(fragment, "bpk="), "the fragment must carry bpk=")

	// THE LOAD-BEARING HALF: nothing about the key may appear before the '#'. A
	// query parameter would be transmitted to the Hub, which could then substitute
	// the key — the MITM this design exists to close (design §5.4.1).
	testing.expect(t, !strings.contains(before, "bpk"), "nothing before the '#' may mention bpk — a fragment is never sent to the server, a query parameter is")
	testing.expect(t, !strings.contains(before, TEST_PUBKEY_HEX), "nothing before the '#' may carry the public key")

	// REQ-IMPL-5 moved the approval screen into the SPA, which is hash-routed, so
	// the route itself now lives after the '#' and EVERY parameter rides in the
	// fragment with it — including the user_code, which used to be the one thing in
	// a real query string. That is strictly stronger than the previous shape: there
	// is now NO query string for the Hub to log at all.
	testing.expectf(t, !strings.contains(before, "?"), "there must be no query string before the '#' at all, got %q", before)
	testing.expect(t, strings.contains(fragment, "user_code=KRJT-9FMQ"), "the user_code rides in the fragment with everything else")
	testing.expectf(t, strings.has_prefix(fragment, "/enroll/approve?"), "the fragment must open with the SPA approval route, got %q", fragment)
}

@(test)
enroll_approval_url_fragment_decodes_to_the_same_point :: proc(t: ^testing.T) {
	url := bridge_enroll_approval_url("https://heimdall.example.com", "AAAA-BBBB", TEST_PUBKEY_HEX, 0, "")
	defer delete(url)
	start := strings.index(url, "bpk=")
	testing.expect(t, start >= 0, "fragment must carry bpk=")
	encoded := url[start + len("bpk="):]
	if amp := strings.index_byte(encoded, '&'); amp >= 0 do encoded = encoded[:amp]
	// The browser decodes this and imports a 65-byte uncompressed point; if the
	// round-trip breaks, the UI's `!== 65 || [0] !== 0x04` guard rejects the key and
	// the vault silently stays locked while enrollment still looks successful.
	testing.expectf(t, encoded == TEST_PUBKEY_HEX, "fragment key must be the hex point verbatim, got %q", encoded)
	decoded, ok := hex.decode(transmute([]byte)(encoded), context.temp_allocator)
	testing.expect(t, ok, "the fragment value must be decodable hex")
	testing.expect(t, len(decoded) == 65 && decoded[0] == 0x04, "it must decode to a 65-byte uncompressed point")
	// Hex is URL-safe, so nothing in the fragment needs escaping — a percent-encoded
	// key would not survive the UI's strict parser.
	testing.expect(t, !strings.contains(encoded, "%"), "the hex key must need no percent-encoding")
}

@(test)
enroll_approval_url_carries_no_secret_anywhere :: proc(t: ^testing.T) {
	// The callback port and state DO ride in the fragment (the Hub has no
	// redirect_uri field, so the browser can only learn the port from the bridge).
	// Neither is a credential: `state` is a correlator, and a valid callback only
	// causes a redemption attempt that still fails without a real Hub-side approval.
	url := bridge_enroll_approval_url("https://heimdall.example.com", "AAAA-BBBB", TEST_PUBKEY_HEX, 49281, "state-nonce-value")
	defer delete(url)
	// What must never be in the link, in any position: the PKCE verifier and the
	// device code are the two values that would let a third party redeem the grant.
	testing.expect(t, !strings.contains(url, "code_verifier"), "the approval link must never carry the PKCE verifier")
	testing.expect(t, !strings.contains(url, "device_code"), "the approval link must never carry the device code")
	testing.expect(t, !strings.contains(url, "access_token"), "the approval link must never carry a credential")
	hash_at := strings.index_byte(url, '#')
	testing.expect(t, strings.contains(url[hash_at:], "cb=49281"), "the callback port rides in the fragment")
	testing.expect(t, !strings.contains(url[:hash_at], "cb="), "the callback port must not reach the Hub in the query string")
	testing.expect(t, !strings.contains(url[:hash_at], "state="), "the callback state must not reach the Hub in the query string")
}

// ===== Property 2: the callback accepts state + status only, and nothing else =====

@(test)
enroll_callback_parses_only_state_and_status :: proc(t: ^testing.T) {
	method, path, query := bridge_enroll_request_line("GET /enroll/callback?state=abc123&status=approved HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	testing.expect(t, method == "GET", "method")
	testing.expectf(t, path == BRIDGE_ENROLL_CALLBACK_PATH, "path was %q", path)
	testing.expect(t, bridge_enroll_query_value(query, "state") == "abc123", "state")
	testing.expect(t, bridge_enroll_query_value(query, "status") == "approved", "status")
	// A field the callback does not accept reads back empty: the handler keys off
	// state and status only, so a secret smuggled into the URL is never consumed.
	testing.expect(t, bridge_enroll_query_value(query, "access_token") == "", "unknown fields must not be read")
}

@(test)
enroll_callback_state_match_is_exact_and_fails_closed :: proc(t: ^testing.T) {
	nonce := "s3cr3t-nonce-value-0123456789abcdef"
	testing.expect(t, bridge_enroll_state_matches(nonce, nonce), "the matching nonce must be accepted")
	testing.expect(t, !bridge_enroll_state_matches(nonce, "s3cr3t-nonce-value-0123456789abcdee"), "a one-byte difference must be rejected")
	testing.expect(t, !bridge_enroll_state_matches(nonce, nonce[:len(nonce) - 1]), "a truncated prefix must be rejected")
	testing.expect(t, !bridge_enroll_state_matches(nonce, ""), "an absent state must be rejected")
	// THE F4 FAILURE CLASS: a blank expectation must never authorise a caller. This
	// is the same bug shape as the loopback authorizer returning true when the
	// configured token is empty.
	testing.expect(t, !bridge_enroll_state_matches("", "anything"), "a bridge with no nonce must accept nobody")
	testing.expect(t, !bridge_enroll_state_matches("", ""), "two empties must not be a match")
}

@(test)
enroll_callback_page_is_self_contained :: proc(t: ^testing.T) {
	page := bridge_enroll_callback_page("approved", context.temp_allocator)
	// No subresources at all: nothing to leak the URL through a Referer, and nothing
	// loaded from the bridge's cleartext loopback origin.
	testing.expect(t, !strings.contains(page, "<script"), "the close-the-tab page must load no script")
	testing.expect(t, !strings.contains(page, "src="), "the close-the-tab page must load no subresource")
	testing.expect(t, !strings.contains(page, "http://"), "the close-the-tab page must reference no URL")
	denied := bridge_enroll_callback_page("denied", context.temp_allocator)
	testing.expect(t, strings.contains(denied, "not approved"), "a non-approved status must say so rather than claiming success")
}

// ===== PKCE =====

@(test)
enroll_pkce_challenge_matches_rfc7636_vector :: proc(t: ^testing.T) {
	// RFC 7636 Appendix B's verifier and its expected S256 challenge, verbatim.
	// Using the RFC's own vector rather than a locally-generated pair is what makes
	// this test evidence that the Hub (which recomputes the same way) will agree.
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	challenge := bridge_pkce_challenge(verifier, context.temp_allocator)
	testing.expectf(t, challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256 challenge mismatch: %q", challenge)
	// Unpadded, URL-safe: the Hub's validator requires exactly 43 chars from the
	// base64url alphabet and rejects '=' padding.
	testing.expect(t, len(challenge) == 43, "an S256 challenge is 43 unpadded base64url chars")
	testing.expect(t, !strings.contains(challenge, "="), "the challenge must not be padded")
	testing.expect(t, !strings.contains(challenge, "+") && !strings.contains(challenge, "/"), "the challenge must use the URL-safe alphabet")
}

@(test)
enroll_generated_verifier_satisfies_rfc7636 :: proc(t: ^testing.T) {
	verifier, ok := bridge_enroll_random_token(context.temp_allocator)
	testing.expect(t, ok, "entropy must be available in the test environment")
	testing.expectf(t, len(verifier) >= 43 && len(verifier) <= 128, "verifier length %d is outside RFC 7636 §4.1", len(verifier))
	for i in 0 ..< len(verifier) {
		c := verifier[i]
		allowed :=
			(c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '.' || c == '_' || c == '~'
		testing.expectf(t, allowed, "verifier byte %q is outside the unreserved set", rune(c))
	}
	second, _ := bridge_enroll_random_token(context.temp_allocator)
	testing.expect(t, verifier != second, "two draws must differ — a constant verifier would make PKCE decorative")
}

// ===== The fingerprint the human compares =====

@(test)
enroll_fingerprint_matches_the_hub_derivation :: proc(t: ^testing.T) {
	fp, ok := bridge_enroll_fingerprint(TEST_PUBKEY_HEX, context.temp_allocator)
	testing.expect(t, ok, "a well-formed point must produce a fingerprint")
	// Independently computed in python over the DECODED point. If the bridge hashed
	// the hex TEXT instead, this value would differ and the human comparison against
	// the Hub's display would fail for every bridge.
	testing.expectf(t, fp == TEST_PUBKEY_FINGERPRINT, "fingerprint mismatch: %q", fp)
}

@(test)
enroll_fingerprint_refuses_a_malformed_point :: proc(t: ^testing.T) {
	// Each rejection matters because an empty fingerprint would render on the
	// approval page as "nothing to compare", which looks like a match.
	_, short := bridge_enroll_fingerprint("0401020304", context.temp_allocator)
	testing.expect(t, !short, "a short key must be refused")
	compressed := strings.concatenate({"02", TEST_PUBKEY_HEX[2:]}, context.temp_allocator)
	_, not_uncompressed := bridge_enroll_fingerprint(compressed, context.temp_allocator)
	testing.expect(t, !not_uncompressed, "a non-0x04 prefix must be refused")
	_, empty := bridge_enroll_fingerprint("", context.temp_allocator)
	testing.expect(t, !empty, "an empty key must be refused")
}

// ===== The machine descriptor — the defect this task exists to fix =====

@(test)
enroll_descriptor_refuses_the_old_placeholder :: proc(t: ^testing.T) {
	// The literal that used to ship for every machine. If it ever comes back, the
	// approval screen shows the same constant for an entire fleet and there is
	// nothing for the human to recognise — REQ-IMPL-5 is then meaningless.
	testing.expect(t, !bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = "ham-bridge"}), "the hardcoded placeholder must be refused")
	testing.expect(t, !bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = ""}), "an empty hostname must be refused")
	testing.expect(t, !bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = "   "}), "a blank hostname must be refused")
	testing.expect(t, bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = "dawnstar"}), "a real hostname must be accepted")
}

@(test)
enroll_descriptor_reads_real_values_from_the_host :: proc(t: ^testing.T) {
	d := bridge_enroll_machine_descriptor(context.temp_allocator)
	testing.expect(t, strings.trim_space(d.hostname) != "", "a real hostname must be resolvable on the test host")
	testing.expect(t, d.hostname != "ham-bridge", "the hostname must not be the placeholder")
	testing.expect(t, strings.trim_space(d.os) != "", "os must be populated")
	testing.expect(t, strings.trim_space(d.arch) != "", "arch must be populated")
	testing.expect(t, strings.trim_space(d.bridge_version) != "", "bridge_version must be populated")
}

@(test)
enroll_authorize_body_sends_the_descriptor_and_no_fingerprint :: proc(t: ^testing.T) {
	d := Bridge_Machine_Descriptor{
		hostname = "dawnstar", os = "Linux", os_version = "6.18.49", arch = "amd64",
		os_user = "tanmay", bridge_version = "1.2.3",
	}
	body := bridge_enroll_authorize_body(d, TEST_PUBKEY_HEX, "challenge-value", context.temp_allocator)
	// device_label is the field the Hub maps into the bridge row's machine_hostname,
	// so the real hostname has to land THERE specifically.
	testing.expect(t, strings.contains(body, "\"device_label\":\"dawnstar\""), "device_label must carry the real hostname")
	testing.expect(t, strings.contains(body, "\"os_user\":\"tanmay\""), "os_user must be sent")
	testing.expect(t, strings.contains(body, "\"os\":\"Linux 6.18.49 amd64\""), "os must carry the real os/version/arch")
	testing.expect(t, strings.contains(body, "\"app_version\":\"1.2.3\""), "the bridge version must be sent")
	testing.expect(t, strings.contains(body, "\"code_challenge_method\":\"S256\""), "S256 only")
	testing.expect(t, !strings.contains(body, "\"hostname\":\"ham-bridge\""), "the placeholder must be gone")
	// The Hub COMPUTES the fingerprint and rejects a disagreeing body value, so
	// sending one can only cause a 400.
	testing.expect(t, !strings.contains(body, "bridge_key_fingerprint"), "the bridge must not assert a fingerprint; the Hub derives it")
	testing.expect(t, !strings.contains(body, "code_verifier"), "the verifier is revealed only at redemption, never at authorize")
}

// ===== F4: the bridge cannot finish enrollment holding nothing =====

@(test)
enroll_credential_rejects_every_empty_shape :: proc(t: ^testing.T) {
	// Each of these is a shape that, if accepted and written, would leave the bridge
	// with a blank or unusable token — and a blank token is what makes the loopback
	// authorizer authorise every caller (audit F4).
	testing.expect(t, !bridge_enroll_credential_usable(""), "empty")
	testing.expect(t, !bridge_enroll_credential_usable("   "), "blank")
	testing.expect(t, !bridge_enroll_credential_usable("hba_"), "prefix only")
	testing.expect(t, !bridge_enroll_credential_usable("hba_btk_1"), "no separator")
	testing.expect(t, !bridge_enroll_credential_usable("hba_btk_1."), "empty secret half")
	testing.expect(t, !bridge_enroll_credential_usable("hba_.secret"), "empty id half")
	testing.expect(t, !bridge_enroll_credential_usable(".secret"), "no prefix at all")
	testing.expect(t, !bridge_enroll_credential_usable("hlat_agent.secret"), "an agent token is not a bridge credential")
	testing.expect(t, bridge_enroll_credential_usable("hba_btk_19fa3d.deadbeefdeadbeef"), "a well-formed access token is accepted")
	testing.expect(t, bridge_enroll_credential_usable("hbf_btk_19fa3d.deadbeefdeadbeef"), "a well-formed refresh token is accepted")
	testing.expect(t, bridge_enroll_credential_usable("hbr_brg_19fa3d.deadbeefdeadbeef"), "a legacy hbr_ credential is still accepted")
}

@(test)
enroll_persist_refuses_to_write_a_blank_credential :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/ham-enroll-test-%d", bridge_now_unix_ms())
	path := fmt.tprintf("%s/credential", dir)
	defer bridge_enroll_test_rmdir(dir)
	testing.expect(t, !bridge_write_secret_file(path, ""), "an empty credential must not be written")
	testing.expect(t, !bridge_write_secret_file(path, "   "), "a blank credential must not be written")
	_, exists := bridge_enroll_test_mode(path)
	testing.expect(t, !exists, "no file may exist after a refused write")
	ok := bridge_enroll_persist(Bridge_Enroll_Credential{access_token = ""}, path, "", "https://example.com")
	testing.expect(t, !ok, "persisting an empty access token must fail")
}

// ===== At-rest storage: 0600, and never in config.toml =====

@(test)
enroll_credential_file_is_0600_in_a_0700_directory :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/ham-enroll-mode-%d", bridge_now_unix_ms())
	path := fmt.tprintf("%s/credential", dir)
	defer os.remove(path)
	defer bridge_enroll_test_rmdir(dir)
	testing.expect(t, bridge_write_secret_file(path, "hba_btk_1.secretsecret"), "the write must succeed")
	mode, mode_ok := bridge_enroll_test_mode(path)
	testing.expect(t, mode_ok, "the file must exist")
	// 0600 exactly: group and other must have nothing. This is what keeps a
	// DIFFERENT local user out; it does not and cannot stop the same user (§3.2).
	testing.expectf(t, mode == 0o600, "credential mode was %o, expected 600", mode)
	dir_mode, dir_ok := bridge_enroll_test_mode(dir)
	testing.expect(t, dir_ok, "the parent directory must exist")
	testing.expectf(t, dir_mode == 0o700, "parent directory mode was %o, expected 700", dir_mode)
	// The content round-trips exactly — a credential mangled on the way to disk is
	// indistinguishable from a revoked one at the next start.
	read_back, read_ok := bridge_read_token_file(path)
	defer delete(read_back)
	testing.expect(t, read_ok && read_back == "hba_btk_1.secretsecret", "the credential must round-trip unchanged")
}

@(test)
enroll_rewrite_is_atomic_and_leaves_no_temp_file :: proc(t: ^testing.T) {
	// A refresh rewrites this file under a running bridge, so a reader must see the
	// old content or the new one and never a truncated line.
	dir := fmt.tprintf("/tmp/ham-enroll-atomic-%d", bridge_now_unix_ms())
	path := fmt.tprintf("%s/credential", dir)
	defer os.remove(path)
	defer bridge_enroll_test_rmdir(dir)
	testing.expect(t, bridge_write_secret_file(path, "hba_btk_1.first"), "first write")
	testing.expect(t, bridge_write_secret_file(path, "hba_btk_2.second"), "rotation")
	read_back, _ := bridge_read_token_file(path)
	defer delete(read_back)
	testing.expect(t, read_back == "hba_btk_2.second", "the rotated credential must be the one on disk")
	_, tmp_exists := bridge_enroll_test_mode(fmt.tprintf("%s.tmp", path))
	testing.expect(t, !tmp_exists, "no .tmp file may survive a completed write")
}

@(test)
enroll_never_writes_a_credential_into_config_toml :: proc(t: ^testing.T) {
	// Audit F2, closed by removing the path: the merge is called with an EMPTY token
	// on this flow, and an empty token writes no bridge_token line at all.
	merged := bridge_config_merge("", "https://heimdall.example.com", "", "brg_123")
	defer delete(merged)
	testing.expect(t, !strings.contains(merged, "bridge_token"), "config.toml must never receive a bridge_token on the device flow")
	testing.expect(t, strings.contains(merged, "brg_123"), "the non-secret bridge id is fine to persist")
	testing.expect(t, strings.contains(merged, "heimdall.example.com"), "the hub url is fine to persist")
	// And the secret must not reach it even when one exists on the flow.
	with_existing := bridge_config_merge("[daemon]\nbridge_token = \"hbr_old.secret\"\n", "https://heimdall.example.com", "", "brg_123")
	defer delete(with_existing)
	testing.expect(t, !strings.contains(with_existing, "hba_"), "no new credential may be written into config.toml")
}

// ===== Proactive refresh scheduling =====

@(test)
refresh_delay_lands_in_the_jittered_band :: proc(t: ^testing.T) {
	// 1 hour: 80% is 2880s, the +/-5% jitter span is 180s, so every delay must land
	// in [2700, 3060] — comfortably before expiry, which is the point.
	lo := 3600 * (BRIDGE_REFRESH_AT_PERCENT - BRIDGE_REFRESH_JITTER_PERCENT) / 100
	hi := 3600 * (BRIDGE_REFRESH_AT_PERCENT + BRIDGE_REFRESH_JITTER_PERCENT) / 100
	for b in 0 ..= 255 {
		d := bridge_refresh_delay_seconds(3600, u8(b))
		testing.expectf(t, d >= lo && d <= hi, "jitter byte %d produced %ds, outside [%d, %d]", b, d, lo, hi)
		testing.expectf(t, d < 3600, "a refresh at %ds would be at or after expiry", d)
	}
	// The jitter must actually spread: identical delays for every byte would be a
	// synchronised fleet, which is the failure the jitter exists to prevent.
	testing.expect(t, bridge_refresh_delay_seconds(3600, 0) != bridge_refresh_delay_seconds(3600, 255), "the jitter must vary with its input")
	testing.expect(t, bridge_refresh_delay_seconds(3600, 0) == lo, "the low end of the band must be reachable")
	testing.expect(t, bridge_refresh_delay_seconds(3600, 255) == hi, "the high end of the band must be reachable")
}

@(test)
refresh_delay_is_zero_for_a_non_expiring_credential :: proc(t: ^testing.T) {
	// A legacy `hbr_` bridge reports no expiry. Zero means "schedule nothing", and
	// must not be confused with "refresh immediately" — that would be a hot loop
	// against the Hub for every pre-REQ-IMPL-3 bridge in the fleet.
	testing.expect(t, bridge_refresh_delay_seconds(0, 128) == 0, "no expiry means no schedule")
	testing.expect(t, bridge_refresh_delay_seconds(-1, 128) == 0, "a negative expiry means no schedule")
}

@(test)
refresh_delay_never_schedules_past_expiry_on_short_lifetimes :: proc(t: ^testing.T) {
	// The 30s floor could otherwise overshoot a very short lifetime, scheduling a
	// renewal for after the token is already dead.
	for lifetime in ([?]int{1, 5, 10, 29, 30, 31, 60, 120}) {
		d := bridge_refresh_delay_seconds(lifetime, 128)
		testing.expectf(t, d <= lifetime, "lifetime %ds scheduled a refresh at %ds, after expiry", lifetime, d)
		testing.expectf(t, d > 0, "lifetime %ds must still schedule something", lifetime)
	}
}

// ===== The Hub origin is the only input =====

@(test)
enroll_hub_url_accepts_an_origin_and_rejects_everything_else :: proc(t: ^testing.T) {
	origin, ok := bridge_enroll_hub_url("https://hub.example.com/", context.temp_allocator)
	testing.expect(t, ok && origin == "https://hub.example.com", "a trailing slash must be normalised away")
	plain, plain_ok := bridge_enroll_hub_url("http://127.0.0.1:8190", context.temp_allocator)
	testing.expect(t, plain_ok && plain == "http://127.0.0.1:8190", "a local http origin must be accepted for the dev stack")
	// A path is refused rather than trimmed: it most likely means the operator
	// pasted the approval page, and silently deriving the origin from it would make
	// a wrong host look like it worked.
	_, with_path := bridge_enroll_hub_url("https://hub.example.com/enroll", context.temp_allocator)
	testing.expect(t, !with_path, "a URL with a path must be refused")
	_, no_scheme := bridge_enroll_hub_url("hub.example.com", context.temp_allocator)
	testing.expect(t, !no_scheme, "a bare hostname must be refused")
	_, empty := bridge_enroll_hub_url("", context.temp_allocator)
	testing.expect(t, !empty, "an empty value must be refused")
	_, fragment := bridge_enroll_hub_url("https://hub.example.com/#x", context.temp_allocator)
	testing.expect(t, !fragment, "a URL with a fragment must be refused")
}

// ===== Property 3: the polling path is sufficient on its own =====

@(test)
enroll_completes_on_the_polling_path_with_no_callback :: proc(t: ^testing.T) {
	// THE ACCEPTANCE CRITERION: enrollment must complete with the callback blocked.
	// This asserts the structural reason it can — with no listener bound, the
	// emitted link simply carries no cb/state, and nothing in the redemption path
	// consumes either. The poll loop's inputs are the device_code and the verifier,
	// both independent of the callback.
	url := bridge_enroll_approval_url("https://heimdall.example.com", "AAAA-BBBB", TEST_PUBKEY_HEX, 0, "")
	defer delete(url)
	testing.expect(t, !strings.contains(url, "cb="), "with no listener bound, no callback port is advertised")
	testing.expect(t, !strings.contains(url, "state="), "with no listener bound, no state is advertised")
	// The key is still delivered, so the vault unlock still works headless.
	testing.expect(t, strings.contains(url, TEST_PUBKEY_HEX), "the key must still ride in the fragment on the headless path")
	// And a fired flag that nobody ever sets leaves the loop polling rather than
	// stalling: the zero value is "not fired".
	cb := Bridge_Enroll_Callback{}
	testing.expect(t, cb.fired == 0, "the callback's zero value must mean 'has not fired'")
	testing.expect(t, !cb.bound, "an unbound listener must not advertise itself")
}

@(test)
enroll_callback_bind_holds_the_socket_before_publishing_the_port :: proc(t: ^testing.T) {
	// The socket is held from bind, before any URL is composed, so there is no
	// window in which the port is named but unbound and squattable (design §3.1).
	cb := Bridge_Enroll_Callback{}
	state, _ := bridge_enroll_random_token(context.temp_allocator)
	if !bridge_enroll_callback_bind(&cb, state) {
		// A sandbox with no loopback is exactly the case the polling path covers.
		testing.expect(t, !cb.bound, "a failed bind must leave the listener unbound")
		return
	}
	defer net.close(cb.listener)
	testing.expect(t, cb.bound, "a successful bind must be recorded")
	testing.expect(t, cb.port != 0, "the kernel must have assigned an ephemeral port")
	testing.expect(t, cb.state == state, "the nonce must be bound to the listener before it serves")
	// A second bind gets a DIFFERENT port: the port is unpredictable, which is what
	// makes pre-binding it unviable for a local attacker.
	other := Bridge_Enroll_Callback{}
	if bridge_enroll_callback_bind(&other, state) {
		defer net.close(other.listener)
		testing.expect(t, other.port != cb.port, "ephemeral ports must not be reused while held")
	}
}

// ===== The second instance of the descriptor defect: the WS hello =====

@(test)
hello_reports_the_real_hostname_not_the_bridge_id :: proc(t: ^testing.T) {
	// The hub assigns the hello's `hostname` to machine_hostname (and to the label
	// when it is not user-customized), so this field previously renamed every bridge
	// after its own `brg_` id moments after it started — overwriting the real value
	// this task captures at enrollment. Observed live on the local stack before the
	// fix: machine_hostname = brg_18dc53cf6bbdb13a.
	host := bridge_hello_hostname()
	testing.expect(t, !strings.has_prefix(host, "brg_"), "the hello must never report a bridge id as the hostname")
	testing.expect(t, host != "ham-bridge", "the hello must not report the old placeholder either")
	// It must agree with the descriptor the approval screen was shown, or the
	// displayed hostname would depend on which message the hub saw last.
	d := bridge_enroll_machine_descriptor(context.temp_allocator)
	testing.expectf(t, host == d.hostname, "hello hostname %q disagrees with the enrollment descriptor %q", host, d.hostname)
	// Cached: a second call must not re-resolve into a different answer.
	testing.expect(t, bridge_hello_hostname() == host, "the resolved hostname must be stable for the process")
}

@(test)
hello_json_carries_the_real_hostname :: proc(t: ^testing.T) {
	// Asserted on the emitted frame, not just the helper, because the defect was in
	// which value the frame passed — the helper is new and the frame is what the hub
	// reads.
	bridge_config.daemon_id = "brg_1234567890abcdef"
	hello := bridge_hub_hello_json()
	defer delete(hello)
	testing.expect(t, strings.contains(hello, "\"hostname\":\""), "the hello must carry a hostname field")
	testing.expect(t, !strings.contains(hello, "\"hostname\":\"brg_1234567890abcdef\""), "the hello must not pass daemon_id as the hostname")
	host := bridge_hello_hostname()
	if host != "" {
		testing.expectf(t, strings.contains(hello, fmt.tprintf("\"hostname\":\"%s\"", host)), "the hello must carry the resolved hostname %q", host)
	}
}

@(test)
enroll_callback_signal_is_consumed_so_the_poll_cannot_spin :: proc(t: ^testing.T) {
    // REGRESSION TEST. The first implementation only READ the latch, so once a
    // callback arrived the poll loop skipped its sleep on every later iteration and
    // hammered the Hub: 7398 polls in ~8 seconds on the local stack, from one hit.
    // A latch that is read but never cleared is the bug; consuming it is the fix.
    cb := Bridge_Enroll_Callback{}
    testing.expect(t, !bridge_enroll_callback_take_fired(&cb), "no callback yet means no signal")
    sync.atomic_store(&cb.fired, 1)
    testing.expect(t, bridge_enroll_callback_take_fired(&cb), "a fired callback must be reported once")
    testing.expect(t, !bridge_enroll_callback_take_fired(&cb), "and must NOT be reported again — this is what stops the hot loop")
    testing.expect(t, !bridge_enroll_callback_take_fired(&cb), "still consumed on every later check")
    // A second genuine callback is reported again.
    sync.atomic_store(&cb.fired, 1)
    testing.expect(t, bridge_enroll_callback_take_fired(&cb), "a later callback must still be seen")
    testing.expect(t, !bridge_enroll_callback_take_fired(&cb), "and consumed again")
}

@(test)
enroll_callback_response_head_is_uncacheable_and_leaks_no_referrer :: proc(t: ^testing.T) {
    // The callback URL carries the correlator, so the response must not encourage
    // the browser to keep it or to pass it onward. Asserted on the built head
    // because the listener is one-shot: a live second request cannot observe it.
    head := bridge_enroll_callback_head(200, "OK", "text/html; charset=utf-8", 42)
    testing.expect(t, strings.contains(head, "HTTP/1.1 200 OK\r\n"), "status line")
    testing.expect(t, strings.contains(head, "Cache-Control: no-store\r\n"), "the response must be uncacheable")
    testing.expect(t, strings.contains(head, "Referrer-Policy: no-referrer\r\n"), "the callback URL must not travel in a Referer")
    testing.expect(t, strings.contains(head, "Content-Length: 42\r\n"), "content length")
    testing.expect(t, strings.has_suffix(head, "\r\n\r\n"), "the head must be terminated")
    // The bridge's OTHER loopback listener sends permissive CORS (write_response in
    // main.odin). This one must not: nothing should be able to read the callback's
    // response cross-origin.
    testing.expect(t, !strings.contains(head, "Access-Control-Allow-Origin"), "the enrollment callback must not send permissive CORS")
    not_found := bridge_enroll_callback_head(404, "Not Found", "text/plain; charset=utf-8", 10)
    testing.expect(t, strings.contains(not_found, "HTTP/1.1 404 Not Found\r\n"), "the refusal is a plain 404")
    testing.expect(t, strings.contains(not_found, "Cache-Control: no-store\r\n"), "the refusal must be uncacheable too")
}

@(test)
enroll_and_startup_agree_on_the_default_credential_path :: proc(t: ^testing.T) {
    // `enroll` writes the credential here and startup reads it from here. If the two
    // ever disagreed, an enrolled bridge would come up unable to find its own
    // credential — and because the device flow no longer writes the token into
    // config.toml (F2), there would be no second source to fall back on.
    written := bridge_enroll_token_file_from_args([]string{"ham-bridge", "enroll", "--hub", "https://hub.example.com"}, context.temp_allocator)
    read := bridge_enroll_default_credential_path(context.temp_allocator)
    testing.expectf(t, written == read, "enroll writes %q but startup reads %q", written, read)
    if read != "" {
        testing.expect(t, !strings.has_prefix(read, "~"), "the path must be expanded, not a literal tilde")
        testing.expect(t, strings.has_prefix(read, "/"), "the path must be absolute")
        // Not a system path: enrollment is run by a person, and a root-only default
        // would fail after the human had already approved in the browser.
        testing.expect(t, !strings.has_prefix(read, "/var/lib/"), "the default must not require root")
    }
    // An explicit flag always wins over the default.
    explicit := bridge_enroll_token_file_from_args([]string{"ham-bridge", "enroll", "--bridge-token-file", "/tmp/explicit-cred"}, context.temp_allocator)
    testing.expect(t, explicit == "/tmp/explicit-cred", "an explicit --bridge-token-file must win")
}

@(test)
enrolled_but_tokenless_startup_is_refused :: proc(t: ^testing.T) {
    // Audit F4 at startup: with a blank token `bridge_loopback_authorized` returns
    // true for every caller, so an enrolled-but-tokenless bridge would serve its
    // loopback API unauthenticated while being unable to reach the hub at all.
    testing.expect(t, bridge_enrolled_but_tokenless("brg_18dc53eec25c54cd", ""), "enrolled with no token must be refused")
    testing.expect(t, bridge_enrolled_but_tokenless("brg_1", "   "), "a blank token counts as none")
    // Narrow by design (Q4 ruling): a dev bridge that was never enrolled still
    // starts, so this cannot break the dev-stack harnesses other workers rely on.
    testing.expect(t, !bridge_enrolled_but_tokenless("local-daemon", ""), "a never-enrolled dev bridge must still start")
    testing.expect(t, !bridge_enrolled_but_tokenless("", ""), "an unconfigured bridge must still start")
    // And a credential of any shape clears it — validity is the enroll path's job,
    // not startup's, so a legacy hbr_ bridge is unaffected.
    testing.expect(t, !bridge_enrolled_but_tokenless("brg_1", "hba_btk_1.secret"), "an enrolled bridge with a token starts")
    testing.expect(t, !bridge_enrolled_but_tokenless("brg_1", "hbr_brg_1.secret"), "a legacy credential still starts")
}

@(test)
default_credential_adoption_never_overrides_an_explicit_token :: proc(t: ^testing.T) {
    // The fallback exists only to rescue the case that is otherwise broken (no token
    // anywhere). It must never shadow what the operator asked for, because adopting
    // an ambient file over an explicit flag would silently point a bridge at a
    // DIFFERENT hub's credential.
    //
    // THE CANDIDATE FILE IS CREATED HERE, and that is the point. The first version of
    // this test let the proc resolve the real default path, so on a machine with no
    // credential there it did nothing whatever the config said — the reviewer deleted
    // BOTH early returns and the test still passed. An assertion that holds because
    // the code under test had nothing to do is not a test.
    dir := fmt.tprintf("/tmp/ham-default-cred-%d", bridge_now_unix_ms())
    candidate := fmt.tprintf("%s/credential", dir)
    defer os.remove(candidate)
    defer bridge_enroll_test_rmdir(dir)
    testing.expect(t, bridge_write_secret_file(candidate, "hba_btk_ambient.ambientsecret"), "the candidate must exist for this test to mean anything")

    // 1. An explicit token wins over a candidate that really is there.
    explicit := Bridge_Config{bridge_token = "hba_btk_explicit.secret"}
    bridge_adopt_default_credential_if_needed(&explicit, candidate)
    testing.expect(t, explicit.bridge_token == "hba_btk_explicit.secret", "an explicit token must survive an existing candidate")
    testing.expect(t, explicit.credential_file == "", "and no credential file is adopted")

    // 2. An explicit credential file wins too.
    named := Bridge_Config{credential_file = "/tmp/some-explicit-path"}
    bridge_adopt_default_credential_if_needed(&named, candidate)
    testing.expect(t, named.credential_file == "/tmp/some-explicit-path", "an explicit credential file must survive")
    testing.expect(t, named.bridge_token == "", "and the candidate is not read")

    // 3. With nothing configured, the candidate IS adopted — the positive half, which
    //    the previous version never exercised at all.
    empty := Bridge_Config{}
    bridge_adopt_default_credential_if_needed(&empty, candidate)
    testing.expect(t, empty.bridge_token == "hba_btk_ambient.ambientsecret", "an unconfigured bridge adopts the candidate")
    testing.expect(t, empty.credential_file == candidate, "and records where it came from, so refresh can rewrite it")

    // 4. A candidate that does not exist adopts nothing and must not invent a path.
    missing := Bridge_Config{}
    bridge_adopt_default_credential_if_needed(&missing, fmt.tprintf("%s/absent", dir))
    testing.expect(t, missing.bridge_token == "", "a missing candidate adopts nothing")
    testing.expect(t, missing.credential_file == "", "and sets no credential file")
}

@(test)
hello_hostname_cache_survives_an_allocator_reset :: proc(t: ^testing.T) {
    // REGRESSION TEST for the reviewer's blocking find. The cache used to hold a
    // clone made from whatever context.allocator was current at the first call, while
    // the global outlives every such scope — so under the test runner, whose per-test
    // rollback allocator is free_all'd after each test, it came back as another
    // test's bytes ("dawnstar" read back as "CDEFGHIJ": the same 8 bytes, rewritten
    // in place). It is now a fixed global buffer owning its own bytes.
    //
    // This reproduces the hazard directly rather than relying on test ordering: call
    // it inside an arena, destroy the arena, and read again.
    arena_backing := make([]byte, 4096)
    defer delete(arena_backing)
    arena: mem.Arena
    mem.arena_init(&arena, arena_backing)
    first: string
    {
        context.allocator = mem.arena_allocator(&arena)
        first = bridge_hello_hostname()
    }
    // SNAPSHOT THE BYTES OUT before wiping, and this is the whole reason the first
    // version of this test could not fail. Pre-fix, both calls return the SAME global
    // string, so `first` and `second` alias one buffer: wiping the arena changes what
    // `first` itself points at, and `second == first` then compares a value with
    // itself and holds no matter how corrupt the memory is. The reviewer reinstated
    // the broken cache and this test still passed. Copying into a local array makes
    // the comparison be against the ORIGINAL bytes.
    first_snapshot: [256]byte
    first_n := copy(first_snapshot[:], first)
    first_bytes := string(first_snapshot[:first_n])
    // Wipe the arena the way a freed scope would, then re-read.
    mem.zero_slice(arena_backing)
    free_all(mem.arena_allocator(&arena))
    second := bridge_hello_hostname()
    testing.expectf(t, second == first_bytes, "the cached hostname changed after its first allocator was reset: %q -> %q", first_bytes, second)
    if second != "" {
        testing.expect(t, !strings.has_prefix(second, "brg_"), "and it must still not be a bridge id")
        testing.expect(t, second != "ham-bridge", "nor the old placeholder")
    }
}
