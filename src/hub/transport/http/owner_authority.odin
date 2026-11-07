package http

// R4a: per-chain authority. A chain registered in owner_local_chains (native
// owner chains and migrated chains alike) is written only through its owner
// Bridge. The Hub marks such chains with authority:{kind:"owner",bridge_id} in
// the task-chain list and detail, and refuses every write route on them with a
// typed owner_authority error naming the Bridge, before any handler (and so
// before the frozen-legacy SQLite trigger) runs.

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import taskchain_service "odin_test:hub/service/taskchain"
import jsonx "odin_test:lib/jsonx"

Chain_Authority_Wire :: struct {
	kind:      string `json:"kind"`,
	bridge_id: string `json:"bridge_id"`,
}

Owner_Authority_Details :: struct {
	kind:      string `json:"kind"`,
	bridge_id: string `json:"bridge_id"`,
	chain_id:  string `json:"chain_id"`,
}

owner_authority_error :: proc(chain_id, bridge_id: string) -> domain.Domain_Error {
	details, _ := json.marshal(Owner_Authority_Details{"owner", bridge_id, chain_id}, allocator = context.temp_allocator)
	return domain.domain_error(.Owner_Authority, "this task chain is held by its owner Bridge; act on it through that Bridge", string(details))
}

// owner_authority_routes maps chain_id -> owner bridge for the account (or for
// one chain). Temp-allocated; nil service or repository means no owner chains.
// ok=false is a registry read failure: write paths must fail closed on it.
owner_authority_routes :: proc(svc: ^taskchain_service.Taskchain_Service, account, chain: string) -> (map[string]string, bool) {
	out := make(map[string]string, context.temp_allocator)
	if svc == nil || svc.repo == nil || svc.repo.owner_registry_routes == nil || account == "" do return out, true
	saved := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = saved
	rows, err := svc.repo.owner_registry_routes(svc.repo.ctx, account, chain)
	if err.code != .None do return out, false
	for r in rows do out[r.chain_id] = r.owner_bridge_id
	return out, true
}

owner_authority_of :: proc(svc: ^taskchain_service.Taskchain_Service, account, chain: string) -> (bridge: string, held: bool, ok: bool) {
	if chain == "" do return "", false, true
	routes, read := owner_authority_routes(svc, account, chain)
	if !read do return "", false, false
	bridge, held = routes[chain]
	return bridge, held, true
}

owner_authority_wire :: proc(routes: map[string]string, chain: string) -> Maybe(Chain_Authority_Wire) {
	bridge, held := routes[chain]
	if !held do return nil
	return Chain_Authority_Wire{"owner", bridge}
}

// Agent-action envelopes that mutate a chain. Reads (show/list/graph/status)
// and the caller's own lease lookups without ids are not owner-checked here.
owner_authority_agent_write :: proc(path: string) -> bool {
	switch path {
	case "/api/v1/agent-actions/tasks/create", "/api/v1/agent-actions/tasks/update", "/api/v1/agent-actions/tasks/comment",
	     "/api/v1/agent-actions/tasks/depend", "/api/v1/agent-actions/chain/set-title", "/api/v1/agent-actions/chain/set-description",
	     "/api/v1/agent-actions/chain/set-status", "/api/v1/agent-actions/chain/summary/set", "/api/v1/agent-actions/chain/propose",
	     "/api/v1/agent-actions/review/post", "/api/v1/agent-actions/lease/submit", "/api/v1/agent-actions/lease/handoff",
	     "/api/v1/agent-actions/lease/block", "/api/v1/agent-actions/lease/switch", "/api/v1/agent-actions/lease/heartbeat",
	     "/api/v1/agent-actions/work/depend", "/api/v1/agent-actions/work/remove-dependency", "/api/v1/agent-actions/work/scope",
	     "/api/v1/agent-actions/work/complete", "/api/v1/agent-actions/workflow/run", "/api/v1/agent-actions/workflow/retry",
	     "/api/v1/agent-actions/workflow/cancel":
		return true
	}
	return false
}

Owner_Target_Kind :: enum { None, Chain, Task, Run, Lease, Holder }

// owner_authority_request classifies a write request by the id that names its
// chain. Pure: no I/O.
owner_authority_request :: proc(req: Request) -> (Owner_Target_Kind, string) {
	parts := strings.split(req.path, "/", context.temp_allocator)
	// "", api, v1, <collection>, <id>, ...
	if len(parts) >= 5 && parts[4] != "" {
		switch parts[3] {
		case "task-chains":
			if parts[4] != "search" do return .Chain, parts[4]
		case "tasks":
			if len(parts) == 6 && (parts[5] == "recheck" || parts[5] == "placement-recovery") do return .Task, parts[4]
		case "workflow-runs":
			if len(parts) == 6 && (parts[5] == "cancel" || parts[5] == "retry") do return .Run, parts[4]
		}
	}
	if !owner_authority_agent_write(req.path) do return .None, ""
	params, has := jsonx.extract_raw_object(req.body, "params", true, context.temp_allocator)
	if !has do params = req.body
	if chain := jsonx.extract_string(params, "chain_id", "", true, context.temp_allocator); chain != "" do return .Chain, chain
	if task := jsonx.extract_string(params, "task_id", "", true, context.temp_allocator); task != "" do return .Task, task
	if run := jsonx.extract_string(params, "run_id", "", true, context.temp_allocator); run != "" do return .Run, run
	if strings.has_prefix(req.path, "/api/v1/agent-actions/lease/") {
		if lease := jsonx.extract_string(params, "lease_id", "", true, context.temp_allocator); lease != "" do return .Lease, lease
		// No ids: the Hub acts on the caller's own current lease.
		return .Holder, ""
	}
	return .None, ""
}

// owner_authority_chain resolves the chain a classified request addresses.
// ok=false is a lookup failure (fail closed); chain="" means none.
owner_authority_chain :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, kind: Owner_Target_Kind, id: string) -> (chain: string, ok: bool) {
	if kind == .Chain do return id, true
	if h == nil || h.taskchains == nil || h.taskchains.repo == nil do return "", true
	repo := h.taskchains.repo
	saved := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = saved
	#partial switch kind {
	case .Task:
		if repo.get_task == nil do return "", true
		t, found, err := repo.get_task(repo.ctx, domain.Task_ID(id))
		if err.code != .None && err.code != .Not_Found do return "", false
		if found do return string(t.chain_id), true
	case .Run:
		r, found, err := iface.taskchain_get_workflow_run(repo, domain.Workflow_Run_ID(id), domain.User_ID(auth.user_id))
		if err.code != .None && err.code != .Not_Found do return "", false
		if found do return string(r.chain_id), true
	case .Lease:
		l, found, err := iface.taskchain_get_lease(repo, id)
		if err.code != .None && err.code != .Not_Found do return "", false
		if found do return string(l.chain_id), true
	case .Holder:
		if auth.agent_instance_id == "" || repo.get_lease_by_holder == nil do return "", true
		l, found, err := iface.taskchain_get_lease_by_holder(repo, auth.agent_instance_id)
		if err.code != .None && err.code != .Not_Found do return "", false
		if found do return string(l.chain_id), true
	}
	return "", true
}

owner_authority_unavailable :: proc(req: Request) -> Response {
	return respond_error(domain.domain_error(.Internal_Error, "owner authority could not be checked; the write was not applied"), req.request_id)
}

// owner_authority_guard runs before the matched handler of every write route.
// Unauthenticated requests are not judged here: the handler answers them.
// Lookup or registry failures refuse the write (fail closed).
owner_authority_guard :: proc(ctx: rawptr, req: Request) -> (Response, bool) {
	if req.method == "GET" || req.method == "HEAD" || req.method == "OPTIONS" do return {}, false
	h := (^Taskchain_Handlers)(ctx)
	if h == nil || h.auth == nil do return {}, false
	kind, id := owner_authority_request(req)
	if kind == .None do return {}, false
	auth, ok, _ := auth_service.resolve_auth_any(h.auth, auth_service.Auth_Request{remote_addr = req.remote_addr, query = req.query, body = req.body, headers = req.headers})
	if !ok || auth.user_id == "" do return {}, false
	chain, resolved := owner_authority_chain(h, auth, kind, id)
	if !resolved do return owner_authority_unavailable(req), true
	if chain == "" do return {}, false
	bridge, held, read := owner_authority_of(h.taskchains, string(auth.user_id), chain)
	if !read do return owner_authority_unavailable(req), true
	if !held do return {}, false
	return respond_error(owner_authority_error(chain, bridge), req.request_id), true
}

_ :: contracts
