// Unit tests for the device-authorization grant store + helpers (ELDA-1 / ELDA-6).
//
// Covers the task-1 acceptance criteria at the service/store layer:
//   AC1: device_code >= 128-bit (64 hex), user_code [A-Z2-7] 8+dash, authorize shape.
//   AC2: device_code/user_code unlinkable (independent CSPRNG draws).
//   AC3: request_ip captured from the request.
//   AC4: resolve_client_ip honors XFF only behind a trusted proxy.
//   AC5: per-IP authorize rate limit -> 429-equivalent (allow_authorize false).
//   + TTL/sweep expiry.
//
// Run: odin run tests/device_auth_grant_store_test.odin -collection:odin_test=src -file
package device_auth_grant_store_test

import "core:fmt"
import "core:os"
import "core:strings"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"

FAILURES: int = 0

assert_eq :: proc(got, want: $T, label: string) {
	if got == want do return
	FAILURES += 1
	fmt.printfln("FAIL {}: got {!v} want {!v}", label, got, want)
}

assert_true :: proc(cond: bool, label: string) {
	if cond do return
	FAILURES += 1
	fmt.printfln("FAIL {}: condition false", label)
}

// --- Fake monotonic clock (returns a mutable global unix-seconds value) ---
FAKE_NOW: i64 = 1_000_000
fake_now :: proc() -> i64 { return FAKE_NOW }
fake_clock :: proc() -> device_auth.Monotonic_Clock { return {now = fake_now} }

is_hex :: proc(s: string) -> bool {
	for ch in s {
		ok := (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
		if !ok do return false
	}
	return true
}

is_base32 :: proc(s: string) -> bool {
	for ch in s {
		ok := (ch >= 'A' && ch <= 'Z') || (ch >= '2' && ch <= '7')
		if !ok do return false
	}
	return true
}

main :: proc() {
	fmt.println("=== device_auth grant store + helpers ===")

	// AC1: device_code entropy/length/charset.
	dc, dcok := device_auth.generate_device_code()
	assert_true(dcok, "generate_device_code succeeds")
	assert_true(len(dc) == 64, "device_code is 64 hex chars (256-bit)")
	assert_true(is_hex(dc), "device_code charset is [0-9a-f]")
	// >= 128-bit: 64 hex chars = 32 bytes = 256 bits >= 128. Assert explicitly.
	assert_true(len(dc) * 4 >= 128, "device_code entropy >= 128 bits")

	// AC1: user_code charset/length/format.
	uc, ucok := device_auth.generate_user_code()
	assert_true(ucok, "generate_user_code succeeds")
	assert_true(len(uc) == 9, "user_code is 8 symbols + 1 dash = 9 chars")
	assert_true(uc[4] == '-', "user_code has dash at index 4 (XXXX-XXXX)")
	assert_true(is_base32(uc[0:4]) && is_base32(uc[5:9]), "user_code charset is [A-Z2-7]")
	fmt.println("sample device_code:", dc[:16], "...  user_code:", uc)

	// AC1/AC2: uniqueness + unlinkability over many draws.
	SEEN_DC := make(map[string]bool)
	SEEN_UC := make(map[string]bool)
	UNLINKABLE := true
	for i in 0..<200 {
		d, dok := device_auth.generate_device_code()
		u, uok := device_auth.generate_user_code()
		assert_true(dok && uok, "code generation succeeds in batch")
		SEEN_DC[d] = true
		SEEN_UC[u] = true
		// Unlinkability sanity: device_code is never a transform of user_code.
		if strings.contains(d, u) || strings.contains(u, d) do UNLINKABLE = false
		if strings.has_prefix(d, u[:4]) do UNLINKABLE = false
	}
	assert_true(len(SEEN_DC) == 200, "200 device_codes are all distinct (high entropy)")
	assert_true(len(SEEN_UC) == 200, "200 user_codes are all distinct")
	assert_true(UNLINKABLE, "device_code and user_code are unlinkable (AC2)")
	delete(SEEN_DC)
	delete(SEEN_UC)

	// AC4: resolve_client_ip trusted-XFF semantics.
	TRUSTED := []string{"127.0.0.1/32"}
	// Trusted peer + XFF -> first XFF hop.
	got := device_auth.resolve_client_ip("127.0.0.1:54321", "203.0.113.9, 10.0.0.1", TRUSTED)
	assert_eq(got, "203.0.113.9", "trusted peer uses first XFF hop")
	// Trusted peer, no XFF -> peer IP (stripped of port).
	got = device_auth.resolve_client_ip("127.0.0.1:54325", "", TRUSTED)
	assert_eq(got, "127.0.0.1", "trusted peer, no XFF -> peer IP")
	// Untrusted peer + spoofed XFF -> IGNORED, peer IP used (AC4 spoofing guard).
	got = device_auth.resolve_client_ip("198.51.100.7:9999", "203.0.113.999", TRUSTED)
	assert_eq(got, "198.51.100.7", "untrusted peer ignores spoofed XFF")
	// Multiple XFF hops -> first (original client).
	got = device_auth.resolve_client_ip("127.0.0.1:1", "203.0.113.10, 10.0.0.1, 10.0.0.2", TRUSTED)
	assert_eq(got, "203.0.113.10", "first XFF hop wins among many")
	fmt.println("resolve_client_ip: trusted-XFF + spoofing guard OK")

	// AC5 + AC3 + AC1: grant store, rate limit, authorize end-to-end.
	store := device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://auth.example.com/device/",
		expires_in = 600, interval = 5, rate_limit = 3, rate_window = 60,
	})
	defer device_auth.grant_store_free(&store)
	svc := device_auth.new_device_auth_service(&store, fake_clock(), TRUSTED)

	// AC3 + AC1: authorize captures request_ip and returns the full contract.
	res, ok, err := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:5555", "203.0.113.42")
	assert_true(ok, "authorize succeeds (trusted peer)")
	assert_eq(err.code, domain.Error_Code.None, "no error on success")
	assert_true(len(res.device_code) == 64, "authorize returns 64-char device_code")
	assert_true(len(res.user_code) == 9, "authorize returns 9-char user_code")
	assert_eq(res.verification_uri, "https://auth.example.com/device/", "verification_uri returned")
	assert_eq(res.interval, 5, "interval returned")
	assert_true(res.expires_in <= 600, "expires_in <= 600 (ELDA-1 cap)")
	// AC3: request_ip captured on the grant.
	grant, gok := device_auth.get_grant(&store, res.device_code)
	assert_true(gok, "grant stored by device_code")
	assert_eq(grant.request_ip, "203.0.113.42", "grant captured trusted-XFF request_ip (AC3)")
	assert_eq(grant.client, "electron", "grant captured client")
	assert_eq(grant.status, device_auth.Grant_Status.Pending, "grant starts Pending")
	// Validation: missing client -> 400.
	_, vok, verr := device_auth.authorize(&svc, {}, "127.0.0.1:1", "")
	assert_true(!vok, "missing client rejected")
	assert_eq(verr.code, domain.Error_Code.Validation_Failed, "missing client -> Validation_Failed (400)")

	// AC5: per-IP rate limit. We already used 1 of 3 for IP 203.0.113.42.
	_, r2, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	_, r3, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	_, r4, r4err := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	assert_true(r2 && r3, "rate limit allows up to N")
	assert_true(!r4, "rate limit denies over N (AC5)")
	assert_eq(r4err.code, domain.Error_Code.Rate_Limited, "over-limit -> Rate_Limited (429)")
	// Different IP is not affected by another IP's limit.
	_, other_ok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.99")
	assert_true(other_ok, "rate limit is per-IP (different IP unaffected)")
	fmt.println("rate limit: per-IP allow/deny OK (AC5)")

	// Rate window reset: advance fake clock past the window, limit clears.
	FAKE_NOW += 61
	_, after_ok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	assert_true(after_ok, "rate limit resets after window elapses")

	// TTL/sweep: a grant past expires_at is evicted.
	FAKE_NOW = 2_000_000
	expired_res, eok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.250")
	assert_true(eok, "created grant for sweep test")
	FAKE_NOW += 601 // past its 600s TTL
	removed := device_auth.sweep(&store, FAKE_NOW)
	assert_true(removed >= 1, "sweep removed at least one expired grant")
	_, still := device_auth.get_grant(&store, expired_res.device_code)
	assert_true(!still, "expired grant is gone after sweep")
	fmt.println("TTL/sweep: expired grant evicted OK")

	if FAILURES == 0 {
		fmt.println("ALL PASS")
	} else {
		fmt.printfln("{} FAILURES", FAILURES)
		os.exit(1)
	}
}
