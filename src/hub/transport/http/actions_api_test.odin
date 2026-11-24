package http

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import actions "odin_test:hub/service/actions"
import delivery "odin_test:hub/service/delivery"
import platform "odin_test:hub/platform"
import placement "odin_test:hub/service/placement"
import provider "odin_test:hub/service/provider"

Action_API_Experiment :: struct {enabled:bool}
action_api_experiments :: proc(ctx:rawptr,owner:string) -> ([dynamic]domain.Experiment,domain.Domain_Error) {
	result:=make([dynamic]domain.Experiment)
	if (^Action_API_Experiment)(ctx).enabled do append(&result,domain.Experiment{owner_user_id=strings.clone(owner),key=strings.clone(domain.ACTIONS_EXPERIMENT_KEY),enabled=true})
	return result,{}
}
action_api_support :: proc(ctx:rawptr) -> int {return (cast(^int)ctx)^}
Action_API_Fixture :: struct {
	wire:^wire_fixture,
	service:actions.Service,
	handlers:Action_Handlers,
	repos:iface.Repositories,
}
action_api_test :: proc(t:^testing.T,scenario:proc(^testing.T,^Action_API_Fixture)) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	{
		// HTTP requests and authentication use an arena in production too.
		arena:virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		context.allocator=virtual.arena_allocator(&arena)
		action_api_scenario(t,scenario)
		virtual.arena_destroy(&arena)
	}
	testing.expect_value(t,len(track.allocation_map),0)
}
action_api_scenario :: proc(t:^testing.T,scenario:proc(^testing.T,^Action_API_Fixture)) {
	wire:=wire_setup(t,"actions_api")
	defer wire_teardown(wire)
	action_impl:sqlite.Action_Repo_SQLite
	outbox_impl:sqlite.Event_Outbox_Repo_SQLite
	f:=Action_API_Fixture{wire=wire}
	f.repos={actions=sqlite.new_action_repository(&action_impl,&wire.conn),
		event_outbox=sqlite.new_event_outbox_repository(&outbox_impl,&wire.conn),
		agents=wire.ag_repo,bridges=wire.br_repo,taskchains=wire.tc_repo}
	factory_impl:sqlite.SQLite_Unit_Of_Work_Factory
	factory:=sqlite.new_unit_of_work_factory(&factory_impl,&wire.conn,&f.repos)
	provider_impl:sqlite.Provider_Repo_SQLite
	provider_repo:=sqlite.new_provider_repository(&provider_impl,&wire.conn)
	providers:=provider.Provider_Service{repo=&provider_repo}
	place:=placement.new_service(&f.repos.bridges,&f.repos.agents,&providers,nil,{})
	defer placement.service_destroy(&place)
	exp_state:=Action_API_Experiment{enabled=true}
	exp:=iface.Experiment_Repository{ctx=&exp_state,list_by_owner=action_api_experiments}
	f.service={factory=&factory,repos=&f.repos,placement=&place,experiments=&exp,clock=&wire.clock,ids=&wire.ids,target_kinds={"agent","instance"}}
	f.handlers={auth=&wire.auth_svc,service=&f.service,experiments=&exp}
	scenario(t,&f)
}
action_api_request :: proc(f:^Action_API_Fixture,method,path,body:string) -> Request {return wire_cookie_request(f.wire,method,path,body)}
action_api_data :: proc(t:^testing.T,response:Response,status:=200) -> json.Object {
	if !testing.expect(t,response.status==status,response.body) do return nil
	value:json.Value
	if !testing.expect(t,json.unmarshal_string(response.body,&value,.JSON,context.temp_allocator)==nil) do return nil
	obj,_:=value.(json.Object)
	data,_:=obj["data"].(json.Object)
	return data
}
action_api_base_body :: proc(f:^Action_API_Fixture,triggers:="[]") -> string {
	return strings.concatenate({"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"instance\",\"instance_id\":\"",f.wire.instance_id,"\"},\"triggers\":",triggers,"}"},context.temp_allocator)
}
action_api_backlog :: proc(t:^testing.T,f:^Action_API_Fixture) -> i64 {
	uow,ok,_:=iface.unit_of_work_begin(f.service.factory)
	if !testing.expect(t,ok) do return -1
	defer iface.unit_of_work_rollback(&uow)
	count,err:=uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	return count
}
@(test)
test_actions_api_crud :: proc(t:^testing.T) {action_api_test(t,action_api_crud)}
action_api_crud :: proc(t:^testing.T,f:^Action_API_Fixture) {
	_,_,_ = iface.agent_save(&f.repos.agents,domain.Agent{agent_id="agt_api",owner_user_id=f.wire.owner,name="API",slug="api",state=.Active})
	body:=strings.concatenate({"{\"name\":\"API\",\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"agt_api\",\"rules\":[{\"bridge_id\":\"",f.wire.bridge_pin,"\",\"provider\":\"*\",\"model\":\"*\"},{\"bridge_id\":\"",f.wire.bridge_alt,"\",\"provider\":\"*\",\"model\":\"*\"}]},\"triggers\":[{\"kind\":\"schedule\",\"config\":{\"mode\":\"interval\",\"interval_s\":600}},{\"kind\":\"event\",\"config\":{\"event_type\":\"chain.state\"}}]}"},context.temp_allocator)
	created:=action_api_data(t,create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",body)),201)
	if created==nil do return
	id,_:=created["id"].(string)
	target,_:=created["target"].(json.Object)
	rules,_:=target["rules"].(json.Array)
	triggers,_:=created["triggers"].(json.Array)
	testing.expect_value(t,len(rules),2)
	if !testing.expect_value(t,len(triggers),2) do return
	testing.expect_value(t,target["selector"].(string),"first")
	testing.expect_value(t,target["instance_strategy"].(string),"reuse")
	first,_:=triggers[0].(json.Object)
	trigger_id,_:=first["id"].(string)
	path:=strings.concatenate({"/api/v1/actions/",id},context.temp_allocator)
	got:=action_api_data(t,get_action_handler(&f.handlers,action_api_request(f,"GET",path,"")))
	testing.expect_value(t,got["id"].(string),id)
	patch:=strings.concatenate({"{\"name\":\"replaced\",\"triggers\":[{\"id\":\"",trigger_id,"\",\"kind\":\"schedule\",\"config\":{\"mode\":\"interval\",\"interval_s\":900}},{\"kind\":\"event\",\"config\":{\"event_type\":\"chain.work_finished\"}}]}"},context.temp_allocator)
	updated:=action_api_data(t,patch_action_handler(&f.handlers,action_api_request(f,"PATCH",path,patch)))
	testing.expect_value(t,updated["name"].(string),"replaced")
	after,_:=updated["triggers"].(json.Array)
	testing.expect_value(t,len(after),2)
	retained:=false
	for entry in after {
		tr,_:=entry.(json.Object)
		if tr["id"].(string)==trigger_id {retained=true;testing.expect_value(t,tr["rev"].(json.Integer),json.Integer(2))}
	}
	testing.expect(t,retained)
	off:=action_api_data(t,disable_action_handler(&f.handlers,action_api_request(f,"POST",strings.concatenate({path,"/disable"},context.temp_allocator),"")))
	testing.expect_value(t,off["enabled"].(bool),false)
	on:=action_api_data(t,enable_action_handler(&f.handlers,action_api_request(f,"POST",strings.concatenate({path,"/enable"},context.temp_allocator),"")))
	testing.expect_value(t,on["enabled"].(bool),true)
	other_request:=action_api_request(f,"GET",path,"")
	other_request.headers=http_test_login(t,&f.wire.auth_svc,"actions_foreign")
	testing.expect_value(t,get_action_handler(&f.handlers,other_request).status,404)
	deleted:=action_api_data(t,delete_action_handler(&f.handlers,action_api_request(f,"DELETE",path,"")))
	testing.expect_value(t,deleted["deleted"].(bool),true)
	testing.expect_value(t,get_action_handler(&f.handlers,action_api_request(f,"GET",path,"")).status,404)
}
@(test)
test_actions_patch_trigger_kind_immutable :: proc(t:^testing.T) {action_api_test(t,action_api_kind_immutable)}
action_api_kind_immutable :: proc(t:^testing.T,f:^Action_API_Fixture) {
	body:=action_api_base_body(f,"[{\"kind\":\"schedule\",\"config\":{\"mode\":\"interval\",\"interval_s\":600}}]")
	created:=action_api_data(t,create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",body)),201)
	if created==nil do return
	id:=created["id"].(string)
	triggers:=created["triggers"].(json.Array)
	tr:=triggers[0].(json.Object)
	path:=strings.concatenate({"/api/v1/actions/",id},context.temp_allocator)
	before:=action_api_backlog(t,f)
	patch:=strings.concatenate({"{\"name\":\"bad\",\"enabled\":false,\"triggers\":[{\"id\":\"",tr["id"].(string),"\",\"kind\":\"event\",\"config\":{\"event_type\":\"chain.state\"}}]}"},context.temp_allocator)
	response:=patch_action_handler(&f.handlers,action_api_request(f,"PATCH",path,patch))
	testing.expect(t,response.status==422,response.body)
	testing.expect(t,strings.contains(response.body,"trigger_kind_immutable"))
	got:=action_api_data(t,get_action_handler(&f.handlers,action_api_request(f,"GET",path,"")))
	testing.expect_value(t,got["name"].(string),created["name"].(string))
	testing.expect_value(t,got["enabled"].(bool),true)
	got_triggers:=got["triggers"].(json.Array)
	got_tr:=got_triggers[0].(json.Object)
	testing.expect_value(t,got_tr["rev"].(json.Integer),json.Integer(1))
	testing.expect_value(t,got_tr["kind"].(string),"schedule")
	testing.expect_value(t,action_api_backlog(t,f),before)
}
@(test)
test_actions_api_bot_target_refused_in_phase_1 :: proc(t:^testing.T) {action_api_test(t,action_api_bot_target)}
action_api_bot_target :: proc(t:^testing.T,f:^Action_API_Fixture) {
	response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions","{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"bot\",\"bot_id\":\"bot_a\"}}"))
	testing.expect(t,response.status==422,response.body)
	testing.expect(t,strings.contains(response.body,"target_kind_unavailable"))
	testing.expect_value(t,action_api_backlog(t,f),i64(0))
}
@(test)
test_actions_api_instance_target_of_bot_refused :: proc(t:^testing.T) {action_api_test(t,action_api_bot_instance)}
action_api_bot_instance :: proc(t:^testing.T,f:^Action_API_Fixture) {
	row:=domain.Bot{bot_id="bot_api",owner_user_id=string(f.wire.owner),agent_id="agt_api",agent_instance_id=f.wire.instance_id}
	save_err:=f.repos.bots.bot_insert(f.repos.bots.ctx,row)
	testing.expect_value(t,save_err.code,domain.Error_Code.None)
	response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",action_api_base_body(f)))
	testing.expect(t,response.status==422,response.body)
	testing.expect(t,strings.contains(response.body,"target_is_bot_instance"))
	rows,err:=actions.list(&f.service,string(f.wire.owner))
	defer actions.action_views_destroy(rows)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect_value(t,len(rows),0)
}
@(test)
test_actions_api_schedules_unsupported :: proc(t:^testing.T) {action_api_test(t,action_api_unsupported)}
action_api_unsupported :: proc(t:^testing.T,f:^Action_API_Fixture) {
	state:=2
	f.service.support={ctx=&state,get=action_api_support}
	body:=action_api_base_body(f,"[{\"kind\":\"schedule\",\"config\":{\"mode\":\"interval\",\"interval_s\":600}}]")
	response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",body))
	testing.expect(t,response.status==409,response.body)
	testing.expect(t,strings.contains(response.body,"schedules_unsupported"))
	testing.expect_value(t,action_api_backlog(t,f),i64(0))
	event_body:=action_api_base_body(f,"[{\"kind\":\"event\",\"config\":{\"event_type\":\"chain.state\"}}]")
	_ = action_api_data(t,create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",event_body)),201)
	meta:=action_api_data(t,action_trigger_types_handler(&f.handlers,action_api_request(f,"GET","/api/v1/actions/trigger-types","")))
	testing.expect_value(t,meta["schedules_supported"].(bool),false)
}
@(test)
test_actions_api_flag_off :: proc(t:^testing.T) {action_api_test(t,action_api_flag_off)}
action_api_flag_off :: proc(t:^testing.T,f:^Action_API_Fixture) {
	(^Action_API_Experiment)(f.handlers.experiments.ctx).enabled=false
	handlers:=[?]struct{method,path:string,handler:proc(rawptr,Request)->Response}{
		{"GET","/api/v1/actions",list_actions_handler},{"POST","/api/v1/actions",create_action_handler},
		{"GET","/api/v1/actions/trigger-types",action_trigger_types_handler},
		{"GET","/api/v1/actions/missing",get_action_handler},{"PATCH","/api/v1/actions/missing",patch_action_handler},
		{"DELETE","/api/v1/actions/missing",delete_action_handler},
		{"POST","/api/v1/actions/missing/enable",enable_action_handler},{"POST","/api/v1/actions/missing/disable",disable_action_handler},
	}
	// A nil service proves that no gated route attempts a service read or write.
	f.handlers.service=nil
	for h in handlers {
		response:=h.handler(&f.handlers,action_api_request(f,h.method,h.path,"invalid body"))
		testing.expect(t,response.status==403,response.body)
		testing.expect(t,strings.contains(response.body,"experimental_feature_disabled"),response.body)
	}
}

@(test)
test_actions_api_validation :: proc(t:^testing.T) {action_api_test(t,action_api_validation)}
action_api_validation :: proc(t:^testing.T,f:^Action_API_Fixture) {
	_,_,_ = iface.agent_save(&f.repos.agents,domain.Agent{agent_id="agt_api",owner_user_id=f.wire.owner,name="API",slug="api",state=.Active})
	_,_,_ = iface.taskchain_save_chain(&f.repos.taskchains,domain.Task_Chain{chain_id="chain_foreign_api",owner_user_id="someone_else",title="Other",kind=domain.CHAIN_KIND_MIXED_WORK,status=.Active})
	cases:=[?]struct{body,code:string,status:int}{
		{"{\"prompt_text\":\" \",\"target\":{\"kind\":\"instance\",\"instance_id\":\"inst_wire_tb2\"}}","prompt_required",422},
		{"{\"prompt_text\":\"hello\",\"min_interval_s\":4,\"target\":{\"kind\":\"instance\",\"instance_id\":\"inst_wire_tb2\"}}","min_interval_out_of_range",422},
		{"{\"prompt_text\":\"hello\",\"min_interval_s\":86401,\"target\":{\"kind\":\"instance\",\"instance_id\":\"inst_wire_tb2\"}}","min_interval_out_of_range",422},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"unknown\"}}","target_kind_unavailable",422},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"missing\"}}","",404},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"instance\",\"instance_id\":\"missing\"}}","",404},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"agt_api\",\"instance_strategy\":\"other\"}}","invalid_strategy",422},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"agt_api\",\"selector\":\"other\"}}","unknown_selector",422},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"instance\",\"instance_id\":\"inst_wire_tb2\",\"rules\":[{\"bridge_id\":\"*\",\"provider\":\"*\",\"model\":\"*\"}]}}","rules_not_allowed",422},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"agt_api\",\"rules\":[{\"bridge_id\":\"*\",\"provider\":\"*\",\"model\":\"specific\"}]}}","model_requires_provider",422},
		{strings.concatenate({"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"agt_api\",\"rules\":[{\"bridge_id\":\"",f.wire.bridge_foreign,"\",\"provider\":\"*\",\"model\":\"*\"}]}}"},context.temp_allocator),"unknown_bridge",422},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"agt_api\",\"rules\":[{\"bridge_id\":\"missing\",\"provider\":\"*\",\"model\":\"*\"}]}}","unknown_bridge",422},
		{"{\"prompt_text\":\"hello\",\"target\":{\"kind\":\"agent\",\"agent_id\":\"agt_api\",\"rules\":[{\"bridge_id\":\"*\",\"provider\":\"missing_provider_api\",\"model\":\"*\"}]}}","unknown_provider",422},
	}
	for c in cases {
		response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",c.body))
		testing.expect(t,response.status==c.status,response.body)
		if c.code!="" do testing.expect(t,strings.contains(response.body,c.code),response.body)
	}
	trigger_cases:=[?]struct{triggers,code:string}{
		{"[{\"kind\":\"unknown\",\"config\":{}}]","unknown_trigger_kind"},
		{"[{\"kind\":\"schedule\",\"config\":{\"mode\":\"cron\",\"cron_expr\":\"bad\"}}]","invalid_cron"},
		{"[{\"kind\":\"schedule\",\"config\":{\"mode\":\"cron\",\"cron_expr\":\"0 0 * * *\",\"timezone\":\"Bad/Zone\"}}]","invalid_timezone"},
		{"[{\"kind\":\"event\",\"config\":{\"event_type\":\"other\"}}]","unknown_event_type"},
		{"[{\"kind\":\"event\",\"config\":{\"event_type\":\"chain.state\",\"chain_id\":\"chain_foreign_api\"}}]","unknown_chain"},
		{"[{\"kind\":\"event\",\"config\":{\"event_type\":\"chain.state\",\"chain_id\":\"missing\"}}]","unknown_chain"},
		{"[{\"kind\":\"event\",\"config\":{\"event_type\":\"chain.state\",\"data\":{\"bad\":\"value\"}}}]","invalid_data_filter"},
	}
	for c in trigger_cases {
		response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",action_api_base_body(f,c.triggers)))
		testing.expect(t,response.status==422,response.body)
		testing.expect(t,strings.contains(response.body,c.code),response.body)
	}
	too_many:=strings.builder_make()
	defer strings.builder_destroy(&too_many)
	strings.write_string(&too_many,"[")
	for i in 0..<17 {
		if i>0 do strings.write_string(&too_many,",")
		strings.write_string(&too_many,"{\"kind\":\"event\",\"config\":{\"event_type\":\"chain.state\"}}")
	}
	strings.write_string(&too_many,"]")
	response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",action_api_base_body(f,strings.to_string(too_many))))
	testing.expect(t,response.status==422,response.body)
	testing.expect(t,strings.contains(response.body,"too_many_triggers"),response.body)
	rows,err:=actions.list(&f.service,string(f.wire.owner))
	defer actions.action_views_destroy(rows)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect_value(t,len(rows),0)
	testing.expect_value(t,action_api_backlog(t,f),i64(0))
}

@(test)
test_runs_endpoint :: proc(t:^testing.T) {action_api_test(t,action_runs_scenario)}
action_runs_expire :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,id:string)->(bool,domain.Domain_Error) {
 return delivery.expire((^delivery.Service)(ctx),uow,id)
}
action_runs_data :: proc(t:^testing.T,response:Response)->json.Array {
 if !testing.expect(t,response.status==200,response.body) do return nil
 value:json.Value
 if !testing.expect(t,json.unmarshal_string(response.body,&value,.JSON,context.temp_allocator)==nil) do return nil
 object,_:=value.(json.Object);array,_:=object["data"].(json.Array)
 return array
}
action_runs_scenario :: proc(t:^testing.T,f:^Action_API_Fixture) {
 impl:sqlite.Pipeline_Delivery_Repo_SQLite
 f.repos.pipeline_deliveries=sqlite.new_pipeline_delivery_repository(&impl,&f.wire.conn)
 router:=actions.Router{factory=f.service.factory,clock=f.service.clock,ids=f.service.ids}
 pipeline:=delivery.Service{factory=f.service.factory,clock=f.service.clock,ids=f.service.ids}
 delivery.register_sink(&pipeline,{kind="prompt",ctx=&router,on_final=actions.on_delivery_final})
 defer delete(pipeline.sinks)
 router.pipeline={ctx=&pipeline,expire=action_runs_expire}
 f.handlers.router=&router
 response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",action_api_base_body(f)))
 data:=action_api_data(t,response,201);id,_:=data["id"].(string)
 if id=="" do return
 now:=platform.clock_now(f.service.clock)
 at1,_:=platform.expires_at_after_seconds_from(now,1)
 at2,_:=platform.expires_at_after_seconds_from(now,2)
 at3,_:=platform.expires_at_after_seconds_from(now,3)
 repo:=&f.repos.actions
 runs:=[3]domain.Action_Run{
  {run_id="run1",action_id=domain.Action_ID(id),owner_user_id=f.wire.owner,occurrence_key="occ1",state="delivered",event_params_json="{}",created_at=at1,finished_at=at1},
  {run_id="run2",action_id=domain.Action_ID(id),owner_user_id=f.wire.owner,occurrence_key="occ2",state="routed",event_params_json="{}",created_at=at2,started_at=at2,delivery_id="dlv_history"},
  {run_id="run3",action_id=domain.Action_ID(id),owner_user_id=f.wire.owner,occurrence_key="occ3",state="joined",event_params_json="{}",created_at=at3,finished_at=at3,joined_run_id="run2"}}
 for run in runs {
  inserted,err:=repo.run_insert(repo.ctx,run);testing.expect(t,inserted && err.code==.None)
 }
 uow,ok,_:=iface.unit_of_work_begin(f.service.factory);assert(ok)
 testing.expect_value(t,uow.repos.pipeline_deliveries.insert(uow.repos.pipeline_deliveries.ctx,{delivery_id="dlv_history",kind="prompt",owner_user_id=string(f.wire.owner),
  bridge_id=f.wire.bridge_pin,agent_instance_id=f.wire.instance_id,ref="run:run2",state="routed",excluded_bridges_json="[]",expires_at="2099-01-01T00:00:00Z",created_at=now,updated_at=now}).code,domain.Error_Code.None)
 _,_=iface.unit_of_work_commit(&uow)
 path:=strings.concatenate({"/api/v1/actions/",id,"/runs"},context.temp_allocator)
 request:=action_api_request(f,"GET",path,"")
 array:=action_runs_data(t,list_action_runs_handler(&f.handlers,request))
 if testing.expect_value(t,len(array),3) {
  first,_:=array[0].(json.Object);second,_:=array[1].(json.Object);last,_:=array[2].(json.Object)
  first_id,_:=first["id"].(string);testing.expect_value(t,first_id,"run3")
  state,_:=second["state"].(string);testing.expect_value(t,state,"routed")
  count,_:=second["joined_count"].(json.Integer);testing.expect_value(t,count,json.Integer(1))
  state,_=last["state"].(string);testing.expect_value(t,state,"delivered")
 }
 request.query="limit=1"
 array=action_runs_data(t,list_action_runs_handler(&f.handlers,request));testing.expect_value(t,len(array),1)
 request.query=strings.concatenate({"before=",at3},context.temp_allocator)
 array=action_runs_data(t,list_action_runs_handler(&f.handlers,request));testing.expect_value(t,len(array),2)

 // Four rows share at3; every row must survive page boundaries exactly once.
 for i in 4..<7 {
  run:=domain.Action_Run{run_id=fmt.tprintf("run%d",i),action_id=domain.Action_ID(id),owner_user_id=f.wire.owner,
   occurrence_key=fmt.tprintf("occ%d",i),state="delivered",event_params_json="{}",created_at=at3,finished_at=at3}
  inserted,err:=repo.run_insert(repo.ctx,run);testing.expect(t,inserted && err.code==.None)
 }
 before,before_id:="",""
 expected:=[]string{"run6","run5","run4","run3","run2","run1"}
 for page in 0..<3 {
  request.query=fmt.tprintf("limit=2&before=%s&before_id=%s",before,before_id)
  array=action_runs_data(t,list_action_runs_handler(&f.handlers,request))
  if !testing.expect_value(t,len(array),2) do return
  for value,i in array {
   row:=value.(json.Object)
   testing.expect_value(t,row["id"].(string),expected[page*2+i])
   before=row["created_at"].(string);before_id=row["id"].(string)
  }
 }
 request.query=fmt.tprintf("limit=2&before=%s&before_id=%s",before,before_id)
 array=action_runs_data(t,list_action_runs_handler(&f.handlers,request));testing.expect_value(t,len(array),0)
 // Legacy timestamp-only requests still exclude all rows at the cursor timestamp.
 request.query=fmt.tprintf("before=%s",at3)
 array=action_runs_data(t,list_action_runs_handler(&f.handlers,request));testing.expect_value(t,len(array),2)
 // An ID without a timestamp does not restrict the first page.
 request.query="limit=1&before_id=run1"
 array=action_runs_data(t,list_action_runs_handler(&f.handlers,request))
 if testing.expect_value(t,len(array),1) do testing.expect_value(t,array[0].(json.Object)["id"].(string),"run6")
 request.query="limit=0";testing.expect_value(t,list_action_runs_handler(&f.handlers,request).status,422)
 uow,ok,_=iface.unit_of_work_begin(f.service.factory);assert(ok)
 d,_,_:=uow.repos.pipeline_deliveries.get(uow.repos.pipeline_deliveries.ctx,"dlv_history")
 d.expires_at="2000-01-01T00:00:00Z"
 changed,e:=uow.repos.pipeline_deliveries.transition(uow.repos.pipeline_deliveries.ctx,d,"routed")
 testing.expect(t,changed && e.code==.None);_,_=iface.unit_of_work_commit(&uow)
 request.query=""
 array=action_runs_data(t,list_action_runs_handler(&f.handlers,request))
 found:=false
 for entry in array {
  object,_:=entry.(json.Object)
  row_id,_:=object["id"].(string)
  if row_id=="run2" {
   state,_:=object["state"].(string);reason,_:=object["reason"].(string)
   testing.expect(t,state=="failed" && reason=="bridge_offline");found=true
  }
 }
 testing.expect(t,found)
 foreign_action:=domain.Action{id="foreign_action",owner_user_id="other",name="Foreign",prompt_text="hello",target_kind="instance",instance_strategy="reuse",enabled=true,min_interval_s=30}
 testing.expect_value(t,repo.save(repo.ctx,foreign_action).code,domain.Error_Code.None)
 request=action_api_request(f,"GET","/api/v1/actions/foreign_action/runs","")
 testing.expect_value(t,list_action_runs_handler(&f.handlers,request).status,404)
 (^Action_API_Experiment)(f.handlers.experiments.ctx).enabled=false
 request=action_api_request(f,"GET",path,"")
 testing.expect_value(t,list_action_runs_handler(&f.handlers,request).status,403)
}
