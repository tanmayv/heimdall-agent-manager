package http

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import placement "odin_test:hub/service/placement"

Placement_Handlers :: struct {
	auth:      ^auth_service.Auth_Service,
	placement: ^placement.Service,
}
Placement_Candidate_Wire :: struct {
	bridge_id, provider, provider_profile, model: string,
	rank:                                         int,
}
Placement_Bridge_Wire :: struct {
	bridge_id, label: string,
	eligible:         bool,
	reason:           string,
}
Placement_Provider_Wire :: struct {
	provider, label: string,
	models:          []string,
}

placement_candidates_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Placement_Handlers)(ctx)
	auth, ok, refusal := require_auth(h.auth, req)
	if !ok do return refusal
	if !contracts.is_user_auth(auth) || auth.user_id == "" do return respond_error(domain.domain_error(.Forbidden, "user authentication is required"), req.request_id)
	agent_id := query_value(req.query, "agent_id")
	if agent_id != "" {
		agent, found, e := iface.agent_get(h.placement.agents, agent_id)
		if e.code != .None do return respond_error(e, req.request_id)
		if !found || string(agent.owner_user_id) != auth.user_id do return respond_error(domain.domain_error(.Not_Found, "agent not found"), req.request_id)
	}
	features := make([dynamic]string, context.temp_allocator)
	parts := strings.split(req.query, "&", context.temp_allocator)
	for part in parts {
		eq := strings.index_byte(part, '=')
		if eq >= 0 && query_component_decode(part[:eq]) == "feature" do append(&features, query_component_decode(part[eq + 1:]))
	}
	requirements := placement.Requirements {
		owner    = auth.user_id,
		agent_id = agent_id,
		features = features[:],
	}
	all := placement.candidates(h.placement, requirements, context.temp_allocator)
	defer placement.candidates_destroy(all, context.temp_allocator)
	ordered := placement.match(nil, all, context.temp_allocator)
	defer delete(ordered, context.temp_allocator)
	candidates := make([]Placement_Candidate_Wire, len(ordered), context.temp_allocator)
	for c, i in ordered do candidates[i] = {
		bridge_id        = c.bridge_id,
		provider         = c.provider,
		provider_profile = c.provider_profile,
		model            = c.model,
		rank             = i,
	}
	bridges, be := iface.bridge_list_by_owner(h.placement.bridges, domain.User_ID(auth.user_id))
	defer {for &b in bridges do domain.bridge_destroy(&b); delete(bridges)}
	if be.code != .None do return respond_error(be, req.request_id)
	machines := make([dynamic]Placement_Bridge_Wire, context.temp_allocator)
	for b in bridges {
		if string(b.owner_user_id) != auth.user_id do continue
		eligible, reason := placement.bridge_eligible(h.placement, b, requirements)
		append(
			&machines,
			Placement_Bridge_Wire{bridge_id = b.bridge_id, label = b.label, eligible = eligible, reason = reason},
		)
	}
	catalog, ce := iface.provider_catalog_list(h.placement.providers.repo)
	defer domain.provider_catalog_destroy(catalog)
	if ce.code != .None do return respond_error(ce, req.request_id)
	providers := make([dynamic]Placement_Provider_Wire, context.temp_allocator)
	for p in catalog {
		if p.state != "active" do continue
		models := make([dynamic]string, context.temp_allocator)
		for m in p.models do if m.state == "active" do append(&models, m.model_id)
		append(&providers, Placement_Provider_Wire{provider = p.provider, label = p.display_name, models = models[:]})
	}
	return respond_success_typed(struct {
			candidates: []Placement_Candidate_Wire,
			bridges:    []Placement_Bridge_Wire,
			providers:  []Placement_Provider_Wire,
		}{candidates, machines[:], providers[:]}, req.request_id, auth_ctx_server_time(req))
}
