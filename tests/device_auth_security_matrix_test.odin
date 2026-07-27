// ELDA-6 / ELDA-7 security matrix for the device-authorization flow.
//
// Covers:
//   - owner spoof in approve body ignored; owner comes from trusted Auth_Context
//   - X-Forwarded-For honored only from trusted CIDRs (authorize + approve)
//   - user_code verify brute-force cap + cooldown
//   - authorize/token public endpoint rate limits
//   - single-use/terminal grants and unknown device_code anti-enumeration
//   - device_code/user_code unlinkability smoke
//   - audit fields queryable on grants and token provenance visible via tokens list
//
// Run: odin run tests/device_auth_security_matrix_test.odin -collection:odin_test=src -file
package device_auth_security_matrix_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import api_http "odin_test:hub/transport/http"

FAILURES: int = 0
FAKE_NOW: i64 = 8_000_000

fake_now :: proc() -> i64 { return FAKE_NOW }
fake_clock :: proc() -> device_auth.Monotonic_Clock { return {now = fake_now} }

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

fake_minter :: proc(ctx: rawptr, user_id, client, device_label: string) -> (string, string, bool) {
	_ = ctx
	_ = user_id
	_ = client
	_ = device_label
	return "hut_security_fake", "utok_security_fake", true
}

new_service :: proc(rate_limit := 2, interval := 5) -> (^device_auth.Grant_Store, device_auth.Device_Auth_Service) {
	store := new(device_auth.Grant_Store)
	store^ = device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://auth.example.com/device/",
		expires_in = 600,
		interval = interval,
		rate_limit = rate_limit,
		rate_window = 10,
	})
	svc := device_auth.new_device_auth_service(store, fake_clock(), []string{"127.0.0.1/32"})
	device_auth.with_token_minter(&svc, fake_minter)
	return store, svc
}

main :: proc() {
	fmt.println("=== device_auth security matrix ===")
	defer {
		if FAILURES == 0 {
			fmt.println("ALL PASS")
		} else {
			fmt.printfln("{} FAILURES", FAILURES)
			os.exit(1)
		}
	}

	test_unlinkability_smoke()
	test_trusted_xff_and_verify_bruteforce()
	test_public_rate_limit_and_token_single_use()
	test_http_owner_spoof_and_audit_queryability()
}

test_unlinkability_smoke :: proc() {
	for i in 0..<32 {
		dc, dc_ok := device_auth.generate_device_code()
		uc, uc_ok := device_auth.generate_user_code()
		assert_true(dc_ok && uc_ok, "code generation succeeds")
		assert_true(len(dc) == 64 && len(uc) == 9, "code lengths are expected")
		assert_true(!strings.contains(dc, uc[:4]) && !strings.contains(dc, uc[5:]), "device_code does not embed user_code segments")
		_ = i
	}
	fmt.println("ELDA-6 OK: device_code/user_code unlinkability smoke")
}

test_trusted_xff_and_verify_bruteforce :: proc() {
	store, svc := new_service(2, 5)
	defer device_auth.grant_store_free(store)

	trusted_res, trusted_ok, _ := device_auth.authorize(&svc, {client = "electron", device_label = "Trusted XFF"}, "127.0.0.1:1111", "203.0.113.5, 10.0.0.1")
	assert_true(trusted_ok, "trusted authorize succeeds")
	trusted_grant, _ := device_auth.get_grant(store, trusted_res.device_code)
	assert_eq(trusted_grant.request_ip, "203.0.113.5", "trusted peer honors first XFF hop at authorize")

	untrusted_res, untrusted_ok, _ := device_auth.authorize(&svc, {client = "electron", device_label = "Spoofed XFF"}, "198.51.100.9:4444", "203.0.113.99")
	assert_true(untrusted_ok, "untrusted authorize succeeds")
	untrusted_grant, _ := device_auth.get_grant(store, untrusted_res.device_code)
	assert_eq(untrusted_grant.request_ip, "198.51.100.9", "untrusted peer ignores spoofed XFF at authorize")

	// Brute-force cap: unknown-code attempts from one IP are capped; after the
	// configured cooldown/window, a legitimate code from the same IP works again.
	_, u1_ok, u1_err := device_auth.verify_with_ip(&svc, "ZZZZ-ZZZA", "198.51.100.200")
	_, u2_ok, u2_err := device_auth.verify_with_ip(&svc, "ZZZZ-ZZZB", "198.51.100.200")
	_, u3_ok, u3_err := device_auth.verify_with_ip(&svc, "ZZZZ-ZZZC", "198.51.100.200")
	assert_true(!u1_ok && !u2_ok, "unknown verify attempts fail generically before cap")
	assert_eq(u1_err.code, domain.Error_Code.Not_Found, "first unknown -> generic Not_Found")
	assert_eq(u2_err.code, domain.Error_Code.Not_Found, "second unknown -> generic Not_Found")
	assert_true(!u3_ok, "third verify over cap fails")
	assert_eq(u3_err.code, domain.Error_Code.Rate_Limited, "verify brute-force cap -> Rate_Limited")
	FAKE_NOW += 11
	info, legit_ok, legit_err := device_auth.verify_with_ip(&svc, trusted_res.user_code, "198.51.100.200")
	assert_true(legit_ok, legit_err.message)
	assert_eq(info.device_label, "Trusted XFF", "legitimate verify works after cooldown")
	fmt.println("ELDA-6 OK: trusted-XFF-only and verify brute-force cap/cooldown")
}

test_public_rate_limit_and_token_single_use :: proc() {
	// Public authorize endpoint rate limit.
	rate_store, rate_svc := new_service(2, 5)
	defer device_auth.grant_store_free(rate_store)
	_, a1, _ := device_auth.authorize(&rate_svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.44")
	_, a2, _ := device_auth.authorize(&rate_svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.44")
	_, a3, a3_err := device_auth.authorize(&rate_svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.44")
	assert_true(a1 && a2 && !a3, "authorize per-IP rate limit trips after budget")
	assert_eq(a3_err.code, domain.Error_Code.Rate_Limited, "authorize over budget -> Rate_Limited")

	// Token poll: unknown device_code stays pending, same grant is single-use,
	// and too-fast polling trips slow_down/Rate_Limited.
	store, svc := new_service(10, 5)
	defer device_auth.grant_store_free(store)
	res, ok, _ := device_auth.authorize(&svc, {client = "electron", device_label = "Single Use"}, "127.0.0.1:1", "203.0.113.55")
	assert_true(ok, "authorize for token test succeeds")
	unknown, unknown_err := device_auth.poll(&svc, "not-a-device-code", "203.0.113.56")
	assert_eq(unknown_err.code, domain.Error_Code.None, "unknown device poll no error")
	assert_eq(unknown.status, device_auth.Poll_Status.Pending, "unknown device_code -> pending")
	pending, pending_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(pending_err.code, domain.Error_Code.None, "first pending poll allowed")
	assert_eq(pending.status, device_auth.Poll_Status.Pending, "unapproved grant -> pending")
	too_fast, too_fast_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(too_fast.status, device_auth.Poll_Status.Slow_Down, "too-fast grant poll -> slow_down")
	assert_eq(too_fast_err.code, domain.Error_Code.Rate_Limited, "too-fast grant poll -> Rate_Limited")
	FAKE_NOW += 5
	approved_ok, approved_err := device_auth.approve(&svc, {user_code = res.user_code, approve = true}, "owner", "203.0.113.99", "UA")
	assert_true(approved_ok, approved_err.message)
	approved, poll_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(poll_err.code, domain.Error_Code.None, "approved poll no error")
	assert_eq(approved.status, device_auth.Poll_Status.Approved, "approved grant returns token once")
	replay, replay_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(replay_err.code, domain.Error_Code.None, "used replay no error")
	assert_eq(replay.status, device_auth.Poll_Status.Expired, "used grant replay -> expired")
	fmt.println("ELDA-6 OK: public rate limits, no-enumeration, single-use terminal grants")
}

test_http_owner_spoof_and_audit_queryability :: proc() {
	db_path := "/tmp/heimdall-device-auth-security-matrix.db"
	_ = os.remove(db_path)
	config := app.default_config()
	config.database_path = db_path
	config.migrations_dir = "src/hub/repository/sqlite/migrations"
	graph: app.App_Graph
	graph_ok, graph_msg := app.build_graph(&graph, config)
	assert_true(graph_ok, graph_msg)
	defer {
		app.shutdown_graph(&graph)
		_ = os.remove(db_path)
	}

	res, auth_ok, auth_err := device_auth.authorize(&graph.device_auth, {client = "heimdall-electron", device_label = "Audit Laptop", os = "macOS", app_version = "0.1"}, "198.51.100.20:5555", "203.0.113.250")
	assert_true(auth_ok, auth_err.message)
	trusted_headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "real-owner"},
		{name = "X-authentik-name", value = "Real Owner"},
		{name = "X-authentik-email", value = "real-owner@example.com"},
		{name = "X-Forwarded-For", value = "203.0.113.88, 10.0.0.1"},
		{name = "User-Agent", value = "SecurityMatrix/1.0"},
	}
	body := strings.concatenate({"{\"user_code\":\"", res.user_code, "\",\"approve\":true,\"owner_user_id\":\"spoof-owner\",\"user\":\"spoof-user\"}"})
	approve_resp := api_http.device_approve_handler(rawptr(&graph.device_auth_handlers), api_http.Request{method = "POST", path = "/api/v1/device/approve", body = body, request_id = "req_security_approve", remote_addr = "127.0.0.1:4444", headers = trusted_headers[:]})
	assert_eq(approve_resp.status, 200, "HTTP approve succeeds through trusted proxy")
	grant, grant_ok := device_auth.get_grant(&graph.device_auth_store, res.device_code)
	assert_true(grant_ok, "approved grant queryable")
	assert_eq(grant.owner_user_id, "real-owner", "spoofed owner body ignored; owner from Auth_Context")
	assert_eq(grant.approver_ip, "203.0.113.88", "approve honors trusted XFF for audit IP")
	assert_eq(grant.approver_ua, "SecurityMatrix/1.0", "approve records user-agent")
	assert_eq(grant.device_label, "Audit Laptop", "audit carries device_label")
	assert_eq(grant.client, "heimdall-electron", "audit carries client")
	assert_true(grant.decided_at > 0, "audit decided_at recorded")

	tokens, token_err := auth_service.list_user_api_tokens(&graph.auth, domain.User_ID("real-owner"))
	assert_eq(token_err.code, domain.Error_Code.None, "tokens list succeeds for approving owner")
	found_device_token := false
	found_token_id := ""
	for token in tokens {
		if token.created_from == "device_authorization" && token.device_label == "Audit Laptop" && token.revoked_at == "" {
			found_device_token = true
			found_token_id = token.token_id
		}
	}
	assert_true(found_device_token, "tokens list surfaces device provenance")

	deny_res, deny_auth_ok, _ := device_auth.authorize(&graph.device_auth, {client = "heimdall-electron", device_label = "Denied Laptop"}, "198.51.100.21:5555", "")
	assert_true(deny_auth_ok, "authorize deny audit grant succeeds")
	deny_body := strings.concatenate({"{\"user_code\":\"", deny_res.user_code, "\",\"approve\":false,\"owner_user_id\":\"spoof-deny\"}"})
	deny_resp := api_http.device_approve_handler(rawptr(&graph.device_auth_handlers), api_http.Request{method = "POST", path = "/api/v1/device/approve", body = deny_body, request_id = "req_security_deny", remote_addr = "127.0.0.1:4444", headers = trusted_headers[:]})
	assert_eq(deny_resp.status, 200, "HTTP deny succeeds through trusted proxy")
	deny_grant, deny_grant_ok := device_auth.get_grant(&graph.device_auth_store, deny_res.device_code)
	assert_true(deny_grant_ok, "denied grant queryable")
	assert_eq(deny_grant.status, device_auth.Grant_Status.Denied, "deny terminal status recorded")
	assert_eq(deny_grant.owner_user_id, "real-owner", "deny owner from context")
	assert_eq(deny_grant.approver_ip, "203.0.113.88", "deny audit IP recorded")
	assert_eq(deny_grant.approver_ua, "SecurityMatrix/1.0", "deny UA recorded")
	assert_eq(deny_grant.minted_token, "", "deny does not mint token")

	// Authoritative token row is queryable by id too, proving provenance survives
	// repository read paths and is not only an in-memory grant field.
	if found_device_token && found_token_id != "" {
		row, row_ok, _ := iface.user_token_get_by_id(graph.auth.user_tokens, found_token_id)
		assert_true(row_ok, "token row query by id succeeds")
		assert_true(row.created_from != "" && row.device_label != "", "token provenance query by id includes audit fields")
	}
	fmt.println("ELDA-6/ELDA-7 OK: HTTP owner spoof guard + queryable approve/deny audit/provenance")
}
