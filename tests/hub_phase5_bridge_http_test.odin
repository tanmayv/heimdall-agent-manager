package hub_phase5_bridge_http_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

// A valid-shaped uncompressed P-256 point, and a precomputed PKCE pair where
// P5_CODE_CHALLENGE == BASE64URL(SHA256(P5_CODE_VERIFIER)), unpadded.
P5_PUBLIC_KEY :: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
P5_CODE_VERIFIER :: "heimdall-req-impl-6-test-code-verifier-aaaa"
P5_CODE_CHALLENGE :: "J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI"

main :: proc() {
	db_path := "/tmp/heimdall-hub-phase5-http-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
	})
	check(ok, message)
	defer {
		app.shutdown_graph(&graph)
		_ = os.remove(db_path)
	}
	alice := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "alice"},
		{name = "X-authentik-name", value = "Alice"},
	}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}

	// ===== PROVISIONED THROUGH THE DEVICE FLOW (REQ-ENROLL-9) =====
	//
	// Everything between here and the ownership assertions below used to exercise the
	// deleted one-time-token endpoints: minting an enrollment with an expiry, listing
	// enrollments without leaking the raw token, revoking a pending one, exchanging
	// the token for an `hbr_` credential, and proving the token was single-use and
	// could not be passed in the query or body. All of those endpoints are gone, so
	// those assertions went with them.
	//
	// THIS FILE WAS ALREADY RED AT PRISTINE HEAD, on "bridge token must not call user
	// bridge-management list API" — and that is not incidental. That assertion expects
	// a bare bridge token to be REFUSED on `/api/v1/bridges`, which is exactly the
	// hole the deleted permissive bridge-auth mode opened by default. The test was
	// asserting the correct behaviour all along and failing because the shipped
	// default disabled the check. REQ-ENROLL-15 is what makes it pass.
	//
	// Three requirements that each reject a request outright: the 130-char
	// lowercase-hex uncompressed P-256 key; NO `bridge_key_fingerprint` (the Hub
	// derives it and refuses a disagreeing one); and mandatory S256 PKCE, precomputed
	// here so this file needs no crypto.
	//
	// `device_label` becomes the hostname and therefore the label, so "Alice Mac"
	// keeps working as the label the assertions below look for.
	authorized := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/authorize",
		body = strings.concatenate({
			"{\"client\":\"ham-bridge\",\"device_label\":\"Alice Mac\",\"os\":\"macos\",\"os_user\":\"tanmay\",\"bridge_public_key\":\"",
			P5_PUBLIC_KEY, "\",\"code_challenge\":\"", P5_CODE_CHALLENGE, "\",\"code_challenge_method\":\"S256\"}",
		}),
		request_id = "req_dev_auth", remote_addr = "127.0.0.1",
	})
	check(authorized.status == 200, authorized.body)
	user_code := extract_json_string(authorized.body, "user_code")
	device_code := extract_json_string(authorized.body, "device_code")

	// The human approves. Ownership comes from this Auth_Context, never the body.
	approved := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/approve",
		body = strings.concatenate({"{\"user_code\":\"", user_code, "\",\"approve\":true}"}),
		request_id = "req_dev_approve", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(approved.status == 200, approved.body)

	issued := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/token",
		body = strings.concatenate({"{\"device_code\":\"", device_code, "\",\"code_verifier\":\"", P5_CODE_VERIFIER, "\"}"}),
		request_id = "req_dev_token", remote_addr = "127.0.0.1",
	})
	check(issued.status == 200, issued.body)
	bridge_id := extract_json_string(issued.body, "bridge_id")
	bridge_token := extract_json_string(issued.body, "access_token")
	check(strings.has_prefix(bridge_id, "brg_"), "enrollment must return a brg_ id")
	// The credential is the EXPIRING access token, not the deleted non-expiring shape.
	check(strings.has_prefix(bridge_token, "hba_"), "enrollment must return an expiring hba_ access token")
	check(strings.contains(issued.body, "refresh_token"), "a bridge grant must also return a refresh token")

	// THE GRANT IS SINGLE-USE. This replaces the deleted "enrollment token must be
	// one-time" assertion: the property it protected is the same one, moved to the
	// mechanism that now carries it.
	replay := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/token",
		body = strings.concatenate({"{\"device_code\":\"", device_code, "\",\"code_verifier\":\"", P5_CODE_VERIFIER, "\"}"}),
		request_id = "req_dev_token_replay", remote_addr = "127.0.0.1",
	})
	// The device-flow protocol reports grant state in the BODY, not the HTTP status —
	// a spent grant is a 200 carrying {"status":"expired"}. So the assertion is about
	// the credential, not the code: no second access token may be issued, and the
	// status must not come back "approved" again. Asserting `status != 200` here
	// would have been wrong about the protocol rather than about the security
	// property, and would have failed against correct behaviour.
	check(!strings.contains(replay.body, "access_token"), fmt.tprintf("a spent device grant must not mint a second credential; got %s", replay.body))
	check(!strings.contains(replay.body, "\"status\":\"approved\""), fmt.tprintf("a spent device grant must not report approved twice; got %s", replay.body))

	list_bridges := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges", request_id = "req_list_bridge", remote_addr = "127.0.0.1", headers = alice[:]})
	check(list_bridges.status == 200 && strings.contains(list_bridges.body, bridge_id) && strings.contains(list_bridges.body, "Alice Mac"), "owner must list own bridge")
	bob_list := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges", request_id = "req_bob", remote_addr = "127.0.0.1", headers = bob[:]})
	check(bob_list.status == 200 && !strings.contains(bob_list.body, bridge_id), "other user must not list bridge")
	bob_detail := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), request_id = "req_bob_detail", remote_addr = "127.0.0.1", headers = bob[:]})
	check(bob_detail.status == 404, "cross-user bridge detail must be hidden")
	rename := api_http.router_dispatch(&graph.router, api_http.Request{method = "PATCH", path = bridge_url(bridge_id, ""), body = "{\"label\":\"Work Mac\"}", request_id = "req_rename", remote_addr = "127.0.0.1", headers = alice[:]})
	check(rename.status == 200 && strings.contains(rename.body, "Work Mac") && strings.contains(rename.body, "\"label_is_user_customized\":true"), "rename endpoint must customize label")
	bridge_auth := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	bridge_detail_with_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), request_id = "req_bridge_token_detail", headers = bridge_auth[:]})
	check(bridge_detail_with_token.status == 200 && strings.contains(bridge_detail_with_token.body, bridge_id), "bridge token must resolve owner/bridge through Authorization: Bearer")
	wrong_bridge_with_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url("brg_other", ""), request_id = "req_bridge_token_wrong", headers = bridge_auth[:]})
	check(wrong_bridge_with_token.status == 404, "bridge token must be scoped to its own bridge")
	bridge_query_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), query = strings.concatenate({"token=", bridge_token}), request_id = "req_bridge_query", headers = bridge_auth[:]})
	check(bridge_query_token.status == 401, "bridge token endpoint must reject query/body tokens")
	bridge_list_with_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges", request_id = "req_bridge_list_token", headers = bridge_auth[:]})
	check(bridge_list_with_token.status == 403, "bridge token must not call user bridge-management list API")
	me_with_bridge := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_bridge_me", headers = bridge_auth[:]})
	check(me_with_bridge.status == 403, "bridge token must not call user APIs")
	body_bridge_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = bridge_url(bridge_id, "/revoke"), body = strings.concatenate({"{\"token\":\"", bridge_token, "\"}"}), request_id = "req_bridge_body_token"})
	check(body_bridge_token.status == 401, "bridge token must be rejected when supplied in request body")
	revoke := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = bridge_url(bridge_id, "/revoke"), request_id = "req_revoke", remote_addr = "127.0.0.1", headers = alice[:]})
	check(revoke.status == 200 && strings.contains(revoke.body, "revoked"), "revoke endpoint must revoke bridge")
	revoked_bridge_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), request_id = "req_revoked_bridge_token", headers = bridge_auth[:]})
	check(revoked_bridge_token.status == 403, "revoked bridge token must be rejected at API boundary")

	fmt.println("PASS: hub phase5 bridge http")
}

bridge_url :: proc(bridge_id, suffix: string) -> string {
	return strings.concatenate({"/api/v1/bridges/", bridge_id, suffix})
}


extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
