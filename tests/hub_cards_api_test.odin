package hub_cards_api_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import content_service "odin_test:hub/service/content"
import agent_service "odin_test:hub/service/agent"
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

// Create a task in the given chain and drive it to in_validation; returns task_id.
create_in_validation_task :: proc(router: ^api_http.Router, chain_id, body: string, headers: []contracts.HTTP_Header, tag: string) -> string {
	resp := api_http.router_dispatch(router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks", chain_id),
		body = body,
		request_id = fmt.tprintf("req_%s_create", tag),
		remote_addr = "127.0.0.1",
		headers = headers,
	})
	check(resp.status == 201, fmt.tprintf("%s: create task failed: %d %s", tag, resp.status, resp.body))
	tid := extract_json_string(resp.body, "task_id")
	// Status bodies are literals (not tprintf) to mirror the proven section-15 pattern.
	transitions := [?][2]string{
		{"in_progress", "{\"status\":\"in_progress\"}"},
		{"in_validation", "{\"status\":\"in_validation\"}"},
	}
	for tr in transitions {
		sresp := api_http.router_dispatch(router, api_http.Request{
			method = "POST",
			path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", chain_id, tid),
			body = tr[1],
			request_id = fmt.tprintf("req_%s_%s", tag, tr[0]),
			remote_addr = "127.0.0.1",
			headers = headers,
		})
		check(sresp.status == 200, fmt.tprintf("%s: move task to %s failed: %d %s", tag, tr[0], sresp.status, sresp.body))
	}
	return tid
}

// create_card_via_api POSTs a user card with the given operations + guard JSON and
// returns the new card_id (asserts 201). operations_json/guard_json are raw JSON.
create_card_via_api :: proc(router: ^api_http.Router, title, operations_json, guard_json: string, headers: []contracts.HTTP_Header, tag: string) -> string {
	body := strings.concatenate({"{\"title\":\"", title, "\",\"operations\":", operations_json, ",\"guard\":", guard_json, "}"})
	resp := api_http.router_dispatch(router, api_http.Request{
		method = "POST", path = "/api/v1/cards", body = body,
		request_id = fmt.tprintf("req_%s_create", tag), remote_addr = "127.0.0.1", headers = headers,
	})
	check(resp.status == 201, fmt.tprintf("%s: create card failed: %d %s", tag, resp.status, resp.body))
	return extract_json_string(resp.body, "card_id")
}

// accept_card_via_api accepts a card by id and returns the raw response.
accept_card_via_api :: proc(router: ^api_http.Router, card_id: string, headers: []contracts.HTTP_Header, tag: string) -> api_http.Response {
	return api_http.router_dispatch(router, api_http.Request{
		method = "POST", path = strings.concatenate({"/api/v1/cards/", card_id, "/accept"}), body = "{}",
		request_id = fmt.tprintf("req_%s_accept", tag), remote_addr = "127.0.0.1", headers = headers,
	})
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
	create_body := "{\"title\":\"Review auth module\",\"rationale\":\"Auth token expiry logic needs audit\",\"scope\":\"project\",\"provider\":\"curator\",\"confidence\":0.85,\"operations\":[{\"op\":\"memory.create\",\"label\":\"Audit auth token\",\"args\":{\"title\":\"Audit auth token\",\"body\":\"Auth token expiry logic needs audit\"}}],\"guard\":{\"chain_idle\":true}}"
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

	// 11. Card actions: accept discarded card -> 409 Conflict
	resp_accept := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", card_id),
		body = "{}",
		request_id = "req_accept",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_accept.status == 409, fmt.tprintf("accept discarded card must return 409, got %d", resp_accept.status))
	check(strings.contains(resp_accept.body, "conflict"), "error code must be conflict")

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
		body = "{\"agent_instance_id\":\"inst_curator_1\",\"params\":{\"title\":\"Agent created card\",\"operations\":[{\"op\":\"memory.create\",\"label\":\"Create subtask memory\",\"args\":{\"title\":\"Subtask\",\"body\":\"Agent created card\"}}]}}",
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

	// 14e. agent.cards.accept discarded card -> 409 Conflict
	agent_accept_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-actions/cards/accept",
		body = card_param_body,
		request_id = "req_agt_accept",
		remote_addr = "127.0.0.1",
		headers = agent_headers[:],
	})
	check(agent_accept_resp.status == 409, fmt.tprintf("agent accept card must return 409, got %d", agent_accept_resp.status))

	// =========================================================================
	// 15. Deterministic task-validation card projection and out-of-band approval drop
	// =========================================================================
	resp_chain := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/task-chains",
		body = "{\"title\":\"Chain For Task Validation\"}",
		request_id = "req_ch_1",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_chain.status == 201, fmt.tprintf("create chain failed: %d %s", resp_chain.status, resp_chain.body))
	val_chain_id := extract_json_string(resp_chain.body, "chain_id")

	resp_pub_chain := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/publish", val_chain_id),
		body = "{}",
		request_id = "req_ch_pub",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_pub_chain.status == 200, "publish chain failed")

	resp_val_task := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks", val_chain_id),
		body = "{\"title\":\"Review code changes\"}",
		request_id = "req_tk_1",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_val_task.status == 201, fmt.tprintf("create task failed: %d %s", resp_val_task.status, resp_val_task.body))
	val_task_id := extract_json_string(resp_val_task.body, "task_id")

	resp_tk_prog := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", val_chain_id, val_task_id),
		body = "{\"status\":\"in_progress\"}",
		request_id = "req_tk_prog",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tk_prog.status == 200, "move task to in_progress failed")

	resp_tk_val := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", val_chain_id, val_task_id),
		body = "{\"status\":\"in_validation\"}",
		request_id = "req_tk_val",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tk_val.status == 200, "move task to in_validation failed")

	expected_task_card_id := fmt.tprintf("crd_task_%s", val_task_id)
	resp_task_cards := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		query = "status=pending",
		request_id = "req_list_task_cards",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_task_cards.status == 200, "list cards failed")
	check(strings.contains(resp_task_cards.body, expected_task_card_id), "cards list must contain projected task card")
	check(strings.contains(resp_task_cards.body, "\"provider\":\"task_validation\""), "task card must have provider task_validation")
	check(strings.contains(resp_task_cards.body, "\"label\":\"Cast LGTM on task: Review code changes\""), "task card must contain op label")

	// Out-of-band: Alice moves task to validated_good directly
	resp_tk_vg := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", val_chain_id, val_task_id),
		body = "{\"status\":\"validated_good\"}",
		request_id = "req_tk_vg",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tk_vg.status == 200, "move task to validated_good failed")

	// Next list cards must drop the card (marked discarded and filtered out)
	resp_task_cards_after := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		query = "status=pending",
		request_id = "req_list_task_cards_after",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(!strings.contains(resp_task_cards_after.body, expected_task_card_id), "stale task card must disappear from pending list")

	// Accepting the stale card must return 409 Conflict
	resp_accept_stale_task := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", expected_task_card_id),
		body = "{}",
		request_id = "req_accept_stale_task",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_accept_stale_task.status == 409, fmt.tprintf("accepting stale task card must return 409, got %d", resp_accept_stale_task.status))

	// =========================================================================
	// 15b. REQ-PROV-2: only project in_validation tasks that AWAIT THE USER.
	// A task with an agent reviewer must NOT produce a card; a task with a user
	// reviewer (or no reviewer) must. A projected card is withdrawn once an agent
	// reviewer is later assigned (guard consistency).
	// =========================================================================

	// Case 1: agent_instance reviewer (via agent_id ref, resolved to inst_curator_1)
	//         => NO card projected.
	agentrev_task_id := create_in_validation_task(
		&graph.router, val_chain_id,
		"{\"title\":\"Agent-reviewed task\",\"reviewer_refs\":[{\"type\":\"agent_id\",\"agent_id\":\"agt_curator\"}]}",
		alice[:], "agentrev")

	agentrev_card_id := fmt.tprintf("crd_task_%s", agentrev_task_id)
	resp_cards_agentrev := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = "/api/v1/cards", query = "status=pending",
		request_id = "req_list_agentrev", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(resp_cards_agentrev.status == 200, "list cards (agent reviewer) failed")
	check(!strings.contains(resp_cards_agentrev.body, agentrev_card_id), "task with an agent reviewer must NOT be projected as a card")

	// Case 2: user reviewer (user_id == chain owner) => card IS projected.
	userrev_task_id := create_in_validation_task(
		&graph.router, val_chain_id,
		"{\"title\":\"User-reviewed task\",\"reviewer_refs\":[{\"type\":\"user\",\"user_id\":\"alice\"}]}",
		alice[:], "userrev")

	userrev_card_id := fmt.tprintf("crd_task_%s", userrev_task_id)
	resp_cards_userrev := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = "/api/v1/cards", query = "status=pending",
		request_id = "req_list_userrev", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(resp_cards_userrev.status == 200, "list cards (user reviewer) failed")
	check(strings.contains(resp_cards_userrev.body, userrev_card_id), "task with a user reviewer must be projected as a card")

	// Case 3 (guard): a projected no-reviewer card is withdrawn once an agent
	// reviewer is assigned, and accepting it then fails cleanly (stale guard).
	norev_task_id := create_in_validation_task(
		&graph.router, val_chain_id,
		"{\"title\":\"Initially unreviewed task\"}",
		alice[:], "norev")

	norev_card_id := fmt.tprintf("crd_task_%s", norev_task_id)
	resp_cards_norev := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = "/api/v1/cards", query = "status=pending",
		request_id = "req_list_norev", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(strings.contains(resp_cards_norev.body, norev_card_id), "no-reviewer in_validation task must be projected as a card")

	// Assign an agent reviewer after the card exists.
	resp_patch_norev := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", val_chain_id, norev_task_id),
		body = "{\"reviewer_refs\":[{\"type\":\"agent_id\",\"agent_id\":\"agt_curator\"}]}",
		request_id = "req_tk_norev_patch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_patch_norev.status == 200, fmt.tprintf("assign agent reviewer failed: %d %s", resp_patch_norev.status, resp_patch_norev.body))

	// The now-stale card must drop from the pending list (guard fails).
	resp_cards_norev_after := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = "/api/v1/cards", query = "status=pending",
		request_id = "req_list_norev_after", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(!strings.contains(resp_cards_norev_after.body, norev_card_id), "card must disappear once an agent reviewer is assigned")

	// Accepting the stale card must fail cleanly (409 Conflict).
	resp_accept_norev := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = fmt.tprintf("/api/v1/cards/%s/accept", norev_card_id),
		body = "{}", request_id = "req_accept_norev_stale", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(resp_accept_norev.status == 409, fmt.tprintf("accepting stale (now agent-reviewed) task card must return 409, got %d", resp_accept_norev.status))

	// =========================================================================
	// 15c. REQ-CARDOP-1: agent.update / agent.delete / project.delete executor ops.
	// Proposal semantics: nothing mutates until accept; accept is atomic; delete==soft.
	// =========================================================================

	// --- agent.update: accepting the card edits the durable agent ---
	resp_au_agent := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/agents", body = "{\"name\":\"AU Agent\",\"slug\":\"au-agent\"}",
		request_id = "req_au_agent", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(resp_au_agent.status == 201, fmt.tprintf("create au agent: %d %s", resp_au_agent.status, resp_au_agent.body))
	au_agent_id := extract_json_string(resp_au_agent.body, "agent_id")
	au_ops := strings.concatenate({"[{\"op\":\"agent.update\",\"label\":\"Edit agent\",\"args\":{\"agent_id\":\"", au_agent_id, "\",\"name\":\"AU Renamed\",\"default_tier\":\"smart\"}}]"})
	au_card := create_card_via_api(&graph.router, "Update agent", au_ops, "{}", alice[:], "au")
	au_accept := accept_card_via_api(&graph.router, au_card, alice[:], "au")
	check(au_accept.status == 200, fmt.tprintf("accept agent.update card: %d %s", au_accept.status, au_accept.body))
	au_after := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = strings.concatenate({"/api/v1/agents/", au_agent_id}), request_id = "req_au_after", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(au_after.status == 200 && strings.contains(au_after.body, "\"name\":\"AU Renamed\""), fmt.tprintf("agent.update must rename agent: %s", au_after.body))
	check(strings.contains(au_after.body, "\"default_tier\":\"smart\""), "agent.update must update default_tier")

	// --- agent.delete: accepting soft-archives the durable agent (state=archived) ---
	resp_ad_agent := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/agents", body = "{\"name\":\"AD Agent\",\"slug\":\"ad-agent\"}",
		request_id = "req_ad_agent", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(resp_ad_agent.status == 201, fmt.tprintf("create ad agent: %d %s", resp_ad_agent.status, resp_ad_agent.body))
	ad_agent_id := extract_json_string(resp_ad_agent.body, "agent_id")
	ad_ops := strings.concatenate({"[{\"op\":\"agent.delete\",\"label\":\"Archive agent\",\"args\":{\"agent_id\":\"", ad_agent_id, "\"}}]"})
	ad_guard := strings.concatenate({"{\"agent_id\":\"", ad_agent_id, "\",\"expected_state\":\"active\"}"})
	ad_card := create_card_via_api(&graph.router, "Archive agent", ad_ops, ad_guard, alice[:], "ad")
	ad_accept := accept_card_via_api(&graph.router, ad_card, alice[:], "ad")
	check(ad_accept.status == 200, fmt.tprintf("accept agent.delete card: %d %s", ad_accept.status, ad_accept.body))
	ad_after := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = strings.concatenate({"/api/v1/agents/", ad_agent_id}), request_id = "req_ad_after", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(ad_after.status == 200 && strings.contains(ad_after.body, "\"state\":\"archived\""), fmt.tprintf("agent.delete must archive agent: %s", ad_after.body))

	// --- project.delete: accepting soft-archives the project (state=archived) ---
	resp_pd_proj := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/projects", body = "{\"name\":\"PD Project\",\"slug\":\"pd-project\",\"default_path\":\"/tmp/pd-project\"}",
		request_id = "req_pd_proj", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(resp_pd_proj.status == 201, fmt.tprintf("create pd project: %d %s", resp_pd_proj.status, resp_pd_proj.body))
	pd_project_id := extract_json_string(resp_pd_proj.body, "project_id")
	pd_ops := strings.concatenate({"[{\"op\":\"project.delete\",\"label\":\"Archive project\",\"args\":{\"project_id\":\"", pd_project_id, "\"}}]"})
	pd_guard := strings.concatenate({"{\"project_id\":\"", pd_project_id, "\",\"expected_state\":\"active\"}"})
	pd_card := create_card_via_api(&graph.router, "Archive project", pd_ops, pd_guard, alice[:], "pd")
	pd_accept := accept_card_via_api(&graph.router, pd_card, alice[:], "pd")
	check(pd_accept.status == 200, fmt.tprintf("accept project.delete card: %d %s", pd_accept.status, pd_accept.body))
	pd_after := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = strings.concatenate({"/api/v1/projects/", pd_project_id}), request_id = "req_pd_after", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(pd_after.status == 200 && strings.contains(pd_after.body, "\"state\":\"archived\""), fmt.tprintf("project.delete must archive project: %s", pd_after.body))

	// --- guard staleness: a project.delete card whose target is ALREADY archived is
	//     stale (expected_state active != archived) => dropped from list + accept 409 ---
	stale_ops := pd_ops // same op targeting the now-archived project
	stale_card := create_card_via_api(&graph.router, "Archive project (stale)", stale_ops, pd_guard, alice[:], "pdstale")
	stale_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = "/api/v1/cards", query = "status=pending", request_id = "req_pdstale_list", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(stale_list.status == 200 && !strings.contains(stale_list.body, stale_card), "stale project.delete card (target already archived) must drop from pending list")
	stale_accept := accept_card_via_api(&graph.router, stale_card, alice[:], "pdstale")
	check(stale_accept.status == 409, fmt.tprintf("accepting stale project.delete card must return 409, got %d", stale_accept.status))

	// --- atomicity: a multi-op card whose LATER op fails must roll back the earlier op ---
	resp_atom_agent := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/agents", body = "{\"name\":\"Atom Agent\",\"slug\":\"atom-agent\"}",
		request_id = "req_atom_agent", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(resp_atom_agent.status == 201, fmt.tprintf("create atom agent: %d %s", resp_atom_agent.status, resp_atom_agent.body))
	atom_agent_id := extract_json_string(resp_atom_agent.body, "agent_id")
	// op1 renames the agent (valid); op2 archives a non-existent project (fails) => rollback.
	atom_ops := strings.concatenate({"[{\"op\":\"agent.update\",\"args\":{\"agent_id\":\"", atom_agent_id, "\",\"name\":\"Atom RENAMED\"}},{\"op\":\"project.delete\",\"args\":{\"project_id\":\"proj_missing_atom\"}}]"})
	atom_card := create_card_via_api(&graph.router, "Atomic multi-op", atom_ops, "{}", alice[:], "atom")
	atom_accept := accept_card_via_api(&graph.router, atom_card, alice[:], "atom")
	check(atom_accept.status != 200, fmt.tprintf("multi-op card with a failing op must NOT succeed, got %d", atom_accept.status))
	atom_after := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET", path = strings.concatenate({"/api/v1/agents/", atom_agent_id}), request_id = "req_atom_after", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(atom_after.status == 200 && !strings.contains(atom_after.body, "Atom RENAMED"), fmt.tprintf("earlier op must roll back when a later op fails: %s", atom_after.body))
	check(strings.contains(atom_after.body, "\"name\":\"Atom Agent\""), "rolled-back agent must keep its original name")

	// =========================================================================
	// 15e. REQ-CARD-VALIDATE-1: required-param validation at CREATE time. Missing
	// required args (or unknown op names) are rejected up front (400), not lazily at
	// accept. Multiple ops and extra args stay allowed.
	// =========================================================================

	// 1. memory.create missing body -> rejected at create; error names op + field.
	val_mc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/cards",
		body = "{\"title\":\"Bad memory card\",\"operations\":[{\"op\":\"memory.create\",\"args\":{\"title\":\"Only a title\"}}]}",
		request_id = "req_val_mc", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(val_mc.status == 400, fmt.tprintf("memory.create missing body must be rejected at create, got %d %s", val_mc.status, val_mc.body))
	check(strings.contains(val_mc.body, "memory.create") && strings.contains(val_mc.body, "body"), fmt.tprintf("error must name the op and the missing field: %s", val_mc.body))

	// 2a. agent.update missing agent_id -> rejected.
	val_au_bad := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/cards",
		body = "{\"title\":\"Bad agent update\",\"operations\":[{\"op\":\"agent.update\",\"args\":{\"name\":\"New\"}}]}",
		request_id = "req_val_au_bad", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(val_au_bad.status == 400 && strings.contains(val_au_bad.body, "agent_id"), fmt.tprintf("agent.update missing agent_id must be rejected: %d %s", val_au_bad.status, val_au_bad.body))
	// 2b. agent.update with agent_id + one field -> accepted at create (201).
	val_au_ok := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/cards",
		body = "{\"title\":\"Good agent update\",\"operations\":[{\"op\":\"agent.update\",\"args\":{\"agent_id\":\"agt_example\",\"name\":\"Renamed\"}}]}",
		request_id = "req_val_au_ok", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(val_au_ok.status == 201, fmt.tprintf("agent.update with agent_id + a field must be accepted at create: %d %s", val_au_ok.status, val_au_ok.body))

	// 3a. project.update with project_id but no name/description -> rejected.
	val_pu_bad := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/cards",
		body = "{\"title\":\"Bad project update\",\"operations\":[{\"op\":\"project.update\",\"args\":{\"project_id\":\"proj_example\"}}]}",
		request_id = "req_val_pu_bad", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(val_pu_bad.status == 400 && strings.contains(val_pu_bad.body, "project.update"), fmt.tprintf("project.update with no name/description must be rejected: %d %s", val_pu_bad.status, val_pu_bad.body))
	// 3b. project.update with a field -> accepted.
	val_pu_ok := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/cards",
		body = "{\"title\":\"Good project update\",\"operations\":[{\"op\":\"project.update\",\"args\":{\"project_id\":\"proj_example\",\"name\":\"Renamed\"}}]}",
		request_id = "req_val_pu_ok", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(val_pu_ok.status == 201, fmt.tprintf("project.update with a field must be accepted at create: %d %s", val_pu_ok.status, val_pu_ok.body))

	// 4. unknown op name -> rejected at create.
	val_unknown := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/cards",
		body = "{\"title\":\"Unknown op\",\"operations\":[{\"op\":\"frobnicate.everything\",\"args\":{}}]}",
		request_id = "req_val_unknown", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(val_unknown.status == 400 && strings.contains(val_unknown.body, "unsupported card operation"), fmt.tprintf("unknown op must be rejected at create: %d %s", val_unknown.status, val_unknown.body))

	// 5. A well-formed multi-op card still creates successfully (no regression).
	val_multi := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/cards",
		body = "{\"title\":\"Valid multi-op\",\"operations\":[{\"op\":\"memory.create\",\"args\":{\"title\":\"A\",\"body\":\"B\"}},{\"op\":\"agent.delete\",\"args\":{\"agent_id\":\"agt_example\"}}]}",
		request_id = "req_val_multi", remote_addr = "127.0.0.1", headers = alice[:],
	})
	check(val_multi.status == 201, fmt.tprintf("well-formed multi-op card must still create: %d %s", val_multi.status, val_multi.body))

	// =========================================================================
	// 16. Deterministic memory-proposal card projection and out-of-band approval drop
	// =========================================================================
	resp_mem_create := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/memories",
		body = "{\"title\":\"User prefers tabs\",\"body\":\"Indent with 4 tabs\",\"type\":\"fact\",\"status\":\"pending\"}",
		request_id = "req_mem_cr_1",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_mem_create.status == 201, fmt.tprintf("create pending memory failed: %d %s", resp_mem_create.status, resp_mem_create.body))
	pending_mem_id := extract_json_string(resp_mem_create.body, "memory_id")
	expected_mem_card_id := fmt.tprintf("crd_mem_%s", pending_mem_id)

	resp_mem_cards := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		query = "status=pending",
		request_id = "req_list_mem_cards",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(strings.contains(resp_mem_cards.body, expected_mem_card_id), "cards list must contain projected memory card")
	check(strings.contains(resp_mem_cards.body, "\"provider\":\"memory_proposal\""), "memory card must have provider memory_proposal")
	check(strings.contains(resp_mem_cards.body, "\"label\":\"Approve memory proposal: User prefers tabs\""), "memory card must contain op label")

	// Out-of-band: approve memory directly
	resp_mem_app := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/memories/%s/approve", pending_mem_id),
		body = "{}",
		request_id = "req_mem_app_1",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_mem_app.status == 200, "out-of-band memory approve failed")

	// Next list cards must drop the memory card
	resp_mem_cards_after := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		query = "status=pending",
		request_id = "req_list_mem_cards_after",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(!strings.contains(resp_mem_cards_after.body, expected_mem_card_id), "stale memory card must disappear from pending list")

	// Accepting stale memory card must return 409 Conflict
	resp_accept_stale_mem := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", expected_mem_card_id),
		body = "{}",
		request_id = "req_accept_stale_mem",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_accept_stale_mem.status == 409, fmt.tprintf("accepting stale memory card must return 409, got %d", resp_accept_stale_mem.status))

	// =========================================================================
	// 17. Accepting memory-proposal card activates memory; second accept fails 409
	// =========================================================================
	resp_mem2 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/memories",
		body = "{\"title\":\"User prefers spaces\",\"body\":\"Indent with 2 spaces\",\"type\":\"fact\",\"status\":\"pending\"}",
		request_id = "req_mem_cr_2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_mem2.status == 201, "create memory 2 failed")
	mem2_id := extract_json_string(resp_mem2.body, "memory_id")
	mem2_card_id := fmt.tprintf("crd_mem_%s", mem2_id)

	// Sync via list
	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		request_id = "req_sync_mem2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	// Accept card
	resp_mem2_acc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", mem2_card_id),
		body = "{}",
		request_id = "req_acc_mem2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_mem2_acc.status == 200, fmt.tprintf("accept memory card failed: %d %s", resp_mem2_acc.status, resp_mem2_acc.body))
	check(extract_json_string(resp_mem2_acc.body, "status") == "accepted", "card status must be accepted")

	// Verify memory is active
	resp_get_mem2 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/memories/%s", mem2_id),
		request_id = "req_get_mem2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_get_mem2.status == 200, "get memory 2 failed")
	check(extract_json_string(resp_get_mem2.body, "status") == "active", "memory status must be active after card accept")

	// Accepting again must fail 409
	resp_mem2_acc_dup := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", mem2_card_id),
		body = "{}",
		request_id = "req_acc_mem2_dup",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_mem2_acc_dup.status == 409, "second accept on accepted memory card must return 409")

	// =========================================================================
	// 18. Accepting task-validation card casts LGTM vote on task
	// =========================================================================
	resp_tk2 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks", val_chain_id),
		body = "{\"title\":\"Task for LGTM vote\"}",
		request_id = "req_tk_2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tk2.status == 201, "create task 2 failed")
	tk2_id := extract_json_string(resp_tk2.body, "task_id")
	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", val_chain_id, tk2_id),
		body = "{\"status\":\"in_progress\"}",
		request_id = "req_tk2_prog",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", val_chain_id, tk2_id),
		body = "{\"status\":\"in_validation\"}",
		request_id = "req_tk2_val",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	tk2_card_id := fmt.tprintf("crd_task_%s", tk2_id)
	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		request_id = "req_sync_tk2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	resp_tk2_acc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", tk2_card_id),
		body = "{}",
		request_id = "req_acc_tk2",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tk2_acc.status == 200, fmt.tprintf("accept task card failed: %d %s", resp_tk2_acc.status, resp_tk2_acc.body))
	check(extract_json_string(resp_tk2_acc.body, "status") == "accepted", "task card status must be accepted")

	resp_votes := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/votes", val_chain_id, tk2_id),
		request_id = "req_get_votes",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_votes.status == 200, "get votes failed")
	check(strings.contains(resp_votes.body, "\"vote\":\"lgtm\""), "task votes must contain lgtm")

	// =========================================================================
	// 19. Rejecting provider card executes negative action (ngtm / memory reject)
	// =========================================================================
	// 19a. Task rejection executes ngtm vote
	resp_tk3 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks", val_chain_id),
		body = "{\"title\":\"Task to NGTM reject\"}",
		request_id = "req_tk_3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tk3.status == 201, "create task 3 failed")
	tk3_id := extract_json_string(resp_tk3.body, "task_id")
	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", val_chain_id, tk3_id),
		body = "{\"status\":\"in_progress\"}",
		request_id = "req_tk3_prog",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", val_chain_id, tk3_id),
		body = "{\"status\":\"in_validation\"}",
		request_id = "req_tk3_val",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	tk3_card_id := fmt.tprintf("crd_task_%s", tk3_id)
	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		request_id = "req_sync_tk3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	resp_tk3_rej := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/reject", tk3_card_id),
		body = "{}",
		request_id = "req_rej_tk3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tk3_rej.status == 200, "reject task card failed")
	check(extract_json_string(resp_tk3_rej.body, "status") == "rejected", "task card status must be rejected")

	resp_votes3 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/votes", val_chain_id, tk3_id),
		request_id = "req_get_votes3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(strings.contains(resp_votes3.body, "\"vote\":\"ngtm\""), "task votes must contain ngtm after card rejection")

	// 19b. Memory rejection marks memory rejected
	resp_mem3 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/memories",
		body = "{\"title\":\"Memory to reject\",\"body\":\"Bad fact\",\"type\":\"fact\",\"status\":\"pending\"}",
		request_id = "req_mem_cr_3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_mem3.status == 201, "create memory 3 failed")
	mem3_id := extract_json_string(resp_mem3.body, "memory_id")
	mem3_card_id := fmt.tprintf("crd_mem_%s", mem3_id)

	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		request_id = "req_sync_mem3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	resp_mem3_rej := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/reject", mem3_card_id),
		body = "{}",
		request_id = "req_rej_mem3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_mem3_rej.status == 200, "reject memory card failed")
	check(extract_json_string(resp_mem3_rej.body, "status") == "rejected", "memory card status must be rejected")

	resp_get_mem3 := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/memories/%s", mem3_id),
		request_id = "req_get_mem3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(extract_json_string(resp_get_mem3.body, "status") == "rejected", "memory status must be rejected after card rejection")

	// =========================================================================
	// 20. Atomic multi-op execution: partial failure rolls back completely
	// =========================================================================
	atomic_fail_body := "{\"title\":\"Atomic Multi-Op Test\",\"operations\":[{\"op\":\"memory.create\",\"label\":\"Create temp fact\",\"args\":{\"title\":\"Atomic Fact Rollback Test\",\"body\":\"Should never persist\",\"type\":\"fact\"}},{\"op\":\"task.vote\",\"label\":\"Vote non-existent task\",\"args\":{\"task_id\":\"task_nonexistent_999999\",\"result\":\"lgtm\"}}]}"
	resp_atomic_cr := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/cards",
		body = atomic_fail_body,
		request_id = "req_atomic_cr",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_atomic_cr.status == 201, "create atomic card failed")
	atomic_card_id := extract_json_string(resp_atomic_cr.body, "card_id")

	resp_atomic_acc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", atomic_card_id),
		body = "{}",
		request_id = "req_atomic_acc",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_atomic_acc.status != 200, "accepting failing multi-op card must not return 200")

	// Verify rollback: memory was NOT created
	resp_mems_all := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/memories",
		request_id = "req_get_mems_check",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(!strings.contains(resp_mems_all.body, "Atomic Fact Rollback Test"), "rolled-back memory must not exist in database")

	// Successful multi-op execution
	multi_ok_body := "{\"title\":\"Multi-Op Success Test\",\"operations\":[{\"op\":\"memory.create\",\"label\":\"Create fact 1\",\"args\":{\"title\":\"Multi Fact 1\",\"body\":\"Content 1\",\"type\":\"fact\"}},{\"op\":\"memory.create\",\"label\":\"Create fact 2\",\"args\":{\"title\":\"Multi Fact 2\",\"body\":\"Content 2\",\"type\":\"fact\"}}]}"
	resp_multi_cr := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/cards",
		body = multi_ok_body,
		request_id = "req_multi_cr",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_multi_cr.status == 201, "create multi ok card failed")
	multi_card_id := extract_json_string(resp_multi_cr.body, "card_id")

	resp_multi_acc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", multi_card_id),
		body = "{}",
		request_id = "req_multi_acc",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_multi_acc.status == 200, fmt.tprintf("accept multi-op card failed: %d %s", resp_multi_acc.status, resp_multi_acc.body))

	resp_mems_verify := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/memories",
		request_id = "req_get_mems_verify",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(strings.contains(resp_mems_verify.body, "Multi Fact 1") && strings.contains(resp_mems_verify.body, "Multi Fact 2"), "both multi-op memories must exist")

	// =========================================================================
	// 21. task_chain.set_status operation + agent.task_chain.set_status RPC
	// =========================================================================
	resp_st_chain := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/task-chains",
		body = "{\"title\":\"Chain For Set Status\"}",
		request_id = "req_st_ch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_st_chain.status == 201, "create chain for set status failed")
	st_chain_id := extract_json_string(resp_st_chain.body, "chain_id")

	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/publish", st_chain_id),
		body = "{}",
		request_id = "req_pub_st_ch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	st_card_body := strings.concatenate({"{\"title\":\"Complete Chain Card\",\"operations\":[{\"op\":\"task_chain.set_status\",\"label\":\"Mark chain completed\",\"args\":{\"chain_id\":\"", st_chain_id, "\",\"status\":\"completed\"}}]}"})
	defer delete(st_card_body)
	resp_st_card := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/cards",
		body = st_card_body,
		request_id = "req_st_card_cr",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_st_card.status == 201, fmt.tprintf("create status card failed: %d %s", resp_st_card.status, resp_st_card.body))
	st_card_id := extract_json_string(resp_st_card.body, "card_id")

	resp_st_acc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", st_card_id),
		body = "{}",
		request_id = "req_st_acc",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_st_acc.status == 200, fmt.tprintf("accept status card failed: %d %s", resp_st_acc.status, resp_st_acc.body))

	resp_chk_chain := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/task-chains/%s", st_chain_id),
		request_id = "req_chk_chain",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(strings.contains(resp_chk_chain.body, "\"status\":\"completed\""), "task chain status must be completed after card accept")

	// Agent action RPC: agent.task_chain.set_status
	resp_agt_chain := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/task-chains",
		body = "{\"title\":\"Chain For Agent Set Status\",\"coordinator_agent_instance_id\":\"inst_curator_1\"}",
		request_id = "req_agt_ch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_agt_chain.status == 201, "create chain for agent set status failed")
	agt_chain_id := extract_json_string(resp_agt_chain.body, "chain_id")

	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/members", agt_chain_id),
		body = "{\"agent_instance_id\":\"inst_curator_1\",\"role\":\"coordinator\"}",
		request_id = "req_add_coord",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	_ = api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/task-chains/%s/publish", agt_chain_id),
		body = "{}",
		request_id = "req_pub_agt_ch",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	agt_st_req := strings.concatenate({"{\"agent_instance_id\":\"inst_curator_1\",\"params\":{\"chain_id\":\"", agt_chain_id, "\",\"status\":\"completed\"}}"})
	defer delete(agt_st_req)
	resp_agt_st := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-actions/chain/set-status",
		body = agt_st_req,
		request_id = "req_agt_st",
		remote_addr = "127.0.0.1",
		headers = agent_headers[:],
	})
	check(resp_agt_st.status == 200, fmt.tprintf("agent set-status RPC failed: %d %s", resp_agt_st.status, resp_agt_st.body))

	resp_chk_agt_chain := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/task-chains/%s", agt_chain_id),
		request_id = "req_chk_agt_chain",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(strings.contains(resp_chk_agt_chain.body, "\"status\":\"completed\""), "chain status must be completed after agent RPC")

	// =========================================================================
	// 22. Cross-owner negative isolation
	// =========================================================================
	bob := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "bob"},
		{name = "X-authentik-name", value = "Bob"},
	}

	resp_bob_get := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/cards/%s", multi_card_id),
		request_id = "req_bob_get",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	check(resp_bob_get.status == 404, "bob cannot get alice's card (must be 404)")

	resp_bob_acc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/accept", multi_card_id),
		body = "{}",
		request_id = "req_bob_acc",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	check(resp_bob_acc.status == 404, "bob cannot accept alice's card (must be 404)")

	resp_bob_disc := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/cards/%s/discard", multi_card_id),
		body = "{}",
		request_id = "req_bob_disc",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	check(resp_bob_disc.status == 404, "bob cannot discard alice's card (must be 404)")

	resp_bob_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/cards",
		request_id = "req_bob_list",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	check(resp_bob_list.status == 200, "bob list cards must return 200")
	check(!strings.contains(resp_bob_list.body, multi_card_id), "bob list must not contain alice's card")

	// 23. T4 / REQ-AGENT-1: Verify tmpl_curator seeded via migration 035
	resp_tmpl_list := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "GET",
		path = "/api/v1/templates",
		request_id = "req_tmpl_list",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	check(resp_tmpl_list.status == 200, "GET /api/v1/templates must return 200")
	check(strings.contains(resp_tmpl_list.body, "\"template_id\":\"tmpl_curator\""), "templates list must include tmpl_curator")
	check(strings.contains(resp_tmpl_list.body, "\"is_system\":true") || strings.contains(resp_tmpl_list.body, "\"is_system\": true"), "tmpl_curator must be system template")

	curator_tmpl, c_ok, c_err := content_service.get_template(&graph.content, contracts.Auth_Context{user_id = "alice", kind = .User_Token}, domain.TEMPLATE_CURATOR_ID)
	check(c_ok, "content_service.get_template for tmpl_curator must succeed")
	check(curator_tmpl.template_id == domain.TEMPLATE_CURATOR_ID, "curator template_id must match domain.TEMPLATE_CURATOR_ID")
	check(curator_tmpl.is_system, "curator is_system must be true")
	check(curator_tmpl.name == "curator", "curator name must be curator")
	check(strings.contains(curator_tmpl.instructions, "Role: Curator"), "curator instructions must contain Role: Curator")
	check(strings.contains(curator_tmpl.instructions, "agent.cards.create"), "curator instructions must cite agent.cards.create")
	check(strings.contains(curator_tmpl.instructions, "REQ-UX-1") || strings.contains(curator_tmpl.instructions, "label"), "curator instructions must enforce REQ-UX-1 label")
	check(strings.contains(curator_tmpl.instructions, "Confidence Calculation Matrix"), "curator instructions must include confidence matrix")
	check(content_service.template_available(&graph.content, "alice", domain.TEMPLATE_CURATOR_ID), "tmpl_curator must be template_available for alice")
	check(agent_service.agent_template_available(&graph.agents, "alice", domain.TEMPLATE_CURATOR_ID), "tmpl_curator must be agent_template_available for alice")

	fmt.println("PASS: hub cards API test (REST + agent-actions)")
}
