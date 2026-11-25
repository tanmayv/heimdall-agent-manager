package http

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import webhooks "odin_test:hub/service/webhooks"

agent_webhook_handler :: proc(ctx:rawptr,req:Request)->Response {
 h:=(^Agent_Action_Handlers)(ctx)
 _,inst,ok,response:=require_instance_action_auth(h,req)
 if !ok do return response
 wh:=h.webhooks
 if wh==nil || wh.service==nil || wh.actions==nil do return action_error(domain.domain_error(.Internal_Error,"webhooks unavailable"),req.request_id)
 owner:=string(inst.owner_user_id)
 if enabled,gate:=require_experiment_enabled(wh.actions.experiments,owner,domain.ACTIONS_EXPERIMENT_KEY,req.request_id);!enabled do return gate
 params:contracts.Webhook_Parameters
 if json.unmarshal_string(verbatim_params(req.body),&params,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid webhook params"),req.request_id)
 verb:=path_part(req.path,6)
 if verb=="list" {
  rows,e:=webhooks.list(wh.service,owner);defer domain.event_webhooks_destroy(rows)
  if e.code!=.None do return action_error(e,req.request_id)
  return action_response(req,rows)
 }
 switch verb {
 case "create","update","show","rotate","enable","disable","delete","test":
 case: return action_error(domain.domain_error(.Not_Found,"webhook verb not found"),req.request_id)
 }
 if verb!="create" && strings.trim_space(params.id)=="" do return action_error(domain.domain_error(.Validation_Failed,"webhook id required"),req.request_id)
 if verb=="show" || verb=="test" {
  row,e:=webhooks.get(wh.service,owner,params.id);defer domain.event_webhook_destroy(&row)
  if e.code!=.None do return action_error(e,req.request_id)
  if verb=="show" do return action_response(req,row)
  if !row.enabled do return action_error(domain.domain_error(.Conflict,"webhook disabled; enable it before testing"),req.request_id)
  if len(params.body)>webhooks.effective_limits(wh.service).body_bytes do return event_webhook_status(413,`{"error":"body_too_large"}`)
  sample:json.Value
  if json.unmarshal_string(params.body,&sample,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid sample body"),req.request_id)
  object,is_object:=sample.(json.Object)
  if !is_object do return action_error(domain.domain_error(.Validation_Failed,"sample body must be an object"),req.request_id)
  object["_test"]=json.Boolean(true)
  body,err:=json.marshal(sample,allocator=context.temp_allocator)
  if err!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid sample body"),req.request_id)
  // Reuse ingress auth, validation, limits and event emission. Never accept a URL.
  ingress:=req
  ingress.path=strings.concatenate({"/api/v1/hooks/",params.id},context.temp_allocator)
  ingress.raw_target=ingress.path
  ingress.query=""
  ingress.body=string(body)
  ingress.headers=[]contracts.HTTP_Header{
   {name="Content-Type",value="application/json"},
   {name="Authorization",value=strings.concatenate({"Bearer ",params.webhook_secret},context.temp_allocator)},
  }
  return event_webhook_receive(wh,ingress,inst.agent_instance_id,owner)
 }
 input:=webhooks.Input{name=params.name,dedupe_header=params.dedupe_header}
 operation:=verb
 if verb=="enable" || verb=="disable" {operation="update";input.enabled=verb=="enable"}
 row,token,e:=webhooks.mutate(wh.service,owner,params.id,operation,input)
 defer domain.event_webhook_destroy(&row)
 defer delete(token)
 if e.code!=.None do return action_error(e,req.request_id)
 if verb=="delete" do return action_response(req,struct{deleted:bool}{true})
 if token!="" {
  status:=201 if verb=="create" else 200
  bearer_url:=strings.concatenate({strings.trim_right(h.public_app_origin,"/"),"/api/v1/hooks/",row.webhook_id},context.temp_allocator)
  secret_url:=strings.concatenate({bearer_url,"/",token},context.temp_allocator)
  result:=action_response(req,struct{webhook:domain.Event_Webhook,token,bearer_url,secret_url:string}{row,token,bearer_url,secret_url},status)
  result.sensitive=true
  return result
 }
 return action_response(req,row)
}
