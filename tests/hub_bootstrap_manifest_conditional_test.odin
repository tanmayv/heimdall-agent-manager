// HUB-1..HUB-3 acceptance test: the conditional, agent-keyed bootstrap manifest.
//
//  1. Cold GET  -> 200 + ETag + version + assembly hashes.
//  2. Warm GET with matching If-None-Match -> 304, no re-render (render counter
//     unchanged) and no memories scan.
//  3. GET a fragment hash from /bridge/blobs/{hash} -> 200 with the body.
//  4. Add a memory -> the content epoch bumps, next GET is a 200 with a NEW
//     version/ETag (memories fragment appears), and the stale If-None-Match no
//     longer yields a 304.
package hub_bootstrap_manifest_conditional_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import agent_service "odin_test:hub/service/agent"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"

main :: proc() {
	db_path := "/tmp/heimdall-hub-bootstrap-manifest-conditional-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}

	// Enroll a bridge so we have a bridge bearer token for the /bridge/* routes.
	bridge_token := enroll_bridge(&graph, alice[:])
	bearer := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}

	// Create an agent with instructions so the identity fragment is non-empty.
	agent := request(&graph, "POST", "/api/v1/agents", "{\"name\":\"Backend Agent\",\"slug\":\"backend\",\"default_provider\":\"claude\",\"default_tier\":\"normal\",\"instructions\":\"You are a backend specialist.\"}", alice[:])
	check(agent.status == 201, "create agent must return 201")
	agent_id := extract_json_string(agent.body, "agent_id")
	check(agent_id != "", "agent_id must be present")

	manifest_url := strings.concatenate({"/api/v1/bridge/agents/", agent_id, "/bootstrap-manifest?role=worker&provider=claude"})

	// (1) COLD: 200 + ETag + version.
	renders_before := agent_service.bootstrap_manifest_render_count()
	cold := request(&graph, "GET", manifest_url, "", bearer[:])
	check(cold.status == 200, "cold manifest GET must be 200")
	etag := response_header(cold, "ETag")
	check(etag != "", "cold manifest must set an ETag header")
	check(strings.contains(cold.body, "\"version\":\""), "manifest must carry a version")
	check(strings.contains(cold.body, "agent_identity"), "manifest assembly must include the identity fragment")
	check(strings.contains(cold.body, "\"protocol\":2"), "manifest must be protocol 2")
	renders_after_cold := agent_service.bootstrap_manifest_render_count()
	check(renders_after_cold == renders_before + 1, "cold GET must render exactly once")

	// Pull one fragment hash out of the manifest for the blob GET below.
	frag_hash := extract_json_string(cold.body, "hash")
	check(strings.has_prefix(frag_hash, "sha256:"), "manifest must expose a sha256 fragment hash")

	// (2) WARM: matching If-None-Match -> 304, and NO additional render.
	// Do intervening heap churn between the cold insert and the warm lookup, then
	// repeat the warm GET, to surface any read-after-free on the map key (a
	// transient key freed after insert would leave the stored key's bytes dangling;
	// churn reallocates that buffer with different content and the lookup MISSes ->
	// spurious re-render). A correct clone-on-insert survives this.
	churn := make([dynamic]string)
	for i := 0; i < 256; i += 1 {
		append(&churn, strings.concatenate({"heap-churn-filler-", itoa(i), "-padding-padding-padding"}))
	}
	inm := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}, {name = "If-None-Match", value = etag}}
	warm := request(&graph, "GET", manifest_url, "", inm[:])
	check(warm.status == 304, "warm GET with matching ETag must be 304")
	check(warm.body == "", "304 response must have an empty body")
	// Second warm GET after even more churn: still a HIT, still no re-render.
	for i := 0; i < 256; i += 1 {
		append(&churn, strings.concatenate({"more-heap-churn-", itoa(i), "-xxxxxxxxxxxxxxxxxxxxxxxx"}))
	}
	warm2 := request(&graph, "GET", manifest_url, "", inm[:])
	check(warm2.status == 304, "repeat warm GET after heap churn must still be 304 (no dangling map key)")
	renders_after_warm := agent_service.bootstrap_manifest_render_count()
	check(renders_after_warm == renders_after_cold, "warm 304s must NOT re-render (no memories scan) even after intervening allocations")
	_ = churn

	// (3) Per-hash immutable blob GET.
	blob_url := strings.concatenate({"/api/v1/bridge/blobs/", url_encode_hash(frag_hash)})
	blob := request(&graph, "GET", blob_url, "", bearer[:])
	check(blob.status == 200, "blob GET must be 200")
	check(strings.contains(blob.body, "backend specialist"), "blob body must contain the fragment content")
	cache_control := response_header(blob, "Cache-Control")
	check(strings.contains(cache_control, "immutable"), "blob response must be marked immutable")

	// (4) Add a memory -> epoch bump -> next GET is a fresh 200 with a NEW ETag,
	//     and the old If-None-Match no longer matches.
	mem := request(&graph, "POST", "/api/v1/memories", strings.concatenate({"{\"type\":\"fact\",\"title\":\"House Style\",\"body\":\"Prefer explicit error handling.\",\"agent_id\":\"", agent_id, "\",\"status\":\"active\"}"}), alice[:])
	check(mem.status == 201 || mem.status == 200, "create memory must succeed")

	after_mem := request(&graph, "GET", manifest_url, "", inm[:])
	check(after_mem.status == 200, "after a memory change the stale ETag must NOT yield 304")
	new_etag := response_header(after_mem, "ETag")
	check(new_etag != "" && new_etag != etag, "memory change must produce a new ETag/version")
	check(strings.contains(after_mem.body, "memories"), "manifest must now include a memories fragment")

	fmt.println("PASS: hub bootstrap manifest conditional")
}

url_encode_hash :: proc(hash: string) -> string {
	// Only the ':' needs encoding for our router/path handling.
	replaced, _ := strings.replace_all(hash, ":", "%3A")
	return replaced
}

response_header :: proc(resp: api_http.Response, name: string) -> string {
	for h in resp.headers {
		if strings.equal_fold(h.name, name) do return h.value
	}
	return ""
}

enroll_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header) -> string {
	// ===== PROVISIONED THROUGH THE REAL DEVICE FLOW (REQ-ENROLL-9) =====
	//
	// This used to POST /api/v1/bridge-enrollments for a one-time token and then
	// exchange it at POST /api/v1/bridges/enroll. Both are deleted. These tests are
	// not about enrollment — they need a bridge and a credential — so the helper was
	// migrated rather than the tests dropped.
	//
	// It drives the PRODUCTION endpoints rather than calling the service directly,
	// which keeps this helper HTTP-only and means every suite below now covers the
	// real enrollment path as a side effect.
	//
	// PKCE is MANDATORY for a bridge grant and S256-only — `plain` and a missing
	// method are both refused, so the pair below is a precomputed
	// BASE64URL(SHA256(verifier)). Hardcoded rather than derived so this helper
	// needs no crypto; the verifier is replayed at the token call.
	//
	// No bridge_key_fingerprint is sent: the Hub DERIVES it from the key, and a
	// body-supplied one that disagrees is rejected (bridge_grant.odin) — a
	// requester-chosen fingerprint would defeat the point of the human comparing it.
	//
	// `device_label` is what becomes the bridge's hostname and therefore its label
	// (wiring.odin maps device_label -> machine_hostname), so label assertions in
	// these suites keep working unchanged.
	authorized := request(graph, "POST", "/api/v1/device/authorize", strings.concatenate({"{\"client\":\"ham-bridge\",\"device_label\":\"", "Alice Bridge", "\",\"os\":\"linux\",\"bridge_public_key\":\"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\",\"os_user\":\"tester\",\"code_challenge\":\"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI\",\"code_challenge_method\":\"S256\"}"}), nil)
	check(authorized.status == 200, authorized.body)
	device_code := extract_json_string(authorized.body, "device_code")
	user_code := extract_json_string(authorized.body, "user_code")

	// The human approves, authenticated by the same trusted-proxy headers the
	// caller passed. Ownership comes from that Auth_Context, never from the body.
	approved := request(graph, "POST", "/api/v1/device/approve", strings.concatenate({"{\"user_code\":\"", user_code, "\",\"approve\":true}"}), headers)
	check(approved.status == 200, approved.body)

	// The bridge collects its credential. Single-use: the grant is spent here.
	issued := request(graph, "POST", "/api/v1/device/token", strings.concatenate({"{\"device_code\":\"", device_code, "\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}"}), nil)
	check(issued.status == 200, issued.body)

	// ===== CAPABILITIES ARE REPORTED, NOT ENROLLED =====
	//
	// The deleted enroll endpoint took a `capabilities` array in its body, so the
	// old helper declared the bridge's providers AT ENROLLMENT. The device flow has
	// no such field by design: what the Hub records at enrollment is only what the
	// approving human confirmed (the key, its fingerprint, the OS user). A real
	// bridge reports its providers when it CONNECTS, over the runtime WS, which the
	// Hub handles with update_runtime_capabilities.
	//
	// No bridge connects in these tests, so this calls the same service proc the WS
	// handler does. Without it the bridge has no declared providers and anything
	// that matches an agent to a provider/tier fails — which is a real difference
	// between the two flows, not a test artifact.
	//
	// NOTE it also marks the bridge Online (as a connect would), where the deleted
	// enroll path left it Offline.
	_, _, _ = bridge_service.update_runtime_capabilities(&graph.bridges, extract_json_string(issued.body, "bridge_id"), "{\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\",\"smart\"],\"default_tier\":\"normal\"}]}")

	return extract_json_string(issued.body, "access_token")
}

request :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	// Mirror the real server's split_target_query: the router matches on a bare
	// path, and handlers read the query string separately.
	bare := path
	query := ""
	if q := strings.index_byte(path, '?'); q >= 0 {
		bare = path[:q]
		query = path[q + 1:]
	}
	return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = bare, query = query, body = body, request_id = "req_bmc", remote_addr = "127.0.0.1", headers = headers})
}

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""}); defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:]); if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

itoa :: proc(n: int) -> string {
	return fmt.aprintf("%d", n)
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
