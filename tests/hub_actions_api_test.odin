package hub_actions_api_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import auth_service "odin_test:hub/service/auth"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

dummy_send :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	return true, {}
}

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

// Capture the checkpoint-1 (bare_token_shared_endpoint) audit event so the test
// can assert it identifies the endpoint (method/path), not just that it fired.
cp1_captured_path: string
cp1_captured_method: string
capture_bridge_auth_monitor :: proc(point, method, path, bridge_id, user_id, target, request_id: string) {
	if point == "bare_token_shared_endpoint" {
		cp1_captured_path = path
		cp1_captured_method = method
	}
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
	db_path := "/tmp/actions_api_test.db"
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

	// Default bridge-auth mode (unset in Hub_Config) must resolve to monitor.
	check(graph.auth.bridge_auth_mode == .Monitor, "default bridge_auth_mode must be monitor")

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
	check(enr1.status == 201, fmt.tprintf("enroll 1 failed: %s", enr1.body))
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
	check(b1_resp.status == 201, fmt.tprintf("bridge 1 exchange token failed: %s", b1_resp.body))
	bridge1_token := extract_json_string(b1_resp.body, "bridge_token")
	bridge1_id := extract_json_string(b1_resp.body, "bridge_id")
	bridge1_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge1_token})}}

	owner_user := domain.User_ID("alice")
	now_ts := "2026-01-01T00:00:00Z"

	// Mark bridge live for restart / command sink
	b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge1_id)
	if b_ok {
		b.status = .Online
		b.capabilities_json = "{\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\"]}]}"
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge1_id, false, "")
	graph.agents.bridge_command_sink.send_runtime_command = dummy_send

	// Seed agent
	agt1 := domain.Agent{
		agent_id = "agt_ac_1",
		owner_user_id = owner_user,
		name = "Test Agent",
		slug = "test-agent",
		default_provider = "claude",
		default_tier = "normal",
		state = .Active,
		created_at = now_ts,
		updated_at = now_ts,
	}
	_, _, save_agt_err := graph.repos.agents.save(graph.repos.agents.ctx, agt1)
	check(save_agt_err.code == .None, "seed agent")

	// Seed an agent instance for bridge 1
	inst1 := domain.Agent_Instance{
		agent_instance_id = "inst_ac_1",
		owner_user_id = owner_user,
		agent_id = "agt_ac_1",
		bridge_id = bridge1_id,
		conversation_id = "conv_ac_1",
		provider = "claude",
		tier = "normal",
		runtime_status = "running",
		created_at = now_ts,
		updated_at = now_ts,
	}
	_, _, save_inst_err := graph.repos.agents.save_instance(graph.repos.agents.ctx, inst1)
	check(save_inst_err.code == .None, "seed instance 1")

	// Seed conversation for instance 1
	conv1 := domain.Chat_Conversation{
		conversation_id = "conv_ac_1",
		owner_user_id = owner_user,
		agent_id = "agt_ac_1",
		agent_instance_id = "inst_ac_1",
		created_at = now_ts,
		updated_at = now_ts,
	}
	_, _, save_conv_err := graph.repos.content.save_conversation(graph.repos.content.ctx, conv1)
	check(save_conv_err.code == .None, "seed conversation 1")

	instance1_id := "inst_ac_1"

	// ==========================================
	// Test 2: Validation on create / patch
	// ==========================================
	// 2a. Malformed cron expressions rejected (400)
	bad_cron_bodies := [?]string{
		"{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"p\",\"cron_expr\":\"not a cron\"}",
		"{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"p\",\"cron_expr\":\"* * *\"}",
		"{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"p\",\"cron_expr\":\"60 * * * *\"}",
		"{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"p\",\"cron_expr\":\"* 25 * * *\"}",
		"{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"p\",\"cron_expr\":\"* * * * * *\"}",
	}
	for b in bad_cron_bodies {
		resp := api_http.router_dispatch(&graph.router, api_http.Request{
			method = "POST",
			path = "/api/v1/actions",
			body = b,
			request_id = "req_bad_cron",
			remote_addr = "127.0.0.1",
			headers = alice[:],
		})
		check(resp.status == 400, fmt.tprintf("expected 400 for bad cron '%s', got %d: %s", b, resp.status, resp.body))
	}

	// 2b. Interval < 60s rejected (400)
	bad_interval_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = "{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"p\",\"interval\":\"30s\"}",
		request_id = "req_bad_int",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(bad_interval_resp.status == 400, fmt.tprintf("expected 400 for interval < 60s, got %d: %s", bad_interval_resp.status, bad_interval_resp.body))

	// ==========================================
	// Test 3: User CRUD /api/v1/actions with schedule fields
	// ==========================================
	create_sched_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = "{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"Check open bugs\",\"cron_expr\":\"0 9 * * 1-5\",\"timezone\":\"America/New_York\",\"blackout_dates\":\"[\\\"2026-12-25\\\"]\",\"active_from\":\"2026-01-01T00:00:00Z\",\"active_until\":\"2026-12-31T23:59:59Z\"}",
		request_id = "req_create_sched",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(create_sched_resp.status == 201, fmt.tprintf("create scheduled action failed: %s", create_sched_resp.body))
	act1_id := extract_json_string(create_sched_resp.body, "id")
	check(act1_id != "", "action id must not be empty")
	check(strings.contains(create_sched_resp.body, "America/New_York"), "timezone in response")
	check(strings.contains(create_sched_resp.body, "0 9 * * 1-5"), "cron_expr in response")
	check(strings.contains(create_sched_resp.body, "2026-12-25"), "blackout_dates in response")

	// Verify bridge version bumped on create
	v_after_create := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)
	check(v_after_create > 0, "bridge version bumped on create")

	// Get action
	get_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/actions/%s", act1_id),
		request_id = "req_get",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(get_resp.status == 200, fmt.tprintf("get action failed: %s", get_resp.body))
	check(strings.contains(get_resp.body, "Check open bugs"), "prompt text in get")

	// Patch action
	patch_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/actions/%s", act1_id),
		body = "{\"cron_expr\":\"*/15 * * * *\",\"prompt_text\":\"Check open bugs updated\"}",
		request_id = "req_patch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(patch_resp.status == 200, fmt.tprintf("patch action failed: %s", patch_resp.body))
	check(strings.contains(patch_resp.body, "*/15 * * * *"), "cron_expr updated")
	check(strings.contains(patch_resp.body, "Check open bugs updated"), "prompt text updated")

	v_after_patch := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)
	check(v_after_patch > v_after_create, "bridge version bumped on patch")

	// ==========================================
	// Test 4: Bridge conditional ETag (GET /api/v1/bridge/actions)
	// ==========================================
	b1_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/bridge/actions",
		request_id = "req_b1_list",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(b1_list.status == 200, fmt.tprintf("bridge list failed: %s", b1_list.body))
	etag := ""
	for h in b1_list.headers {
		if h.name == "ETag" do etag = h.value
	}
	check(etag != "", "ETag header missing in bridge list response")

	// Conditional GET with If-None-Match should return 304
	if_none_headers := [?]contracts.HTTP_Header{
		{name = "Authorization", value = strings.concatenate({"Bearer ", bridge1_token})},
		{name = "If-None-Match", value = etag},
	}
	b1_304 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/bridge/actions",
		request_id = "req_b1_304",
		remote_addr = "127.0.0.1",
		headers = if_none_headers[:],
	})
	check(b1_304.status == 304, fmt.tprintf("expected 304 Not Modified, got %d", b1_304.status))

	// ==========================================
	// Test 5: Bridge execute with CAS lease (POST /api/v1/bridge/actions/:id/execute)
	// ==========================================
	// Seed target_run_at to past so it's eligible
	_, _ = graph.repos.actions.cas_lease(graph.repos.actions.ctx, domain.Action_ID(act1_id), "2020-01-01T00:00:00Z", "2020-01-01T00:00:00Z")
	// Make sure action has target_run_at <= now
	cur_act, _, _ := graph.repos.actions.get(graph.repos.actions.ctx, domain.Action_ID(act1_id))
	cur_act.target_run_at = "2020-01-01T00:00:00Z"
	cur_act.in_flight = false
	cur_act.state = .Active
	_, _, _ = graph.repos.actions.save(graph.repos.actions.ctx, cur_act)

	v_before_exec := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)

	exec_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridge/actions/%s/execute", act1_id),
		body = "{\"target_run_at\":\"2029-01-01T00:00:00Z\"}",
		request_id = "req_exec",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(exec_resp.status == 200, fmt.tprintf("bridge execute failed: %s", exec_resp.body))
	del_msg_id := extract_json_string(exec_resp.body, "message_id")
	check(del_msg_id != "", "delivered message_id in execute response")

	// Verify message in chat has message_type == "action"
	msg_rec, got_msg, _ := graph.repos.content.get_message(graph.repos.content.ctx, del_msg_id)
	check(got_msg, "chat message found")
	check(msg_rec.message_type == "action", fmt.tprintf("expected message_type 'action', got '%s'", msg_rec.message_type))

	v_after_exec := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)
	check(v_after_exec > v_before_exec, "bridge version bumped on execute")

	// Second immediate execute should fail CAS (target_run_at is now 2026-09-04T12:00:00Z > now)
	exec_fail := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridge/actions/%s/execute", act1_id),
		body = "{}",
		request_id = "req_exec_fail",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(exec_fail.status == 409, fmt.tprintf("expected 409 on second execute, got %d: %s", exec_fail.status, exec_fail.body))

	// ==========================================
	// Test 6: Run-Now (POST /api/v1/actions/:id/run)
	// ==========================================
	// Create a run-only action
	run_only_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = "{\"target_instance_id\":\"inst_ac_1\",\"prompt_text\":\"Immediate run prompt\"}",
		request_id = "req_ro_create",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(run_only_resp.status == 201, fmt.tprintf("create run-only action failed: %s", run_only_resp.body))
	ro_id := extract_json_string(run_only_resp.body, "id")

	// Test 6a: Run when instance is running
	v_before_run := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)
	run_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/actions/%s/run", ro_id),
		body = "{}",
		request_id = "req_run_now",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(run_resp.status == 200, fmt.tprintf("run-now failed: %s", run_resp.body))
	ro_msg_id := extract_json_string(run_resp.body, "message_id")
	check(ro_msg_id != "", "run-now returned message_id")

	// Verify delivered message has message_type == "action"
	ro_msg, ro_ok, _ := graph.repos.content.get_message(graph.repos.content.ctx, ro_msg_id)
	check(ro_ok, "run-now chat message found")
	check(ro_msg.message_type == "action", fmt.tprintf("expected message_type 'action', got '%s'", ro_msg.message_type))
	check(ro_msg.body == "Immediate run prompt", "run-now prompt text mismatch")

	v_after_run := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)
	check(v_after_run > v_before_run, "bridge version bumped on run-now")

	// Test 6b: Run-Now wakes/restarts stopped instance
	inst_rec, _, _ := graph.repos.agents.get_instance(graph.repos.agents.ctx, "inst_ac_1")
	inst_rec.runtime_status = "stopped"
	_, _, _ = graph.repos.agents.save_instance(graph.repos.agents.ctx, inst_rec)

	run_wake_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/actions/%s/run", ro_id),
		body = "{}",
		request_id = "req_run_wake",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(run_wake_resp.status == 200, fmt.tprintf("run-now wake failed: %s", run_wake_resp.body))

	// ==========================================
	// Test 7: Delete action & version bump on delete
	// ==========================================
	v_before_del := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)
	del_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "DELETE",
		path = fmt.tprintf("/api/v1/actions/%s", ro_id),
		request_id = "req_del",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(del_resp.status == 200, fmt.tprintf("delete action failed: %s", del_resp.body))
	v_after_del := api_http.get_actions_bridge_version(&graph.action_handlers, bridge1_id)
	check(v_after_del > v_before_del, "bridge version bumped on delete")

	// Deleted action should return 404
	del_get := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/actions/%s", ro_id),
		request_id = "req_del_get",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(del_get.status == 404, fmt.tprintf("expected 404 for deleted action, got %d", del_get.status))

	// ==========================================
	// Test 8: Backward-compatibility routes
	// ==========================================
	sp_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/scheduled-prompts",
		request_id = "req_sp_compat",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(sp_list.status == 200, fmt.tprintf("backward compat list failed: %s", sp_list.body))
	check(strings.contains(sp_list.body, act1_id), "backward compat list contains act1")

	// ==========================================
	// Test 9: Agent-targeted actions (REQ-SCHED-1)
	// ==========================================
	// 9a. Target validation
	// Neither target specified
	resp_no_target := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = "{\"prompt_text\":\"no target\"}",
		request_id = "req_no_target",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_no_target.status == 400, fmt.tprintf("expected 400 for no target, got %d: %s", resp_no_target.status, resp_no_target.body))

	// Both instance and agent target specified
	both_targets_body := strings.concatenate({"{\"target_instance_id\":\"inst_ac_1\",\"target_agent_id\":\"agt_ac_1\",\"target_bridge_id\":\"", bridge1_id, "\",\"prompt_text\":\"both targets\"}"})
	defer delete(both_targets_body)
	resp_both_target := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = both_targets_body,
		request_id = "req_both_targets",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_both_target.status == 400, fmt.tprintf("expected 400 for both targets, got %d: %s", resp_both_target.status, resp_both_target.body))

	// Incomplete agent target: agent_id without bridge_id
	resp_no_bridge := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = "{\"target_agent_id\":\"agt_ac_1\",\"prompt_text\":\"no bridge\"}",
		request_id = "req_no_bridge",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_no_bridge.status == 400, fmt.tprintf("expected 400 for missing bridge_id, got %d: %s", resp_no_bridge.status, resp_no_bridge.body))

	// Incomplete agent target: bridge_id without agent_id
	no_agent_body := strings.concatenate({"{\"target_bridge_id\":\"", bridge1_id, "\",\"prompt_text\":\"no agent\"}"})
	defer delete(no_agent_body)
	resp_no_agent := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = no_agent_body,
		request_id = "req_no_agent",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_no_agent.status == 400, fmt.tprintf("expected 400 for missing agent_id, got %d: %s", resp_no_agent.status, resp_no_agent.body))

	// 9b. Create valid agent-targeted action
	create_agent_body := strings.concatenate({"{\"target_agent_id\":\"agt_ac_1\",\"target_bridge_id\":\"", bridge1_id, "\",\"target_provider\":\"claude\",\"target_tier\":\"normal\",\"prompt_text\":\"Curator recurring prompt\",\"cron_expr\":\"0 9 * * 1-5\"}"})
	defer delete(create_agent_body)
	create_agent_action_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/actions",
		body = create_agent_body,
		request_id = "req_create_agent_act",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(create_agent_action_resp.status == 201, fmt.tprintf("create agent-targeted action failed: %s", create_agent_action_resp.body))
	agent_act_id := extract_json_string(create_agent_action_resp.body, "id")
	check(agent_act_id != "", "agent action id must not be empty")
	check(strings.contains(create_agent_action_resp.body, "\"target_agent_id\":\"agt_ac_1\""), "target_agent_id in response")
	check(strings.contains(create_agent_action_resp.body, bridge1_id), "target_bridge_id in response")
	check(strings.contains(create_agent_action_resp.body, "\"target_provider\":\"claude\""), "target_provider in response")
	check(strings.contains(create_agent_action_resp.body, "\"target_tier\":\"normal\""), "target_tier in response")

	// 9c. Bridge actions sync includes agent-targeted action
	bridge_sync_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/bridge/actions",
		request_id = "req_bridge_sync_agent_act",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bridge_sync_resp.status == 200, fmt.tprintf("bridge sync failed: %s", bridge_sync_resp.body))
	check(strings.contains(bridge_sync_resp.body, agent_act_id), "bridge actions sync returned agent-targeted action")
	check(strings.contains(bridge_sync_resp.body, "Curator recurring prompt"), "prompt text in bridge sync")

	// 9d. Bridge execute with dynamically resolved instance_id in body
	// Set target_run_at to past so it's eligible
	agent_act_rec, _, _ := graph.repos.actions.get(graph.repos.actions.ctx, domain.Action_ID(agent_act_id))
	agent_act_rec.target_run_at = "2020-01-01T00:00:00Z"
	agent_act_rec.in_flight = false
	agent_act_rec.state = .Active
	_, _, _ = graph.repos.actions.save(graph.repos.actions.ctx, agent_act_rec)

	bridge_exec_agent_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridge/actions/%s/execute", agent_act_id),
		body = "{\"instance_id\":\"inst_ac_1\",\"target_run_at\":\"2029-01-01T00:00:00Z\"}",
		request_id = "req_bridge_exec_agent",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bridge_exec_agent_resp.status == 200, fmt.tprintf("bridge execute agent action failed: %s", bridge_exec_agent_resp.body))
	agent_act_msg_id := extract_json_string(bridge_exec_agent_resp.body, "message_id")
	check(agent_act_msg_id != "", "message_id in bridge execute agent response")

	delivered_agent_msg, got_agent_msg, _ := graph.repos.content.get_message(graph.repos.content.ctx, agent_act_msg_id)
	check(got_agent_msg, "chat message found for executed agent action")
	check(delivered_agent_msg.body == "Curator recurring prompt", "message body mismatch")
	check(delivered_agent_msg.message_type == "action", "message_type mismatch")

	// 9e. Run-Now resolves existing live instance of that agent
	run_agent_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/actions/%s/run", agent_act_id),
		body = "{}",
		request_id = "req_run_agent_act",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(run_agent_resp.status == 200, fmt.tprintf("run-now agent action failed: %s", run_agent_resp.body))
	run_agent_msg_id := extract_json_string(run_agent_resp.body, "message_id")
	check(run_agent_msg_id != "", "message_id in run-now agent response")

	// 10. Security & Bridge Auth Isolation Tests — 10a–10g asserted under ENFORCE mode.
	graph.auth.bridge_auth_mode = .Enforce
	// 10a. Negative Test: Bare hbr_ token REJECTED on user endpoint (GET /api/v1/task-chains)
	bare_bridge_tc_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/task-chains",
		request_id = "req_bare_bridge_tc",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bare_bridge_tc_resp.status != 200, fmt.tprintf("bare bridge token must NOT access task-chains; got status: %d body: %s", bare_bridge_tc_resp.status, bare_bridge_tc_resp.body))

	// 10b. Negative Test: Bare hbr_ token REJECTED on task-chains mutation (POST /api/v1/task-chains)
	bare_bridge_tc_post_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/task-chains",
		body = "{\"title\":\"Rogue Chain\"}",
		request_id = "req_bare_bridge_tc_post",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bare_bridge_tc_post_resp.status != 200 && bare_bridge_tc_post_resp.status != 201, fmt.tprintf("bare bridge token must NOT create task-chains; got status: %d body: %s", bare_bridge_tc_post_resp.status, bare_bridge_tc_post_resp.body))

	// 10c. Positive Test: Bare hbr_ token SUCCEEDS on GET /api/v1/agent-instances (scoped to calling bridge)
	bridge_list_inst_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/agent-instances",
		query = fmt.tprintf("agent_id=%s", agt1.agent_id),
		request_id = "req_bridge_list_inst",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bridge_list_inst_resp.status == 200, fmt.tprintf("bridge token should list agent instances: %s", bridge_list_inst_resp.body))
	check(strings.contains(bridge_list_inst_resp.body, "inst_ac_1"), "bridge list instances contains inst_ac_1")

	// 10d. Scoping Test: Bare hbr_ token querying another bridge_id is REJECTED (403 Forbidden)
	bridge_list_other_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/agent-instances",
		query = "bridge_id=brg_other",
		request_id = "req_bridge_list_other",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bridge_list_other_resp.status == 403, fmt.tprintf("bridge listing other bridge instances must be 403: %d %s", bridge_list_other_resp.status, bridge_list_other_resp.body))

	// 10e. Positive Test: Bare hbr_ token SUCCEEDS on POST /api/v1/agent-instances
	bridge_create_body := strings.concatenate({"{\"agent_id\":\"", agt1.agent_id, "\"}"})
	defer delete(bridge_create_body)
	bridge_create_inst_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances",
		body = bridge_create_body,
		request_id = "req_bridge_create_inst",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bridge_create_inst_resp.status == 201, fmt.tprintf("bridge token create agent instance failed: %s", bridge_create_inst_resp.body))
	created_inst_bridge := extract_json_string(bridge_create_inst_resp.body, "bridge_id")
	check(created_inst_bridge == bridge1_id, fmt.tprintf("created instance bridge_id (%s) must match caller bridge_id (%s)", created_inst_bridge, bridge1_id))

	// 10f. Scoping Test: Bare hbr_ token creating instance on another bridge is REJECTED (403 Forbidden)
	bridge_create_other_body := strings.concatenate({"{\"agent_id\":\"", agt1.agent_id, "\",\"bridge_id\":\"brg_other\"}"})
	defer delete(bridge_create_other_body)
	bridge_create_other_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances",
		body = bridge_create_other_body,
		request_id = "req_bridge_create_other",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(bridge_create_other_resp.status == 403, fmt.tprintf("bridge creating instance on other bridge must be 403: %d %s", bridge_create_other_resp.status, bridge_create_other_resp.body))

	// 10g. Defense-in-depth: Bridge execute on action owned by another user is REJECTED (403 Forbidden)
	bob := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "bob"},
		{name = "X-authentik-name", value = "Bob"},
	}
	enr2 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridge-enrollments",
		body = "{\"label\":\"Bridge 2 Bob\"}",
		request_id = "req_enr2",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	check(enr2.status == 201, fmt.tprintf("enroll 2 failed: %s", enr2.body))
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
	check(b2_resp.status == 201, fmt.tprintf("bridge 2 exchange token failed: %s", b2_resp.body))
	bridge2_token := extract_json_string(b2_resp.body, "bridge_token")
	bridge2_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge2_token})}}

	cross_exec_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridge/actions/%s/execute", agent_act_id),
		body = "{\"instance_id\":\"inst_ac_1\",\"target_run_at\":\"2029-01-01T00:00:00Z\"}",
		request_id = "req_cross_exec",
		remote_addr = "127.0.0.1",
		headers = bridge2_headers[:],
	})
	check(cross_exec_resp.status == 403, fmt.tprintf("cross-owner bridge execute must be 403: %d %s", cross_exec_resp.status, cross_exec_resp.body))

	// 10h–10j. MONITOR mode: the same boundary cases now ALLOW (audit-not-enforce).
	graph.auth.bridge_auth_mode = .Monitor
	auth_service.bridge_auth_monitor_hook = capture_bridge_auth_monitor
	defer auth_service.bridge_auth_monitor_hook = nil

	// 10h. Bare hbr_ token on /api/v1/task-chains is ALLOWED under monitor, and the
	// checkpoint-1 audit line must identify the endpoint (method + path).
	cp1_captured_path = ""
	cp1_captured_method = ""
	mon_tc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/task-chains",
		request_id = "req_mon_bare_tc",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(mon_tc.status == 200, fmt.tprintf("monitor: bare bridge token should be allowed on task-chains; got %d %s", mon_tc.status, mon_tc.body))
	check(cp1_captured_path == "/api/v1/task-chains", fmt.tprintf("monitor cp1 audit must carry the endpoint path; got '%s'", cp1_captured_path))
	check(cp1_captured_method == "GET", fmt.tprintf("monitor cp1 audit must carry the method; got '%s'", cp1_captured_method))

	// 10i. Cross-bridge list is ALLOWED under monitor (not 403).
	mon_list_other := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/agent-instances",
		query = "bridge_id=brg_other",
		request_id = "req_mon_list_other",
		remote_addr = "127.0.0.1",
		headers = bridge1_headers[:],
	})
	check(mon_list_other.status != 403, fmt.tprintf("monitor: cross-bridge list must NOT be 403; got %d %s", mon_list_other.status, mon_list_other.body))

	// 10j. Cross-owner bridge execute bypasses the owner gate under monitor
	// (no "does not belong to bridge owner" rejection; an unrelated same-bridge
	// check may still apply downstream, which is fine).
	mon_cross_exec := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridge/actions/%s/execute", agent_act_id),
		body = "{\"instance_id\":\"inst_ac_1\",\"target_run_at\":\"2029-01-01T00:00:00Z\"}",
		request_id = "req_mon_cross_exec",
		remote_addr = "127.0.0.1",
		headers = bridge2_headers[:],
	})
	check(!strings.contains(mon_cross_exec.body, "does not belong to bridge owner"), fmt.tprintf("monitor: cross-owner execute must bypass the owner gate; got %d %s", mon_cross_exec.status, mon_cross_exec.body))

	fmt.println("ALL ACTIONS API TESTS PASSED")
}
