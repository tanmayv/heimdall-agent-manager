package http
import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import actions "odin_test:hub/service/actions"

agent_automation_test_call :: proc(f:^Action_API_Fixture,verb,params:string)->Response {
 f.wire.ah.automations=&f.handlers
 body:=strings.concatenate({`{"agent_instance_id":"`,f.wire.instance_id,`","params":`,params,"}"},context.temp_allocator)
 req:=wire_agent_request(f.wire,"",body)
 req.path=strings.concatenate({"/api/v1/agent-actions/automations/",verb},context.temp_allocator)
 return agent_automation_handler(&f.wire.ah,req)
}
@(test)
test_agent_automations_crud_audit_scope :: proc(t:^testing.T) {action_api_test(t,agent_automations_crud_scenario)}
agent_automations_crud_scenario :: proc(t:^testing.T,f:^Action_API_Fixture) {
 f.service.max_per_owner=1
 input:=action_api_base_body(f)
 params:=strings.concatenate({`{"owner":"foreign","created_by":"spoof","input":`,input,"}"},context.temp_allocator)
 created:=action_api_data(t,agent_automation_test_call(f,"create",params),201)
 if created==nil do return
 id:=created["id"].(string)
 testing.expect_value(t,created["owner_user_id"].(string),string(f.wire.owner))
 testing.expect_value(t,created["created_by"].(string),f.wire.instance_id)
 testing.expect_value(t,created["updated_by"].(string),f.wire.instance_id)
 testing.expect_value(t,agent_automation_test_call(f,"create",params).status,409)
 id_params:=strings.concatenate({`{"id":"`,id,`"}`},context.temp_allocator)
 got:=action_api_data(t,agent_automation_test_call(f,"show",id_params))
 testing.expect_value(t,got["id"].(string),id)
 updated:=action_api_data(t,agent_automation_test_call(f,"update",strings.concatenate({`{"id":"`,id,`","input":{"enabled":false,"prompt_text":"Changed"}}`},context.temp_allocator)))
 testing.expect_value(t,updated["enabled"].(bool),false)
 testing.expect_value(t,updated["prompt_text"].(string),"Changed")
 testing.expect_value(t,agent_automation_test_call(f,"list","{}").status,200)
 testing.expect_value(t,agent_automation_test_call(f,"trigger-types","{}").status,200)
 testing.expect_value(t,agent_automation_test_call(f,"filter-test",`{"event_type":"chain.state","filter":{"field":"data.state","op":"eq","value":"completed"},"event":{"data":{"state":"completed"}}}`).status,200)
 // Persist an automation owned by a different user; never expose it by id.
 row:=domain.Action{id="act_foreign",owner_user_id="someone_else",prompt_text="secret",target_kind="instance",target_instance_id="elsewhere",instance_strategy="reuse",placement_selector="first",enabled=true,min_interval_s=30,created_at="2026-11-01T00:00:00Z",updated_at="2026-11-01T00:00:00Z"}
 testing.expect_value(t,f.repos.actions.save(f.repos.actions.ctx,row).code,domain.Error_Code.None)
 for verb in ([]string{"show","update","delete"}) {
  response:=agent_automation_test_call(f,verb,`{"id":"act_foreign","input":{"enabled":false}}`)
  testing.expect_value(t,response.status,404)
  testing.expect(t,!strings.contains(response.body,"secret"))
 }
 deleted:=action_api_data(t,agent_automation_test_call(f,"delete",id_params))
 testing.expect_value(t,deleted["deleted"].(bool),true)
 testing.expect_value(t,agent_automation_test_call(f,"show",id_params).status,404)
 f.wire.ah.automations=&f.handlers
 req:=wire_agent_request(f.wire,"",`{"params":{}}`)
 req.path="/api/v1/agent-actions/automations/list";req.headers=nil
 testing.expect_value(t,agent_automation_handler(&f.wire.ah,req).status,401)
}
@(test)
test_agent_automations_event_roundtrip :: proc(t:^testing.T) {action_api_test(t,agent_automations_event_scenario)}
agent_automations_event_scenario :: proc(t:^testing.T,f:^Action_API_Fixture) {
 tree:=`{"all":[{"field":"data.state","op":"in","value":["completed","cancelled"]},{"not":{"field":"data.state","op":"eq","value":"archived"}}]}`
 triggers:=strings.concatenate({`[{"kind":"event","delay_s":30,"config":{"event_type":"chain.state","entity_id":"`,string(f.wire.chain_id),`","filter":`,tree,`}}]`},context.temp_allocator)
 input:=action_api_base_body(f,triggers)
 created:=action_api_data(t,agent_automation_test_call(f,"create",strings.concatenate({`{"input":`,input,"}"},context.temp_allocator)),201)
 if created==nil do return
 ts:=created["triggers"].(json.Array)
 trigger:=ts[0].(json.Object)
 testing.expect_value(t,trigger["delay_s"].(json.Integer),json.Integer(30))
 config:=trigger["config"].(json.Object)
 testing.expect_value(t,config["entity_id"].(string),string(f.wire.chain_id))
 filter:=config["filter"].(json.Object)
 testing.expect_value(t,len(filter["all"].(json.Array)),2)
 // runs includes F1's immutable trace stored with the event snapshot.
 router:=actions.Router{factory=f.service.factory,clock=f.service.clock,ids=f.service.ids}
 f.handlers.router=&router
 id:=created["id"].(string)
 run:=domain.Action_Run{run_id="run_trace",action_id=domain.Action_ID(id),trigger_id=trigger["id"].(string),owner_user_id=f.wire.owner,occurrence_key="trace",event_type="chain.state",event_id="evt_trace",event_params_json=`{"_match":{"rev":1,"nodes":"TTTF"},"data":{"state":"completed"}}`,state="delivered",created_at="2026-11-01T00:00:00Z"}
 inserted,err:=f.repos.actions.run_insert(f.repos.actions.ctx,run)
 testing.expect(t,inserted && err.code==.None)
 response:=agent_automation_test_call(f,"runs",strings.concatenate({`{"id":"`,id,`","limit":20}`},context.temp_allocator))
 testing.expect_value(t,response.status,200)
 testing.expect(t,strings.contains(response.body,"TTTF"),response.body)
 testing.expect(t,strings.contains(response.body,"_match"),response.body)
 testing.expect_value(t,agent_automation_test_call(f,"runs",`{"id":"act_foreign"}`).status,404)
}
