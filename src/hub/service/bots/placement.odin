package bots
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import placement "odin_test:hub/service/placement"

bots_detail_error :: proc(code: domain.Error_Code, detail: string) -> domain.Domain_Error {
	e := domain.domain_error(code, detail)
	e.details_json = fmt.tprintf(`{{"code":"%s"}}`, detail)
	return e
}


bots_placement :: proc(s: ^Bots_Service) -> placement.Service {
	if s.placement != nil do return s.placement^
	agents: ^iface.Agent_Repository
	if s.agents != nil do agents = s.agents.agents
	return placement.Service {
		bridges = s.bridges,
		agents = agents,
		providers = s.providers,
		registry = s.registry,
		entitlements = s.entitlements,
	}
}
bots_rules :: proc(rows: []domain.Bot_Placement_Candidate) -> []placement.Rule {
	out := make([]placement.Rule, len(rows), context.temp_allocator)
	for row, i in rows do out[i] = {
		position  = row.position,
		bridge_id = row.bridge_id,
		provider  = row.provider,
		model     = row.model,
		tier      = placement.Tier(row.tier),
	}
	return out
}
bots_validate_placement :: proc(
	s: ^Bots_Service,
	owner: string,
	rows: []domain.Bot_Placement_Candidate,
) -> domain.Domain_Error {
	ps := bots_placement(s)
	return placement.validate_rules(&ps, owner, bots_rules(rows), domain.BOT_MAX_PLACEMENT_CANDIDATES)
}
bots_expand_candidates :: proc(
	s: ^Bots_Service,
	bot: domain.Bot,
	policy: []domain.Bot_Placement_Candidate,
	bridge_id: string,
) -> []contracts.Bot_Candidate_Wire {
	ps := bots_placement(s)
	req := placement.Requirements {
		owner       = bot.owner_user_id,
		agent_id    = bot.agent_id,
		only_bridge = bridge_id,
		features    = {"bot_deliver_v1", "instance_reconfiguration_v1"},
	}
	all := placement.candidates(&ps, req, context.allocator)
	defer placement.candidates_destroy(all, context.allocator)
	ordered := placement.match(bots_rules(policy), all, context.allocator)
	defer delete(ordered)
	limit := s.timers.bot_max_local_candidates
	if limit <= 0 do limit = 3
	out := make([dynamic]contracts.Bot_Candidate_Wire)
	for c in ordered {
		append(
			&out,
			contracts.Bot_Candidate_Wire {
				provider = strings.clone(c.provider),
				provider_profile = strings.clone(c.provider_profile),
				model = strings.clone(c.model),
				tier = strings.clone("preferred" if c.tier == .Preferred else "allowed"),
			},
		)
		if len(out) >= limit do break
	}
	return out[:]
}
bots_candidates_destroy :: proc(rows: []contracts.Bot_Candidate_Wire) {
	for row in rows {delete(row.provider); delete(row.provider_profile); delete(row.model); delete(row.tier)}
	delete(rows)
}
bots_select_bridge :: proc(
	s: ^Bots_Service,
	bot: domain.Bot,
	delivery: domain.Bot_Delivery,
	round: int,
) -> (
	string,
	bool,
) {
	policy, e := iface.placement_list(s.repo, bot.bot_id)
	defer {for &row in policy do domain.bot_placement_candidate_destroy(&row); delete(policy)}
	if e.code != .None do return "", false
	attempts, ae := iface.attempt_list_for_delivery(s.repo, delivery.delivery_id)
	defer {for &a in attempts do domain.bot_delivery_attempt_destroy(&a); delete(attempts)}
	if ae.code != .None do return "", false
	excluded := make([dynamic]string, context.temp_allocator)
	for a in attempts do if a.round == round do append(&excluded, a.bridge_id)
	sticky := ""
	if bot.agent_instance_id != "" {
		inst, found, _ := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
		if found do sticky = strings.clone(inst.bridge_id)
		domain.agent_instance_destroy(&inst)
	}
	defer delete(sticky)
	ps := bots_placement(s)
	c, ok, _ := placement.select(
		&ps,
		{
			owner = bot.owner_user_id,
			agent_id = bot.agent_id,
			features = {"bot_deliver_v1", "instance_reconfiguration_v1"},
			exclude = excluded[:],
			prefer_bridge = sticky,
		},
		bots_rules(policy),
		allocator = context.allocator,
	)
	if !ok do return "", false
	defer placement.candidate_destroy(c, context.allocator)
	return strings.clone(c.bridge_id), true
}
