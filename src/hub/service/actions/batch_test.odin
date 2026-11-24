package actions
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

batch_seed :: proc(t:^testing.T,f:^Action_Test,count:int) {
 for i in 1..<count do action_test_seed(t,f,fmt.tprintf("action%d",i),fmt.tprintf("trigger%d",i),"owner")
}
@(thread_local) batch_resolutions:int
batch_instance_counter :: proc(ctx:rawptr,owner,id:string)->(string,string,string,bool) {
 batch_resolutions+=1
 return action_test_instance(ctx,owner,id)
}
batch_ten :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,10)
 batch_resolutions=0;f.runtime.router.agents.instance=batch_instance_counter
 action_test_match(t,f,"batch-event");drain_due(&f.runtime.router)
 testing.expect_value(t,batch_resolutions,1)
 testing.expect_value(t,action_test_prompt_count(t,f),1)
 deliveries,e:=action_test_deliveries(f)
 if !testing.expect(t,e.code==.None && len(deliveries)==1) do return
 actions,err:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 for action in actions {
  run,found,e:=f.repos.actions.run_open(f.repos.actions.ctx,action.id)
  testing.expect(t,e.code==.None && found && run.state=="routed")
  testing.expect_value(t,run.delivery_id,deliveries[0].delivery_id)
  testing.expect_value(t,run.message_id,deliveries[0].message_id)
 }
 message,_,_:=iface.content_get_message(&f.repos.content,deliveries[0].message_id)
 testing.expect(t,strings.has_prefix(message.body,"10 actions fired for you.\n"))
 object:=test_config(message.metadata_json)
 runs,valid:=object["runs"].(json.Array)
 testing.expect(t,valid && len(runs)==10)
 // Redrain must neither duplicate the batch nor resolve already routed rows.
 drain_due(&f.runtime.router)
 testing.expect_value(t,batch_resolutions,1);testing.expect_value(t,f.routes,1)
}
batch_single :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"single")
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 expected:=render(action.prompt_text,action,run,0,context.temp_allocator)
 metadata,e:=prompt_metadata(&f.repos.actions,action,run,0)
 testing.expect_value(t,e.code,domain.Error_Code.None)
 drain_due(&f.runtime.router)
 run,_,_=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 message,_,_:=iface.content_get_message(&f.repos.content,run.message_id)
 testing.expect_value(t,message.body,expected)
 expected_metadata:=test_config(metadata)
 actual_metadata:=test_config(message.metadata_json)
 testing.expect_value(t,len(actual_metadata),len(expected_metadata))
 for key,value in expected_metadata {
  expected_bytes,_:=json.marshal(value,allocator=context.temp_allocator)
  actual_bytes,_:=json.marshal(actual_metadata[key],allocator=context.temp_allocator)
  testing.expect_value(t,string(actual_bytes),string(expected_bytes))
 }
}
batch_twenty_five :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,25)
 action_test_match(t,f,"many");drain_due(&f.runtime.router)
 testing.expect_value(t,f.routes,1)
 actions,_:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 routed,parked:=0,0
 delivery_id:=""
 for action in actions {
  run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,action.id)
  if run.state=="routed" {routed+=1;delivery_id=run.delivery_id}
  if run.state=="deferred" {parked+=1;testing.expect(t,run.target_instance_id=="instance" && run.not_before!="")}
 }
 testing.expect_value(t,routed,20);testing.expect_value(t,parked,5)
 // B2 owns automatic final fan-out/release; simulate its terminal state here.
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 d,_,_:=uow.repos.pipeline_deliveries.get(uow.repos.pipeline_deliveries.ctx,delivery_id)
 d.state=domain.DELIVERY_DONE
 _,_=uow.repos.pipeline_deliveries.transition(uow.repos.pipeline_deliveries.ctx,d,domain.DELIVERY_ROUTED)
 _,_=iface.unit_of_work_commit(&uow)
 f.now_ms+=3601000;drain_due(&f.runtime.router)
 testing.expect_value(t,f.routes,2)
 deliveries,_:=action_test_deliveries(f)
 if !testing.expect_value(t,len(deliveries),1) do return
 message,_,_:=iface.content_get_message(&f.repos.content,deliveries[0].message_id)
 testing.expect(t,strings.has_prefix(message.body,"5 actions fired for you.\n"))
}
batch_bot :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,10);bot_target_seed(t,f)
 actions,_:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 for &a in actions {a.target_kind=domain.ACTION_TARGET_BOT;a.target_bot_id="bot";a.target_instance_id="";_=f.repos.actions.save(f.repos.actions.ctx,a)}
 batch_resolutions=0;f.runtime.router.agents.instance=batch_instance_counter
 action_test_match(t,f,"bot-batch");drain_due(&f.runtime.router)
 testing.expect_value(t,batch_resolutions,1);testing.expect_value(t,f.routes,1)
}
batch_spec_boundary :: proc(t:^testing.T,f:^Action_Test) {
 action_test_seed(t,f,"action2","trigger2","owner");bot_target_seed(t,f)
 batch_resolutions=0;f.runtime.router.agents.instance=batch_instance_counter
 action_test_match(t,f,"mixed");drain_due(&f.runtime.router)
 testing.expect_value(t,batch_resolutions,2);testing.expect_value(t,f.routes,1)
 first,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 second,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action2")
 testing.expect(t,(first.state=="routed" && second.state=="deferred") || (second.state=="routed" && first.state=="deferred"))
}
@(test) test_batch_ten_actions_one_delivery :: proc(t:^testing.T) {action_test_case(t,batch_ten)}
@(test) test_batch_single_preserves_bytes :: proc(t:^testing.T) {action_test_case(t,batch_single)}
@(test) test_batch_twenty_five_split :: proc(t:^testing.T) {action_test_case(t,batch_twenty_five)}
@(test) test_batch_bot_resolves_once :: proc(t:^testing.T) {action_test_case(t,batch_bot)}
@(test) test_batch_different_specs_serialize :: proc(t:^testing.T) {action_test_case(t,batch_spec_boundary)}

batch_agent_fresh :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,3)
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 actions,_:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 for &a in actions {
  a.target_kind=domain.ACTION_TARGET_AGENT;a.target_agent_id="agent";a.instance_strategy=domain.ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN
  _=f.repos.actions.save(f.repos.actions.ctx,a)
  _=f.repos.actions.rules_replace(f.repos.actions.ctx,a.id,[]domain.Action_Target_Rule{{0,"bridge1","alpha","m1"}})
 }
 action_test_match(t,f,"fresh");drain_due(&f.runtime.router)
 testing.expect_value(t,p.created,3);testing.expect_value(t,f.routes,3)
 ids:=make(map[string]bool)
 for a in actions {
  run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,a.id)
  testing.expect_value(t,run.state,"routed");ids[run.target_instance_id]=true
 }
 testing.expect_value(t,len(ids),3)
}
batch_agent_reuse :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,3)
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 actions,_:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 for &a in actions {
  a.target_kind=domain.ACTION_TARGET_AGENT;a.target_agent_id="agent"
  _=f.repos.actions.save(f.repos.actions.ctx,a)
  _=f.repos.actions.rules_replace(f.repos.actions.ctx,a.id,[]domain.Action_Target_Rule{{0,"bridge1","alpha","m1"}})
 }
 action_test_match(t,f,"reuse");drain_due(&f.runtime.router)
 testing.expect_value(t,p.created,1);testing.expect_value(t,f.routes,1)
 for a in actions {
  run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,a.id)
  testing.expect_value(t,run.target_instance_id,"created1")
  saved,_,_:=f.repos.actions.get(f.repos.actions.ctx,a.id)
  testing.expect_value(t,string(saved.last_spawned_instance_id),"created1")
 }
}
batch_body_cap :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,4)
 actions,_:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 for &a in actions {a.prompt_text=strings.repeat("x",9000,context.temp_allocator);_=f.repos.actions.save(f.repos.actions.ctx,a)}
 action_test_match(t,f,"body");drain_due(&f.runtime.router)
 routed,parked:=0,0
 for a in actions {
  run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,a.id)
  if run.state=="routed" do routed+=1
  if run.state=="deferred" do parked+=1
 }
 testing.expect_value(t,routed,2);testing.expect_value(t,parked,2)
 messages,_:=iface.content_list_messages(&f.repos.content,"conversation","owner",10,"")
 if testing.expect_value(t,len(messages),1) do testing.expect(t,len(messages[0].body)<=BATCH_MAX_BYTES)
}
batch_failure :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,3);f.fail_prompt=true
 action_test_match(t,f,"failure");drain_due(&f.runtime.router)
 testing.expect_value(t,action_test_prompt_count(t,f),0)
 actions,_:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 for a in actions {
  runs,_:=f.repos.actions.runs_list(f.repos.actions.ctx,a.id,10,"","")
  if testing.expect_value(t,len(runs),1) {testing.expect_value(t,runs[0].state,"failed");testing.expect_value(t,runs[0].reason,"delivery_failed")}
 }
 deliveries,_:=action_test_deliveries(f);testing.expect_value(t,len(deliveries),0)
}
@(test) test_batch_agent_fresh_per_run_unchanged :: proc(t:^testing.T) {action_test_case(t,batch_agent_fresh)}
@(test) test_batch_agent_reuse_resolves_once :: proc(t:^testing.T) {action_test_case(t,batch_agent_reuse)}
@(test) test_batch_body_size_parks_remainder :: proc(t:^testing.T) {action_test_case(t,batch_body_cap)}
@(test) test_batch_failure_rolls_back_all_members :: proc(t:^testing.T) {action_test_case(t,batch_failure)}
