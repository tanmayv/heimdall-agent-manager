#+feature dynamic-literals
package http

import "core:encoding/json"
import contracts "odin_test:contracts"
import "core:time"
import "core:strconv"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import actions "odin_test:hub/service/actions"
import auth_service "odin_test:hub/service/auth"
import schedule "odin_test:lib/schedule"

Action_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	service: ^actions.Service,
 router:^actions.Router,
	experiments: ^iface.Experiment_Repository,
}
action_route_auth :: proc(h:^Action_Handlers,req:Request) -> (string,bool,Response) {
	auth,ok,response:=require_auth(h.auth,req)
	if !ok do return "",false,response
	if enabled,gate:=require_experiment_enabled(h.experiments,auth.user_id,domain.ACTIONS_EXPERIMENT_KEY,req.request_id); !enabled do return "",false,gate
	return auth.user_id,true,{}
}
action_response :: proc(req:Request,data:any,status:=200) -> Response {
	bytes,err:=json.marshal(data)
	if err!=nil do return action_error(domain.domain_error(.Internal_Error,"could not encode action response"),req.request_id)
	defer delete(bytes)
	result:=respond_success(string(bytes),req.request_id,auth_ctx_server_time(req))
	result.status=status
	return result
}
action_json_object :: proc() -> json.Object {return make(json.Object,context.temp_allocator)}
action_next_fire :: proc(s:^actions.Service,a:domain.Action,trigger:domain.Action_Trigger,config:json.Object) -> string {
	if trigger.kind!="schedule" || !a.enabled || !trigger.enabled do return ""
	mode,_:=config["mode"].(string)
	now,_:=platform.rfc3339_to_unix_ms(platform.clock_now(s.clock))
	if mode=="once" {
		at,_:=config["run_at"].(string)
		parsed,consumed:=time.rfc3339_to_time_utc(at)
		if consumed==0 || time.to_unix_nanoseconds(parsed)/1_000_000<=now do return ""
		return platform.format_rfc3339_utc(parsed)
	}
	if mode!="cron" do return ""
	expr,_:=config["cron_expr"].(string)
	zone,_:=config["timezone"].(string)
	blackout:="[]"
	if dates,present:=config["blackout_dates"]; present {
		bytes,_:=json.marshal(dates,allocator=context.temp_allocator)
		blackout=string(bytes)
	}
	from,until:i64
	if at,ok:=config["active_from"].(string); ok {
		if parsed,consumed:=time.rfc3339_to_time_utc(at); consumed!=0 do from=time.to_unix_nanoseconds(parsed)/1_000_000
	}
	if at,ok:=config["active_until"].(string); ok {
		if parsed,consumed:=time.rfc3339_to_time_utc(at); consumed!=0 do until=time.to_unix_nanoseconds(parsed)/1_000_000
	}
	next,ok:=schedule.next_cron_slot(expr,zone,blackout,from,until,now)
	if !ok do return ""
	return platform.format_rfc3339_utc(time.unix(next/1000,(next%1000)*1_000_000))
}
action_view_json :: proc(s:^actions.Service,v:actions.Action_View) -> json.Object {
	a:=v.action
	target:=action_json_object()
	target["kind"]=a.target_kind
	switch a.target_kind {
	case "agent":
		target["agent_id"]=string(a.target_agent_id)
		target["project_id"]=string(a.target_project_id)
		target["instance_strategy"]=a.instance_strategy
		target["selector"]=a.placement_selector
		target["last_spawned_instance_id"]=string(a.last_spawned_instance_id)
		rules:=make(json.Array,len(v.rules),allocator=context.temp_allocator)
		for rule,i in v.rules {
			obj:=action_json_object()
			obj["bridge_id"]=rule.bridge_id;obj["provider"]=rule.provider;obj["model"]=rule.model
			rules[i]=obj
		}
		target["rules"]=rules
	case "instance": target["instance_id"]=string(a.target_instance_id)
	case "bot": target["bot_id"]=a.target_bot_id
	}
	triggers:=make(json.Array,len(v.triggers),allocator=context.temp_allocator)
	for trigger,i in v.triggers {
		value:json.Value
		_ = json.unmarshal(transmute([]u8)trigger.config_json,&value,allocator=context.temp_allocator)
		config,_:=value.(json.Object)
		obj:=action_json_object()
		obj["id"]=trigger.trigger_id;obj["kind"]=trigger.kind;obj["enabled"]=trigger.enabled
		obj["delay_s"]=json.Integer(trigger.delay_s)
		obj["rev"]=json.Integer(trigger.rev);obj["config"]=config
		obj["next_fire_at"]=action_next_fire(s,a,trigger,config)
		obj["created_at"]=trigger.created_at;obj["updated_at"]=trigger.updated_at
		triggers[i]=obj
	}
	obj:=action_json_object()
	obj["id"]=string(a.id);obj["owner_user_id"]=string(a.owner_user_id)
	obj["name"]=a.name;obj["prompt_text"]=a.prompt_text;obj["enabled"]=a.enabled
	obj["min_interval_s"]=json.Integer(a.min_interval_s)
	obj["target"]=target;obj["triggers"]=triggers
	obj["created_at"]=a.created_at;obj["updated_at"]=a.updated_at
 obj["created_by"]=a.created_by;obj["updated_by"]=a.updated_by
	return obj
}
list_actions_handler :: proc(ctx:rawptr,req:Request) -> Response {
	h:=(^Action_Handlers)(ctx)
	owner,ok,response:=action_route_auth(h,req)
	if !ok do return response
	rows,err:=actions.list(h.service,owner)
	defer actions.action_views_destroy(rows)
	if err.code!=.None do return action_error(err,req.request_id)
	values:=make([]json.Value,len(rows),context.temp_allocator)
	for row,i in rows do values[i]=action_view_json(h.service,row)
	return action_response(req,values)
}
create_action_handler :: proc(ctx:rawptr,req:Request) -> Response {
	h:=(^Action_Handlers)(ctx)
	owner,ok,response:=action_route_auth(h,req)
	if !ok do return response
	input:actions.Action_Input
	if json.unmarshal_string(req.body,&input,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid action request"),req.request_id)
	v,err:=actions.create(h.service,owner,input)
	defer actions.action_view_destroy(&v)
	if err.code!=.None do return action_error(err,req.request_id)
	return action_response(req,action_view_json(h.service,v),201)
}
get_action_handler :: proc(ctx:rawptr,req:Request) -> Response {
	h:=(^Action_Handlers)(ctx)
	owner,ok,response:=action_route_auth(h,req)
	if !ok do return response
	v,err:=actions.get(h.service,owner,path_part(req.path,4))
	defer actions.action_view_destroy(&v)
	if err.code!=.None do return action_error(err,req.request_id)
	return action_response(req,action_view_json(h.service,v))
}
patch_action_handler :: proc(ctx:rawptr,req:Request) -> Response {
	h:=(^Action_Handlers)(ctx)
	owner,ok,response:=action_route_auth(h,req)
	if !ok do return response
	input:actions.Action_Input
	if json.unmarshal_string(req.body,&input,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid action request"),req.request_id)
	v,err:=actions.update(h.service,owner,path_part(req.path,4),input)
	defer actions.action_view_destroy(&v)
	if err.code!=.None do return action_error(err,req.request_id)
	return action_response(req,action_view_json(h.service,v))
}
delete_action_handler :: proc(ctx:rawptr,req:Request) -> Response {
	h:=(^Action_Handlers)(ctx)
	owner,ok,response:=action_route_auth(h,req)
	if !ok do return response
	if err:=actions.delete_action(h.service,owner,path_part(req.path,4)); err.code!=.None do return action_error(err,req.request_id)
	return action_response(req,struct{deleted:bool}{true})
}
enable_action_handler :: proc(ctx:rawptr,req:Request) -> Response {return action_enable_response(ctx,req,true)}
disable_action_handler :: proc(ctx:rawptr,req:Request) -> Response {return action_enable_response(ctx,req,false)}
action_enable_response :: proc(ctx:rawptr,req:Request,enabled:bool) -> Response {
	h:=(^Action_Handlers)(ctx)
	owner,ok,response:=action_route_auth(h,req)
	if !ok do return response
	v,err:=actions.set_enabled(h.service,owner,path_part(req.path,4),enabled)
	defer actions.action_view_destroy(&v)
	if err.code!=.None do return action_error(err,req.request_id)
	return action_response(req,action_view_json(h.service,v))
}
action_trigger_types_handler :: proc(ctx:rawptr,req:Request) -> Response {
	h:=(^Action_Handlers)(ctx)
	_,ok,response:=action_route_auth(h,req)
	if !ok do return response
	return action_response(req,actions.trigger_types(h.service))
}

action_error :: proc(err:domain.Domain_Error,request_id:string) -> Response {
	e:=err
	if e.code==.Validation_Failed do e.code=.Unprocessable_Entity
	return respond_error(e,request_id)
}

list_action_runs_handler :: proc(ctx:rawptr,req:Request)->Response {
 h:=(^Action_Handlers)(ctx)
 owner,ok,response:=action_route_auth(h,req)
 if !ok do return response
 return action_runs_response(h,req,owner,path_part(req.path,4),req.query)
}
action_runs_response :: proc(h:^Action_Handlers,req:Request,owner,id,query:string)->Response {
 limit:=50
 if text:=query_value(query,"limit"); text!="" {
  n,valid:=strconv.parse_int(text)
  if !valid || n<1 || n>200 do return action_error(domain.domain_error(.Validation_Failed,"limit must be 1..200"),req.request_id)
  limit=n
 }
 return action_runs_page(h,req,owner,id,limit,query_value(query,"before"),query_value(query,"before_id"))
}
action_runs_page :: proc(h:^Action_Handlers,req:Request,owner,id:string,limit:int,before,before_id:string)->Response {
 if h.router==nil do return action_error(domain.domain_error(.Internal_Error,"actions router unavailable"),req.request_id)
 rows,err:=actions.list_runs(h.router,owner,id,limit,before,before_id)
 defer actions.run_views_destroy(rows)
 if err.code!=.None do return action_error(err,req.request_id)
 values:=make(json.Array,len(rows),context.temp_allocator)
 for row,i in rows {
  run:=row.run
  obj:=action_json_object()
  obj["id"]=run.run_id; obj["trigger_id"]=run.trigger_id;obj["event_type"]=run.event_type
  obj["event_id"]=run.event_id;obj["state"]=run.state;obj["reason"]=run.reason
  obj["not_before"]=run.not_before;obj["joined_run_id"]=run.joined_run_id
  obj["event_params"]=json_value_or_null(run.event_params_json)
  obj["batch_size"]=json.Integer(row.batch_size)
  obj["joined_count"]=json.Integer(row.joined_count);obj["rule_position"]=json.Integer(run.rule_position)
  obj["target_instance_id"]=run.target_instance_id;obj["message_id"]=run.message_id;obj["delivery_id"]=run.delivery_id
  obj["delivery_expires_at"]=row.delivery_expires_at
  obj["delivery_state"]=row.delivery_state;obj["delivery_outcome"]=row.delivery_outcome
  obj["created_at"]=run.created_at;obj["started_at"]=run.started_at;obj["finished_at"]=run.finished_at
  values[i]=obj
 }
 return action_response(req,values)
}

action_filter_test_handler :: proc(ctx:rawptr,req:Request)->Response {
 h:=(^Action_Handlers)(ctx)
 _,ok,response:=action_route_auth(h,req)
 if !ok do return response
 input:contracts.Action_Filter_Test_Request
 if json.unmarshal_string(req.body,&input,.JSON,context.temp_allocator)!=nil do return action_error(domain.domain_error(.Validation_Failed,"invalid filter test request"),req.request_id)
 return action_response(req,actions.filter_test(h.service,input))
}
