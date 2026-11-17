package bots

import "core:strings"
import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import provider_service "odin_test:hub/service/provider"
import project_service "odin_test:hub/service/project"

bots_detail_error :: proc(code: domain.Error_Code, detail: string) -> domain.Domain_Error {
	e := domain.domain_error(code, detail)
	e.details_json = fmt.tprintf(`{{"code":"%s"}}`, detail)
	return e
}

bots_validate_placement :: proc(s: ^Bots_Service, owner: string, rows: []domain.Bot_Placement_Candidate) -> domain.Domain_Error {
	if len(rows) > domain.BOT_MAX_PLACEMENT_CANDIDATES do return bots_detail_error(.Validation_Failed, "too_many_candidates")
	for row, i in rows {
		if row.bridge_id != "*" {
			b, found, err := iface.bridge_get_bridge(s.bridges, row.bridge_id)
			defer domain.bridge_destroy(&b)
			if err.code != .None do return err
			if !found || string(b.owner_user_id) != owner do return bots_detail_error(.Validation_Failed, "unknown_bridge")
		}
		if row.provider != "*" {
			p, found, err := iface.provider_catalog_get(s.providers.repo, row.provider)
			defer domain.provider_catalog_entry_destroy(p)
			if err.code != .None do return err
			if !found do return bots_detail_error(.Validation_Failed, "unknown_provider")
		}
		if row.provider == "*" && row.model != "*" do return bots_detail_error(.Validation_Failed, "model_requires_provider")
		for prev in rows[:i] {
			if prev.bridge_id == row.bridge_id && prev.provider == row.provider && prev.model == row.model do return bots_detail_error(.Validation_Failed, "duplicate_candidate")
		}
	}
	return {}
}

// The first matching policy row determines both permission and rank.
bots_candidate_rank :: proc(policy: []domain.Bot_Placement_Candidate, bridge_id, provider, model: string) -> (tier: domain.Bot_Placement_Tier, position: int, wildcard: bool, allowed: bool) {
	if len(policy) == 0 do return .Allowed, 0, false, true
	for row in policy {
		if (row.bridge_id == "*" || row.bridge_id == bridge_id) && (row.provider == "*" || row.provider == provider) && (row.model == "*" || row.model == model) do return row.tier, row.position, row.model == "*", true
	}
	return {}, 0, false, false
}

Ranked_Bot_Candidate :: struct {
	wire: contracts.Bot_Candidate_Wire,
	tier: domain.Bot_Placement_Tier,
	position, provider_order, model_order: int,
}
bots_rank_before :: proc(a, b: Ranked_Bot_Candidate) -> bool {
	if a.tier != b.tier do return a.tier == .Preferred
	if a.position != b.position do return a.position < b.position
	if a.provider_order != b.provider_order do return a.provider_order < b.provider_order
	return a.model_order < b.model_order
}

// Returned entries own their strings; callers use bots_candidates_destroy.
bots_expand_candidates :: proc(s: ^Bots_Service, bot: domain.Bot, policy: []domain.Bot_Placement_Candidate, bridge_id: string) -> []contracts.Bot_Candidate_Wire {
	views, err := provider_service.list_bridge_providers(s.providers, bridge_id)
	defer provider_service.bridge_provider_views_destroy(views)
	if err.code != .None do return nil
	// Views are profile ordered. Rank ties use the catalog's provider order.
	catalog, catalog_err := iface.provider_catalog_list(s.providers.repo)
	defer domain.provider_catalog_destroy(catalog)
	if catalog_err.code != .None do return nil
	ranked := make([dynamic]Ranked_Bot_Candidate)
	defer delete(ranked)
	for view in views {
		if !view.enabled || view.detection_state != "present" || view.profile_state == "missing" do continue
		provider_order := len(catalog)
		for entry, i in catalog do if entry.provider == view.catalog.provider do provider_order = i
		first_active := -1
		for model, mi in view.catalog.models {
			if model.state != "active" do continue
			if first_active < 0 do first_active = mi
			tier, position, wildcard, allowed := bots_candidate_rank(policy, bridge_id, view.catalog.provider, model.model_id)
			if !allowed || (wildcard && mi != first_active) do continue
			candidate := Ranked_Bot_Candidate{wire = {provider = view.catalog.provider, provider_profile = view.profile_id, model = model.model_id, tier = domain.bot_placement_tier_text(tier)}, tier = tier, position = position, provider_order = provider_order, model_order = mi}
			append(&ranked, candidate)
			// Stable insertion preserves profile order for otherwise identical ranks.
			for j := len(ranked)-1; j > 0 && bots_rank_before(ranked[j], ranked[j-1]); j -= 1 do ranked[j], ranked[j-1] = ranked[j-1], ranked[j]
		}
	}
	out := make([dynamic]contracts.Bot_Candidate_Wire)
	limit := s.timers.bot_max_local_candidates
	if limit <= 0 do limit = 3
	for candidate in ranked {
		duplicate := false
		for existing in out do if existing.provider == candidate.wire.provider && existing.model == candidate.wire.model do duplicate = true
		if duplicate do continue
		append(&out, contracts.Bot_Candidate_Wire{provider = strings.clone(candidate.wire.provider), provider_profile = strings.clone(candidate.wire.provider_profile), model = strings.clone(candidate.wire.model), tier = strings.clone(candidate.wire.tier)})
		if len(out) >= limit do break
	}
	return out[:]
}

bots_candidates_destroy :: proc(rows: []contracts.Bot_Candidate_Wire) {
	for row in rows {delete(row.provider); delete(row.provider_profile); delete(row.model); delete(row.tier)}
	delete(rows)
}

bots_bridge_capable :: proc(b: domain.Bridge) -> bool {
	return agent_service.bridge_feature_supported(b, "bot_deliver_v1") && agent_service.bridge_feature_supported(b, "instance_reconfiguration_v1")
}

bots_select_bridge :: proc(s: ^Bots_Service, bot: domain.Bot, delivery: domain.Bot_Delivery, round: int) -> (bridge_id: string, found: bool) {
	policy, policy_err := iface.placement_list(s.repo, bot.bot_id)
	defer {for &row in policy do domain.bot_placement_candidate_destroy(&row); delete(policy)}
	if policy_err.code != .None do return "", false
	bridges, bridge_err := iface.bridge_list_by_owner(s.bridges, domain.User_ID(bot.owner_user_id))
	defer {for &b in bridges do domain.bridge_destroy(&b); delete(bridges)}
	if bridge_err.code != .None do return "", false
	attempts, attempt_err := iface.attempt_list_for_delivery(s.repo, delivery.delivery_id)
	defer {for &a in attempts do domain.bot_delivery_attempt_destroy(&a); delete(attempts)}
	if attempt_err.code != .None do return "", false
	sticky := ""
	if bot.agent_instance_id != "" {
		inst, ok, _ := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
		if ok do sticky = strings.clone(inst.bridge_id)
		domain.agent_instance_destroy(&inst)
	}
	defer delete(sticky)
	best := -1
	best_rank: Ranked_Bot_Candidate
	for b, i in bridges {
		if string(b.owner_user_id) != bot.owner_user_id || b.status != .Online || !bots_bridge_capable(b) || s.registry == nil || !project_service.bridge_runtime_registry_has_live(s.registry, b.bridge_id) do continue
		if agent_service.require_launch_bridge_enabled(s.agents, b).code != .None do continue
		tried := false
		for a in attempts do if a.round == round && a.bridge_id == b.bridge_id do tried = true
		if tried do continue
		candidates := bots_expand_candidates(s, bot, policy, b.bridge_id)
		defer bots_candidates_destroy(candidates)
		if len(candidates) == 0 do continue
		if b.bridge_id == sticky do return strings.clone(b.bridge_id), true
		tier, pos, _, _ := bots_candidate_rank(policy, b.bridge_id, candidates[0].provider, candidates[0].model)
		rank := Ranked_Bot_Candidate{tier = tier, position = pos}
		if best < 0 || bots_rank_before(rank, best_rank) || (rank.tier == best_rank.tier && rank.position == best_rank.position && (b.created_at < bridges[best].created_at || (b.created_at == bridges[best].created_at && b.bridge_id < bridges[best].bridge_id))) {
			best, best_rank = i, rank
		}
	}
	if best < 0 do return "", false
	return strings.clone(bridges[best].bridge_id), true
}
