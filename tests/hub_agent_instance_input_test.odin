package hub_agent_instance_input_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import app "odin_test:hub/app"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

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
	created := request(graph, "POST", "/api/v1/bridge-enrollments", strings.concatenate({"{\"label\":\"", label, "\"}"}), headers)
	check(created.status == 201, "bridge enrollment create failed")
	token := extract_json_string(created.body, "enrollment_token")
	enroll_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	enrolled := request(graph, "POST", "/api/v1/bridges/enroll", "{\"machine\":{\"hostname\":\"host\"},\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\",\"smart\"],\"default_tier\":\"normal\"}]}", enroll_headers[:])
	check(enrolled.status == 201, enrolled.body)
	bridge_id = extract_json_string(enrolled.body, "bridge_id")
	bridge_token = extract_json_string(enrolled.body, "bridge_token")
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
		request_id = "req_input_test",
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
	db_path := "/tmp/heimdall-hub-input-test.db"
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

	input_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/input"})

	// 1. Unauthenticated request must return 401
	unauth_res := request(&graph, "POST", input_path, "{\"data\":\"ls -la\\n\"}", nil)
	check(unauth_res.status == 401, strings.concatenate({"unauthenticated request must return 401, got: ", fmt.tprintf("%d", unauth_res.status)}))

	// 2. Bare bridge token caller must be rejected with 403
	bridge_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	bridge_res := request(&graph, "POST", input_path, "{\"data\":\"ls -la\\n\"}", bridge_headers[:])
	check(bridge_res.status == 403, strings.concatenate({"bridge caller must return 403, got: ", fmt.tprintf("%d", bridge_res.status)}))

	// 3. Cross-user request (bob) must return 404 (ownership check)
	cross_res := request(&graph, "POST", input_path, "{\"data\":\"ls -la\\n\"}", bob[:])
	check(cross_res.status == 404, strings.concatenate({"cross-user request must return 404, got: ", fmt.tprintf("%d", cross_res.status)}))

	// 4. Non-existent instance must return 404
	non_existent_path := "/api/v1/agent-instances/inst_doesnotexist/input"
	non_exist_res := request(&graph, "POST", non_existent_path, "{\"data\":\"ls -la\\n\"}", alice[:])
	check(non_exist_res.status == 404, strings.concatenate({"non-existent instance must return 404, got: ", fmt.tprintf("%d", non_exist_res.status)}))

	// 5. Valid authenticated request from alice: sends agent_pty_input runtime command to bridge
	mock_bridge_call_count = 0
	valid_res := request(&graph, "POST", input_path, "{\"data\":\"ls -la\\n\"}", alice[:])
	check(valid_res.status == 200, strings.concatenate({"valid input request must return 200, got: ", fmt.tprintf("%d body=%s", valid_res.status, valid_res.body)}))
	check(mock_bridge_call_count == 1, "mock bridge must be called exactly once")
	check(last_received_command.bridge_id == bridge_id, "bridge_id must match target instance bridge")
	check(strings.contains(last_received_command.body_json, "\"type\":\"agent_pty_input\""), "command must have type agent_pty_input")
	check(strings.contains(last_received_command.body_json, strings.concatenate({"\"agent_instance_id\":\"", inst_id, "\""})), "command must have agent_instance_id")
	check(strings.contains(last_received_command.body_json, "\"data\":\"ls -la\\n\""), "command must pass data payload")
	check(strings.contains(valid_res.body, "\"ok\":true"), "response must contain ok: true")

	// 6. Valid keystrokes with control characters (e.g. Ctrl+C)
	mock_bridge_call_count = 0
	ctrl_c_res := request(&graph, "POST", input_path, "{\"data\":\"\\u0003\"}", alice[:])
	check(ctrl_c_res.status == 200, "ctrl_c input request must return 200")
	check(mock_bridge_call_count == 1, "mock bridge must be called")
	check(strings.contains(last_received_command.body_json, "\\u0003"), "command must escape control character 0x03")

	// 7. Verify GET /api/v1/agent-instances/{id}/pane is NOT broken
	pane_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/pane"})
	pane_res := request(&graph, "GET", pane_path, "", alice[:])
	check(pane_res.status == 200, "pane endpoint must continue to work")

	fmt.println("PASS: hub agent instance input endpoint (REQ-INT-2)")
}
