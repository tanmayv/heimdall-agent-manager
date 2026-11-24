package http
import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import webhooks "odin_test:hub/service/webhooks"
import contracts "odin_test:contracts"
import iface "odin_test:hub/repository/iface"

agent_webhook_test_call :: proc(f:^Webhook_Test,verb,params:string)->Response {
 f.api.wire.ah.webhooks=&f.h
 f.api.wire.ah.public_app_origin="https://example.test"
 body:=strings.concatenate({`{"agent_instance_id":"`,f.api.wire.instance_id,`","params":`,params,"}"},context.temp_allocator)
 req:=wire_agent_request(f.api.wire,"",body)
 req.path=strings.concatenate({"/api/v1/agent-actions/automations/webhooks/",verb},context.temp_allocator)
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
 testing.expect_value(t,agent_webhook_test_call(&f,"test",test_params).status,401)
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
