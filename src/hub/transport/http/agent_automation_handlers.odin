package http

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import actions "odin_test:hub/service/actions"
import contracts "odin_test:contracts"

// Agent automations use the authenticated instance owner, never params.owner.
// The bridge relays its instance token; action cards have separate routes.
agent_automation_handler :: proc(ctx:rawptr, req:Request)->Response {
 h:=(^Agent_Action_Handlers)(ctx)
 _,inst,ok,response:=require_instance_action_auth(h,req)
 if !ok do return response
 ah:=h.automations
 if ah==nil || ah.service==nil do return action_error(domain.domain_error(.Internal_Error,"automations unavailable"),req.request_id)
 owner:=string(inst.owner_user_id)
 if enabled,gate:=require_experiment_enabled(ah.experiments,owner,domain.ACTIONS_EXPERIMENT_KEY,req.request_id);!enabled do return gate
 params:=verbatim_params(req.body)
 verb:=path_part(req.path,5)
 input_params:contracts.Automation_Parameters
 // Filter-test has its own request schema; other verbs share pagination/id.
 if verb!="filter-test" && json.unmarshal_string(params,&input_params,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid automation params"),req.request_id)
 id:=input_params.id
 switch verb {
 case "trigger-types": return action_response(req,actions.trigger_types(ah.service))
 case "filter-test":
  input:contracts.Action_Filter_Test_Request
  if json.unmarshal_string(params,&input,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid filter test request"),req.request_id)
  return action_response(req,actions.filter_test(ah.service,input))
 case "list":
  rows,err:=actions.list(ah.service,owner)
  defer actions.action_views_destroy(rows)
  if err.code!=.None do return action_error(err,req.request_id)
  values:=make(json.Array,len(rows),context.temp_allocator)
  for row,i in rows do values[i]=action_view_json(ah.service,row)
  return action_response(req,values)
 case "create","update","show","delete","runs":
 case: return action_error(domain.domain_error(.Not_Found,"automation verb not found"),req.request_id)
 }
 if verb!="create" && strings.trim_space(id)=="" do return action_error(domain.domain_error(.Validation_Failed,"automation id required"),req.request_id)
 if verb=="delete" {
  if err:=actions.delete_action(ah.service,owner,id);err.code!=.None do return action_error(err,req.request_id)
  return action_response(req,struct{deleted:bool}{true})
 }
 if verb=="runs" {
  // Query keys use the same validated pagination contract as the user API.
  limit:=50
  if n,present:=input_params.limit.?;present {
   if n<1 || n>200 do return action_error(domain.domain_error(.Validation_Failed,"limit must be 1..200"),req.request_id)
   limit=n
  }
  return action_runs_page(ah,req,owner,id,limit,input_params.before,input_params.before_id)
 }
 v:actions.Action_View
 err:domain.Domain_Error
 if verb=="show" {
  v,err=actions.get(ah.service,owner,id)
 } else {
  input:actions.Action_Input
  if json.unmarshal_string(verbatim_field(params,"input"),&input,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid automation request"),req.request_id)
  if verb=="create" {v,err=actions.create(ah.service,owner,input,inst.agent_instance_id)} else {v,err=actions.update(ah.service,owner,id,input,inst.agent_instance_id)}
 }
 defer actions.action_view_destroy(&v)
 if err.code!=.None do return action_error(err,req.request_id)
 status:=200
 if verb=="create" do status=201
 return action_response(req,action_view_json(ah.service,v),status)
}
