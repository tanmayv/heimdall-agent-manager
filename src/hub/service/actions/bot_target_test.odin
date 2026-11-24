package actions
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

bot_target_seed :: proc(t:^testing.T,f:^Action_Test) {
 f.bots_on=true
 testing.expect_value(t,iface.bot_insert(&f.repos.bots,{bot_id="bot",owner_user_id="owner",agent_id="agent",agent_instance_id="instance",created_at="now",updated_at="now"}).code,domain.Error_Code.None)
 a,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 a.target_kind=domain.ACTION_TARGET_BOT;a.target_bot_id="bot";a.target_instance_id=""
 testing.expect_value(t,f.repos.actions.save(f.repos.actions.ctx,a).code,domain.Error_Code.None)
}
bot_target_route :: proc(t:^testing.T,f:^Action_Test) {
 bot_target_seed(t,f)
 action_test_match(t,f,"bot-event");drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f)
 if !testing.expect_value(t,len(rows),1) do return
 testing.expect_value(t,rows[0].state,domain.ACTION_RUN_ROUTED)
 testing.expect_value(t,rows[0].target_instance_id,"instance")
 testing.expect_value(t,action_test_prompt_count(t,f),1)
 d,found,e:=action_test_delivery(f,rows[0].delivery_id)
 testing.expect(t,found && e.code==.None)
 testing.expect_value(t,d.kind,"prompt")
 testing.expect_value(t,d.agent_instance_id,"instance")
 // The existing final callback completes bot runs too.
 action_test_done(t,f)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1)
}
bot_target_missing :: proc(t:^testing.T,f:^Action_Test) {
 bot_target_seed(t,f)
 for id in ([]string{"", "missing"}) {
  testing.expect_value(t,iface.bot_set_instance(&f.repos.bots,"bot",id,"now").code,domain.Error_Code.None)
  a,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
  plan:=prompt_plan(&f.runtime.router,a,{},nil)
  testing.expect(t,!plan.ok && plan.reason=="target_missing")
 }
 testing.expect_value(t,iface.bot_set_instance(&f.repos.bots,"bot","instance","now").code,domain.Error_Code.None)
 a,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 a.target_bot_id=""
 testing.expect(t,prompt_plan(&f.runtime.router,a,{},nil).ok,"omitted bot id resolves owner")
 a.owner_user_id="other"
 testing.expect_value(t,prompt_plan(&f.runtime.router,a,{},nil).reason,"target_missing")
}
bot_target_validation :: proc(t:^testing.T,f:^Action_Test) {
 bot_target_seed(t,f)
 s:=Service{experiments=&f.experiments,target_kinds={"agent","instance","bot"}}
 target:=Target_Input{kind="bot",bot_id="bot"}
 testing.expect_value(t,validate_target(&s,&f.repos,"owner",target).code,domain.Error_Code.None)
 target.bot_id=""
 testing.expect_value(t,validate_target(&s,&f.repos,"owner",target).code,domain.Error_Code.None)
 target.instance_strategy="reuse"
 testing.expect_value(t,validate_target(&s,&f.repos,"owner",target).code,domain.Error_Code.None)
 target.instance_strategy="fresh_per_run"
 testing.expect(t,strings.contains(validate_target(&s,&f.repos,"owner",target).details_json,"strategy_not_allowed"))
 target.instance_strategy=""
 target.rules=[]Rule_Input{{bridge_id="bridge"}}
 testing.expect(t,strings.contains(validate_target(&s,&f.repos,"owner",target).details_json,"rules_not_allowed"))
 target.rules=nil
 // INSTANCE targets still reject bot instances; callers must use BOT explicitly.
 f.repos.agents=iface.Agent_Repository{get_instance=bot_target_instance_record}
 testing.expect(t,strings.contains(validate_target(&s,&f.repos,"owner",{kind="instance",instance_id="instance"}).details_json,"target_is_bot_instance"))
 target.bot_id="missing"
 testing.expect_value(t,validate_target(&s,&f.repos,"owner",target).code,domain.Error_Code.Not_Found)
 for id in ([]string{"bot","missing",""}) {
  target.bot_id=id
  testing.expect_value(t,validate_target(&s,&f.repos,"other",target).code,domain.Error_Code.Not_Found)
 }
 // Verify the public create path persists an owner-default bot target.
 s.factory=&f.factory;s.repos=&f.repos;s.clock=&f.clock;s.ids=&f.ids
 input:=test_input();input.target=Target_Input{kind="bot"}
 view,create_err:=create(&s,"owner",input)
 defer action_view_destroy(&view)
 testing.expect_value(t,create_err.code,domain.Error_Code.None)
 testing.expect_value(t,view.action.target_kind,"bot")
 testing.expect_value(t,view.action.instance_strategy,"reuse")
 f.bots_on=false
 rejected,reject_err:=create(&s,"owner",input)
 defer action_view_destroy(&rejected)
 testing.expect(t,strings.contains(reject_err.details_json,"experiment_off"))
 testing.expect(t,strings.contains(validate_target(&s,&f.repos,"owner",target).details_json,"experiment_off"))
}
@(test) test_bot_target_routes_via_instance :: proc(t:^testing.T) {action_test_case(t,bot_target_route)}
@(test) test_bot_target_missing_and_default_owner :: proc(t:^testing.T) {action_test_case(t,bot_target_missing)}
@(test) test_bot_target_validation :: proc(t:^testing.T) {action_test_case(t,bot_target_validation)}

bot_target_instance_record :: proc(_:rawptr,id:string)->(domain.Agent_Instance,bool,domain.Domain_Error) {
 return {agent_instance_id=strings.clone(id),owner_user_id=domain.User_ID(strings.clone("owner"))},true,{}
}
