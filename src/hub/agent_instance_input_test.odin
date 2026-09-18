package main

import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import app "odin_test:hub/app"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

@(test)
test_agent_instance_input_route_registered_and_dispatches :: proc(t: ^testing.T) {
	db_path := "/tmp/heimdall-hub-test-input-unit.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}

	// Enroll bridge
	created := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridge-enrollments",
		body = `{"label":"Alice Bridge"}`,
		request_id = "req_1",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect(t, created.status == 201, "bridge enrollment failed")

	token := ""
	token_idx := strings.index(created.body, "\"enrollment_token\":\"")
	if token_idx >= 0 {
		rest := created.body[token_idx + len("\"enrollment_token\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do token = rest[:end]
	}

	enroll_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	enrolled := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridges/enroll",
		body = `{"machine":{"hostname":"host"},"capabilities":[{"provider":"claude","tiers":["normal","smart"],"default_tier":"normal"}]}`,
		request_id = "req_2",
		remote_addr = "127.0.0.1",
		headers = enroll_headers[:],
	})
	testing.expect(t, enrolled.status == 201, "bridge enroll failed")

	bridge_id := ""
	b_idx := strings.index(enrolled.body, "\"bridge_id\":\"")
	if b_idx >= 0 {
		rest := enrolled.body[b_idx + len("\"bridge_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do bridge_id = rest[:end]
	}

	bridge_token := ""
	bt_idx := strings.index(enrolled.body, "\"bridge_token\":\"")
	if bt_idx >= 0 {
		rest := enrolled.body[bt_idx + len("\"bridge_token\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do bridge_token = rest[:end]
	}

	b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	if b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge_id, false, "")

	call_count := 0
	mock_sink := proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
		p_count := (^int)(ctx)
		p_count^ += 1
		return true, domain.Domain_Error{}
	}
	graph.agents.bridge_command_sink.ctx = rawptr(&call_count)
	graph.agents.bridge_command_sink.send_runtime_command = mock_sink

	// Create agent
	agent_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agents",
		body = `{"name":"Coder","slug":"coder","default_provider":"claude","default_tier":"normal"}`,
		request_id = "req_3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect(t, agent_res.status == 201, "agent create failed")

	agent_id := ""
	aid_idx := strings.index(agent_res.body, "\"agent_id\":\"")
	if aid_idx >= 0 {
		rest := agent_res.body[aid_idx + len("\"agent_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do agent_id = rest[:end]
	}

	// Enable bridge support
	api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id}),
		body = `{"enabled":true,"provider":"claude","tier":"normal"}`,
		request_id = "req_4",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	// Create agent instance
	inst_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances",
		body = strings.concatenate({`{"agent_id":"`, agent_id, `","bridge_id":"`, bridge_id, `"}`}),
		request_id = "req_5",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect(t, inst_res.status == 201, "instance create failed")

	inst_id := ""
	iid_idx := strings.index(inst_res.body, "\"agent_instance_id\":\"")
	if iid_idx >= 0 {
		rest := inst_res.body[iid_idx + len("\"agent_instance_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do inst_id = rest[:end]
	}

	input_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/input"})

	// 1. Unauthenticated -> 401
	unauth := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_6",
		remote_addr = "127.0.0.1",
	})
	testing.expect_value(t, unauth.status, 401)

	// 2. Bridge token -> 403
	bridge_hdr := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	br_call := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_7",
		remote_addr = "127.0.0.1",
		headers = bridge_hdr[:],
	})
	testing.expect_value(t, br_call.status, 403)

	// 3. Cross-user (bob) -> 404
	cross := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_8",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	testing.expect_value(t, cross.status, 404)

	// 4. Non-existent instance -> 404
	nonexist := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances/inst_fake/input",
		body = `{"data":"ls -la\n"}`,
		request_id = "req_9",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, nonexist.status, 404)

	// 5. Valid input request -> 200
	call_count = 0
	valid := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_10",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, valid.status, 200)
	testing.expect(t, strings.contains(valid.body, "\"ok\":true"), "body has ok: true")
	testing.expect_value(t, call_count, 1)
}
