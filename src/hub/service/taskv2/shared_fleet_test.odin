package taskv2

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import fleet "odin_test:hub/service/fleet_settings"
import provider "odin_test:hub/service/provider"
import sqlite "odin_test:hub/repository/sqlite"
import jsonx "odin_test:lib/jsonx"

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
	after = legacy; after.capacity = 9; after.paused = true
	testing.expect(t, fleet.guard_legacy_write(&s, "u1", legacy, after).code == .None, "staffing and pause changes remain valid")
	// Saving the complete snapshot removed the override; subsequent dispatch
	// inherits the default without new startup traffic or an agent-side fetch.
	draft.expected_revision = 1; draft.overrides = nil
	next, _, ne := fleet.save(&s, "u1", "br_1", draft)
	testing.expect_value(t, ne.code, domain.Error_Code.None); domain.fleet_settings_destroy(next)
	seed_instance(fx, chain, "shared_worker", "agt_w", "br_1", "stopped")
	_ = publish_task(t, fx, chain, "shared_task", brief=`{"goal":"g","assignee":"agt_w"}`)
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
		task := publish_task(t, fx, chain, "shared_claim_task", brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`)
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

shared_fleet_claim_policies :: proc(t: ^testing.T, log: ^Wake_Log) -> (domain.Fleet_Runtime, domain.Fleet_Runtime) {
	ps := provider.Provider_Service{repo=log.service.providers}
	e := provider.apply_profiles_report(&ps, "br_1", {
		{profile_id="claude_live", provider="claude", enabled=true, state="ok"},
		{profile_id="codex_work", provider="codex", enabled=true, state="ok"},
	})
	testing.expect_value(t, e.code, domain.Error_Code.None)
	for r in ([]domain.Fleet_Runtime{{"claude","claude_live","claude-opus-5-5"}, {"codex","codex_work",""}}) {
		_, _ = iface.bridge_provider_status_upsert(log.service.providers, {bridge_id="br_1", provider=r.provider, profile_id=r.provider_profile, state="present"})
		_, _ = iface.bridge_provider_setting_upsert(log.service.providers, {bridge_id="br_1", provider=r.provider, profile_id=r.provider_profile, enabled=true})
	}
	p, m := resolve_launch_model(&log.service, "br_1", "codex", "", "codex_work")
	testing.expect(t, p == "codex" && m != "", "recorded Codex profile has an available catalog model")
	delete(p)
	return {"claude","claude_live","claude-opus-5-5"}, {"codex","codex_work",m}
}

shared_fleet_expect_recorded_runtime :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, task: domain.Task, lease: domain.Task_Lease, inst: domain.Agent_Instance, actual: domain.Fleet_Runtime, pack_json: string = "") {
	testing.expect_value(t, lease.provider, actual.provider)
	testing.expect_value(t, lease.provider_profile, actual.provider_profile)
	testing.expect_value(t, lease.model, actual.model)
	history := last_event_payload(fx, string(task.task_id), EV_LEASE_GRANTED)
	testing.expect_value(t, jsonx.extract_string(history, "provider", "", true, context.temp_allocator), actual.provider)
	testing.expect_value(t, jsonx.extract_string(history, "provider_profile", "", true, context.temp_allocator), actual.provider_profile)
	testing.expect_value(t, jsonx.extract_string(history, "model", "", true, context.temp_allocator), actual.model)
	pack := pack_json
	if pack == "" do pack = build_pack_json(&fx.svc, chain, task, lease, inst)
	placement, found := jsonx.extract_raw_object(pack, "placement", true, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, jsonx.extract_string(placement, "provider", "", true, context.temp_allocator), actual.provider)
	testing.expect_value(t, jsonx.extract_string(placement, "provider_profile", "", true, context.temp_allocator), actual.provider_profile)
	testing.expect_value(t, jsonx.extract_string(placement, "model", "", true, context.temp_allocator), actual.model)
}

@(test)
test_shared_fleet_inline_and_coordinator_claim_keep_actual_runtime_across_relaunch :: proc(t: ^testing.T) {
	for solo in ([]bool{false, true}) {
		tag := "shared_inline_coord" if solo else "shared_inline_manual"
		fx, log, ok := lease_fixture(t, tag)
		if !ok {lease_fixture_close(fx, log); continue}
		chain := seed_live_chain(t, fx, "shared_inline")
		actual, desired := shared_fleet_claim_policies(t, log)
		s := agent.fleet_service(&log.service)
		snapshot, _, se := fleet.save(&s, "u1", "br_1", {default_runtime=desired})
		testing.expect_value(t, se.code, domain.Error_Code.None); domain.fleet_settings_destroy(snapshot)
		id := "inst_coord" if solo else "inline_manual"
		inst: domain.Agent_Instance
		task: domain.Task
		if solo {
			inst, _, _ = iface.agent_get_instance(&fx.agents, id)
			task = publish_coordinator_task(t, fx, chain, "shared_inline_task", brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_c","reviewers":["user"]}`)
		} else {
			task = publish_task(t, fx, chain, "shared_inline_task", brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`)
			seed_fleet(fx, chain, "agt_w")
			inst = seed_instance(fx, chain, id, "agt_w", "br_1", "running")
		}
		inst.provider, inst.provider_profile, inst.model = actual.provider, actual.provider_profile, actual.model
		inst, _, _ = iface.agent_save_instance(&fx.agents, inst)
		testing.expect_value(t, iface.fleet_scope_set(&fx.bridges, inst, "manual").code, domain.Error_Code.None)
		wake_log_reset(log)
		lease: domain.Task_Lease; pack: string; granted: bool; err: domain.Domain_Error
		if solo {
			result, rok, re := lease_next(&fx.svc, inst_auth(id), {})
			lease, pack, granted, err = result.lease, result.pack_json, rok && result.status == "granted", re
		} else {
			result, rok, re := lease_claim(&fx.svc, inst_auth(id), {task_id=task.task_id})
			lease, pack, granted, err = result.lease, result.pack_json, rok && result.status == "granted", re
		}
		testing.expect(t, granted && err.code == .None, err.message)
		if granted {
			current, _, _ := iface.agent_get_instance(&fx.agents, id)
			testing.expect(t, current.provider == actual.provider && current.provider_profile == actual.provider_profile && current.model == actual.model && current.run_count == inst.run_count && current.runtime_status == "running", "inline claim never changes the running process tuple/generation")
			testing.expect(t, len(log.cmds) == 0, "inline claim emits no restart/wake/stop")
			shared_fleet_expect_recorded_runtime(t, fx, chain, task, lease, current, actual, pack)
			included, ce := iface.fleet_scope_get(&fx.bridges, current)
			testing.expect(t, ce.code == .None && included, "eligible manual caller promotes transactionally")
			if solo do testing.expect(t, get_task(fx, string(task.task_id)).requires_user_approval, "the user review listed on the coordinator's task remains required")
			ticket, te := agent.start_begin(&log.service, {kind=.Internal_User,user_id="u1"}, id, {if_live=.Relaunch})
			testing.expect_value(t, te.code, domain.Error_Code.None)
			if te.code == .None {
				// N2: a relaunch keeps the instance's own runtime; only applying
				// Fleet settings reconfigures it (fleet_application).
				testing.expect(t, ticket.instance.provider == actual.provider && ticket.instance.provider_profile == actual.provider_profile && ticket.instance.model == actual.model, "a relaunch keeps the instance runtime")
				agent.start_cancel(&log.service, &ticket); agent.start_ticket_destroy(&ticket)
			}
		}
		delete(desired.model)
		lease_fixture_close(fx, log)
	}
}

@(test)
test_shared_fleet_excluded_bot_action_claims_ignore_conflicting_fleet_runtime :: proc(t: ^testing.T) {
	for origin in ([]string{"bot", "action"}) {
		for inline in ([]bool{false, true}) {
			tag := strings.concatenate({"shared_excluded_", origin, "_inline" if inline else "_wake"}, context.temp_allocator)
			fx, log, ok := lease_fixture(t, tag)
			if !ok {lease_fixture_close(fx, log); continue}
			chain := seed_live_chain(t, fx, "shared_excluded")
			actual, desired := shared_fleet_claim_policies(t, log)
			task := publish_task(t, fx, chain, "shared_excluded_task", brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`)
			seed_fleet(fx, chain, "agt_w")
			rows, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
			rows[0].provider, rows[0].provider_profile, rows[0].model = "claude", "claude", "claude-sonnet-5-5"
			_, _ = iface.taskchain_upsert_fleet(&fx.repo, rows[0])
			inst := seed_instance(fx, chain, "excluded_claimant", "agt_w", "br_1", "running" if inline else "stopped")
			inst.provider, inst.provider_profile, inst.model = actual.provider, actual.provider_profile, actual.model
			inst, _, _ = iface.agent_save_instance(&fx.agents, inst)
			testing.expect_value(t, iface.fleet_scope_set(&fx.bridges, inst, "excluded").code, domain.Error_Code.None)
			if origin == "bot" {
				testing.expect(t, sqlite.exec(&fx.conn, "INSERT INTO bots(bot_id,owner_user_id,agent_id,agent_instance_id,created_at,updated_at) VALUES('shared_bot','u1','agt_w','excluded_claimant','now','now');"))
			} else {
				testing.expect(t, sqlite.exec(&fx.conn, "INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,created_at,updated_at) VALUES('shared_action','u1','p','agent','now','now'); INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,target_instance_id,created_at) VALUES('shared_run','shared_action','trigger','u1','occurrence','test','queued','excluded_claimant','now');"))
			}
			s := agent.fleet_service(&log.service)
			snapshot, _, se := fleet.save(&s, "u1", "br_1", {default_runtime=desired})
			testing.expect_value(t, se.code, domain.Error_Code.None); domain.fleet_settings_destroy(snapshot)
			_, unauthorized, ue := lease_claim(&fx.svc, inst_auth("inst_coord"), {task_id=task.task_id})
			testing.expect(t, !unauthorized && ue.code == .Forbidden, "Fleet scope does not weaken durable-identity claim authorization")
			wake_log_reset(log)
			auth := inst_auth("excluded_claimant") if inline else inst_auth("inst_coord")
			result, granted, ge := lease_claim(&fx.svc, auth, {task_id=task.task_id,instance_id="excluded_claimant"})
			testing.expect(t, granted && ge.code == .None, ge.message)
			if granted {
				current, _, _ := iface.agent_get_instance(&fx.agents, inst.agent_instance_id)
				testing.expect(t, current.provider == actual.provider && current.provider_profile == actual.provider_profile && current.model == actual.model, "neither shared nor legacy chain policy replaces excluded runtime")
				scope, ce := iface.fleet_scope_classify(&fx.bridges, current)
				testing.expect(t, ce.code == .None && scope == .Excluded)
				shared_fleet_expect_recorded_runtime(t, fx, chain, task, result.lease, current, actual, result.pack_json)
				if inline {
					testing.expect(t, len(log.cmds) == 0 && current.run_count == inst.run_count, "excluded inline claim keeps its process")
				} else {
					testing.expect(t, current.run_count == inst.run_count + 1 && wake_log_has_run(log, inst.agent_instance_id), "excluded wake retains its existing launch permission")
					for cmd in log.cmds do testing.expect(t, !strings.contains(cmd.body_json, desired.model) && !strings.contains(cmd.body_json, "claude-sonnet-5-5"), "emitted launch uses only actual excluded runtime")
				}
			}
			delete(desired.model)
			lease_fixture_close(fx, log)
		}
	}
}

@(test)
test_shared_fleet_unavailable_policy_preserves_structural_diagnosis :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "shared_diagnosis")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "shared_diagnosis")
	seed_fleet(fx, chain, "agt_w", bridge_id="br_1")
	seed_bridge(fx, "br_2"); seed_directory(fx, chain, "other_workspace", "br_2")
	s := agent.fleet_service(&log.service)
	snapshot, _, se := fleet.save(&s, "u1", "br_1", {default_runtime={"claude","claude","claude-sonnet-5-5"}})
	if !testing.expect_value(t, se.code, domain.Error_Code.None) do return
	domain.fleet_settings_destroy(snapshot)
	_, _ = iface.bridge_provider_setting_upsert(log.service.providers, {bridge_id="br_1",provider="claude",enabled=false})
	ctx, loaded, ce := load_match_context(&fx.svc, chain)
	if !testing.expect(t, loaded && ce.code == .None) do return
	defer destroy_match_context(&ctx)
	f := domain.Task_Chain_Fleet{agent_id="agt_w",bridge_id="br_1"}
	p, resolved := resolve_placement(&ctx, {}, f, true)
	testing.expect(t, resolved && p.bridge_id == "br_1" && p.directory_id == "" && p.provider == "claude" && p.model == "claude-sonnet-5-5", "raw shared policy and bridge placement survive unavailable provider")
	set_bridge_status(fx, "br_1", false)
	reason, _ := placement_problem(&fx.svc, &ctx, p, resolved, "agt_w")
	testing.expect_value(t, reason, "bridge_offline")
	set_bridge_status(fx, "br_1", true)
	_, _, _ = iface.agent_save_support(&fx.agents, {agent_id="agt_w",bridge_id="br_1",owner_user_id="u1",enabled=false})
	reason, _ = placement_problem(&fx.svc, &ctx, p, resolved, "agt_w")
	testing.expect_value(t, reason, "bridge_ineligible")
	_, _, _ = iface.agent_save_support(&fx.agents, {agent_id="agt_w",bridge_id="br_1",owner_user_id="u1",enabled=true})
	reason, _ = placement_problem(&fx.svc, &ctx, p, resolved, "agt_w")
	testing.expect_value(t, reason, "workspace_missing")
	// Once structural placement is valid, explicit unavailable policy must fail.
	dirs := ctx.dirs
	ctx.dirs = nil
	defer ctx.dirs = dirs
	reason, _ = placement_problem(&fx.svc, &ctx, p, resolved, "agt_w")
	testing.expect_value(t, reason, "provider_ineligible")
	// Storage errors retain placement facts and surface after structural checks.
	p.runtime_error = domain.domain_error(.Internal_Error, "settings read failed")
	message: string
	reason, message = placement_problem(&fx.svc, &ctx, p, resolved, "agt_w")
	testing.expect(t, reason == "provider_ineligible" && message == "settings read failed")
	_, _ = iface.bridge_provider_setting_upsert(log.service.providers, {bridge_id="br_1",provider="claude",enabled=true})
	p.runtime_error = {}
	reason, _ = placement_problem(&fx.svc, &ctx, p, resolved, "agt_w")
	testing.expect_value(t, reason, "")
}
