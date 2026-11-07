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
owner_authority_routes :: proc(svc: ^taskchain_service.Taskchain_Service, account, chain: string) -> map[string]string {
	out := make(map[string]string, context.temp_allocator)
	if svc == nil || svc.repo == nil || svc.repo.owner_registry_routes == nil || account == "" do return out
	saved := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = saved
	rows, err := svc.repo.owner_registry_routes(svc.repo.ctx, account, chain)
	if err.code != .None do return out
	for r in rows do out[r.chain_id] = r.owner_bridge_id
	return out
}

owner_authority_of :: proc(svc: ^taskchain_service.Taskchain_Service, account, chain: string) -> (string, bool) {
	if chain == "" do return "", false
	routes := owner_authority_routes(svc, account, chain)
	bridge, held := routes[chain]
	return bridge, held
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

// owner_authority_target names the chain a write request addresses, if any.
owner_authority_target :: proc(h: ^Taskchain_Handlers, req: Request) -> string {
	if strings.has_prefix(req.path, "/api/v1/task-chains/") {
		parts := strings.split(req.path, "/", context.temp_allocator)
		// "", api, v1, task-chains, <chain>, ...
		if len(parts) < 5 || parts[4] == "" || parts[4] == "search" do return ""
		return parts[4]
	}
	if owner_authority_agent_write(req.path) {
		params, has := jsonx.extract_raw_object(req.body, "params", true, context.temp_allocator)
		if !has do params = req.body
		if chain := jsonx.extract_string(params, "chain_id", "", true, context.temp_allocator); chain != "" do return chain
		task := jsonx.extract_string(params, "task_id", "", true, context.temp_allocator)
		if task == "" || h == nil || h.taskchains == nil || h.taskchains.repo == nil || h.taskchains.repo.get_task == nil do return ""
		saved := context.allocator
		context.allocator = context.temp_allocator
		defer context.allocator = saved
		t, found, _ := h.taskchains.repo.get_task(h.taskchains.repo.ctx, domain.Task_ID(task))
		if found do return string(t.chain_id)
	}
	return ""
}

// owner_authority_guard runs before the matched handler of every write route.
// Unauthenticated requests are not judged here: the handler answers them.
owner_authority_guard :: proc(ctx: rawptr, req: Request) -> (Response, bool) {
	if req.method == "GET" || req.method == "HEAD" || req.method == "OPTIONS" do return {}, false
	h := (^Taskchain_Handlers)(ctx)
	if h == nil || h.auth == nil do return {}, false
	chain := owner_authority_target(h, req)
	if chain == "" do return {}, false
	auth, ok, _ := auth_service.resolve_auth_any(h.auth, auth_service.Auth_Request{remote_addr = req.remote_addr, query = req.query, body = req.body, headers = req.headers})
	if !ok || auth.user_id == "" do return {}, false
	bridge, held := owner_authority_of(h.taskchains, string(auth.user_id), chain)
	if !held do return {}, false
	return respond_error(owner_authority_error(chain, bridge), req.request_id), true
}

_ :: contracts
