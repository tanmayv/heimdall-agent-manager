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

owner_authority_stub_lease :: proc(ctx: rawptr, lease_id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	if lease_id != "lease_owner" do return {}, false, {}
	return domain.Task_Lease{lease_id = lease_id, chain_id = "chain_wire_tb2"}, true, {}
}
owner_authority_stub_holder :: proc(ctx: rawptr, holder: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	return domain.Task_Lease{lease_id = "lease_owner", chain_id = "chain_wire_tb2"}, true, {}
}
owner_authority_stub_run :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, owner: domain.User_ID) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	return domain.Workflow_Run{run_id = run_id, chain_id = "chain_wire_tb2", owner_user_id = owner}, true, {}
}
owner_authority_stub_task_failure :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	return {}, false, domain.domain_error(.Internal_Error, "database is locked")
}
owner_authority_stub_registry_failure :: proc(ctx: rawptr, account, chain: string) -> ([]domain.Owner_Registry_Record, domain.Domain_Error) {
	return nil, domain.domain_error(.Internal_Error, "registry read failed")
}
owner_authority_stub_list_failure :: proc(ctx: rawptr, account, chain, after_chain, after_task: string, limit: int, headers_only: bool) -> ([]domain.Owner_Registry_Record, domain.Domain_Error) {
	return nil, domain.domain_error(.Internal_Error, "registry read failed")
}

@(test)
test_owner_authority_resolves_task_run_and_lease_ids_and_fails_closed :: proc(t: ^testing.T) {
	f := wire_setup(t, "owner_authority_ids")
	defer wire_teardown(f)
	chain := string(f.chain_id)
	created := create_task_handler(&f.th, wire_cookie_request(f, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", chain), `{"title":"held"}`))
	task_value, _ := json.parse_string(created.body, .JSON, true, context.temp_allocator)
	task_id := string(task_value.(json.Object)["data"].(json.Object)["task_id"].(json.String))
	owner_authority_register(t, f, chain, "brg_owner")

	// Pure classification of every covered write shape.
	cases := [?]struct{path, body: string, kind: Owner_Target_Kind, id: string}{
		{"/api/v1/tasks/t1/recheck", "", .Task, "t1"},
		{"/api/v1/tasks/t1/placement-recovery", "", .Task, "t1"},
		{"/api/v1/workflow-runs/run_1/cancel", "", .Run, "run_1"},
		{"/api/v1/workflow-runs/run_1/retry", "", .Run, "run_1"},
		{"/api/v1/agent-actions/lease/heartbeat", `{"params":{"lease_id":"lease_owner"}}`, .Lease, "lease_owner"},
		{"/api/v1/agent-actions/lease/submit", `{"params":{}}`, .Holder, ""},
		{"/api/v1/agent-actions/workflow/cancel", `{"params":{"run_id":"run_1"}}`, .Run, "run_1"},
		{"/api/v1/tasks/t1/events", "", .None, ""},
	}
	for c in cases {
		kind, id := owner_authority_request(Request{method = "POST", path = c.path, body = c.body})
		testing.expectf(t, kind == c.kind && id == c.id, "%s -> %v %q", c.path, kind, id)
	}

	recheck := wire_cookie_request(f, "POST", fmt.tprintf("/api/v1/tasks/%s/recheck", task_id), "{}")
	resp, blocked := owner_authority_guard(&f.th, recheck)
	testing.expect(t, blocked && resp.status == 409, "task-id routes resolve the owner chain")

	// Stubbed repository: run and lease ids resolve to the owner chain.
	repo := f.tc_repo
	repo.get_lease = owner_authority_stub_lease
	repo.get_lease_by_holder = owner_authority_stub_holder
	repo.get_workflow_run = owner_authority_stub_run
	svc := f.tc_svc
	svc.repo = &repo
	h := f.th
	h.taskchains = &svc
	for path in ([2]string{"/api/v1/workflow-runs/run_1/cancel", "/api/v1/workflow-runs/run_1/retry"}) {
		r, refused := owner_authority_guard(&h, wire_cookie_request(f, "POST", path, "{}"))
		testing.expectf(t, refused && r.status == 409, "%s is refused on an owner chain", path)
	}
	by_lease := wire_agent_request(f, "comment", `{"method":"agent.lease.heartbeat","params":{"lease_id":"lease_owner"}}`)
	by_lease.path = "/api/v1/agent-actions/lease/heartbeat"
	r, refused := owner_authority_guard(&h, by_lease)
	testing.expect(t, refused && r.status == 409, "lease-id agent verbs resolve the chain through the lease")
	holder := wire_agent_request(f, "comment", `{"method":"agent.lease.submit","params":{"summary":"x"}}`)
	holder.path = "/api/v1/agent-actions/lease/submit"
	r, refused = owner_authority_guard(&h, holder)
	testing.expect(t, refused && r.status == 409, "id-less agent lease verbs resolve the caller's current lease")

	// Fail closed: a failed lookup or registry read refuses the write.
	failing := repo
	failing.get_task = owner_authority_stub_task_failure
	svc_task := f.tc_svc
	svc_task.repo = &failing
	h_task := f.th
	h_task.taskchains = &svc_task
	r, refused = owner_authority_guard(&h_task, recheck)
	testing.expect(t, refused && r.status == 500, "a task lookup failure refuses the write")
	broken := f.tc_repo
	broken.owner_registry_routes = owner_authority_stub_registry_failure
	svc_broken := f.tc_svc
	svc_broken.repo = &broken
	h_broken := f.th
	h_broken.taskchains = &svc_broken
	r, refused = owner_authority_guard(&h_broken, wire_cookie_request(f, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", chain), `{"title":"x"}`))
	testing.expect(t, refused && r.status == 500, "a registry read failure refuses the write")
	_, unrelated := owner_authority_guard(&h_broken, wire_cookie_request(f, "GET", fmt.tprintf("/api/v1/task-chains/%s", chain), ""))
	testing.expect(t, !unrelated, "reads are never refused by the guard")

	// The unpaged owner listing reports a storage failure as internal.
	list_repo := f.tc_repo
	list_repo.owner_registry_list = owner_authority_stub_list_failure
	svc_list := f.tc_svc
	svc_list.repo = &list_repo
	bh := Bridge_Handlers{auth = &f.auth_svc, taskchains = &svc_list}
	listed := owner_local_list_handler(&bh, wire_cookie_request(f, "GET", "/api/v1/owner-local/chains", ""))
	testing.expect(t, listed.status == 500 && strings.contains(listed.body, "registry read failed"), "a registry storage failure is an internal error, not a bound")
}
