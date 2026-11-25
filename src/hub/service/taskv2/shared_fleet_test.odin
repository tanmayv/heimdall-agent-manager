package taskv2

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import fleet "odin_test:hub/service/fleet_settings"
import provider "odin_test:hub/service/provider"

@(test)
test_shared_fleet_resolution_dispatch_pins_and_legacy_transition :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "shared_fleet")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "shared_chain_1")
	other := seed_live_chain(t, fx, "shared_chain_2")
	seed_bridge(fx, "br_2")
	seed_fleet(fx, chain, "agt_w"); seed_fleet(fx, other, "agt_w")
	s := agent.fleet_service(&log.service)
	legacy := domain.Task_Chain_Fleet{agent_id="agt_w", provider="claude", model="claude-fable-5-1", bridge_id="br_1"}
	before, e := fleet.resolve(&s, "u1", "br_1", "agt_w", fleet.legacy_runtime(legacy, "br_1"))
	testing.expect(t, e.code == .None && before.source == "legacy" && before.runtime.model == "claude-fable-5-1")
	domain.fleet_runtime_destroy(before.runtime)
	draft := domain.Fleet_Settings_Draft{default_runtime={"claude","claude","claude-sonnet-5-5"}, overrides={{"agt_w", {"claude","claude","claude-opus-5-5"}}}}
	settings, changed, se := fleet.save(&s, "u1", "br_1", draft)
	if !testing.expect(t, changed && se.code == .None, se.message) do return
	defer domain.fleet_settings_destroy(settings)
	for c in ([]domain.Task_Chain{chain, other}) {
		ctx, loaded, err := load_match_context(&fx.svc, c)
		if !testing.expect(t, loaded && err.code == .None) do continue
		p, placed := resolve_placement(&ctx, {}, legacy, true)
		testing.expect(t, placed && p.bridge_id == "br_1" && p.model == "claude-opus-5-5" && p.provider_profile == "claude", "same durable agent resolves identically across chains")
		pinned, placed2 := resolve_placement(&ctx, {bridge_id="br_2"}, legacy, true)
		testing.expect(t, placed2 && pinned.bridge_id == "br_2" && pinned.model == "claude-fable-5-1", "task bridge pin and unconfigured bridge legacy policy survive")
		review, placed3 := resolve_placement(&ctx, {bridge_id="br_2"}, legacy, false)
		testing.expect(t, placed3 && review.bridge_id == "br_1" && review.model == "claude-opus-5-5", "reviewer bridge placement contract is unchanged")
		destroy_match_context(&ctx)
	}
	defaulted, de := fleet.resolve(&s, "u1", "br_1", "agt_coord", fleet.legacy_runtime(legacy, "br_1"))
	testing.expect(t, de.code == .None && defaulted.source == "bridge_default" && defaulted.runtime.model == "claude-sonnet-5-5")
	domain.fleet_runtime_destroy(defaulted.runtime)
	after := legacy; after.model = "claude-opus-5-5"
	conflict := fleet.guard_legacy_write(&s, "u1", legacy, after)
	testing.expect(t, conflict.code == .Conflict && strings.contains(conflict.details_json, "fleet_runtime_managed"))
	after = legacy; after.capacity = 9; after.roles_json = `["worker","reviewer"]`; after.paused_roles_json = `["reviewer"]`
	testing.expect(t, fleet.guard_legacy_write(&s, "u1", legacy, after).code == .None, "staffing and pause changes remain valid")
	// Saving the complete snapshot removed the override; subsequent dispatch
	// inherits the default without new startup traffic or an agent-side fetch.
	draft.expected_revision = 1; draft.overrides = nil
	next, _, ne := fleet.save(&s, "u1", "br_1", draft)
	testing.expect_value(t, ne.code, domain.Error_Code.None); domain.fleet_settings_destroy(next)
	seed_instance(fx, chain, "shared_worker", "agt_w", "br_1", "stopped")
	_ = publish_task(t, fx, chain, "shared_task", brief=`{"goal":"g","assignee":"agt_w","review_roles":[]}`)
	l, held := lease_of(fx, "shared_worker")
	testing.expect(t, held && l.provider == "claude" && l.model == "claude-sonnet-5-5" && l.provider_profile == "claude", "dispatch history uses current shared settings")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "shared_worker")
	testing.expect_value(t, inst.model, "claude-sonnet-5-5")
}

@(test)
test_shared_fleet_validates_actual_profile_model_and_agent_support :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "shared_fleet_validation")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "shared_validation_chain")
	seed_fleet(fx, chain, "agt_w")
	s := agent.fleet_service(&log.service)
	draft := domain.Fleet_Settings_Draft{default_runtime={"claude","missing-profile","claude-opus-5-5"}}
	_, _, err := fleet.save(&s, "u1", "br_1", draft)
	testing.expect(t, err.code == .Unprocessable_Entity && strings.contains(err.details_json, "fleet_selection_unavailable"))
	draft.default_runtime.provider_profile = "claude"; draft.default_runtime.model = "unknown-model"
	_, _, err = fleet.save(&s, "u1", "br_1", draft)
	testing.expect_value(t, err.code, domain.Error_Code.Unprocessable_Entity)
	draft.default_runtime.model = "claude-opus-5-5"
	draft.overrides = {{"foreign", draft.default_runtime}}
	_, _, err = fleet.save(&s, "u1", "br_1", draft)
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)
	draft.overrides = nil
	_, _, err = fleet.save(&s, "other", "br_1", draft)
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)
	_, _, _ = iface.agent_save_support(&fx.agents, {agent_id="agt_w", bridge_id="br_1", owner_user_id="u1", enabled=false, created_at="now", updated_at="now"})
	draft.overrides = {{"agt_w", draft.default_runtime}}
	_, _, err = fleet.save(&s, "u1", "br_1", draft)
	testing.expect_value(t, err.code, domain.Error_Code.Unprocessable_Entity)
	snapshot, _ := iface.fleet_settings_get(&fx.bridges, "u1", "br_1")
	testing.expect(t, snapshot.revision == 0, "invalid snapshots cannot establish authority")
	domain.fleet_settings_destroy(snapshot)
	// A recorded, enabled custom account profile is distinct from the driver's
	// default account and survives validation, storage and launch resolution.
	ps := provider.Provider_Service{repo=log.service.providers}
	pe := provider.apply_profiles_report(&ps, "br_1", {{profile_id="claude_work", provider="claude", enabled=true, state="ok"}})
	testing.expect_value(t, pe.code, domain.Error_Code.None)
	_, _ = iface.bridge_provider_status_upsert(log.service.providers, {bridge_id="br_1", provider="claude", profile_id="claude_work", state="present"})
	_, _ = iface.bridge_provider_setting_upsert(log.service.providers, {bridge_id="br_1", provider="claude", profile_id="claude_work", enabled=true})
	draft.overrides = nil; draft.default_runtime.provider_profile = "claude_work"
	profiled, did_save, profile_err := fleet.save(&s, "u1", "br_1", draft)
	testing.expect(t, did_save && profile_err.code == .None, profile_err.message)
	testing.expect_value(t, profiled.default_runtime.provider_profile, "claude_work")
	domain.fleet_settings_destroy(profiled)
	resolved, re := fleet.resolve(&s, "u1", "br_1", "agt_c", {})
	testing.expect(t, re.code == .None && resolved.runtime.provider_profile == "claude_work")
	domain.fleet_runtime_destroy(resolved.runtime)
}

@(test)
test_shared_fleet_new_coordinator_and_manual_start_boundary :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "shared_fleet_start")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "shared_start_chain")
	seed_fleet(fx, chain, "agt_w")
	s := agent.fleet_service(&log.service)
	snapshot, _, err := fleet.save(&s, "u1", "br_1", {default_runtime={"claude","claude","claude-sonnet-5-5"}})
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
	domain.fleet_settings_destroy(snapshot)
	auth := contracts.Auth_Context{kind=.Internal_User, user_id="u1"}
	for scope in ([]string{"chain", "manual", "excluded"}) {
		inst, created, e := agent.create_instance_stopped(&log.service, auth, {fleet_scope=scope, agent_id="agt_w", bridge_id="br_1", provider="claude", model="claude-fable-5-1", member_role="coordinator"})
		if !testing.expect(t, created && e.code == .None, e.message) do continue
		testing.expect_value(t, inst.model, "claude-sonnet-5-5" if scope == "chain" else "claude-fable-5-1")
		included, ce := iface.fleet_scope_get(&fx.bridges, inst)
		testing.expect(t, ce.code == .None && included == (scope == "chain"), "new empty task coordinator is distinguished from a manual conversation")
		ticket, start_err := agent.start_begin(&log.service, auth, inst.agent_instance_id, {})
		if testing.expect_value(t, start_err.code, domain.Error_Code.None) {
			testing.expect_value(t, ticket.instance.model, "claude-sonnet-5-5" if scope == "chain" else "claude-fable-5-1")
			command := agent.start_launch_json(&log.service, ticket)
			testing.expect(t, strings.contains(command, ticket.instance.model) && strings.contains(command, `"provider_profile":"claude"`), "existing launch command carries the resolved runtime")
			delete(command)
			agent.start_cancel(&log.service, &ticket)
			agent.start_ticket_destroy(&ticket)
		}
	}
}

@(test)
test_shared_fleet_excluded_claim_preserves_runtime_and_manual_claim_promotes :: proc(t: ^testing.T) {
	for scope in ([]string{"excluded", "manual"}) {
		fx, log, ok := lease_fixture(t, strings.concatenate({"shared_claim_", scope}, context.temp_allocator))
		if !ok {lease_fixture_close(fx, log); continue}
		chain := seed_live_chain(t, fx, "shared_claim")
		inst := seed_instance(fx, chain, "shared_claimant", "agt_w", "br_1", "stopped")
		testing.expect_value(t, iface.fleet_scope_set(&fx.bridges, inst, scope).code, domain.Error_Code.None)
		s := agent.fleet_service(&log.service)
		snapshot, _, e := fleet.save(&s, "u1", "br_1", {default_runtime={"claude","claude","claude-sonnet-5-5"}})
		testing.expect_value(t, e.code, domain.Error_Code.None); domain.fleet_settings_destroy(snapshot)
		// No fleet row: an explicit eligible claim remains the orchestration path.
		task := publish_task(t, fx, chain, "shared_claim_task", brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
		lease, granted, ge := t25_grant(t, fx, chain, task, inst)
		testing.expect(t, granted && ge.code == .None, ge.message)
		if granted {
			testing.expect_value(t, lease.model, "claude-opus-5-5" if scope == "excluded" else "claude-sonnet-5-5")
			current, _, _ := iface.agent_get_instance(&fx.agents, inst.agent_instance_id)
			included, ce := iface.fleet_scope_get(&fx.bridges, current)
			testing.expect(t, ce.code == .None && included == (scope == "manual"), "explicit excluded origins keep their eligible claim without Fleet promotion")
		}
		lease_fixture_close(fx, log)
	}
}
