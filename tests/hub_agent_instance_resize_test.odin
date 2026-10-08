package hub_agent_instance_resize_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import app "odin_test:hub/app"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln("FAIL:", message)
	os.exit(1)
}

mock_bridge_call_count := 0
last_received_command: project_service.Runtime_Command

mock_send_runtime_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	_ = ctx
	mock_bridge_call_count += 1
	last_received_command = command
	return true, domain.Domain_Error{}
}

mock_send_runtime_command_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = ctx
	_ = timeout_ms
	mock_bridge_call_count += 1
	last_received_command = command
	return `{"ok":true}`, true, domain.Domain_Error{}
}

enroll_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, label: string) -> (bridge_id: string, bridge_token: string) {
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

	bridge_id = extract_json_string(issued.body, "bridge_id")
	bridge_token = extract_json_string(issued.body, "access_token")
	return bridge_id, bridge_token
}

request :: proc(graph: ^app.App_Graph, method, target, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	path := target
	query := ""
	q_idx := strings.index_byte(target, '?')
	if q_idx >= 0 {
		path = target[:q_idx]
		query = target[q_idx + 1:]
	}
	return api_http.router_dispatch(&graph.router, api_http.Request{
		method = method,
		path = path,
		query = query,
		body = body,
		request_id = "req_resize_test",
		remote_addr = "127.0.0.1",
		headers = headers,
	})
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
	for i := 1; i < len(rest); i += 1 {
		if rest[i] == '"' do return rest[1:i]
	}
	return ""
}

main :: proc() {
	db_path := "/tmp/heimdall-hub-resize-test.db"
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

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}

	bridge_id, bridge_token := enroll_bridge(&graph, alice[:], "Alice Bridge")
	check(bridge_id != "", "bridge_id must not be empty")

	b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	if b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge_id, false, "")

	// Wire mock send_runtime_command
	graph.agents.bridge_command_sink.send_runtime_command = mock_send_runtime_command
	graph.agents.bridge_command_sink.send_runtime_command_wait = mock_send_runtime_command_wait

	// Create agent for alice
	agent_res := request(&graph, "POST", "/api/v1/agents", "{\"name\":\"Coder Agent\",\"slug\":\"coder\",\"default_provider\":\"claude\",\"default_tier\":\"normal\"}", alice[:])
	check(agent_res.status == 201, "agent creation must succeed")
	agent_id := extract_json_string(agent_res.body, "agent_id")

	// Enable bridge support for agent
	support_res := request(&graph, "PATCH", strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id}), "{\"enabled\":true,\"provider\":\"claude\",\"tier\":\"normal\"}", alice[:])
	check(support_res.status == 200, "bridge support configuration must succeed")

	// Create an agent instance for alice
	inst_post := strings.concatenate({"{\"agent_id\":\"", agent_id, "\",\"bridge_id\":\"", bridge_id, "\"}"})
	inst_res := request(&graph, "POST", "/api/v1/agent-instances", inst_post, alice[:])
	check(inst_res.status == 201, strings.concatenate({"agent instance creation failed: ", inst_res.body}))
	inst_id := extract_json_string(inst_res.body, "agent_instance_id")
	check(inst_id != "", "inst_id must not be empty")

	resize_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/resize"})

	// 1. Unauthenticated request must return 401
	unauth_res := request(&graph, "POST", resize_path, "{\"rows\":25,\"cols\":110}", nil)
	check(unauth_res.status == 401, strings.concatenate({"unauthenticated request must return 401, got: ", fmt.tprintf("%d", unauth_res.status)}))

	// 2. Bare bridge token caller must be rejected with 403
	bridge_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	bridge_res := request(&graph, "POST", resize_path, "{\"rows\":25,\"cols\":110}", bridge_headers[:])
	check(bridge_res.status == 403, strings.concatenate({"bridge caller must return 403, got: ", fmt.tprintf("%d", bridge_res.status)}))

	// 3. Cross-user request (bob) must return 404 (ownership check)
	cross_res := request(&graph, "POST", resize_path, "{\"rows\":25,\"cols\":110}", bob[:])
	check(cross_res.status == 404, strings.concatenate({"cross-user request must return 404, got: ", fmt.tprintf("%d", cross_res.status)}))

	// 4. Non-existent instance must return 404
	non_existent_path := "/api/v1/agent-instances/inst_doesnotexist/resize"
	non_exist_res := request(&graph, "POST", non_existent_path, "{\"rows\":25,\"cols\":110}", alice[:])
	check(non_exist_res.status == 404, strings.concatenate({"non-existent instance must return 404, got: ", fmt.tprintf("%d", non_exist_res.status)}))

	// 5. Invalid parameters: rows < 1 must return 400
	bad_rows_res := request(&graph, "POST", resize_path, "{\"rows\":0,\"cols\":110}", alice[:])
	check(bad_rows_res.status == 400, strings.concatenate({"zero rows must return 400, got: ", fmt.tprintf("%d", bad_rows_res.status)}))

	// 6. Invalid parameters: cols < 1 must return 400
	bad_cols_res := request(&graph, "POST", resize_path, "{\"rows\":25,\"cols\":0}", alice[:])
	check(bad_cols_res.status == 400, strings.concatenate({"zero cols must return 400, got: ", fmt.tprintf("%d", bad_cols_res.status)}))

	// 7. Valid authenticated request from alice: sends agent_pty_resize runtime command to bridge
	mock_bridge_call_count = 0
	valid_res := request(&graph, "POST", resize_path, "{\"rows\":25,\"cols\":110}", alice[:])
	check(valid_res.status == 200, strings.concatenate({"valid resize request must return 200, got: ", fmt.tprintf("%d body=%s", valid_res.status, valid_res.body)}))
	check(mock_bridge_call_count == 1, "mock bridge must be called exactly once")
	check(last_received_command.bridge_id == bridge_id, "bridge_id must match target instance bridge")
	check(strings.contains(last_received_command.body_json, "\"type\":\"shell_pty_resize\"") || strings.contains(last_received_command.body_json, "\"type\":\"agent_pty_resize\""), "command must have type shell_pty_resize or agent_pty_resize")
	check(strings.contains(last_received_command.body_json, strings.concatenate({"\"shell_id\":\"", inst_id, "\""})), "command must have shell_id")
	check(strings.contains(last_received_command.body_json, strings.concatenate({"\"agent_instance_id\":\"", inst_id, "\""})), "command must have agent_instance_id")
	check(strings.contains(last_received_command.body_json, "\"rows\":25"), "command must pass rows payload")
	check(strings.contains(last_received_command.body_json, "\"cols\":110"), "command must pass cols payload")
	check(strings.contains(valid_res.body, "\"ok\":true"), "response must contain ok: true")

	// 8. Verify POST /input and GET /pane endpoints are NOT broken
	input_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/input"})
	input_res := request(&graph, "POST", input_path, "{\"data\":\"ls -la\\n\"}", alice[:])
	check(input_res.status == 200, "input endpoint must continue to work")

	pane_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/pane"})
	pane_res := request(&graph, "GET", pane_path, "", alice[:])
	check(pane_res.status == 200, "pane endpoint must continue to work")

	fmt.println("PASS: hub agent instance resize endpoint (REQ-WINSIZE-2)")
}
