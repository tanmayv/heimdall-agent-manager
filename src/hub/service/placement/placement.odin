package placement

import "core:fmt"
import "core:mem"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import provider "odin_test:hub/service/provider"

ANY :: "*"
Tier :: enum {
	Preferred,
	Allowed,
}
Rule :: struct {
	position:                   int,
	bridge_id, provider, model: string,
	tier:                       Tier,
}
Candidate :: struct {
	bridge_id, provider, provider_profile, model, resolved_model, bridge_created_at: string,
	provider_order, model_order, rule_position:                                      int,
	tier:                                                                            Tier,
}
Requirements :: struct {
	owner, agent_id: string,
	features:        []string,
	only_bridge:     string,
	exclude:         []string,
	prefer_bridge:   string,
}
Service :: struct {
	bridges:      ^iface.Bridge_Repository,
	agents:       ^iface.Agent_Repository,
	providers:    ^provider.Provider_Service,
	registry:     ^project.Bridge_Runtime_Registry,
	entitlements: domain.Entitlement_Lookup,
	selectors:    [dynamic]Selector,
}
new_service :: proc(
	bridges: ^iface.Bridge_Repository,
	agents: ^iface.Agent_Repository,
	providers: ^provider.Provider_Service,
	registry: ^project.Bridge_Runtime_Registry,
	entitlements: domain.Entitlement_Lookup,
) -> Service {
	s := Service {
		bridges      = bridges,
		agents       = agents,
		providers    = providers,
		registry     = registry,
		entitlements = entitlements,
	}
	selector_register(&s, FIRST_SATISFIABLE)
	return s
}
service_destroy :: proc(s: ^Service) {delete(s.selectors); s.selectors = nil}

candidate_clone :: proc(c: Candidate, allocator: mem.Allocator) -> Candidate {
	out := c
	out.bridge_id = strings.clone(c.bridge_id, allocator)
	out.provider = strings.clone(c.provider, allocator)
	out.provider_profile = strings.clone(c.provider_profile, allocator)
	out.model = strings.clone(c.model, allocator)
	out.resolved_model = strings.clone(c.resolved_model, allocator)
	out.bridge_created_at = strings.clone(c.bridge_created_at, allocator)
	return out
}
candidate_destroy :: proc(c: Candidate, allocator: mem.Allocator) {
	delete(c.bridge_id, allocator); delete(c.provider, allocator); delete(c.provider_profile, allocator)
	delete(c.model, allocator); delete(c.resolved_model, allocator); delete(c.bridge_created_at, allocator)
}
candidates_destroy :: proc(rows: []Candidate, allocator: mem.Allocator) {
	for c in rows do candidate_destroy(c, allocator)
	delete(rows, allocator)
}

// The result and every string it contains belong to allocator. Repository
// snapshots use the calling allocator and are destroyed before returning.
candidates :: proc(s: ^Service, req: Requirements, allocator: mem.Allocator) -> []Candidate {
	if s == nil || s.bridges == nil || s.providers == nil || s.providers.repo == nil do return nil
	bridges, err := iface.bridge_list_by_owner(s.bridges, domain.User_ID(req.owner))
	defer {for &b in bridges do domain.bridge_destroy(&b); delete(bridges)}
	if err.code != .None do return nil
	catalog, ce := iface.provider_catalog_list(s.providers.repo)
	defer domain.provider_catalog_destroy(catalog)
	if ce.code != .None do return nil
	out := make([dynamic]Candidate, allocator)
	for b in bridges {
		if req.only_bridge != "" && req.only_bridge != b.bridge_id do continue
		excluded := false
		for id in req.exclude do if id == b.bridge_id do excluded = true
		if excluded do continue
		if ok, _ := bridge_eligible(s, b, req); !ok do continue
		if req.agent_id != "" {
			support, found, e := iface.agent_get_support(s.agents, req.agent_id, b.bridge_id)
			defer support_destroy(support)
			if e.code != .None && e.code != .Not_Found do continue
			if found && !support.enabled do continue
		}
		views, ve := provider.list_bridge_providers(s.providers, b.bridge_id)
		defer provider.bridge_provider_views_destroy(views)
		if ve.code != .None do continue
		for view in views {
			if !view.enabled || view.detection_state != "present" || view.profile_state == "missing" || view.catalog.state != "active" do continue
			po := len(catalog)
			for entry, i in catalog do if entry.provider == view.catalog.provider do po = i
			for model, mi in view.catalog.models {
				if model.state != "active" do continue
				append(
					&out,
					candidate_clone(
						Candidate {
							bridge_id = b.bridge_id,
							provider = view.catalog.provider,
							provider_profile = view.profile_id,
							model = model.model_id,
							resolved_model = model.resolved_model,
							bridge_created_at = b.created_at,
							provider_order = po,
							model_order = mi,
						},
						allocator,
					),
				)
			}
		}
	}
	return out[:]
}

rank_before :: proc(a, b: Candidate) -> bool {
	if a.tier != b.tier do return a.tier == .Preferred
	if a.rule_position != b.rule_position do return a.rule_position < b.rule_position
	if a.provider_order != b.provider_order do return a.provider_order < b.provider_order
	if a.model_order != b.model_order do return a.model_order < b.model_order
	if a.bridge_created_at != b.bridge_created_at do return a.bridge_created_at < b.bridge_created_at
	return a.bridge_id < b.bridge_id
}
rule_matches :: proc(r: Rule, c: Candidate) -> bool {
	return (r.bridge_id == ANY || r.bridge_id == c.bridge_id) &&
	       (r.provider == ANY || r.provider == c.provider) &&
	       (r.model == ANY || r.model == c.model || (c.resolved_model != "" && r.model == c.resolved_model))
}

// Explicit user selection uses the same scope predicate as automatic
// placement, without ranking tiers or collapsing wildcard model choices.
allows_explicit_destination :: proc(rules: []Rule, candidate: Candidate) -> bool {
	if len(rules) == 0 do return true
	for rule in rules do if rule_matches(rule, candidate) do return true
	return false
}

// Pure: only the returned slice is owned; strings alias all.
match :: proc(rules: []Rule, all: []Candidate, allocator: mem.Allocator) -> []Candidate {
	out := make([dynamic]Candidate, allocator)
	for c, ci in all {
		next := c
		next.tier = .Allowed; next.rule_position = 0
		allowed := len(rules) == 0
		wildcard := false
		for r in rules {
			if rule_matches(r, c) {
				next.tier = r.tier; next.rule_position = r.position; wildcard = r.model == ANY; allowed = true; break
			}
		}
		if !allowed do continue
		if wildcard {
			first := true
			for other, oi in all do if other.bridge_id == c.bridge_id && other.provider == c.provider && (other.model_order < c.model_order || (other.model_order == c.model_order && oi < ci)) do first = false
			if !first do continue
		}
		append(&out, next)
		for j := len(out) - 1; j > 0 && rank_before(out[j], out[j - 1]); j -= 1 do out[j], out[j - 1] = out[j - 1], out[j]
	}
	n := 0
	for c in out {
		duplicate := false
		for prev in out[:n] do if prev.bridge_id == c.bridge_id && prev.provider == c.provider && prev.model == c.model do duplicate = true
		if !duplicate {out[n] = c; n += 1}
	}
	// Return an exact-sized slice so delete does not need a dynamic capacity.
	result := make([]Candidate, n, allocator)
	copy(result, out[:n]); delete(out)
	return result
}
detail_error :: proc(detail: string) -> domain.Domain_Error {
	e := domain.domain_error(.Validation_Failed, detail)
	e.details_json = fmt.tprintf(`{"code":"%s"}`, detail)
	return e
}
validate_rules :: proc(s: ^Service, owner: string, rules: []Rule, max: int) -> domain.Domain_Error {
	if len(rules) > max do return detail_error("too_many_candidates")
	// Shape checks precede repository reads.
	for r, i in rules {
		if r.provider == ANY && r.model != ANY do return detail_error("model_requires_provider")
		for prev in rules[:i] do if prev.bridge_id == r.bridge_id && prev.provider == r.provider && prev.model == r.model do return detail_error("duplicate_candidate")
	}
	for r in rules {
		if r.bridge_id != ANY {
			b, found, e := iface.bridge_get_bridge(s.bridges, r.bridge_id)
			defer domain.bridge_destroy(&b)
			if e.code != .None do return e
			if !found || string(b.owner_user_id) != owner do return detail_error("unknown_bridge")
		}
		if r.provider != ANY {
			p, found, e := iface.provider_catalog_get(s.providers.repo, r.provider)
			defer domain.provider_catalog_entry_destroy(p)
			if e.code != .None do return e
			if !found do return detail_error("unknown_provider")
		}
	}
	return {}
}
