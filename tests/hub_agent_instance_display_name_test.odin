package hub_agent_instance_display_name_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import app "odin_test:hub/app"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln("FAIL:", message)
	os.exit(1)
}

dummy_send_runtime_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	_ = ctx
	_ = command
	return true, domain.Domain_Error{}
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
	return api_http.router_dispatch(&graph.router, api_http.Request{
		method = method,
		path = path,
		body = body,
		request_id = "req_display_name_test",
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
	if len(rest) == 0 || rest[0] != 34 do return ""
	for i := 1; i < len(rest); i += 1 {
		if rest[i] == 34 do return rest[1:i]
	}
	return ""
}

main :: proc() {
	db_path := "/tmp/heimdall-hub-agent-instance-display-name-test.db"
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
	bridge_id := enroll_bridge(&graph, alice[:], "Alice Bridge")
	check(bridge_id != "", "bridge_id must not be empty")

	b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	if b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge_id, false, "")
	graph.agents.bridge_command_sink.send_runtime_command = dummy_send_runtime_command

	// 1. REQ-1: Verify direct SQLite repository roundtrip for display_name
	auth_ctx := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	repo_inst := domain.Agent_Instance{
		agent_instance_id = "inst_repo_direct",
		owner_user_id = "alice",
		agent_id = "agt_repo",
		bridge_id = bridge_id,
		display_name = "Repo Direct Name",
		provider = "claude",
		tier = "normal",
		runtime_status = "running",
		created_at = "2026-09-03T10:00:00Z",
		updated_at = "2026-09-03T10:00:00Z",
	}
	saved_direct, saved_direct_ok, save_err := iface.agent_save_instance(graph.agents.agents, repo_inst)
	check(saved_direct_ok && save_err.code == .None, "direct save_instance must succeed")
	check(saved_direct.display_name == "Repo Direct Name", "saved instance must retain display_name")

	got_direct, got_direct_ok, get_err := iface.agent_get_instance(graph.agents.agents, "inst_repo_direct")
	check(got_direct_ok && get_err.code == .None, "direct get_instance must succeed")
	check(got_direct.display_name == "Repo Direct Name", "retrieved instance must have saved display_name")

	owner_list, owner_list_err := iface.agent_list_instances_by_owner(graph.agents.agents, "alice", 10, "")
	check(owner_list_err.code == .None && len(owner_list) >= 1, "list_instances_by_owner must find instance")
	found_direct := false
	for inst in owner_list {
		if inst.agent_instance_id == "inst_repo_direct" {
			check(inst.display_name == "Repo Direct Name", "list_instances_by_owner must populate display_name")
			found_direct = true
			break
		}
	}
	check(found_direct, "inst_repo_direct must be in owner instance list")

	bridge_list, bridge_list_err := iface.agent_list_instances_by_bridge(graph.agents.agents, bridge_id)
	check(bridge_list_err.code == .None && len(bridge_list) >= 1, "list_instances_by_bridge must find instance")
	found_bridge := false
	for inst in bridge_list {
		if inst.agent_instance_id == "inst_repo_direct" {
			check(inst.display_name == "Repo Direct Name", "list_instances_by_bridge must populate display_name")
			found_bridge = true
			break
		}
	}
	check(found_bridge, "inst_repo_direct must be in bridge instance list")

	active_list, active_list_err := iface.agent_list_active_runtime_instances(graph.agents.agents)
	check(active_list_err.code == .None && len(active_list) >= 1, "list_active_runtime_instances must find running instance")
	found_active := false
	for inst in active_list {
		if inst.agent_instance_id == "inst_repo_direct" {
			check(inst.display_name == "Repo Direct Name", "list_active_runtime_instances must populate display_name")
			found_active = true
			break
		}
	}
	check(found_active, "inst_repo_direct must be in active runtime instance list")

	// 2. REQ-2: Verify Service default minting with monotonic counter and fallbacks
	agent_res1 := request(&graph, "POST", "/api/v1/agents", "{\"name\":\"Reviewer\",\"slug\":\"reviewer\",\"default_provider\":\"claude\",\"default_tier\":\"normal\"}", alice[:])
	check(agent_res1.status == 201, "create Reviewer agent must succeed")
	reviewer_id := extract_json_string(agent_res1.body, "agent_id")

	agent_res2 := request(&graph, "POST", "/api/v1/agents", "{\"name\":\"Coder\",\"slug\":\"coder\",\"default_provider\":\"claude\",\"default_tier\":\"normal\"}", alice[:])
	check(agent_res2.status == 201, "create Coder agent must succeed")
	coder_id := extract_json_string(agent_res2.body, "agent_id")

	slug_agent := domain.Agent{
		agent_id = "agt_slug_only",
		owner_user_id = "alice",
		name = "",
		slug = "helper-bot",
		default_provider = "claude",
		default_tier = "normal",
		state = .Active,
		created_at = "2026-09-03T10:00:00Z",
		updated_at = "2026-09-03T10:00:00Z",
	}
	_, _, _ = iface.agent_save(graph.agents.agents, slug_agent)

	blank_agent := domain.Agent{
		agent_id = "agt_blank",
		owner_user_id = "alice",
		name = "",
		slug = "",
		default_provider = "claude",
		default_tier = "normal",
		state = .Active,
		created_at = "2026-09-03T10:00:00Z",
		updated_at = "2026-09-03T10:00:00Z",
	}
	_, _, _ = iface.agent_save(graph.agents.agents, blank_agent)

	inst_rev1, ok_rev1, err_rev1 := agent_service.create_instance(&graph.agents, auth_ctx, agent_service.Create_Instance_Input{
		agent_id = reviewer_id,
		bridge_id = bridge_id,
	})
	if !ok_rev1 || err_rev1.code != .None { fmt.eprintln("ERR_REV1:", err_rev1.code, err_rev1.message); check(false, "launch Reviewer #1 must succeed") }
	check(inst_rev1.display_name == "Reviewer #1", fmt.tprintf("expected Reviewer #1, got '%s'", inst_rev1.display_name))

	inst_rev2, ok_rev2, err_rev2 := agent_service.launch_agent(&graph.agents, auth_ctx, agent_service.Create_Instance_Input{
		agent_id = reviewer_id,
		bridge_id = bridge_id,
	})
	check(ok_rev2 && err_rev2.code == .None, "launch Reviewer #2 via launch_agent alias must succeed")
	check(inst_rev2.display_name == "Reviewer #2", fmt.tprintf("expected Reviewer #2, got '%s'", inst_rev2.display_name))

	inst_coder1, ok_coder1, err_coder1 := agent_service.create_instance(&graph.agents, auth_ctx, agent_service.Create_Instance_Input{
		agent_id = coder_id,
		bridge_id = bridge_id,
	})
	check(ok_coder1 && err_coder1.code == .None, "launch Coder #1 must succeed")
	check(inst_coder1.display_name == "Coder #1", fmt.tprintf("expected Coder #1, got '%s'", inst_coder1.display_name))

	inst_slug, ok_slug, err_slug := agent_service.create_instance(&graph.agents, auth_ctx, agent_service.Create_Instance_Input{
		agent_id = "agt_slug_only",
		bridge_id = bridge_id,
	})
	check(ok_slug && err_slug.code == .None, "launch slug agent must succeed")
	check(inst_slug.display_name == "helper-bot #1", fmt.tprintf("expected helper-bot #1, got '%s'", inst_slug.display_name))

	inst_blank, ok_blank, err_blank := agent_service.create_instance(&graph.agents, auth_ctx, agent_service.Create_Instance_Input{
		agent_id = "agt_blank",
		bridge_id = bridge_id,
	})
	check(ok_blank && err_blank.code == .None, "launch blank agent must succeed")
	check(inst_blank.display_name == "Agent #1", fmt.tprintf("expected Agent #1, got '%s'", inst_blank.display_name))

	inst_override, ok_override, err_override := agent_service.create_instance(&graph.agents, auth_ctx, agent_service.Create_Instance_Input{
		agent_id = reviewer_id,
		bridge_id = bridge_id,
		display_name = "Custom Lead Reviewer",
	})
	check(ok_override && err_override.code == .None, "launch with custom display_name must succeed")
	check(inst_override.display_name == "Custom Lead Reviewer", fmt.tprintf("expected Custom Lead Reviewer, got '%s'", inst_override.display_name))

	// 3. REQ-3: Verify HTTP API Serialization (POST, GET, PATCH)
	post_body_default := strings.concatenate({"{\"agent_id\":\"", reviewer_id, "\",\"bridge_id\":\"", bridge_id, "\"}"})
	post_res_default := request(&graph, "POST", "/api/v1/agent-instances", post_body_default, alice[:])
	check(post_res_default.status == 201, "POST /api/v1/agent-instances default must return 201")
	post_dn_default := extract_json_string(post_res_default.body, "display_name")
	check(post_dn_default == "Reviewer #4", fmt.tprintf("expected Reviewer #4 in HTTP POST, got '%s'", post_dn_default))

	post_body_custom := strings.concatenate({"{\"agent_id\":\"", coder_id, "\",\"bridge_id\":\"", bridge_id, "\"}"})
	post_body_custom = strings.concatenate({"{\"agent_id\":\"", coder_id, "\",\"bridge_id\":\"", bridge_id, "\",\"display_name\":\"Custom HTTP Coder\"}"})
	post_res_custom := request(&graph, "POST", "/api/v1/agent-instances", post_body_custom, alice[:])
	check(post_res_custom.status == 201, "POST /api/v1/agent-instances custom must return 201")
	http_inst_id := extract_json_string(post_res_custom.body, "agent_instance_id")
	post_dn_custom := extract_json_string(post_res_custom.body, "display_name")
	check(post_dn_custom == "Custom HTTP Coder", fmt.tprintf("expected Custom HTTP Coder in HTTP POST, got '%s'", post_dn_custom))

	detail_res := request(&graph, "GET", strings.concatenate({"/api/v1/agent-instances/", http_inst_id}), "", alice[:])
	check(detail_res.status == 200, "GET /api/v1/agent-instances/:id must return 200")
	detail_dn := extract_json_string(detail_res.body, "display_name")
	check(detail_dn == "Custom HTTP Coder", fmt.tprintf("expected Custom HTTP Coder in HTTP GET detail, got '%s'", detail_dn))

	list_res := request(&graph, "GET", "/api/v1/agent-instances", "", alice[:])
	check(list_res.status == 200, "GET /api/v1/agent-instances must return 200")
	check(strings.contains(list_res.body, "Custom HTTP Coder"), "list response must contain custom display_name")
	check(strings.contains(list_res.body, "Reviewer #1"), "list response must contain default display_name")

	patch_res := request(&graph, "PATCH", strings.concatenate({"/api/v1/agent-instances/", http_inst_id}), "{\"display_name\":\"Renamed HTTP Coder\"}", alice[:])
	check(patch_res.status == 200, "PATCH /api/v1/agent-instances/:id must return 200")
	patch_dn := extract_json_string(patch_res.body, "display_name")
	check(patch_dn == "Renamed HTTP Coder", fmt.tprintf("expected Renamed HTTP Coder in PATCH response, got '%s'", patch_dn))

	detail_after_patch := request(&graph, "GET", strings.concatenate({"/api/v1/agent-instances/", http_inst_id}), "", alice[:])
	check(detail_after_patch.status == 200, "GET /api/v1/agent-instances/:id after patch must return 200")
	detail_after_dn := extract_json_string(detail_after_patch.body, "display_name")
	check(detail_after_dn == "Renamed HTTP Coder", fmt.tprintf("expected Renamed HTTP Coder after PATCH in GET, got '%s'", detail_after_dn))

	fmt.println("PASS: hub agent instance display_name (sqlite repo, monotonic default minting, custom override, http serialization)")
}
