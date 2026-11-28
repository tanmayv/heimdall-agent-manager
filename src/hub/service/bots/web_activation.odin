package bots

import "core:log"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import placement "odin_test:hub/service/placement"

// Reads and writes are scoped to the already authenticated owner. The caller
// owns the returned activation even for an idempotent same-intent retry.
get_web_activation :: proc(s: ^Bots_Service, owner: string) -> (domain.Bot_Web_Activation, domain.Domain_Error) {
	state, found, err := iface.bot_web_activation_get(s.repo, owner)
	if !found || err.code != .None do return state, err
	if gate := bots_gate_error(s.experiments, owner); gate.code == .Forbidden {
		state.enabled = false
	} else if gate.code != .None {
		domain.bot_web_activation_destroy(&state)
		return {}, gate
	}
	return state, {}
}

set_web_activation :: proc(s: ^Bots_Service, owner: string, enabled: bool, expected_generation: i64) -> (domain.Bot_Web_Activation, domain.Domain_Error) {
	state, legacy_id, err := set_web_activation_locked(s, owner, enabled, expected_generation)
	if err.code != .None do return {}, err
	// Legacy dispatch is already fenced. Do not hold locks or a transaction
	// while asking the bridge to stop, and never stop the canonical runtime.
	if legacy_id != "" && legacy_id != state.agent_instance_id {
		guard := Legacy_Stop_Guard{s=s, owner=owner, instance_id=legacy_id}
		{
			context.allocator = context.temp_allocator
			_, _, stop_err := agent.stop_instance(s.agents, {kind=.Internal_User, user_id=owner}, legacy_id,
				{reason="bot_cutover"}, &guard, legacy_stop_guard)
			if stop_err.code != .None && !guard.already_stopped do log.warn("legacy bot fenced but runtime stop was not accepted")
		}
	}
	return state, {}
}

Legacy_Stop_Guard :: struct {
	s: ^Bots_Service,
	owner, instance_id: string,
	already_stopped: bool,
}

// stop_instance invokes this under its lifecycle lock. A concurrent opt-in or
// retry cannot request a second stop from a stale pre-stop snapshot.
legacy_stop_guard :: proc(raw: rawptr) -> domain.Domain_Error {
	guard := (^Legacy_Stop_Guard)(raw)
	old, found, err := iface.agent_get_instance(guard.s.agents.agents, guard.instance_id)
	defer domain.agent_instance_destroy(&old)
	if err.code != .None && err.code != .Not_Found do return err
	if !found || old.owner_user_id != domain.User_ID(guard.owner) ||
	   !agent.runtime_expected_active(old.runtime_status) || old.runtime_status == "stopping" {
		guard.already_stopped = true
		return domain.domain_error(.Conflict, "legacy bot is not running")
	}
	return {}
}

set_web_activation_locked :: proc(s: ^Bots_Service, owner: string, enabled: bool, expected_generation: i64) -> (domain.Bot_Web_Activation, string, domain.Domain_Error) {
	sync.mutex_lock(&s.web_activation_mutex)
	defer sync.mutex_unlock(&s.web_activation_mutex)
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	sync.mutex_lock(&s.legacy_fence_mutex)
	defer sync.mutex_unlock(&s.legacy_fence_mutex)
	if err := bots_gate_error(s.experiments, owner); err.code != .None do return {}, "", err
	uow, begun, begin_err := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return {}, "", begin_err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	repo := &uow.repos.bots
	current, found, err := iface.bot_web_activation_get(repo, owner)
	defer domain.bot_web_activation_destroy(&current)
	if err.code != .None do return {}, "", err
	// A replay may be one generation behind only if that exact transition is
	// already reflected in the current state. An older intent is stale.
	same_intent := current.enabled == enabled && expected_generation >= 0 &&
	               (expected_generation == current.generation || expected_generation == current.generation - 1)
	if expected_generation != current.generation && !same_intent do return {}, "", bots_detail_error(.Conflict, "activation_generation_changed")
	legacy_id := ""
	if enabled {
		legacy, legacy_found, get_err := iface.bot_get_by_owner(repo, owner)
		defer domain.bot_destroy(&legacy)
		if get_err.code != .None do return {}, "", get_err
		if legacy_found do legacy_id = strings.clone(legacy.agent_instance_id, context.temp_allocator)
	}
	if found && !same_intent {
		changed, set_err := iface.bot_web_activation_set_enabled(repo, owner, enabled, expected_generation)
		if set_err.code != .None do return {}, "", set_err
		if !changed do return {}, "", bots_detail_error(.Conflict, "activation_generation_changed")
		current.enabled = enabled
		current.generation += 1
	} else if !found && enabled {
		provisioned, provision_err := provision_web_activation(s, repo, owner)
		if provision_err.code != .None do return {}, "", provision_err
		current = provisioned
	}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed do return {}, "", commit_err
	if !same_intent && current.generation > 0 do bots_publish_changed(s, owner, current.bot_id)
	result := current
	current = {}
	return result, legacy_id, {}
}

provision_web_activation :: proc(s: ^Bots_Service, repo: ^iface.Bot_Repository, owner: string) -> (domain.Bot_Web_Activation, domain.Domain_Error) {
	// Agent service snapshots use request-local scratch. The returned state is
	// read from the repository using the caller allocator after all writes.
	auth := contracts.Auth_Context{kind=.Internal_User, user_id=owner}
	bot, found, err := iface.bot_get_by_owner(repo, owner)
	defer if found do domain.bot_destroy(&bot)
	if err.code != .None do return {}, err
	bot_id, instance_id, conversation_id: string
	{
		context.allocator = context.temp_allocator
		bot_id = bot.bot_id
		if !found do bot_id = strings.clone(platform.generate_id(s.ids, "bot_"))
		name := bot.display_name
		if name == "" do name = "Ninjy bot"
		role, created, create_err := agent.create_agent(s.agents, auth, {
			name=name, slug=strings.concatenate({bot_id, "-web"}), template_id=domain.TEMPLATE_BOT_WEB_ID,
			has_template_id=true, permission_mode=domain.AGENT_PERMISSION_MODE_YOLO,
		})
		if create_err.code != .None do return {}, create_err
		if !created do return {}, domain.domain_error(.Internal_Error, "could not create bot agent")
		if !found {
			now := platform.clock_now(s.clock)
			bot = {bot_id=bot_id, owner_user_id=owner, agent_id=role.agent_id, display_name=name, placement_revision=1, created_at=now, updated_at=now}
			if insert_err := iface.bot_insert(repo, bot); insert_err.code != .None do return {}, insert_err
		}
		policy, policy_err := iface.placement_list(repo, bot.bot_id)
		if policy_err.code != .None do return {}, policy_err
		ps := bots_placement(s)
		prefer_bridge := ""
		if len(policy) == 0 && bot.agent_instance_id != "" {
			old, old_found, old_err := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
			if old_err.code != .None && old_err.code != .Not_Found do return {}, old_err
			if old_found && old.owner_user_id == domain.User_ID(owner) do prefer_bridge = old.bridge_id
		}
		c, placed, _ := placement.select(&ps, {owner=owner, agent_id=bot.agent_id, prefer_bridge=prefer_bridge}, bots_rules(policy))
		if !placed do return {}, bots_detail_error(.Bridge_Offline, "bot_no_eligible_placement")
		inst, prepared, prepare_err := agent.create_instance_stopped(s.agents, auth, {
			agent_id=role.agent_id, bridge_id=c.bridge_id, provider=c.provider, provider_profile=c.provider_profile,
			model=c.model, display_name=bot.display_name, fleet_scope="excluded",
		})
		if prepare_err.code != .None do return {}, prepare_err
		if !prepared || inst.agent_instance_id == "" || inst.conversation_id == "" || inst.agent_instance_id == bot.agent_instance_id {
			return {}, domain.domain_error(.Internal_Error, "could not create fresh bot conversation")
		}
		instance_id, conversation_id = inst.agent_instance_id, inst.conversation_id
		if insert_err := iface.bot_web_activation_insert(repo, {
			owner_user_id=owner, bot_id=bot_id, agent_instance_id=instance_id, conversation_id=conversation_id,
			enabled=true, generation=1,
		}); insert_err.code != .None do return {}, insert_err
	}
	state, saved, get_err := iface.bot_web_activation_get(repo, owner)
	if get_err.code != .None do return {}, get_err
	if !saved do return {}, domain.domain_error(.Internal_Error, "web activation was not stored")
	return state, {}
}

// Normal shared agent checks already verify the bridge, profile and requested
// model. Fence the retired instance and apply the owner's current eligibility
// and placement rules only to its pinned canonical replacement.
check_web_runtime_policy :: proc(ctx: rawptr, inst: domain.Agent_Instance, bridge_id, provider, requested_model, resolved_model: string) -> domain.Domain_Error {
	s := (^Bots_Service)(ctx)
	activation, found, err := iface.bot_web_activation_get(s.repo, string(inst.owner_user_id))
	defer domain.bot_web_activation_destroy(&activation)
	if err.code != .None do return err
	if !found do return {}
	// The old runtime can still receive stale generic start/reconfiguration
	// requests after cutover. Do not treat it as an unrelated same-owner agent.
	bot, bot_found, bot_err := iface.bot_get(s.repo, activation.bot_id)
	defer domain.bot_destroy(&bot)
	if bot_err.code != .None do return bot_err
	owns_bot := bot_found && bot.owner_user_id == string(inst.owner_user_id)
	if activation.agent_instance_id != inst.agent_instance_id {
		if owns_bot && bot.agent_instance_id == inst.agent_instance_id do return bots_detail_error(.Conflict, "bot_generation_inactive")
		return {}
	}
	if !activation.enabled do return bots_detail_error(.Conflict, "bot_generation_inactive")
	if gate := bots_gate_error(s.experiments, string(inst.owner_user_id)); gate.code != .None do return gate
	if !owns_bot do return domain.domain_error(.Internal_Error, "bot placement owner not found")
	if bot.agent_id != inst.agent_id {
		// This is the same stored policy role used when selecting the initial
		// destination, even though the fresh runtime has its own role template.
		ps := bots_placement(s)
		if support := placement.agent_bridge_support_check(&ps, bot.agent_id, bridge_id); support.code != .None do return support
	}
	policy, list_err := iface.placement_list(s.repo, activation.bot_id)
	defer {
		for &row in policy do domain.bot_placement_candidate_destroy(&row)
		delete(policy)
	}
	if list_err.code != .None do return list_err
	candidate := placement.Candidate{
		bridge_id=bridge_id, provider=provider, model=requested_model, resolved_model=resolved_model,
	}
	if !placement.allows_explicit_destination(bots_rules(policy), candidate) do return bots_detail_error(.Forbidden, "bot_placement_not_allowed")
	return {}
}
