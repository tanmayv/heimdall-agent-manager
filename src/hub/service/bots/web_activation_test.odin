package bots

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"

Activation_Fixture :: struct {
	pair: ^Pairing_Fixture,
	placement: ^Placement_Fixture,
	agent_repo: sqlite.Agent_Repo_SQLite,
	content_repo: sqlite.Content_Repo_SQLite,
	task_repo: sqlite.Taskchain_Repo_SQLite,
	repos: iface.Repositories,
	agent: agent.Agent_Service,
	ids: platform.ID_Generator,
	stops: int,
	stop_after_activation: bool,
}

activation_stop_sink :: proc(raw: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	f := (^Activation_Fixture)(raw)
	state, found, _ := iface.bot_web_activation_get(&f.repos.bots, "alice")
	defer domain.bot_web_activation_destroy(&state)
	if strings.contains(cmd.body_json,"inst_legacy") && strings.contains(cmd.body_json,"bot_cutover") {
		f.stops += 1
		f.stop_after_activation = found && state.enabled && state.agent_instance_id != "inst_legacy"
	}
	return true, {}
}

activation_fixture_open :: proc(t: ^testing.T, f: ^Activation_Fixture, existing: bool) {
	f.pair = pairing_fixture(t)
	f.placement = placement_fixture()
	f.repos.bots = f.pair.repo
	f.repos.agents = sqlite.new_agent_repository(&f.agent_repo, &f.pair.conn)
	f.repos.content = sqlite.new_content_repository(&f.content_repo, &f.pair.conn)
	f.repos.taskchains = sqlite.new_taskchain_repository(&f.task_repo, &f.pair.conn)
	f.pair.uow = sqlite.new_unit_of_work_factory(&f.pair.uow_impl, &f.pair.conn, &f.repos)
	f.ids = platform.real_id_generator()
	f.agent = {
		agents=&f.repos.agents, content=&f.repos.content, taskchains=&f.repos.taskchains,
		bridges=&f.placement.bridge_repo, providers=&f.placement.provider_repo,
		bridge_runtime_registry=&f.placement.registry, clock=&f.pair.clock, ids=&f.ids,
		bridge_command_sink={ctx=f,send_runtime_command=activation_stop_sink},
	}
	s := &f.pair.service
	s.agents, s.bridges, s.providers, s.registry, s.ids = &f.agent, &f.placement.bridge_repo, &f.placement.providers, &f.placement.registry, &f.ids
	if !existing {
		testing.expect_value(t, iface.bot_delete(s.repo,"bot_a").code, domain.Error_Code.None)
		return
	}
	_, role_ok, role_err := iface.agent_save(&f.repos.agents, {
		agent_id="agt_a", owner_user_id="alice", name="Ninjy bot", slug="bot_a",
		template_id=domain.TEMPLATE_BOT_ID, state=.Active, created_at="now", updated_at="now",
	})
	testing.expect(t, role_ok, role_err.message)
	_, old_ok, old_err := iface.agent_save_instance(&f.repos.agents, {
		owner_user_id="alice", agent_id="agt_a", agent_instance_id="inst_legacy", bridge_id="b",
		runtime_status="running", conversation_id="chat_legacy", created_at="now", updated_at="now",
	})
	testing.expect(t, old_ok, old_err.message)
	_, conv_ok, conv_err := iface.content_save_conversation(&f.repos.content, {
		owner_user_id="alice", agent_id="agt_a", agent_instance_id="inst_legacy", conversation_id="chat_legacy",
		created_at="now", updated_at="now",
	})
	testing.expect(t, conv_ok, conv_err.message)
	_, msg_ok, msg_err := iface.content_save_message(&f.repos.content, {
		message_id="msg_legacy", owner_user_id="alice", conversation_id="chat_legacy",
		direction="user_to_agent", body="fixture legacy history", created_at="now",
	})
	testing.expect(t, msg_ok, msg_err.message)
	testing.expect_value(t, iface.bot_set_instance(s.repo,"bot_a","inst_legacy","now").code, domain.Error_Code.None)
	_, policy_err := iface.placement_replace(s.repo,"bot_a",0,{{bridge_id="b",provider="beta",model="m2",tier=.Preferred}}, "now")
	testing.expect_value(t, policy_err.code, domain.Error_Code.None)
}

activation_fixture_close :: proc(f: ^Activation_Fixture) {
	placement_fixture_destroy(f.placement)
	pairing_fixture_destroy(f.pair)
}

Activation_Race :: struct {
	svc: ^Bots_Service,
	barrier: ^sync.Barrier,
	activation: domain.Bot_Web_Activation,
	err: domain.Domain_Error,
}

activation_call :: proc(data: rawptr) {
	r := (^Activation_Race)(data)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	context.allocator = runtime.heap_allocator()
	_ = sync.barrier_wait(r.barrier)
	r.activation, r.err = set_web_activation(r.svc, "alice", true, 0)
}

@(test)
test_web_activation_race_creates_one_empty_chat_and_reenable_recovers_identity :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t, &f, true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	barrier: sync.Barrier
	sync.barrier_init(&barrier, 2)
	requests := [2]Activation_Race{{svc=s,barrier=&barrier},{svc=s,barrier=&barrier}}
	a := thread.create_and_start_with_data(&requests[0], activation_call)
	b := thread.create_and_start_with_data(&requests[1], activation_call)
	defer thread.destroy(a)
	defer thread.destroy(b)
	thread.join(a)
	thread.join(b)
	defer {
		context.allocator = runtime.heap_allocator()
		for &r in requests do domain.bot_web_activation_destroy(&r.activation)
	}
	for r in requests do if !testing.expect(t, r.err.code == .None, r.err.message) do return
	initial := requests[0].activation
	if !testing.expect(t, initial.enabled && initial.generation == 1 && initial.agent_instance_id != "inst_legacy" && initial.conversation_id != "chat_legacy", "new stopped identity") do return
	testing.expect_value(t, requests[1].activation, initial)
	testing.expect(t, f.stops == 1 && f.stop_after_activation, "old runtime stopped once, after the activation committed")

	all, _ := iface.agent_list_instances_by_owner(&f.repos.agents,"alice",20,"")
	testing.expect_value(t, len(all), 2)
	conversations, _ := iface.content_list_conversations(&f.repos.content,"alice",20,"")
	testing.expect_value(t, len(conversations), 2)
	inst, found, _ := iface.agent_get_instance(&f.repos.agents,initial.agent_instance_id)
	defer domain.agent_instance_destroy(&inst)
	canonical_role, has_role, _ := iface.agent_get(&f.repos.agents, inst.agent_id)
	testing.expect(t, has_role && canonical_role.agent_id != "agt_a" && canonical_role.template_id == domain.TEMPLATE_BOT_WEB_ID, "canonical web role does not change the legacy prompt")
	testing.expect(t, found && inst.runtime_status == "stopped" && inst.run_count == 0 && inst.model == "m2" && inst.provider == "beta", "ordinary stopped instance honors owner placement")
	chat, chat_found, _ := iface.content_get_conversation(&f.repos.content,initial.conversation_id)
	testing.expect(t, chat_found && chat.agent_instance_id == initial.agent_instance_id && chat.unread_count == 0 && chat.last_message_preview == "", "fresh conversation is bound and empty")
	rows, _ := iface.content_list_messages(&f.repos.content,initial.conversation_id,"alice",100,"")
	testing.expect_value(t, len(rows), 0)
	legacy, legacy_found, _ := iface.content_get_message(&f.repos.content,"msg_legacy")
	testing.expect(t, legacy_found && legacy.body == "fixture legacy history", "old history not imported or erased")
	_, written, _ := iface.content_save_message(&f.repos.content, {
		message_id="msg_fresh", owner_user_id="alice", conversation_id=initial.conversation_id,
		direction="user_to_agent", body="synthetic persisted fresh message", created_at="now",
	})
	testing.expect(t, written)

	off, off_err := set_web_activation(s,"alice",false,1)
	defer domain.bot_web_activation_destroy(&off)
	testing.expect(t, off_err.code == .None && !off.enabled && off.generation == 2)
	_, stale := set_web_activation(s,"alice",true,1)
	testing.expect_value(t, stale.code, domain.Error_Code.Conflict)
	testing.expect_value(t, bots_delete(s, {kind=.Internal_User, user_id="alice"}).code, domain.Error_Code.Conflict)
	on, on_err := set_web_activation(s,"alice",true,2)
	defer domain.bot_web_activation_destroy(&on)
	testing.expect(t, on_err.code == .None && on.enabled && on.generation == 3 && on.agent_instance_id == initial.agent_instance_id && on.conversation_id == initial.conversation_id, "re-enable resumes the same conversation")
	_, exists, _ := iface.content_get_message(&f.repos.content,"msg_fresh")
	testing.expect(t, exists, "fresh history survives toggles")
}

@(test)
test_web_activation_enforces_eligibility_and_rolls_back_unplaceable_owner :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t, &f, false)
	defer activation_fixture_close(&f)
	s := &f.pair.service

	_, denied := set_web_activation(s,"bob",true,0)
	testing.expect_value(t, denied.code, domain.experimental_feature_disabled_error(domain.BOTS_EXPERIMENT_KEY).code)
	ready := f.placement.bridges
	f.placement.bridges = nil
	_, unavailable := set_web_activation(s,"alice",true,0)
	testing.expect_value(t, unavailable.code, domain.Error_Code.Bridge_Offline)
	old, exists, _ := iface.bot_get_by_owner(s.repo,"alice")
	defer domain.bot_destroy(&old)
	roles, _ := iface.agent_list_by_owner(&f.repos.agents,"alice",20,"")
	testing.expect(t, !exists && len(roles) == 0, "no orphan bot or role after failed activation")

	f.placement.bridges = ready
	state, activated := set_web_activation(s,"alice",true,0)
	defer domain.bot_web_activation_destroy(&state)
	if !testing.expect(t, activated.code == .None, activated.message) do return
	testing.expect(t, state.enabled && state.generation == 1 && state.conversation_id != "")
	bot, bot_found, _ := iface.bot_get_by_owner(s.repo,"alice")
	defer domain.bot_destroy(&bot)
	role, role_found, _ := iface.agent_get(&f.repos.agents,bot.agent_id)
	testing.expect(t, bot_found && bot.agent_instance_id == "" && role_found && role.template_id == domain.TEMPLATE_BOT_WEB_ID, "new owner starts with canonical Ninjy role, no legacy instance")
	chat, chat_found, _ := iface.content_get_conversation(&f.repos.content,state.conversation_id)
	testing.expect(t, chat_found && chat.last_message_preview == "" && chat.unread_count == 0)
}

@(test)
test_web_bot_policy_fences_runtime_without_restricting_unrelated_instance :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t, &f, true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	f.agent.runtime_policy = {ctx=s,check=check_web_runtime_policy}
	state, activated := set_web_activation(s,"alice",true,0)
	defer domain.bot_web_activation_destroy(&state)
	if !testing.expect(t, activated.code == .None, activated.message) do return
	auth := contracts.Auth_Context{kind=.Internal_User,user_id="alice"}
	instance, found, _ := iface.agent_get_instance(&f.repos.agents,state.agent_instance_id)
	if !testing.expect(t, found) do return
	defer domain.agent_instance_destroy(&instance)
	// alpha/m1 is an ordinary eligible combination on this bridge, but not in
	// Alice's bot policy. The normal reconfiguration entry cannot bypass it.
	_, accepted, denied := agent.begin_instance_reconfiguration(&f.agent,auth,state.agent_instance_id,{
		bridge_id="b",provider="alpha",provider_profile="alpha",model="m1",
		expected_revision=instance.configuration_revision,idempotency_key="outside-policy",
	})
	testing.expect(t, !accepted && denied.code == .Forbidden && strings.contains(denied.details_json,"bot_placement_not_allowed"), denied.message)
	_, exists, _ := iface.instance_reconfiguration_get(&f.repos.agents,"alice",state.agent_instance_id,"outside-policy")
	testing.expect(t, !exists, "disallowed configuration cannot reserve a durable operation")
	_, allowed, allowed_err := agent.validate_pinned_provider_model(&f.agent,auth,instance,"beta","m2")
	testing.expect(t, allowed, allowed_err.message)
	legacy, legacy_found, _ := iface.agent_get_instance(&f.repos.agents,"inst_legacy")
	if !testing.expect(t, legacy_found) do return
	defer domain.agent_instance_destroy(&legacy)
	_, old_allowed, old_err := agent.validate_pinned_provider_model(&f.agent,auth,legacy,"alpha","m1")
	testing.expect(t, !old_allowed && strings.contains(old_err.details_json,"bot_generation_inactive"), "retired runtime cannot use shared restart paths")
	ordinary := legacy
	ordinary.agent_instance_id = "inst_unrelated"
	_, unrestricted, unrestricted_err := agent.validate_pinned_provider_model(&f.agent,auth,ordinary,"alpha","m1")
	testing.expect(t, unrestricted, unrestricted_err.message)

	// The fresh role has no bridge override of its own. Disabling the bridge
	// for the stored policy role must nevertheless exclude this destination.
	_, support_saved, support_err := iface.agent_save_support(&f.repos.agents,{
		agent_id="agt_a", owner_user_id="alice", bridge_id="b", enabled=false,
		created_at="now", updated_at="now",
	})
	if !testing.expect(t, support_saved, support_err.message) do return
	_, support_accepted, support_denied := agent.begin_instance_reconfiguration(&f.agent,auth,state.agent_instance_id,{
		bridge_id="b",provider="beta",provider_profile="beta",model="m2",
		expected_revision=instance.configuration_revision,idempotency_key="disabled-by-role",
	})
	testing.expect(t, !support_accepted && support_denied.code == .Provider_Unavailable, support_denied.message)
	_, support_op, _ := iface.instance_reconfiguration_get(&f.repos.agents,"alice",state.agent_instance_id,"disabled-by-role")
	testing.expect(t, !support_op, "explicit reconfiguration cannot bypass a disabled bridge")
	_, removed, _ := iface.agent_save_support(&f.repos.agents,{
		agent_id="agt_a", owner_user_id="alice", bridge_id="b", enabled=true,
		created_at="now", updated_at="now",
	})
	testing.expect(t, removed)

	off, off_err := set_web_activation(s,"alice",false,state.generation)
	defer domain.bot_web_activation_destroy(&off)
	if !testing.expect(t, off_err.code == .None, off_err.message) do return
	_, started_off, pause_err := agent.start_instance(&f.agent,auth,state.agent_instance_id,.User_Start)
	testing.expect(t, !started_off && strings.contains(pause_err.details_json,"bot_generation_inactive"), pause_err.message)
	on, on_err := set_web_activation(s,"alice",true,off.generation)
	defer domain.bot_web_activation_destroy(&on)
	if !testing.expect(t, on_err.code == .None, on_err.message) do return
	_, _ = iface.experiment_set(&f.pair.experiments,{owner_user_id="alice",key="bots",enabled=false,updated_at="now"})
	_, started_revoked, revoked_err := agent.start_instance(&f.agent,auth,state.agent_instance_id,.User_Start)
	testing.expect(t, !started_revoked && strings.contains(revoked_err.details_json,"experimental_feature_disabled"), revoked_err.message)
}
