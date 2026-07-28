package hub_phase6_agent_http_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import agent_service "odin_test:hub/service/agent"
import api_http "odin_test:hub/transport/http"

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
	created := request(graph, "POST", "/api/v1/bridge-enrollments", strings.concatenate({"{\"label\":\"", label, "\"}"}), headers)
	check(created.status == 201, "bridge enrollment create failed")
	token := extract_json_string(created.body, "enrollment_token")
	enroll_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	enrolled := request(graph, "POST", "/api/v1/bridges/enroll", "{\"machine\":{\"hostname\":\"host\"},\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\",\"smart\"],\"default_tier\":\"normal\"}]}", enroll_headers[:])
	check(enrolled.status == 201, enrolled.body)
	return extract_json_string(enrolled.body, "bridge_id")
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
