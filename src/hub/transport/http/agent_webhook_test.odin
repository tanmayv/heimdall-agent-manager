package http
import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import webhooks "odin_test:hub/service/webhooks"
import contracts "odin_test:contracts"
import iface "odin_test:hub/repository/iface"

agent_webhook_test_call :: proc(f:^Webhook_Test,verb,params:string,instance_id:="",headers:[]contracts.HTTP_Header=nil)->Response {
 f.api.wire.ah.webhooks=&f.h
 f.api.wire.ah.public_app_origin="https://example.test"
 caller:=instance_id
 if caller=="" do caller=f.api.wire.instance_id
 body:=strings.concatenate({`{"agent_instance_id":"`,caller,`","params":`,params,"}"},context.temp_allocator)
 req:=wire_agent_request(f.api.wire,"",body)
 req.path=strings.concatenate({"/api/v1/agent-actions/automations/webhooks/",verb},context.temp_allocator)
 if headers!=nil do req.headers=headers
 return agent_webhook_handler(&f.api.wire.ah,req)
}
@(test)
test_agent_webhook_crud_scope_and_token_once :: proc(t:^testing.T) {action_api_test(t,agent_webhook_scenario)}
agent_webhook_scenario :: proc(t:^testing.T,api:^Action_API_Fixture) {
 impl:sqlite.Event_Webhook_Repo_SQLite
 f:=event_webhook_test_setup(api,&impl);event_webhook_test_bind(&f)
 defer event_webhook_limiter_destroy(&f.h.limiter)
 created:=agent_webhook_test_call(&f,"create",`{"name":"CI","owner":"spoof"}`)
 data:=action_api_data(t,created,201)
 if data==nil do return
 testing.expect(t,created.sensitive)
 row:=data["webhook"].(json.Object)
 id:=row["webhook_id"].(string)
 token:=data["token"].(string)
 testing.expect(t,strings.has_prefix(token,"whsec_"))
 testing.expect_value(t,data["bearer_url"].(string),strings.concatenate({"https://example.test/api/v1/hooks/",id},context.temp_allocator))
 testing.expect_value(t,data["secret_url"].(string),strings.concatenate({data["bearer_url"].(string),"/",token},context.temp_allocator))
 testing.expect_value(t,row["owner_user_id"].(string),string(api.wire.owner))
 params:=strings.concatenate({`{"id":"`,id,`"}`},context.temp_allocator)
 for verb in ([]string{"show","list","enable","disable"}) {
  response:=agent_webhook_test_call(&f,verb,params)
  testing.expect_value(t,response.status,200)
  testing.expect(t,!response.sensitive)
  testing.expect(t,!strings.contains(response.body,token) && !strings.contains(response.body,"token_hash"))
 }
 test_params:=strings.concatenate({`{"id":"`,id,`","webhook_secret":"`,token,`","body":"{\"build\":\"passed\",\"token\":\"payload-value\",\"_test\":false}"}`},context.temp_allocator)
 disabled:=agent_webhook_test_call(&f,"test",test_params)
 testing.expect_value(t,disabled.status,409)
 testing.expect(t,strings.contains(disabled.body,"webhook disabled"))
 testing.expect_value(t,agent_webhook_test_call(&f,"enable",params).status,200)
 before:=action_api_backlog(t,api)
 accepted:=action_api_data(t,agent_webhook_test_call(&f,"test",test_params),202)
 testing.expect_value(t,action_api_backlog(t,api),before+1)
 u,uok,_:=iface.unit_of_work_begin(f.service.factory)
 if testing.expect(t,uok) {
  event,found,e:=u.repos.event_outbox.next(u.repos.event_outbox.ctx)
  testing.expect(t,found && e.code==.None)
  defer domain.event_outbox_row_destroy(&event)
  envelope:contracts.Event_Envelope
  testing.expect_value(t,json.unmarshal_string(event.envelope_json,&envelope,.JSON,context.temp_allocator),nil)
  testing.expect_value(t,event.event_id,accepted["event_id"].(string))
  testing.expect_value(t,envelope.actor,api.wire.instance_id)
  testing.expect_value(t,envelope.data["_test"].(bool),true)
  testing.expect_value(t,envelope.data["token"].(string),"payload-value")
  iface.unit_of_work_rollback(&u)
 }
 rotated_response:=agent_webhook_test_call(&f,"rotate",params)
 rotated:=action_api_data(t,rotated_response)
 testing.expect(t,rotated_response.sensitive)
 new_token:=rotated["token"].(string)
 testing.expect(t,new_token!=token)
 testing.expect_value(t,agent_webhook_test_call(&f,"test",test_params).status,401)
 testing.expect_value(t,agent_webhook_test_call(&f,"test",strings.concatenate({`{"id":"`,id,`","webhook_secret":"`,new_token,`","body":"{}"}`},context.temp_allocator)).status,202)
 testing.expect_value(t,agent_webhook_test_call(&f,"test",strings.concatenate({`{"id":"`,id,`","webhook_secret":"`,new_token,`","body":"[]"}`},context.temp_allocator)).status,422)
 f.service.limits=webhooks.DEFAULT_LIMITS
 f.service.limits.per_webhook_per_minute=1
 testing.expect_value(t,agent_webhook_test_call(&f,"test",strings.concatenate({`{"id":"`,id,`","webhook_secret":"`,new_token,`","body":"{}"}`},context.temp_allocator)).status,429)
 other,secret,e:=webhooks.mutate(&f.service,"foreign-owner","","create")
 defer domain.event_webhook_destroy(&other);defer delete(secret)
 testing.expect_value(t,e.code,domain.Error_Code.None)
 listed:=agent_webhook_test_call(&f,"list","{}")
 testing.expect(t,!strings.contains(listed.body,other.webhook_id))
 for verb in ([]string{"show","rotate","enable","disable","delete","test"}) {
  r:=agent_webhook_test_call(&f,verb,strings.concatenate({`{"id":"`,other.webhook_id,`","webhook_secret":"`,secret,`","body":"{}"}`},context.temp_allocator))
  testing.expect_value(t,r.status,404)
  testing.expect(t,!strings.contains(r.body,secret))
 }
 testing.expect_value(t,agent_webhook_test_call(&f,"delete",params).status,200)
 testing.expect_value(t,agent_webhook_test_call(&f,"show",params).status,404)
 req:=wire_agent_request(api.wire,"",`{"params":{}}`)
 req.path="/api/v1/agent-actions/automations/webhooks/list";req.headers=nil
 testing.expect_value(t,agent_webhook_handler(&api.wire.ah,req).status,401)
}

@(test)
test_agent_webhook_failed_auth_isolated_by_owner :: proc(t:^testing.T) {action_api_test(t,agent_webhook_owner_limit_scenario)}
agent_webhook_owner_limit_scenario :: proc(t:^testing.T,api:^Action_API_Fixture) {
 impl:sqlite.Event_Webhook_Repo_SQLite
 f:=event_webhook_test_setup(api,&impl);event_webhook_test_bind(&f)
 defer event_webhook_limiter_destroy(&f.h.limiter)
 own:=action_api_data(t,agent_webhook_test_call(&f,"create","{}"),201)
 id:=own["webhook"].(json.Object)["webhook_id"].(string)
 token:=own["token"].(string)
 bad:=strings.concatenate({`{"id":"`,id,`","webhook_secret":"wrong","body":"{}"}`},context.temp_allocator)
 // Same bridge/proxy remote_addr on every request; owner A must not poison B.
 for _ in 0..<webhooks.DEFAULT_LIMITS.failed_auth_per_ip do testing.expect_value(t,agent_webhook_test_call(&f,"test",bad).status,401)
 testing.expect_value(t,agent_webhook_test_call(&f,"test",bad).status,429)
 second_owner:="wire_webhook_second_owner"
 bridge_token:string
 bridge:=wire_enroll_bridge(t,api.wire,second_owner,"webhook-second",&bridge_token)
 instance:="inst_webhook_second"
 _,saved,e:=iface.agent_save_instance(&api.wire.ag_repo,domain.Agent_Instance{
  agent_instance_id=instance,owner_user_id=domain.User_ID(second_owner),agent_id="agt_second",bridge_id=bridge,
  display_name="second owner",runtime_status="running",startup_status="ready",created_at="2026-11-01T00:00:00Z",updated_at="2026-11-01T00:00:00Z",
 })
 testing.expect(t,saved && e.code==.None)
 headers:=[]contracts.HTTP_Header{
  {name="Authorization",value=strings.concatenate({"Bearer ",bridge_token},context.temp_allocator)},
  {name="X-Heimdall-Instance-Token",value=strings.concatenate({"hit_",instance},context.temp_allocator)},
 }
 other:=action_api_data(t,agent_webhook_test_call(&f,"create","{}",instance,headers),201)
 other_id:=other["webhook"].(json.Object)["webhook_id"].(string)
 other_token:=other["token"].(string)
 sample:=strings.concatenate({`{"id":"`,other_id,`","webhook_secret":"`,other_token,`","body":"{}"}`},context.temp_allocator)
 testing.expect_value(t,agent_webhook_test_call(&f,"test",sample,instance,headers).status,202)
 // Owner A's relay bucket is separate from public ingress at that same peer IP.
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id,token,ip="127.0.0.1:4444")).status,202)
}
