package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

owner_authority_register :: proc(t: ^testing.T, f: ^wire_fixture, chain, bridge: string) {
	r := domain.Owner_Registry_Record{account_id = string(f.owner), chain_id = chain, owner_bridge_id = bridge, owner_key_id = "owner_key",
		creator_id = "dev_owner", genesis_digest = "digest", genesis_json = "genesis", registry_json = "{}", metadata_revision = 1}
	testing.expect_value(t, f.tc_repo.owner_registry_publish(f.tc_repo.ctx, r).code, domain.Error_Code.None)
}

owner_authority_details :: proc(body: string) -> (code, bridge, chain: string) {
	value, _ := json.parse_string(body, .JSON, true, context.temp_allocator)
	o, _ := value.(json.Object)
	e, _ := o["error"].(json.Object)
	d, _ := e["details"].(json.Object)
	c, _ := e["code"].(json.String)
	b, _ := d["bridge_id"].(json.String)
	ch, _ := d["chain_id"].(json.String)
	return string(c), string(b), string(ch)
}

owner_authority_guard_hits: int
owner_authority_test_handler :: proc(ctx: rawptr, req: Request) -> Response {
	owner_authority_guard_hits += 1
	return respond_success("{}", req.request_id, "")
}

@(test)
test_owner_authority_typed_error_before_handlers_and_marked_list_and_detail :: proc(t: ^testing.T) {
	f := wire_setup(t, "owner_authority")
	defer wire_teardown(f)
	chain := string(f.chain_id)
	// A task created while the chain is still Hub-held.
	created := create_task_handler(&f.th, wire_cookie_request(f, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", chain), `{"title":"before migration"}`))
	testing.expect_value(t, created.status, 201)
	task_value, _ := json.parse_string(created.body, .JSON, true, context.temp_allocator)
	task_id := string(task_value.(json.Object)["data"].(json.Object)["task_id"].(json.String))

	write := wire_cookie_request(f, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", chain), `{"title":"after"}`)
	_, blocked := owner_authority_guard(&f.th, write)
	testing.expect(t, !blocked, "a Hub-held chain is not intercepted")

	owner_authority_register(t, f, chain, "brg_owner")
	owner_authority_register(t, f, "chain_native_owner", "brg_owner")

	resp, held := owner_authority_guard(&f.th, write)
	testing.expect(t, held, "writes to a migrated chain are refused before the handler")
	testing.expect_value(t, resp.status, 409)
	code, bridge, named := owner_authority_details(resp.body)
	testing.expect(t, code == "owner_authority" && bridge == "brg_owner" && named == chain, "typed owner_authority error names the owner Bridge")
	for method in ([3]string{"PATCH", "PUT", "DELETE"}) {
		req := wire_cookie_request(f, method, fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", chain, task_id), "{}")
		_, refused := owner_authority_guard(&f.th, req)
		testing.expectf(t, refused, "%s on an owner chain is refused", method)
	}
	_, read_blocked := owner_authority_guard(&f.th, wire_cookie_request(f, "GET", fmt.tprintf("/api/v1/task-chains/%s", chain), ""))
	testing.expect(t, !read_blocked, "reads are not intercepted")
	unauth := write
	unauth.headers = nil
	_, anonymous := owner_authority_guard(&f.th, unauth)
	testing.expect(t, !anonymous, "unauthenticated requests are left to the handler's own auth")
	other := wire_cookie_request(f, "POST", "/api/v1/task-chains/chain_unregistered/tasks", `{"title":"x"}`)
	_, unrelated := owner_authority_guard(&f.th, other)
	testing.expect(t, !unrelated, "a chain without an owner route is untouched")

	// Agent envelopes resolve the chain from chain_id or from the task.
	by_chain := wire_agent_request(f, "comment", strings.concatenate({`{"method":"agent.task.comment","params":{"chain_id":"`, chain, `","body":"x"}}`}, context.temp_allocator))
	agent_resp, agent_blocked := owner_authority_guard(&f.th, by_chain)
	testing.expect(t, agent_blocked && agent_resp.status == 409, "agent envelope naming the chain is refused")
	by_task := wire_agent_request(f, "comment", strings.concatenate({`{"method":"agent.task.comment","params":{"task_id":"`, task_id, `","body":"x"}}`}, context.temp_allocator))
	_, task_blocked := owner_authority_guard(&f.th, by_task)
	testing.expect(t, task_blocked, "agent envelope naming a task of the chain is refused")

	// Through the router the handler never runs (so no frozen-source trigger).
	router := new_router()
	defer router_free(&router)
	router.guard = owner_authority_guard
	router.guard_ctx = &f.th
	router_add(&router, "POST", "/api/v1/task-chains/*/tasks", nil, owner_authority_test_handler)
	router_add(&router, "POST", "/api/v1/agent-actions/tasks/comment", nil, owner_authority_test_handler)
	owner_authority_guard_hits = 0
	routed := router_dispatch(&router, write)
	testing.expect_value(t, routed.status, 409)
	testing.expect_value(t, owner_authority_guard_hits, 0)
	_ = router_dispatch(&router, other)
	testing.expect_value(t, owner_authority_guard_hits, 1)

	// Detail and list mark the owner chain; a native owner chain names its Bridge.
	detail := task_chain_detail_handler(&f.th, wire_cookie_request(f, "GET", fmt.tprintf("/api/v1/task-chains/%s", chain), ""))
	testing.expect_value(t, detail.status, 200)
	detail_value, _ := json.parse_string(detail.body, .JSON, true, context.temp_allocator)
	authority := detail_value.(json.Object)["data"].(json.Object)["authority"].(json.Object)
	testing.expect(t, string(authority["kind"].(json.String)) == "owner" && string(authority["bridge_id"].(json.String)) == "brg_owner")
	native := task_chain_detail_handler(&f.th, wire_cookie_request(f, "GET", "/api/v1/task-chains/chain_native_owner", ""))
	native_code, native_bridge, _ := owner_authority_details(native.body)
	testing.expect(t, native.status == 409 && native_code == "owner_authority" && native_bridge == "brg_owner")

	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{chain_id = "chain_hub_only", owner_user_id = f.owner, title = "hub", status = .Active,
		kind = domain.CHAIN_KIND_MIXED_WORK, publish_state = .Draft, created_at = "2026-01-01", updated_at = "2026-10-01"})
	list_req := wire_cookie_request(f, "GET", "/api/v1/task-chains", "")
	list_req.query = "flat=1"
	listed := list_task_chains_handler(&f.th, list_req)
	testing.expect_value(t, listed.status, 200)
	list_value, _ := json.parse_string(listed.body, .JSON, true, context.temp_allocator)
	marked, plain := false, false
	for item in list_value.(json.Object)["data"].(json.Array) {
		o := item.(json.Object)
		id := string(o["chain_id"].(json.String))
		a, has := o["authority"].(json.Object)
		if id == chain do marked = has && string(a["bridge_id"].(json.String)) == "brg_owner"
		if id == "chain_hub_only" do plain = !has
	}
	testing.expect(t, marked, "list marks the migrated chain with its owner authority")
	testing.expect(t, plain, "Hub-held chains carry no authority marker")
}
