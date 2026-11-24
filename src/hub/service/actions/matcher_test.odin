#+feature dynamic-literals
package actions
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import delivery "odin_test:hub/service/delivery"
import placement "odin_test:hub/service/placement"

Action_Test :: struct {
 db:sqlite.Conn,
 repos:iface.Repositories,
 actions_impl:sqlite.Action_Repo_SQLite,
 bots_impl:sqlite.Bot_Repo_SQLite,
 content_impl:sqlite.Content_Repo_SQLite,
 outbox_impl:sqlite.Event_Outbox_Repo_SQLite,
 deliveries_impl:sqlite.Pipeline_Delivery_Repo_SQLite,
 factory_impl:sqlite.SQLite_Unit_Of_Work_Factory,
 factory:iface.Unit_Of_Work_Factory,
 original_factory:iface.Unit_Of_Work_Factory,
 crash_before_commit,route_written:bool,
 experiments:iface.Experiment_Repository,
 bridges:iface.Bridge_Repository,
 clock:platform.Clock,
 ids:platform.ID_Generator,
 place:placement.Service,
 runtime:Runtime,
 pipeline:delivery.Service,
 now_ms:i64,
 serial,routes,prompts:int,
 hints:int,
 hint_valid:bool,
 support:int,
 last_cause,last_notice:string,
 validity_reads,settle_plans:int,
 chain_status:domain.Task_Chain_Status,
 chain_revision:i64,
 flag_off,fail_prompt,fail_retire,bots_on:bool,
}
action_test_clock :: proc(ctx:rawptr)->string {
 return platform.format_rfc3339_utc(time.Time{_nsec=((^Action_Test)(ctx)).now_ms*1_000_000})
}
action_test_id :: proc(ctx:rawptr,prefix:string)->string {
 f:=(^Action_Test)(ctx); f.serial+=1
 return fmt.tprintf("%s%d",prefix,f.serial)
}
action_test_support :: proc(ctx:rawptr)->int {return ((^Action_Test)(ctx)).support}
action_test_experiments :: proc(ctx:rawptr,owner:string)->([dynamic]domain.Experiment,domain.Domain_Error) {
 f:=(^Action_Test)(ctx)
 rows: [dynamic]domain.Experiment
 if !f.flag_off do append(&rows,domain.Experiment{owner_user_id=strings.clone(owner),key=strings.clone("actions"),enabled=true})
 if f.bots_on do append(&rows,domain.Experiment{owner_user_id=strings.clone(owner),key=strings.clone("bots"),enabled=true})
 return rows,{}
}
action_test_bridge :: proc(ctx:rawptr,id:string)->(domain.Bridge,bool,domain.Domain_Error) {
 return {bridge_id=strings.clone(id),owner_user_id=domain.User_ID(strings.clone("owner")),capabilities_json=strings.clone(`{"features":["event_pipeline_v1"]}`)},true,{}
}
action_test_instance :: proc(ctx:rawptr,owner,id:string)->(string,string,string,bool) {
 return "agent","bridge","conversation",id!="missing"
}
action_test_persist :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,cid,body,metadata:string)->(string,domain.Domain_Error) {
 f:=(^Action_Test)(ctx)
 id:=platform.generate_id(&f.ids,"msg_")
 _,ok,err:=iface.content_save_message(&uow.repos.content,{
  message_id=id,conversation_id=cid,owner_user_id=domain.User_ID(owner),body=body,
  direction="user_to_agent",message_type="action",metadata_json=metadata,created_at=platform.clock_now(&f.clock)})
 if !ok do return "",err
 if f.fail_prompt do return "",domain.domain_error(.Internal_Error,"injected after prompt insert")
 f.prompts+=1
 return id,{}
}
action_test_route :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,input:delivery.Route_Input)->(string,domain.Domain_Error) {
 f:=(^Action_Test)(ctx)
 f.last_cause="schedule" if input.cause=="schedule" else "event"
 f.last_notice="message" if input.notice_line=="message" else ""
 id,err:=delivery.route(&f.pipeline,uow,input)
 if err.code==.None {f.routes+=1;f.route_written=true}
 return id,err
}
action_test_expire :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,id:string)->(bool,domain.Domain_Error) {
 return delivery.expire(&((^Action_Test)(ctx)).pipeline,uow,id)
}
action_test_retire :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,id,moved:string)->domain.Domain_Error {
 if ((^Action_Test)(ctx)).fail_retire do return domain.domain_error(.Internal_Error,"injected retirement error")
 return {}
}
action_test_case :: proc(t:^testing.T,scenario:proc(^testing.T,^Action_Test)) {
 track:mem.Tracking_Allocator
 mem.tracking_allocator_init(&track,context.allocator)
 defer mem.tracking_allocator_destroy(&track)
 context.allocator=mem.tracking_allocator(&track)
 {
  arena:virtual.Arena
  if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
  defer virtual.arena_destroy(&arena)
  context.allocator=virtual.arena_allocator(&arena); context.temp_allocator=context.allocator
  f:Action_Test
  opened:bool
  f.db,opened,_=sqlite.open(":memory:")
  if !testing.expect(t,opened) do return
  defer sqlite.close(&f.db)
  migrated,_:=sqlite.run_migrations(&f.db)
  if !testing.expect(t,migrated) do return
  testing.expect(t,sqlite.exec(&f.db,"PRAGMA foreign_keys=OFF;"))
  f.repos.bots=sqlite.new_bot_repository(&f.bots_impl,&f.db)
  f.repos.actions=sqlite.new_action_repository(&f.actions_impl,&f.db)
  f.repos.content=sqlite.new_content_repository(&f.content_impl,&f.db)
  f.repos.event_outbox=sqlite.new_event_outbox_repository(&f.outbox_impl,&f.db)
  f.repos.pipeline_deliveries=sqlite.new_pipeline_delivery_repository(&f.deliveries_impl,&f.db)
  f.factory=sqlite.new_unit_of_work_factory(&f.factory_impl,&f.db,&f.repos)
  f.now_ms,_=platform.rfc3339_to_unix_ms("2026-11-23T00:00:00Z")
  f.clock={ctx=&f,now=action_test_clock}; f.ids={ctx=&f,generate=action_test_id}
  f.experiments={ctx=&f,list_by_owner=action_test_experiments}
  f.bridges={ctx=&f,get_bridge=action_test_bridge}
  f.place.bridges=&f.bridges
  f.pipeline=delivery.Service{factory=&f.factory,bridges=&f.bridges,clock=&f.clock,ids=&f.ids}
  f.runtime.svc=&Service{factory=&f.factory,repos=&f.repos,clock=&f.clock,ids=&f.ids}
  f.runtime.router=Router{factory=&f.factory,experiments=&f.experiments,placement=&f.place,clock=&f.clock,ids=&f.ids,
   support={ctx=&f,get=action_test_support},agents={ctx=&f,instance=action_test_instance,persist_prompt=action_test_persist,retire_prompt=action_test_retire},
   pipeline={ctx=&f,route=action_test_route,expire=action_test_expire}}
  delivery.register_sink(&f.pipeline,{kind="prompt",ctx=&f.runtime.router,on_final=on_delivery_final,replace=on_delivery_replace})
  defer {
   for sink in f.pipeline.sinks do delete(sink.kind,runtime.heap_allocator())
   delete(f.pipeline.sinks)
  }
  _,_,_=iface.content_save_conversation(&f.repos.content,{conversation_id="conversation",owner_user_id="owner",agent_id="agent",agent_instance_id="instance"})
  action_test_seed(t,&f,"action","trigger","owner")
  scenario(t,&f)
 }
 testing.expect_value(t,len(track.allocation_map),0)
}
action_test_seed :: proc(t:^testing.T,f:^Action_Test,id,trigger,owner:string) {
 repo:=&f.repos.actions
 testing.expect_value(t,repo.save(repo.ctx,{id=domain.Action_ID(id),owner_user_id=domain.User_ID(owner),name="Action",prompt_text="event {{event.id}} {{run.joined_count}}",
  enabled=true,instance_strategy="reuse",placement_selector="first",target_kind=domain.ACTION_TARGET_INSTANCE,target_instance_id="instance",min_interval_s=30,created_at="2026-01-01T00:00:00Z"}).code,domain.Error_Code.None)
 testing.expect_value(t,repo.trigger_save(repo.ctx,{trigger_id=trigger,action_id=domain.Action_ID(id),owner_user_id=domain.User_ID(owner),kind="event",config_json="{}",enabled=true,rev=1,
  event_type="chain.state",subject_filter=fmt.tprintf("ev.%s.chain.*.state",owner),data_filter_json="{}",match_key="",
  created_at="2026-01-01T00:00:00Z",updated_at="2026-01-01T00:00:00Z"}).code,domain.Error_Code.None)
}
action_test_match :: proc(t:^testing.T,f:^Action_Test,id:string) {
 testing.expect(t,handle_message(&f.runtime,{
  subject="ev.owner.chain.chain1.state",owner="owner",event_type="chain.state",event_id=id,
  stream_time_ms=f.now_ms,stream_sequence=u64(f.serial+1),envelope=test_config(`{"type":"chain.state","data":{"state":"completed"}}`)}))
}
action_test_rows :: proc(t:^testing.T,f:^Action_Test)->[]domain.Action_Run {
 rows,err:=f.repos.actions.runs_list(f.repos.actions.ctx,"action",1000,"","")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 return rows
}
action_test_expect :: proc(t:^testing.T,f:^Action_Test,state:string,count:int) {
 rows:=action_test_rows(t,f);actual:=0
 for row in rows do if row.state==state do actual+=1
 testing.expect(t,actual==count,fmt.tprintf("state %s: got %d, want %d",state,actual,count))
}
action_test_done :: proc(t:^testing.T,f:^Action_Test) {
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 run,found,_:=uow.repos.actions.run_open(uow.repos.actions.ctx,"action");assert(found)
 err:=on_delivery_final(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id,state=domain.DELIVERY_DONE})
 testing.expect_value(t,err.code,domain.Error_Code.None)
 _,_=iface.unit_of_work_commit(&uow)
}
@(test)
test_subject_matches_table :: proc(t:^testing.T) {actions_track(t,subject_match_cases)}
subject_match_cases :: proc(t:^testing.T) {
 cases:=[?]struct{filter,subject:string,want:bool}{
 {"ev.*.chain.*.state","ev.owner.chain.id.state",true},{"ev.owner.chain.*.state","ev.other.chain.id.state",false},
 {"ev.*.chain","ev.owner.chain.id",false},{"ev.*.chain.*","ev.owner.chain",false},{"ev.>","ev.owner.chain",false},
 {"","",true},{"ev.owner","ev.owner",true},{"ev.owner","ev.other",false}}
 for c in cases do testing.expect_value(t,subject_matches(c.filter,c.subject),c.want)
}
@(test)
test_data_matches_table :: proc(t:^testing.T) {actions_track(t,data_match_cases)}
data_match_cases :: proc(t:^testing.T) {
 data:=test_config(`{"state":"completed","n":3,"bool":true,"nested":{"key":"v"}}`)
 for filter in ([]string{"","{}",`{"state":"completed"}`,`{"n":"3","bool":"true"}`}) do testing.expect(t,data_matches(filter,data),filter)
 for filter in ([]string{`{"missing":"x"}`,`{"state":"failed"}`,`{"nested":"x"}`,"[]","broken"}) do testing.expect(t,!data_matches(filter,data),filter)
}
@(test)
test_matcher_tenant_isolation :: proc(t:^testing.T) {action_test_case(t,tenant_scenario)}
tenant_scenario :: proc(t:^testing.T,f:^Action_Test) {
 action_test_seed(t,f,"other_action","other_trigger","other")
 action_test_match(t,f,"one")
 action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1)
 rows,err:=f.repos.actions.runs_list(f.repos.actions.ctx,"other_action",20,"","")
 testing.expect(t,err.code==.None && len(rows)==0)
 testing.expect(t,handle_message(&f.runtime,{subject="ev.owner.chain.chain1.state",event_type="chain.state",event_id="two",stream_time_ms=f.now_ms,
  envelope=test_config(`{"owner_user_id":"other","data":{}}`)}))
 action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1)
 testing.expect_value(t,f.runtime.skipped_owner_mismatch,i64(1))
}


@(test)
test_exact_and_wildcard_triggers_both_match :: proc(t:^testing.T) {action_test_case(t,matcher_exact_wildcard)}
matcher_exact_wildcard :: proc(t:^testing.T,f:^Action_Test) {
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"trigger")
 trigger.trigger_id="exact";trigger.subject_filter="ev.owner.chain.chain1.state";trigger.match_key=trigger.subject_filter
 testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,trigger).code,domain.Error_Code.None)
 action_test_match(t,f,"one");action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1);action_test_expect(t,f,domain.ACTION_RUN_JOINED,1)
}
@(test)
test_schedule_fire_reads_one_trigger :: proc(t:^testing.T) {action_test_case(t,matcher_one_schedule)}
matcher_one_schedule :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"interval","interval_s":60}`)
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"schedule")
 for i in 0..<100 {
  other:=trigger;other.trigger_id=fmt.tprintf("unrelated%d",i)
  other.subject_filter=fmt.tprintf("ev.owner.sched.%s",other.trigger_id);other.match_key=other.subject_filter
  testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,other).code,domain.Error_Code.None)
 }
 rows,err:=f.repos.actions.triggers_match(f.repos.actions.ctx,"owner","schedule.fired","ev.owner.sched.schedule")
 testing.expect(t,err.code==.None && len(rows)==1 && rows[0].trigger_id=="schedule")
 action_test_fire(t,f,"one","1");testing.expect_value(t,len(action_test_rows(t,f)),1)
}
