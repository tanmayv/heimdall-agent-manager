package hub_cards_api_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
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
	db_path := "/tmp/cards_api_test.db"
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

	// 1. Validation failure: empty title
	resp_bad_title := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/cards",
		body = "{\"title\":\"   \"}",
		request_id = "req_1",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_bad_title.status == 400, "empty title must return 400")

	// 2. Validation failure: invalid operations JSON
	resp_bad_ops := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/cards",
		body = "{\"title\":\"Card 1\",\"operations\":\"not an array\"}",
		request_id = "req_2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_bad_ops.status == 400, "non-array operations must return 400")

	// 3. Validation failure: invalid guard JSON
	resp_bad_guard := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/cards",
		body = "{\"title\":\"Card 1\",\"guard\":\"[1, 2]\"}",
		request_id = "req_3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_bad_guard.status == 400, "non-object guard must return 400")

	// 4. Create valid card
	create_body := "{\"title\":\"Review auth module\",\"rationale\":\"Auth token expiry logic needs audit\",\"scope\":\"project\",\"provider\":\"curator\",\"confidence\":0.85,\"operations\":[{\"type\":\"task.create\",\"params\":{\"title\":\"Audit auth token\"}}],\"guard\":{\"chain_idle\":true}}"
	resp_create := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/cards",
		body = create_body,
		request_id = "req_create",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_create.status == 201, fmt.tprintf("create card failed: %d %s", resp_create.status, resp_create.body))
	card_id := extract_json_string(resp_create.body, "card_id")
	check(strings.has_prefix(card_id, "crd_"), "card_id must start with crd_")
	status := extract_json_string(resp_create.body, "status")
	check(status == "pending", "initial status must be pending")
	check(strings.contains(resp_create.body, "\"confidence\":0.8500"), "confidence should be formatted")

	// 5. GET card by id
	resp_get := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/cards/%s", card_id),
		request_id = "req_get",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_get.status == 200, "get card must return 200")
	check(extract_json_string(resp_get.body, "card_id") == card_id, "card_id in GET must match")
	check(extract_json_string(resp_get.body, "title") == "Review auth module", "title in GET must match")

	// 6. List cards
	resp_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		query = "status=pending&limit=10",
		request_id = "req_list",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_list.status == 200, "list cards must return 200")
	check(strings.contains(resp_list.body, card_id), "list must contain created card")

	// 7. PATCH card
	patch_body := "{\"rationale\":\"Updated rationale\",\"confidence\":0.95}"
	resp_patch := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/cards/%s", card_id),
		body = patch_body,
		request_id = "req_patch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_patch.status == 200, "patch card must return 200")
	check(extract_json_string(resp_patch.body, "rationale") == "Updated rationale", "rationale must be updated")
	check(strings.contains(resp_patch.body, "\"confidence\":0.9500"), "confidence must be updated")

	// 8. Card actions: snooze
	resp_snooze := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/snooze", card_id),
		body = "{\"snooze_until\":\"2026-09-20T00:00:00Z\"}",
		request_id = "req_snooze",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_snooze.status == 200, "snooze card must return 200")
	check(extract_json_string(resp_snooze.body, "status") == "snoozed", "status must be snoozed")
	check(extract_json_string(resp_snooze.body, "snooze_until") == "2026-09-20T00:00:00Z", "snooze_until must match")

	// 9. Card actions: reject
	resp_reject := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/reject", card_id),
		body = "{}",
		request_id = "req_reject",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_reject.status == 200, "reject card must return 200")
	check(extract_json_string(resp_reject.body, "status") == "rejected", "status must be rejected")

	// 10. Card actions: discard
	resp_discard := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/discard", card_id),
		body = "{}",
		request_id = "req_discard",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_discard.status == 200, "discard card must return 200")
	check(extract_json_string(resp_discard.body, "status") == "discarded", "status must be discarded")

	// 11. Card actions: accept -> 501 NOT IMPLEMENTED in T2
	resp_accept := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", card_id),
		body = "{}",
		request_id = "req_accept",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_accept.status == 501, fmt.tprintf("accept card must return 501 in T2, got %d", resp_accept.status))
	check(strings.contains(resp_accept.body, "not_implemented"), "error code must be not_implemented")
	check(strings.contains(resp_accept.body, "card executor is not yet available"), "message must mention executor unavailable")

	// 12. Delete card
	resp_del := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "DELETE",
		path = fmt.tprintf("/api/v1/cards/%s", card_id),
		request_id = "req_del",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_del.status == 200, "delete card must return 200")

	// 13. GET deleted card -> 404
	resp_get_deleted := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/cards/%s", card_id),
		request_id = "req_get_del",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_get_deleted.status == 404, "get deleted card must return 404")

	// 14. Agent Action RPCs
	// Enroll bridge
	enr := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridge-enrollments",
		body = "{\"label\":\"Test Bridge\"}",
		request_id = "req_enr",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(enr.status == 201, "enroll bridge failed")
	enr_token := extract_json_string(enr.body, "enrollment_token")

	b_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridges/enroll",
		body = "{\"machine\":{\"hostname\":\"host1\"}}",
		request_id = "req_benr",
		remote_addr = "127.0.0.1",
		headers = []contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", enr_token})}},
	})
	check(b_resp.status == 201, "bridge exchange token failed")
	brg_token := extract_json_string(b_resp.body, "bridge_token")
	brg_id := extract_json_string(b_resp.body, "bridge_id")

	// Seed agent and instance
	agt := domain.Agent{
		agent_id = "agt_curator",
		owner_user_id = domain.User_ID("alice"),
		name = "Curator Agent",
		slug = "curator",
		default_provider = "claude",
		default_tier = "smart",
		state = .Active,
		created_at = "2026-01-01T00:00:00Z",
		updated_at = "2026-01-01T00:00:00Z",
	}
	_, _, _ = iface.agent_save(&graph.repos.agents, agt)

	inst := domain.Agent_Instance{
		agent_instance_id = "inst_curator_1",
		owner_user_id = domain.User_ID("alice"),
		agent_id = "agt_curator",
		bridge_id = brg_id,
		provider = "claude",
		tier = "smart",
		project_id = "proj_test",
		runtime_status = "live",
		startup_status = "running",
		activity_status = "idle",
		created_at = "2026-01-01T00:00:00Z",
		updated_at = "2026-01-01T00:00:00Z",
		started_at = "2026-01-01T00:00:00Z",
		last_seen_at = "2026-01-01T00:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&graph.repos.agents, inst)

	agent_headers := [?]contracts.HTTP_Header{
		{name = "Authorization", value = strings.concatenate({"Bearer ", brg_token})},
		{name = "X-Heimdall-Instance-Token", value = "hit_inst_curator_1"},
	}

	// 14a. agent.cards.create
	agent_create_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-actions/cards/create",
		body = "{\"agent_instance_id\":\"inst_curator_1\",\"params\":{\"title\":\"Agent created card\",\"operations\":[{\"type\":\"task.create\",\"params\":{\"title\":\"Subtask\"}}]}}",
		request_id = "req_agt_create",
		remote_addr = "127.0.0.1",
		headers = agent_headers[:],
	})
	check(agent_create_resp.status == 201, fmt.tprintf("agent_action card create failed: %d %s", agent_create_resp.status, agent_create_resp.body))
	agt_card_id := extract_json_string(agent_create_resp.body, "card_id")
	check(strings.has_prefix(agt_card_id, "crd_"), "agent card_id must start with crd_")
	check(extract_json_string(agent_create_resp.body, "project_id") == "proj_test", "agent card should infer instance project_id")

	card_param_body := strings.concatenate({"{\"agent_instance_id\":\"inst_curator_1\",\"params\":{\"card_id\":\"", agt_card_id, "\"}}"})
	defer delete(card_param_body)

	// 14b. agent.cards.show
	agent_show_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-actions/cards/show",
		body = card_param_body,
		request_id = "req_agt_show",
		remote_addr = "127.0.0.1",
		headers = agent_headers[:],
	})
	check(agent_show_resp.status == 200, fmt.tprintf("agent show card must return 200, got %d %s", agent_show_resp.status, agent_show_resp.body))
	check(extract_json_string(agent_show_resp.body, "title") == "Agent created card", "title must match")

	// 14c. agent.cards.list
	agent_list_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-actions/cards/list",
		body = "{\"agent_instance_id\":\"inst_curator_1\",\"params\":{\"status\":\"pending\"}}",
		request_id = "req_agt_list",
		remote_addr = "127.0.0.1",
		headers = agent_headers[:],
	})
	check(agent_list_resp.status == 200, "agent list cards must return 200")
	check(strings.contains(agent_list_resp.body, agt_card_id), "agent list cards must contain created card")

	// 14d. agent.cards.discard
	agent_discard_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-actions/cards/discard",
		body = card_param_body,
		request_id = "req_agt_discard",
		remote_addr = "127.0.0.1",
		headers = agent_headers[:],
	})
	check(agent_discard_resp.status == 200, "agent discard card must return 200")
	check(extract_json_string(agent_discard_resp.body, "status") == "discarded", "card status must be discarded")

	// 14e. agent.cards.accept -> 501 Not_Implemented
	agent_accept_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-actions/cards/accept",
		body = card_param_body,
		request_id = "req_agt_accept",
		remote_addr = "127.0.0.1",
		headers = agent_headers[:],
	})
	check(agent_accept_resp.status == 501, fmt.tprintf("agent accept card must return 501, got %d", agent_accept_resp.status))

	fmt.println("PASS: hub cards API test (REST + agent-actions)")
}
