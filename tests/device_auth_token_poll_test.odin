// Unit tests for the /device/token poll lifecycle (ELDA-3) and device-token
// issuance boundary (ELDA-4 token_id propagation).
//
// Covers:
//   AC1: pending -> approved(token) -> used/expired; denied; expired;
//        slow_down/429 with Retry-After.
//   AC2: unknown device_code -> pending (anti-enumeration).
//   AC3: approved token is single-use; plaintext cleared after first poll.
//   AC7: public token polling is rate-limited per IP.
//
// Run: odin run tests/device_auth_token_poll_test.odin -collection:odin_test=src -file
package device_auth_token_poll_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import api_http "odin_test:hub/transport/http"

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

FAKE_NOW: i64 = 7_000_000
fake_now :: proc() -> i64 { return FAKE_NOW }
fake_clock :: proc() -> device_auth.Monotonic_Clock { return {now = fake_now} }

MINT_COUNT: int = 0
fake_minter :: proc(ctx: rawptr, user_id, client, device_label: string) -> (string, string, bool) {
	_ = ctx
	_ = user_id
	_ = client
	_ = device_label
	MINT_COUNT += 1
	return "hut_fake_poll_token", "utok_fake_poll", true
}

new_service :: proc(rate_limit := 100, interval := 5) -> (^device_auth.Grant_Store, device_auth.Device_Auth_Service) {
	store := new(device_auth.Grant_Store)
	store^ = device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://auth.example.com/device/",
		expires_in = 600,
		interval = interval,
		rate_limit = rate_limit,
		rate_window = 60,
	})
	svc := device_auth.new_device_auth_service(store, fake_clock(), []string{"127.0.0.1/32"})
	device_auth.with_token_minter(&svc, fake_minter)
	return store, svc
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if strings.to_lower(h.name) == strings.to_lower(name) do return h.value
	}
	return ""
}

main :: proc() {
	fmt.println("=== device_auth token poll ===")
	defer {
		if FAILURES == 0 {
			fmt.println("ALL PASS")
		} else {
			fmt.printfln("{} FAILURES", FAILURES)
			os.exit(1)
		}
	}

	store, svc := new_service()
	defer device_auth.grant_store_free(store)

	res, ok, err := device_auth.authorize(&svc, {client = "electron", device_label = "MBP"}, "127.0.0.1:1", "")
	assert_true(ok, "authorize for poll lifecycle succeeds")
	assert_eq(err.code, domain.Error_Code.None, "authorize no error")

	// AC2: unknown device_code never reveals validity.
	unknown, unknown_err := device_auth.poll(&svc, "not-a-real-device-code", "203.0.113.20")
	assert_eq(unknown_err.code, domain.Error_Code.None, "unknown poll has no error")
	assert_eq(unknown.status, device_auth.Poll_Status.Pending, "unknown device_code -> pending")

	// AC1: pending while not yet approved; too-fast second poll -> slow_down.
	pending, pending_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(pending_err.code, domain.Error_Code.None, "pending poll no error")
	assert_eq(pending.status, device_auth.Poll_Status.Pending, "unapproved grant -> pending")
	too_fast, too_fast_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(too_fast.status, device_auth.Poll_Status.Slow_Down, "too-fast poll -> slow_down")
	assert_eq(too_fast_err.code, domain.Error_Code.Rate_Limited, "too-fast poll -> Rate_Limited")

	// AC1/AC3: once approved and polled at interval, token is returned once, then expired.
	FAKE_NOW += 5
	aok, aerr := device_auth.approve(&svc, {user_code = res.user_code, approve = true}, "owner-1", "203.0.113.30", "UA")
	assert_true(aok, "approve for token poll succeeds")
	assert_eq(aerr.code, domain.Error_Code.None, "approve no error")
	approved, approved_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(approved_err.code, domain.Error_Code.None, "approved poll no error")
	assert_eq(approved.status, device_auth.Poll_Status.Approved, "approved grant -> approved status")
	assert_eq(approved.access_token, "hut_fake_poll_token", "approved poll returns plaintext token")
	assert_eq(approved.token_id, "utok_fake_poll", "approved poll returns authoritative token_id")
	assert_eq(approved.expires_in, 600, "approved poll returns expires_in")
	used_grant, used_ok := device_auth.get_grant(store, res.device_code)
	assert_true(used_ok, "used grant remains recorded")
	assert_eq(used_grant.status, device_auth.Grant_Status.Used, "approved poll marks grant Used")
	assert_eq(used_grant.minted_token, "", "approved poll clears plaintext token from grant")
	replay, replay_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(replay_err.code, domain.Error_Code.None, "used replay no error")
	assert_eq(replay.status, device_auth.Poll_Status.Expired, "used grant replay -> expired")
	fmt.println("AC1/AC2/AC3 OK: pending, slow_down, approved single-use, unknown")

	// AC1: denied grants poll as denied.
	FAKE_NOW += 10
	denied_res, dok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	assert_true(dok, "authorize denied grant succeeds")
	device_auth.approve(&svc, {user_code = denied_res.user_code, approve = false}, "owner-1", "203.0.113.30", "UA")
	denied, denied_err := device_auth.poll(&svc, denied_res.device_code, "203.0.113.22")
	assert_eq(denied_err.code, domain.Error_Code.None, "denied poll no error")
	assert_eq(denied.status, device_auth.Poll_Status.Denied, "denied grant -> denied")

	// AC1: TTL expiry polls as expired.
	exp_res, eok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	assert_true(eok, "authorize expired grant succeeds")
	FAKE_NOW += 601
	expired, expired_err := device_auth.poll(&svc, exp_res.device_code, "203.0.113.23")
	assert_eq(expired_err.code, domain.Error_Code.None, "expired poll no error")
	assert_eq(expired.status, device_auth.Poll_Status.Expired, "expired grant -> expired")
	fmt.println("AC1 OK: denied and expired states")

	// AC7: independent per-IP token poll rate limit, observable through handler as
	// HTTP 429 + Retry-After.
	rate_store, rate_svc := new_service(1, 7)
	defer device_auth.grant_store_free(rate_store)
	for i in 0..<6 {
		p, perr := device_auth.poll(&rate_svc, fmt.tprintf("unknown-%d", i), "198.51.100.77")
		assert_eq(perr.code, domain.Error_Code.None, "poll rate pre-budget no error")
		assert_eq(p.status, device_auth.Poll_Status.Pending, "poll rate pre-budget unknown -> pending")
	}
	handlers := api_http.Device_Auth_Handlers{service = &rate_svc}
	resp := api_http.device_token_handler(rawptr(&handlers), api_http.Request{
		method = "POST",
		path = "/api/v1/device/token",
		body = "{\"device_code\":\"unknown-rate-limited\"}",
		request_id = "req_poll_rate",
		remote_addr = "198.51.100.77:4444",
	})
	assert_eq(resp.status, 429, "poll rate limit -> HTTP 429")
	assert_eq(header_value(resp.headers, "Retry-After"), "7", "poll rate limit sets Retry-After")
	assert_true(strings.contains(resp.body, "\"status\":\"slow_down\""), "poll rate limit body status slow_down")
	fmt.println("AC7 OK: per-IP poll rate limit + Retry-After")
}
