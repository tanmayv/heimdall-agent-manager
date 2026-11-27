package actions
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import provider "odin_test:hub/service/provider"
import provider_service "odin_test:hub/service/provider"
import placement "odin_test:hub/service/placement"
Action_Placement_Fixture :: struct {
 action:^Action_Test,allocator:mem.Allocator,existing:map[string]string,created:int,
 last_bridge,last_provider,last_model,stopped:string,stop_after_commit:bool,
	service:                                                  placement.Service,
	providers:                                                provider_service.Provider_Service,
	provider_repo:                                            iface.Provider_Repository,
	bridge_repo:                                              iface.Bridge_Repository,
	agent_repo:                                               iface.Agent_Repository,
	registry:                                                 project_service.Bridge_Runtime_Registry,
	policy:                                                   []domain.Bot_Placement_Candidate,
	attempts:                                                 []domain.Bot_Delivery_Attempt,
	sticky:                                                   string,
	bridges:                                                  []domain.Bridge,
	models:                                                   []domain.Bridge_Provider_Models,
	provider_ids:                                             []string,
	disabled, inactive, absent, not_detected, inactive_model: bool,
}
action_place_clone :: proc(value: $T) -> T {
	data, _ := json.marshal(value, allocator = context.temp_allocator)
	result: T
	assert(json.unmarshal(data, &result) == nil)
	return result
}
action_place_provider_ids :: proc(ctx: rawptr) -> []string {
	f := (^Action_Placement_Fixture)(ctx)
	if len(f.provider_ids) > 0 do return f.provider_ids
	ids := make([]string, 2, context.temp_allocator)
	ids[0], ids[1] = "alpha", "beta"
	return ids
}
action_place_catalog_get :: proc(ctx: rawptr, id: string) -> (domain.Provider_Catalog_Entry, bool, domain.Domain_Error) {
	known := false
	for provider in action_place_provider_ids(ctx) do if provider == id do known = true
	if !known do return {}, false, {}
	entry := domain.Provider_Catalog_Entry {
		provider = strings.clone(id),
		state    = strings.clone("deprecated" if (^Action_Placement_Fixture)(ctx).inactive else "active"),
		models   = make([dynamic]domain.Provider_Model),
	}
	for model in ([]string{"old", "m1", "m2", "m3", "m4"}) do append(&entry.models, domain.Provider_Model{model_id = strings.clone(model), state = strings.clone("deprecated" if model == "old" || (^Action_Placement_Fixture)(ctx).inactive_model else "active")})
	return entry, true, {}
}
action_place_catalog_list :: proc(ctx: rawptr) -> ([dynamic]domain.Provider_Catalog_Entry, domain.Domain_Error) {
	out := make([dynamic]domain.Provider_Catalog_Entry)
	for id in action_place_provider_ids(ctx) {entry, _, _ := action_place_catalog_get(ctx, id); append(&out, entry)}
	return out, {}
}
action_place_statuses :: proc(
	ctx: rawptr,
	bridge: string,
) -> (
	[dynamic]domain.Bridge_Provider_Status,
	domain.Domain_Error,
) {
	out := make([dynamic]domain.Bridge_Provider_Status)
	for id in action_place_provider_ids(ctx) do append(&out, domain.Bridge_Provider_Status{provider = strings.clone(id), state = strings.clone("missing" if (^Action_Placement_Fixture)(ctx).not_detected else "present")})
	return out, {}
}
// Production settings default to PTY when no transport override is stored.
action_place_transport :: proc(ctx: rawptr, bridge, provider, profile: string) -> (string, domain.Domain_Error) {return "", {}}
action_place_settings :: proc(
	ctx: rawptr,
	bridge: string,
) -> (
	[dynamic]domain.Bridge_Provider_Setting,
	domain.Domain_Error,
) {
	if !(^Action_Placement_Fixture)(ctx).absent do return nil, {}
	out := make([dynamic]domain.Bridge_Provider_Setting)
	append(
		&out,
		domain.Bridge_Provider_Setting {
			provider = strings.clone("alpha"),
			profile_id = strings.clone("alpha"),
			enabled = false,
		},
	)
	return out, {}
}
action_place_models :: proc(
	ctx: rawptr,
	bridge: string,
) -> (
	[dynamic]domain.Bridge_Provider_Models,
	domain.Domain_Error,
) {
	out := make([dynamic]domain.Bridge_Provider_Models)
	for row in (^Action_Placement_Fixture)(ctx).models do if row.bridge_id == bridge do append(&out, action_place_clone(row))
	return out, {}
}
action_place_bridge_list :: proc(
	ctx: rawptr,
	owner: domain.User_ID,
) -> (
	[]domain.Bridge,
	domain.Domain_Error,
) {return action_place_clone((^Action_Placement_Fixture)(ctx).bridges), {}}
action_place_bridge_get :: proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	for b in (^Action_Placement_Fixture)(ctx).bridges do if b.bridge_id == id do return action_place_clone(b), true, {}
	return {}, false, {}
}
action_place_policy :: proc(
	ctx: rawptr,
	bot: string,
) -> (
	[]domain.Bot_Placement_Candidate,
	domain.Domain_Error,
) {return action_place_clone((^Action_Placement_Fixture)(ctx).policy), {}}
action_place_attempts :: proc(
	ctx: rawptr,
	delivery: string,
) -> (
	[]domain.Bot_Delivery_Attempt,
	domain.Domain_Error,
) {return action_place_clone((^Action_Placement_Fixture)(ctx).attempts), {}}
action_place_instance :: proc(
	ctx: rawptr,
	id: string,
) -> (
	domain.Agent_Instance,
	bool,
	domain.Domain_Error,
) {return domain.Agent_Instance{bridge_id = strings.clone((^Action_Placement_Fixture)(ctx).sticky)}, true, {}}

action_place_support :: proc(
	ctx: rawptr,
	agent, bridge: string,
) -> (
	domain.Agent_Bridge_Support,
	bool,
	domain.Domain_Error,
) {
	if !(^Action_Placement_Fixture)(ctx).disabled do return {}, false, {}
	return domain.Agent_Bridge_Support{enabled = false}, true, {}
}
action_place_fixture :: proc() -> ^Action_Placement_Fixture {
	f := new(Action_Placement_Fixture)
 f.allocator=context.allocator
	f.provider_repo = {
		ctx                    = f,
		list                   = action_place_catalog_list,
		get                    = action_place_catalog_get,
		list_status            = action_place_statuses,
		list_settings          = action_place_settings,
		list_models            = action_place_models,
		get_provider_transport = action_place_transport,
	}
	f.providers.repo = &f.provider_repo
	f.bridge_repo = {
		ctx           = f,
		get_bridge    = action_place_bridge_get,
		list_by_owner = action_place_bridge_list,
	}
	f.agent_repo = {
		ctx         = f,
		get_support = action_place_support,
	}
	f.service = {
		bridges   = &f.bridge_repo,
		agents    = &f.agent_repo,
		providers = &f.providers,
		registry  = &f.registry,
	}
	f.bridges = make([]domain.Bridge, 1, context.temp_allocator)
	f.bridges[0] = {
		bridge_id         = "b",
		owner_user_id     = "alice",
		status            = .Online,
		created_at        = "1",
		capabilities_json = `{"features":["x"]}`,
	}
	assert(project_service.bridge_runtime_registry_mark_live(&f.registry, "b", false, ""))
	return f
}
action_place_fixture_destroy :: proc(f: ^Action_Placement_Fixture) {project_service.bridge_runtime_registry_destroy(&f.registry)
	free(f)}

// Placement tests use the real placement module and fake row-only agent ports.
routing_place_setup :: proc(t:^testing.T,f:^Action_Test)->^Action_Placement_Fixture {
 p:=action_place_fixture()
 p.bridges=make([]domain.Bridge,2,context.temp_allocator)
 for &bridge,i in p.bridges {
  bridge={bridge_id=fmt.tprintf("bridge%d",i+1),owner_user_id="owner",status=.Online,created_at=fmt.tprintf("%d",i),
   capabilities_json=`{"features":["event_pipeline_v1"]}`}
  testing.expect(t,project_service.bridge_runtime_registry_mark_live(&p.registry,bridge.bridge_id,false,""))
 }
 p.action=f;p.existing=make(map[string]string)
 f.runtime.router.placement=&p.service
 f.runtime.router.agents.ctx=p;f.runtime.router.agents.find=routing_place_find;f.runtime.router.agents.create=routing_place_create
 f.runtime.router.agents.stop=routing_place_stop;f.runtime.router.agents.instance=routing_place_instance
 f.runtime.router.agents.persist_prompt=routing_place_persist;f.runtime.router.agents.retire_prompt=routing_place_retire
 f.pipeline.bridges=&p.bridge_repo
 a,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 a.target_kind=domain.ACTION_TARGET_AGENT;a.target_agent_id="agent";a.instance_strategy="reuse";a.placement_selector="first"
 _=f.repos.actions.save(f.repos.actions.ctx,a)
 _=f.repos.actions.rules_replace(f.repos.actions.ctx,"action",[]domain.Action_Target_Rule{{0,"bridge1","alpha","m1"},{1,"bridge2","alpha","m1"}})
 return p
}
routing_place_plan :: proc(f:^Action_Test)->Plan {
 a,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 return prompt_plan(&f.runtime.router,a,{},nil)
}
routing_place_find :: proc(ctx:rawptr,owner,agent,project,prefer:string,c:placement.Candidate)->(string,string,bool) {
 p:=(^Action_Placement_Fixture)(ctx)
 id,found:=p.existing[c.bridge_id]
 return id,"conversation",found
}
routing_place_create :: proc(ctx:rawptr,owner,agent,project:string,c:placement.Candidate)->(string,string,domain.Domain_Error) {
 p:=(^Action_Placement_Fixture)(ctx)
 p.created+=1
 p.last_bridge=strings.clone(c.bridge_id,p.allocator)
 p.last_provider=strings.clone(c.provider,p.allocator);p.last_model=strings.clone(c.model,p.allocator)
 id:=fmt.tprintf("created%d",p.created)
 id=strings.clone(id,p.allocator)
 p.existing[strings.clone(c.bridge_id,p.allocator)]=id
 conversation:=fmt.tprintf("conversation%d",p.created)
 _,_,err:=iface.content_save_conversation(&p.action.repos.content,{conversation_id=conversation,owner_user_id=domain.User_ID(owner),agent_instance_id=id,agent_id=agent})
 return id,conversation,err
}
routing_place_stop :: proc(ctx:rawptr,owner,id:string) {
 p:=(^Action_Placement_Fixture)(ctx)
 p.stopped=strings.clone(id,p.allocator)
 run,found,_:=p.action.repos.actions.run_open(p.action.repos.actions.ctx,"action")
 p.stop_after_commit=found && run.state==domain.ACTION_RUN_ROUTED
}
routing_place_instance :: proc(ctx:rawptr,owner,id:string)->(string,string,string,bool) {
 p:=(^Action_Placement_Fixture)(ctx)
 return "agent","bridge1","conversation",id!="missing"
}
routing_place_persist :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,cid,body,metadata:string)->(string,domain.Domain_Error) {
 return action_test_persist((^Action_Placement_Fixture)(ctx).action,uow,owner,cid,body,metadata)
}
routing_place_retire :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,id,moved:string)->domain.Domain_Error {
 p:=(^Action_Placement_Fixture)(ctx)
 repo:=&uow.repos.content
 message,found,err:=iface.content_get_message(repo,id)
 if err.code!=.None do return err
 if !found do return domain.domain_error(.Not_Found,"prompt gone")
 metadata:=test_config(message.metadata_json)
 metadata["moved_to_instance_id"]=moved
 data,_:=json.marshal(metadata,allocator=context.temp_allocator)
 _,_,err=iface.content_update_message(repo,domain.User_ID(owner),message.conversation_id,id,message.body,message.message_status,string(data))
 if err.code!=.None do return err
 ids:=[1]string{id}
 _,err=iface.content_mark_messages_read(repo,domain.User_ID(owner),ids[:],platform.clock_now(&p.action.clock))
 if err.code!=.None do return err
 if p.action.fail_retire do return domain.domain_error(.Internal_Error,"injected retirement failure")
 return {}
}
place_first :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 plan:=routing_place_plan(f)
 testing.expect(t,plan.ok && plan.rule_position==0 && plan.bridge_id=="bridge1")
}
place_second :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 p.bridges[0].status=.Offline
 plan:=routing_place_plan(f)
 testing.expect(t,plan.ok && plan.rule_position==1 && plan.bridge_id=="bridge2")
}
place_any :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 _=f.repos.actions.rules_replace(f.repos.actions.ctx,"action",[]domain.Action_Target_Rule{{0,"*","*","*"}})
 plan:=routing_place_plan(f)
 testing.expect(t,plan.ok && plan.bridge_id=="bridge1" && p.last_provider=="alpha" && p.last_model=="m1")
}
place_model_any :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 _=f.repos.actions.rules_replace(f.repos.actions.ctx,"action",[]domain.Action_Target_Rule{{0,"bridge1","beta","*"}})
 plan:=routing_place_plan(f)
 testing.expect(t,plan.ok && p.last_provider=="beta" && p.last_model=="m1")
}
place_feature :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 p.bridges[0].capabilities_json=`{"features":[]}`
 plan:=routing_place_plan(f);testing.expect(t,plan.ok && plan.bridge_id=="bridge2")
 p.bridges[1].capabilities_json=`{"features":[]}`
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f)
 testing.expect(t,len(rows)==1 && rows[0].state=="failed" && rows[0].reason=="bridge_too_old")
}
place_pinned :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 p.bridges[0].status=.Offline
 _=f.repos.actions.rules_replace(f.repos.actions.ctx,"action",[]domain.Action_Target_Rule{{0,"bridge1","alpha","m1"}})
 p.existing["bridge1"]="existing"
 plan:=routing_place_plan(f)
 testing.expect(t,plan.ok)
 testing.expect_value(t,plan.bridge_id,"bridge1")
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
 testing.expect_value(t,p.created,0)
 delete_key(&p.existing,"bridge1")
 plan=routing_place_plan(f);testing.expect(t,!plan.ok && plan.reason=="no_placement")
}
place_reuse :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 p.existing["bridge1"]="existing"
 plan:=routing_place_plan(f);testing.expect(t,plan.ok && plan.instance_id=="existing" && !plan.spawned && p.created==0)
 delete_key(&p.existing,"bridge1")
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 testing.expect(t,p.created==1 && string(action.last_spawned_instance_id)=="created1")
}
place_rule_priority :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 p.existing["bridge2"]="running"
 plan:=routing_place_plan(f)
 testing.expect(t,plan.ok && plan.bridge_id=="bridge1" && plan.spawned && p.created==1)
}
place_fresh :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 action.instance_strategy="fresh_per_run";action.last_spawned_instance_id="previous"
 _=f.repos.actions.save(f.repos.actions.ctx,action)
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 testing.expect(t,p.created==1 && p.stopped=="previous" && p.stop_after_commit)
 action_test_done(t,f);f.now_ms+=31000;action_test_match(t,f,"two");drain_due(&f.runtime.router)
 testing.expect(t,p.created==2 && p.stopped=="created1" && p.stop_after_commit)
}
place_none :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 p.bridges[0].status=.Offline;p.bridges[1].status=.Offline
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f)
 testing.expect(t,len(rows)==1 && rows[0].state=="failed" && rows[0].reason=="no_placement")
}
place_instance :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action");action.target_kind=domain.ACTION_TARGET_INSTANCE;action.target_instance_id="missing"
 _=f.repos.actions.save(f.repos.actions.ctx,action)
 plan:=routing_place_plan(f);testing.expect(t,!plan.ok && plan.reason=="target_missing")
 action.target_instance_id="instance";_=f.repos.actions.save(f.repos.actions.ctx,action)
 p.bridges[0].status=.Offline
 plan=routing_place_plan(f);testing.expect(t,plan.ok && plan.bridge_id=="bridge1")
 p.bridges[0].status=.Revoked
 plan=routing_place_plan(f);testing.expect(t,!plan.ok && plan.reason=="no_placement")
 p.bridges[0].status=.Online;p.bridges[0].capabilities_json=`{"features":[]}`
 plan=routing_place_plan(f);testing.expect(t,!plan.ok && plan.reason=="bridge_too_old")
}
replace_move :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 old,_,_:=action_test_delivery(f,run.delivery_id)
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 replaced,err:=on_delivery_replace(&f.runtime.router,&uow,old,.Bridge_Offline)
 testing.expect(t,replaced && err.code==.None)
 _,_=iface.unit_of_work_commit(&uow)
 moved,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,run.run_id)
 testing.expect(t,moved.state=="routed" && moved.delivery_id!=run.delivery_id && moved.target_instance_id!=run.target_instance_id && moved.started_at==run.started_at)
 d,_,_:=action_test_delivery(f,moved.delivery_id)
 testing.expect(t,d.round==1 && strings.contains(d.excluded_bridges_json,"bridge1") && d.bridge_id=="bridge2")
 message,_,_:=iface.content_get_message(&f.repos.content,old.message_id)
 testing.expect(t,message.read_at!="" && strings.contains(message.metadata_json,"moved_to_instance_id"))
}
replace_retire_error :: proc(t:^testing.T,f:^Action_Test) {
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action");old,_,_:=action_test_delivery(f,run.delivery_id)
 f.fail_retire=true
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 replaced,err:=on_delivery_replace(&f.runtime.router,&uow,old,.Bridge_Offline)
 testing.expect(t,!replaced && err.code!=.None);iface.unit_of_work_rollback(&uow)
 current,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,run.run_id)
 testing.expect_value(t,current.delivery_id,old.delivery_id)
 message,_,_:=iface.content_get_message(&f.repos.content,old.message_id)
 testing.expect(t,message.read_at=="" && !strings.contains(message.metadata_json,"moved_to_instance_id"))
 rows,e:=iface.content_list_messages(&f.repos.content,"conversation2","owner",20,"")
 testing.expect(t,e.code==.None && len(rows)==0)
 f.fail_retire=false
 uow,ok,_=iface.unit_of_work_begin(&f.factory);assert(ok)
 replaced,err=on_delivery_replace(&f.runtime.router,&uow,old,.Bridge_Offline)
 testing.expect(t,replaced && err.code==.None);_,_=iface.unit_of_work_commit(&uow)
}
@(test)
test_place_first_rule :: proc(t:^testing.T) {action_test_case(t,place_first)}
@(test)
test_place_falls_to_second_rule :: proc(t:^testing.T) {action_test_case(t,place_second)}
@(test)
test_place_any_bridge_uses_module_order :: proc(t:^testing.T) {action_test_case(t,place_any)}
@(test)
test_place_provider_any_model :: proc(t:^testing.T) {action_test_case(t,place_model_any)}
@(test)
test_place_requires_pipeline_feature :: proc(t:^testing.T) {action_test_case(t,place_feature)}
@(test)
test_place_pinned_offline_machine_waits :: proc(t:^testing.T) {action_test_case(t,place_pinned)}
@(test)
test_reuse_finds_or_creates :: proc(t:^testing.T) {action_test_case(t,place_reuse)}
@(test)
test_reuse_rule_one_beats_running_instance_on_rule_two :: proc(t:^testing.T) {action_test_case(t,place_rule_priority)}
@(test)
test_reuse_user_stopped_instance_is_used :: proc(t:^testing.T) {action_test_case(t,place_reuse)}
@(test)
test_reuse_failed_or_unreachable_instance_is_used :: proc(t:^testing.T) {action_test_case(t,place_reuse)}
@(test)
test_fresh_per_run_stops_previous :: proc(t:^testing.T) {action_test_case(t,place_fresh)}
@(test)
test_no_placement :: proc(t:^testing.T) {action_test_case(t,place_none)}
@(test)
test_instance_target_missing_and_offline :: proc(t:^testing.T) {action_test_case(t,place_instance)}
@(test)
test_replace_moves_prompt_to_next_rule :: proc(t:^testing.T) {action_test_case(t,replace_move)}
@(test)
test_replace_retirement_error_rolls_back :: proc(t:^testing.T) {action_test_case(t,replace_retire_error)}

// T14: an explicitly pinned legacy machine must fail, never fall through.
old_bridge_pinned :: proc(t: ^testing.T, f: ^Action_Test) {
	p := routing_place_setup(t, f); defer action_place_fixture_destroy(p)
	p.bridges[0].capabilities_json = `{}`
	err := f.repos.actions.rules_replace(f.repos.actions.ctx, "action", []domain.Action_Target_Rule{{0, "bridge1", "alpha", "m1"}})
	testing.expect_value(t, err.code, domain.Error_Code.None)
	action_test_match(t, f, "legacy-pinned"); drain_due(&f.runtime.router)
	rows := action_test_rows(t, f)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].state, "failed")
		testing.expect_value(t, rows[0].reason, "bridge_too_old")
	}
	testing.expect_value(t, p.created, 0)
}
@(test)
test_old_bridge_is_not_a_candidate :: proc(t: ^testing.T) {action_test_case(t, old_bridge_pinned)}
