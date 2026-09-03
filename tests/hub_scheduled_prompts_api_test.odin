package hub_scheduled_prompts_api_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import api_http "odin_test:hub/transport/http"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	tail := body[idx + len(needle):]
	end_idx := strings.index(tail, "\"")
	if end_idx < 0 do return ""
	return tail[:end_idx]
}

main :: proc() {
	db_path := "/tmp/sp_api_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

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
	defer app.shutdown_graph(&graph)

	alice := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "alice"},
		{name = "X-authentik-name", value = "Alice"},
	}

	// 1. Enroll bridge 1
	enr1 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridge-enrollments",
		body = "{\"label\":\"Bridge 1\"}",
		request_id = "req_enr1",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(enr1.status == 201, "create enrollment 1")
	tok1 := extract_json_string(enr1.body, "enrollment_token")

	enroll1_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", tok1})}}
	b1_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridges/enroll",
		body = "{\"machine\":{\"hostname\":\"host1\"}}",
		request_id = "req_b1",
		remote_addr = "127.0.0.1",
		headers = enroll1_headers[:],
	})
	check(b1_resp.status == 201, "enroll bridge 1")
	bridge1_id := extract_json_string(b1_resp.body, "bridge_id")
	bridge1_token := extract_json_string(b1_resp.body, "bridge_token")
	bridge1_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge1_token})}}

	// 2. Enroll bridge 2
	enr2 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridge-enrollments",
		body = "{\"label\":\"Bridge 2\"}",
		request_id = "req_enr2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	tok2 := extract_json_string(enr2.body, "enrollment_token")
	enroll2_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", tok2})}}
	b2_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridges/enroll",
		body = "{\"machine\":{\"hostname\":\"host2\"}}",
		request_id = "req_b2",
		remote_addr = "127.0.0.1",
		headers = enroll2_headers[:],
	})
	bridge2_token := extract_json_string(b2_resp.body, "bridge_token")
	bridge2_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge2_token})}}

	owner_user := domain.User_ID("alice")
	now_ts := "2026-01-01T00:00:00Z"

	// Directly seed an agent instance for bridge 1
	inst1 := domain.Agent_Instance{
		agent_instance_id = "inst_1",
		owner_user_id = owner_user,
		agent_id = "agt_1",
		bridge_id = bridge1_id,
		conversation_id = "conv_1",
		runtime_status = "running",
		created_at = now_ts,
		updated_at = now_ts,
	}
	_, _, save_inst_err := graph.repos.agents.save_instance(graph.repos.agents.ctx, inst1)
	check(save_inst_err.code == .None, "seed instance 1")

	// Seed conversation for instance 1
	conv1 := domain.Chat_Conversation{
		conversation_id = "conv_1",
		owner_user_id = owner_user,
		agent_id = "agt_1",
		agent_instance_id = "inst_1",
		created_at = now_ts,
		updated_at = now_ts,
	}
	_, _, save_conv_err := graph.repos.content.save_conversation(graph.repos.content.ctx, conv1)
	check(save_conv_err.code == .None, "seed conversation 1")

	instance1_id := "inst_1"

	// 4. User creates scheduled prompt targeting instance1
	create_sp_body := strings.concatenate({"{\"target_instance_id\":\"", instance1_id, "\",\"prompt_text\":\"wake up\",\"target_run_at\":\"2026-01-01T00:00:00Z\",\"interval\":\"1h\"}"})
	create_sp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/scheduled-prompts",
		body = create_sp_body,
		request_id = "req_create_sp",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(create_sp.status == 201, fmt.tprintf("create scheduled prompt: %s", create_sp.body))
	sp1_id := extract_json_string(create_sp.body, "id")

	// Verify bridge 1 version bumped to 1
	v1 := api_http.get_scheduled_prompts_bridge_version(&graph.scheduled_prompt_handlers, bridge1_id)
	check(v1 == 1, fmt.tprintf("bridge 1 version should be 1, got %d", v1))

	// 5. Bridge 1 reads scheduled prompts (scoped to own instances)
	b1_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/bridge/scheduled-prompts",
		request_id = "req_b1_list",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(b1_list.status == 200, "bridge 1 list prompts")
	check(strings.contains(b1_list.body, sp1_id), "bridge 1 should see sp1")

	// Bridge 2 reads scheduled prompts (should NOT see sp1)
	b2_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/bridge/scheduled-prompts",
		request_id = "req_b2_list",
		remote_addr = "127.0.0.1",
		headers = bridge2_headers[:],
	})
	check(b2_list.status == 200, "bridge 2 list prompts")
	check(!strings.contains(b2_list.body, sp1_id), "bridge 2 must not see sp1 (scoped to own instances)")

	// 6. Conditional ETag check on bridge 1 read
	etag := ""
	for h in b1_list.headers {
		if h.name == "ETag" do etag = h.value
	}
	check(etag != "", "ETag header must be returned on bridge read")

	cached_headers := [?]contracts.HTTP_Header{
		{name = "Authorization", value = strings.concatenate({"Bearer ", bridge1_token})},
		{name = "If-None-Match", value = etag},
	}
	b1_cached := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/bridge/scheduled-prompts",
		request_id = "req_b1_cached",
		remote_addr = "127.0.0.1",
		headers = cached_headers[:],
	})
	check(b1_cached.status == 304, fmt.tprintf("expected 304 Not Modified with matching ETag, got %d", b1_cached.status))

	// 7. Bridge 1 executes scheduled prompt (CAS atomic check)
	exec_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridge/scheduled-prompts/%s/execute", sp1_id),
		request_id = "req_exec",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(exec_resp.status == 200, fmt.tprintf("execute prompt failed: %s", exec_resp.body))

	// Verify CAS prevents double-inject if not ready
	exec_resp2 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridge/scheduled-prompts/%s/execute", sp1_id),
		request_id = "req_exec2",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(exec_resp2.status == 409, fmt.tprintf("expected 409 Conflict on double execution, got %d", exec_resp2.status))

	// 8. Version bumps on delete
	v_before_del := api_http.get_scheduled_prompts_bridge_version(&graph.scheduled_prompt_handlers, bridge1_id)
	del_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "DELETE",
		path = fmt.tprintf("/api/v1/scheduled-prompts/%s", sp1_id),
		request_id = "req_del",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(del_resp.status == 200, "delete prompt failed")
	v_after_del := api_http.get_scheduled_prompts_bridge_version(&graph.scheduled_prompt_handlers, bridge1_id)
	check(v_after_del == v_before_del + 1, fmt.tprintf("version must bump on delete: before=%d after=%d", v_before_del, v_after_del))

	fmt.println("ALL SCHEDULED PROMPT API TESTS PASSED")
}
