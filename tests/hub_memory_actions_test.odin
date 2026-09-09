package hub_memory_actions_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import bridge "odin_test:bridge"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"
import api_http "odin_test:hub/transport/http"

PORT :: 49679

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln("FAIL:", message)
	os.exit(1)
}

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return rest[:end]
}

request :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	bare := path
	query := ""
	if q := strings.index_byte(path, '?'); q >= 0 {
		bare = path[:q]
		query = path[q + 1:]
	}
	return api_http.router_dispatch(&graph.router, api_http.Request{
		method = method,
		path = bare,
		query = query,
		body = body,
		headers = headers,
		remote_addr = "127.0.0.1",
		request_id = "req_test",
	})
}

enroll_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header) -> (string, string) {
	created := request(graph, "POST", "/api/v1/bridge-enrollments", "{\"label\":\"Test Bridge\"}", headers)
	check(created.status == 201, "bridge enrollment create failed")
	token := extract_json_string(created.body, "enrollment_token")
	enroll_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	enrolled := request(graph, "POST", "/api/v1/bridges/enroll", "{\"machine\":{\"hostname\":\"host\"},\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\",\"smart\"],\"default_tier\":\"normal\"}]}", enroll_headers[:])
	check(enrolled.status == 201, enrolled.body)
	return extract_json_string(enrolled.body, "bridge_id"), extract_json_string(enrolled.body, "bridge_token")
}

main :: proc() {
	db_path := "/tmp/heimdall-hub-memory-actions-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		bind_host = "127.0.0.1",
		port = PORT,
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
	})
	check(ok, message)

	user_headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "alice"},
		{name = "X-authentik-name", value = "Alice User"},
		{name = "X-authentik-email", value = "alice@example.com"},
	}
	bridge_id, bridge_token := enroll_bridge(&graph, user_headers[:])

	owner := domain.User_ID("alice")
	now := "2026-07-23T00:00:00Z"
	agent_id := "agent_memory_test"
	instance_id := "inst_memory_test"

	_, agent_saved, agent_err := iface.agent_save(&graph.repos.agents, domain.Agent{
		agent_id = agent_id,
		owner_user_id = owner,
		name = "Memory Test Agent",
		slug = "mem-agent",
		default_provider = "claude",
		default_tier = "normal",
		state = .Active,
		created_at = now,
		updated_at = now,
	})
	check(agent_saved, agent_err.message)

	_, inst_saved, inst_err := iface.agent_save_instance(&graph.repos.agents, domain.Agent_Instance{
		agent_instance_id = instance_id,
		owner_user_id = owner,
		agent_id = agent_id,
		bridge_id = bridge_id,
		provider = "claude",
		tier = "normal",
		chain_id = "chain_test",
		runtime_status = "live",
		startup_status = "ready",
		activity_status = "idle",
		created_at = now,
		updated_at = now,
		started_at = now,
		last_seen_at = now,
	})
	check(inst_saved, inst_err.message)

	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = string(owner), name = string(owner)}

	// Create two test memories
	// Memory 1: Fact, scoped to agent_id
	mem1, saved1, err1 := content_service.create_memory(&graph.content, auth, content_service.Memory_Input{
		agent_ids = []string{agent_id},
		type = .Fact,
		status = "active",
		title = "Build Command",
		description = "How to build Heimdall",
		body = "odin check src/hub",
		evidence = "verified in nix develop shell",
	})
	check(saved1, err1.message)

	// Memory 2: Habit, global
	mem2, saved2, err2 := content_service.create_memory(&graph.content, auth, content_service.Memory_Input{
		type = .Habit,
		status = "active",
		title = "Review Checklist",
		description = "Run tests before voting LGTM",
		body = "Always verify tests pass before approving",
		evidence = "reviewed by team",
	})
	check(saved2, err2.message)

	thread.run_with_poly_data(&graph.router, serve_hub)
	bridge.bridge_agent_token_store_init()
	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", PORT)
	bridge.bridge_config.bridge_token = bridge_token
	issued := bridge.bridge_agent_token_issue(instance_id, strings.concatenate({"hit_", instance_id}), .Agent)

	// Test 1: agent.memory.list returns metadata-only
	list_line := strings.concatenate({
		"{\"v\":1,\"id\":\"list_all\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.list\",\"params\":{}}"
	})
	list_resp := ""
	for attempt in 0..<25 {
		_ = attempt
		list_resp = bridge.bridge_local_endpoint_handle_jsonl_line(list_line)
		if strings.contains(list_resp, "\"ok\":true") do break
	}
	check(strings.contains(list_resp, "\"ok\":true"), fmt.tprintf("memory.list failed: %s", list_resp))
	check(strings.contains(list_resp, mem1.memory_id), "memory 1 id present")
	check(strings.contains(list_resp, mem2.memory_id), "memory 2 id present")
	check(strings.contains(list_resp, "Build Command"), "memory 1 title present")
	check(strings.contains(list_resp, "How to build Heimdall"), "memory 1 description present")
	check(strings.contains(list_resp, "Review Checklist"), "memory 2 title present")
	// Metadata only: must NOT contain body or evidence!
	check(!strings.contains(list_resp, "odin check src/hub"), "memory body must be omitted from memory.list")
	check(!strings.contains(list_resp, "verified in nix develop shell"), "evidence must be omitted from memory.list")
	check(!strings.contains(list_resp, "\"body\":"), "no body key in list response")
	check(!strings.contains(list_resp, "\"evidence\":"), "no evidence key in list response")

	// Test 2: agent.memory.list with filter type=habit
	list_habit_line := strings.concatenate({
		"{\"v\":1,\"id\":\"list_habit\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.list\",\"params\":{\"type\":\"habit\"}}"
	})
	list_habit_resp := bridge.bridge_local_endpoint_handle_jsonl_line(list_habit_line)
	check(strings.contains(list_habit_resp, "\"ok\":true"), list_habit_resp)
	check(strings.contains(list_habit_resp, mem2.memory_id), "habit memory present")
	check(!strings.contains(list_habit_resp, mem1.memory_id), "fact memory filtered out")

	// Test 3: agent.memory.show returns full memory JSON including body and evidence
	show_line := strings.concatenate({
		"{\"v\":1,\"id\":\"show_mem\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.show\",\"params\":{\"memory_id\":\"", mem1.memory_id, "\"}}"
	})
	show_resp := bridge.bridge_local_endpoint_handle_jsonl_line(show_line)
	check(strings.contains(show_resp, "\"ok\":true"), show_resp)
	check(strings.contains(show_resp, mem1.memory_id), "show has memory_id")
	check(strings.contains(show_resp, "Build Command"), "show has title")
	check(strings.contains(show_resp, "odin check src/hub"), "show has body")
	check(strings.contains(show_resp, "verified in nix develop shell"), "show has evidence")

	// Test 4: agent.memory.content returns content payload {"content": m.body}
	content_line := strings.concatenate({
		"{\"v\":1,\"id\":\"content_mem\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.content\",\"params\":{\"memory_id\":\"", mem1.memory_id, "\"}}"
	})
	content_resp := bridge.bridge_local_endpoint_handle_jsonl_line(content_line)
	check(strings.contains(content_resp, "\"ok\":true"), content_resp)
	check(strings.contains(content_resp, "\"content\":\"odin check src/hub\""), "content response has raw body as content")

	// Test 5: User-mode GET /api/v1/memories?type=habit
	user_list := request(&graph, "GET", "/api/v1/memories?type=habit", "", user_headers[:])
	check(user_list.status == 200, "user list memories status 200")
	check(strings.contains(user_list.body, mem2.memory_id), "user list has mem2")
	check(!strings.contains(user_list.body, mem1.memory_id), "user list filtered out mem1")

	// Test 6: User-mode GET /api/v1/memories/:id (as used by ctl_hub_memories show and content)
	user_show := request(&graph, "GET", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), "", user_headers[:])
	check(user_show.status == 200, "user show memory status 200")
	check(strings.contains(user_show.body, "odin check src/hub"), "user show has body")

	fmt.println("PASS: hub memory actions (list metadata-only, show, content)")
	app.shutdown_graph(&graph)
	_ = os.remove(db_path)
	os.exit(0)
}

serve_hub :: proc(router: ^api_http.Router) {
	_ = api_http.serve(router, api_http.Server_Config{bind_host = "127.0.0.1", port = PORT})
}
