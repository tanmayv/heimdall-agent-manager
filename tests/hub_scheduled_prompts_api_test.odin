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

// device_enroll_bridge provisions a bridge through the REAL device flow (REQ-ENROLL-9),
// replacing the deleted bridge-enrollments + bridges/enroll pair. These tests are not
// about enrollment; they need a bridge and a credential.
//
// IT REPORTS NO CAPABILITIES AND LEAVES THE BRIDGE OFFLINE, deliberately, because
// that is what the deleted setup did here: the old enroll body in this file was
// `{"machine":{"hostname":"..."}}` with no `capabilities` array. Other migrated
// suites DO replicate a connect-time capability report, because their old bodies
// declared providers. Adding one here would also flip the bridge Online and change
// what these tests exercise.
//
// Three requirements that each reject a request outright, hence more than two lines:
//  1. bridge_public_key must be a 130-char lowercase-hex uncompressed P-256 point.
//  2. NO bridge_key_fingerprint is sent — the Hub derives it and refuses a
//     body-supplied one that disagrees, since a requester-chosen fingerprint would
//     defeat the human comparing it on the approval screen.
//  3. PKCE is mandatory for a bridge grant and S256-only (`plain` and a missing
//     method are both refused); the pair below is precomputed so this needs no
//     crypto, and the verifier is replayed at /device/token.
//
// `device_label` becomes the bridge's hostname and therefore its label.
//
// Bodies are heap-concatenated, never fmt.tprintf: tprintf returns per-thread TEMP
// allocator memory and router_dispatch calls tprintf freely downstream, so a temp
// body can be overwritten in place before the handler parses it.
DEV_TEST_PUBLIC_KEY :: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
DEV_TEST_CODE_VERIFIER :: "heimdall-req-impl-6-test-code-verifier-aaaa"
DEV_TEST_CODE_CHALLENGE :: "J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI"

device_enroll_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, label, tag: string) -> (bridge_id: string, bridge_token: string) {
	authorized := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/authorize",
		body = strings.concatenate({
			"{\"client\":\"ham-bridge\",\"device_label\":\"", label,
			"\",\"os\":\"linux\",\"os_user\":\"tester\",\"bridge_public_key\":\"", DEV_TEST_PUBLIC_KEY,
			"\",\"code_challenge\":\"", DEV_TEST_CODE_CHALLENGE, "\",\"code_challenge_method\":\"S256\"}",
		}),
		request_id = strings.concatenate({"req_dev_auth_", tag}), remote_addr = "127.0.0.1",
	})
	check(authorized.status == 200, authorized.body)
	user_code := extract_json_string(authorized.body, "user_code")
	device_code := extract_json_string(authorized.body, "device_code")

	// The human approves; ownership comes from this Auth_Context, never the body.
	approved := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/approve",
		body = strings.concatenate({"{\"user_code\":\"", user_code, "\",\"approve\":true}"}),
		request_id = strings.concatenate({"req_dev_appr_", tag}), remote_addr = "127.0.0.1", headers = headers,
	})
	check(approved.status == 200, approved.body)

	// The bridge collects its credential. The grant is single-use and spent here.
	issued := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/token",
		body = strings.concatenate({"{\"device_code\":\"", device_code, "\",\"code_verifier\":\"", DEV_TEST_CODE_VERIFIER, "\"}"}),
		request_id = strings.concatenate({"req_dev_tok_", tag}), remote_addr = "127.0.0.1",
	})
	check(issued.status == 200, issued.body)
	bridge_id = extract_json_string(issued.body, "bridge_id")
	bridge_token = extract_json_string(issued.body, "access_token")
	return bridge_id, bridge_token
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

	// 1-2. Two bridges, both owned by the same user, provisioned through the device
	// flow (see device_enroll_bridge).
	bridge1_id, bridge1_token := device_enroll_bridge(&graph, alice[:], "Bridge 1", "sp1")
	bridge1_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge1_token})}}

	// 2. Enroll bridge 2
	bridge2_id, bridge2_token := device_enroll_bridge(&graph, alice[:], "Bridge 2", "sp2")
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

	// 3. Verify min-60s interval validation on create
	bad_interval_body := strings.concatenate({"{\"target_instance_id\":\"", instance1_id, "\",\"prompt_text\":\"fast ping\",\"target_run_at\":\"2026-01-01T00:00:00Z\",\"interval\":\"30s\"}"})
	bad_create := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/scheduled-prompts",
		body = bad_interval_body,
		request_id = "req_bad_interval",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(bad_create.status == 400, fmt.tprintf("expected 400 for interval < 60s, got %d: %s", bad_create.status, bad_create.body))

	invalid_interval_body := strings.concatenate({"{\"target_instance_id\":\"", instance1_id, "\",\"prompt_text\":\"bad ping\",\"target_run_at\":\"2026-01-01T00:00:00Z\",\"interval\":\"invalid\"}"})
	invalid_create := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/scheduled-prompts",
		body = invalid_interval_body,
		request_id = "req_invalid_interval",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(invalid_create.status == 400, fmt.tprintf("expected 400 for invalid interval, got %d: %s", invalid_create.status, invalid_create.body))

	min_interval_body := strings.concatenate({"{\"target_instance_id\":\"", instance1_id, "\",\"prompt_text\":\"min ping\",\"target_run_at\":\"2026-01-01T00:00:00Z\",\"interval\":\"60s\"}"})
	min_create := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/scheduled-prompts",
		body = min_interval_body,
		request_id = "req_min_interval",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(min_create.status == 201, fmt.tprintf("expected 201 for interval 60s, got %d: %s", min_create.status, min_create.body))

	// 4. User creates scheduled prompt targeting instance1 with interval="1h"
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

	// Patch interval validation
	bad_patch := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/scheduled-prompts/%s", sp1_id),
		body = "{\"interval\":\"15s\"}",
		request_id = "req_bad_patch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(bad_patch.status == 400, fmt.tprintf("expected 400 for patch interval < 60s, got %d: %s", bad_patch.status, bad_patch.body))

	good_patch := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/scheduled-prompts/%s", sp1_id),
		body = "{\"interval\":\"2h\"}",
		request_id = "req_good_patch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(good_patch.status == 200, fmt.tprintf("expected 200 for patch interval 2h, got %d: %s", good_patch.status, good_patch.body))

	// Verify bridge 1 version is positive and bumped
	v1 := api_http.get_scheduled_prompts_bridge_version(&graph.scheduled_prompt_handlers, bridge1_id)
	check(v1 > 0, fmt.tprintf("bridge 1 version should be > 0, got %d", v1))

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
