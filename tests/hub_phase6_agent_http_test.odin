package hub_phase6_agent_http_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import agent_service "odin_test:hub/service/agent"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"

main :: proc() {
	db_path := "/tmp/heimdall-hub-phase6-agent-http-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }
	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}

	bridge_id := enroll_bridge(&graph, alice[:], "Alice Bridge")
	bridge_id_2 := enroll_bridge(&graph, alice[:], "Second Bridge")
	agent := request(&graph, "POST", "/api/v1/agents", "{\"name\":\"Backend Agent\",\"slug\":\"backend\",\"default_provider\":\"claude\",\"default_tier\":\"normal\"}", alice[:])
	check(agent.status == 201 && strings.contains(agent.body, "backend"), "create agent endpoint must return agent")
	agent_id := extract_json_string(agent.body, "agent_id")
	list_a := request(&graph, "GET", "/api/v1/agents", "", alice[:])
	check(list_a.status == 200 && strings.contains(list_a.body, agent_id), "owner must list own agent")
	list_b := request(&graph, "GET", "/api/v1/agents", "", bob[:])
	check(list_b.status == 200 && !strings.contains(list_b.body, agent_id), "other user must not list agent")
	bob_detail := request(&graph, "GET", agent_url(agent_id, ""), "", bob[:])
	check(bob_detail.status == 404, "cross-user agent detail must be hidden")
	auth_ctx := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	_, enabled_before_err := agent_service.require_enabled_support(&graph.agents, auth_ctx, agent_id)
	check(enabled_before_err.code == .Provider_Unavailable, "agent with no enabled support must not be runnable")
	updated := request(&graph, "PATCH", agent_url(agent_id, ""), "{\"name\":\"Backend Updated\"}", alice[:])
	check(updated.status == 200 && strings.contains(updated.body, "Backend Updated"), "update agent endpoint must update owner agent")
	bob_agent := request(&graph, "POST", "/api/v1/agents", "{\"name\":\"Bob Agent\",\"slug\":\"bob-agent\"}", bob[:])
	bob_agent_id := extract_json_string(bob_agent.body, "agent_id")
	bob_cross_bridge := request(&graph, "PATCH", support_url(bob_agent_id, bridge_id), "{\"enabled\":true,\"provider\":\"claude\",\"tier\":\"smart\"}", bob[:])
	check(bob_cross_bridge.status == 404, "cannot configure another user's bridge support")
	substring_support := request(&graph, "PATCH", support_url(agent_id, bridge_id), "{\"enabled\":true,\"provider\":\"laud\",\"tier\":\"mart\"}", alice[:])
	check(substring_support.status == 503, "provider/tier validation must reject substrings of capabilities")
	provider_as_tier := request(&graph, "PATCH", support_url(agent_id, bridge_id), "{\"enabled\":true,\"provider\":\"claude\",\"tier\":\"claude\"}", alice[:])
	check(provider_as_tier.status == 503, "provider/tier validation must reject provider name as tier when not in tiers array")
	key_as_tier := request(&graph, "PATCH", support_url(agent_id, bridge_id), "{\"enabled\":true,\"provider\":\"claude\",\"tier\":\"tiers\"}", alice[:])
	check(key_as_tier.status == 503, "provider/tier validation must reject JSON key names as tiers")
	bad_support := request(&graph, "PATCH", support_url(agent_id, bridge_id), "{\"enabled\":true,\"provider\":\"openai\",\"tier\":\"smart\"}", alice[:])
	check(bad_support.status == 503, "unsupported provider/tier must be rejected")
	support := request(&graph, "PATCH", support_url(agent_id, bridge_id), "{\"enabled\":true,\"provider\":\"claude\",\"tier\":\"smart\",\"priority\":10,\"max_instances\":2}", alice[:])
	check(support.status == 200 && strings.contains(support.body, bridge_id) && strings.contains(support.body, "smart"), "support endpoint must configure owned bridge")
	enabled_after, enabled_after_err := agent_service.require_enabled_support(&graph.agents, auth_ctx, agent_id)
	check(enabled_after && enabled_after_err.code == .None, "enabled support must satisfy run precondition")
	resolved_support, resolved_support_ok, resolved_support_err := agent_service.resolve_provider_tier(&graph.agents, auth_ctx, agent_id, bridge_id, agent_service.Run_Request{})
	check(resolved_support_ok && resolved_support_err.code == .None && resolved_support.provider == "claude" && resolved_support.tier == "smart", "resolution must use support override before agent/bridge defaults")
	resolved_request, resolved_request_ok, resolved_request_err := agent_service.resolve_provider_tier(&graph.agents, auth_ctx, agent_id, bridge_id, agent_service.Run_Request{tier = "normal"})
	check(resolved_request_ok && resolved_request_err.code == .None && resolved_request.tier == "normal", "resolution must use request override before support override")
	second_support := request(&graph, "PATCH", support_url(agent_id, bridge_id_2), "{\"enabled\":true,\"provider\":\"claude\",\"tier\":\"normal\"}", alice[:])
	check(second_support.status == 200, "second support setup must work before replace")
	replace_two := request(&graph, "PUT", agent_url(agent_id, "/bridge-support"), strings.concatenate({"{\"bridges\":[{\"bridge_id\":\"", bridge_id, "\",\"enabled\":true,\"provider\":\"claude\",\"tier\":\"smart\"},{\"bridge_id\":\"", bridge_id_2, "\",\"enabled\":true,\"provider\":\"claude\",\"tier\":\"normal\"}]}"}), alice[:])
	check(replace_two.status == 200 && strings.contains(replace_two.body, bridge_id) && strings.contains(replace_two.body, bridge_id_2), "replace support endpoint must persist every bridges array entry")
	list_two := request(&graph, "GET", agent_url(agent_id, "/bridge-support"), "", alice[:])
	check(list_two.status == 200 && strings.contains(list_two.body, bridge_id) && strings.contains(list_two.body, bridge_id_2), "list support must show all replaced entries")
	replace_support := request(&graph, "PUT", agent_url(agent_id, "/bridge-support"), strings.concatenate({"{\"bridges\":[{\"bridge_id\":\"", bridge_id, "\",\"enabled\":true,\"provider\":\"claude\",\"tier\":\"smart\"}]}"}), alice[:])
	check(replace_support.status == 200, "replace support endpoint must accept documented bridges array")
	list_support := request(&graph, "GET", agent_url(agent_id, "/bridge-support"), "", alice[:])
	check(list_support.status == 200 && strings.contains(list_support.body, bridge_id) && !strings.contains(list_support.body, bridge_id_2), "replace support endpoint must remove omitted support rows")
	archived := request(&graph, "POST", agent_url(agent_id, "/archive"), "", alice[:])
	check(archived.status == 200 && strings.contains(archived.body, "archived"), "archive endpoint must archive agent")
	deleted := request(&graph, "DELETE", support_url(agent_id, bridge_id), "", alice[:])
	check(deleted.status == 200 && strings.contains(deleted.body, "deleted"), "delete support endpoint must remove support")
	fmt.println("PASS: hub phase6 agent http")
}

enroll_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, label: string) -> string {
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
	authorized := request(graph, "POST", "/api/v1/device/authorize", strings.concatenate({"{\"client\":\"ham-bridge\",\"device_label\":\"", label, "\",\"os\":\"linux\",\"bridge_public_key\":\"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\",\"os_user\":\"tester\",\"code_challenge\":\"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI\",\"code_challenge_method\":\"S256\"}"}), nil)
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

	return extract_json_string(issued.body, "bridge_id")
}

request :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = path, body = body, request_id = "req_p6", remote_addr = "127.0.0.1", headers = headers})
}

agent_url :: proc(agent_id, suffix: string) -> string { return strings.concatenate({"/api/v1/agents/", agent_id, suffix}) }
support_url :: proc(agent_id, bridge_id: string) -> string { return strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id}) }

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""}); defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:]); if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
