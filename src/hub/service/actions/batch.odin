package actions

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

BATCH_MAX_RUNS :: 20
BATCH_MAX_BYTES :: 24*1024
Prepared_Run :: struct {action:domain.Action,run:domain.Action_Run}
Target_Group :: struct {members:[dynamic]Prepared_Run,rules:[]domain.Action_Target_Rule}

// Keys are structured JSON, not concatenated IDs: owner and placement boundaries
// must remain unambiguous even when user-controlled selector/model text contains separators.
target_group_key :: proc(item:Prepared_Run,rules:[]domain.Action_Target_Rule)->string {
 a:=item.action
 key:=[]string{string(a.owner_user_id),a.target_kind}
 switch a.target_kind {
 case domain.ACTION_TARGET_INSTANCE: key=append_key(key,string(a.target_instance_id))
 case domain.ACTION_TARGET_BOT: key=append_key(key,string(a.target_bot_id))
 case domain.ACTION_TARGET_AGENT:
  if a.instance_strategy==domain.ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN {
   key=append_key(key,item.run.run_id)
  } else {
   selector:=a.placement_selector
   if selector=="" do selector="first"
   bytes,_:=json.marshal(rules,allocator=context.temp_allocator)
   key=append_key(key,string(a.target_agent_id),string(a.target_project_id),selector,string(bytes))
  }
 case: key=append_key(key,item.run.run_id)
 }
 bytes,_:=json.marshal(key,allocator=context.temp_allocator)
 return string(bytes)
}
append_key :: proc(key:[]string,values:..string)->[]string {
 out:=make([]string,len(key)+len(values),context.temp_allocator)
 copy(out,key);copy(out[len(key):],values)
 return out
}
route_groups :: proc(r:^Router,items:[]Prepared_Run) {
 slice.sort_by(items,proc(a,b:Prepared_Run)->bool {
  if a.run.created_at!=b.run.created_at do return a.run.created_at<b.run.created_at
  return a.run.run_id<b.run.run_id
 })
 groups:=make([dynamic]Target_Group)
 indices:=make(map[string]int)
 owner_rules:=make(map[string][]iface.Action_Rule_Row)
 failed_owners:=make(map[string]bool)
 for item in items {
  rules:=make([dynamic]domain.Action_Target_Rule)
  if item.action.target_kind==domain.ACTION_TARGET_AGENT {
   owner:=string(item.action.owner_user_id)
   if failed_owners[owner] do continue
   rows,loaded:=owner_rules[owner]
   if !loaded {
    uow,ok,_:=iface.unit_of_work_begin(r.factory)
    if !ok {failed_owners[owner]=true;continue}
    err:domain.Domain_Error
    rows,err=uow.repos.actions.rules_for_owner(uow.repos.actions.ctx,owner)
    iface.unit_of_work_rollback(&uow)
    if err.code!=.None {failed_owners[owner]=true;continue}
    owner_rules[owner]=rows
   }
   for row in rows do if row.action_id==string(item.action.id) do append(&rules,row.rule)
  }
  key:=target_group_key(item,rules[:])
  index,exists:=indices[key]
  if !exists {
   index=len(groups);indices[key]=index
   append(&groups,Target_Group{members=make([dynamic]Prepared_Run),rules=rules[:]})
  }
  append(&groups[index].members,item)
 }
 for group in groups do route_group(r,group)
}

batch_render :: proc(repo:^iface.Action_Repository,members:[]Prepared_Run)->(string,string,int,domain.Domain_Error) {
 if len(members)==1 do return "","",0,{}
 body:=strings.builder_make(context.temp_allocator)
 strings.write_string(&body,fmt.tprintf("%d actions fired for you.\n",len(members)))
 runs:=make(json.Array,0,len(members),context.temp_allocator)
 notice_count:=0
 untrusted:=false
 metadata:json.Object
 for item,i in members {
  joined,err:=repo.run_joined_count(repo.ctx,item.run.run_id)
  if err.code!=.None do return "","",0,err
  raw,e:=prompt_metadata(repo,item.action,item.run,joined)
  if e.code!=.None do return "","",0,e
  value:json.Value
  if json.unmarshal(transmute([]u8)raw,&value,allocator=context.temp_allocator)!=nil do return "","",0,domain.domain_error(.Internal_Error,"cannot decode batch metadata")
  object,_:=value.(json.Object)
  if i==0 do metadata=object
  fired,_:=object["triggered_at"].(string)
  events:=""
  if joined>0 do events=fmt.tprintf(", %d events",joined+1)
  strings.write_string(&body,fmt.tprintf("\n### %d. %s  (%s, %s%s)\n%s\n",i+1,item.action.name,item.run.event_type,fired,events,render(item.action.prompt_text,item.action,item.run,joined,context.temp_allocator,&untrusted)))
  entry:=make(json.Object,context.temp_allocator)
  for key in ([]string{"action_id","action_name","run_id","trigger_id","event_type","event_id","joined_count"}) do entry[key]=object[key]
  append(&runs,entry)
  notice_count+=joined+1
 }
 metadata["runs"]=runs
 if untrusted do strings.write_string(&body,"\n"+WEBHOOK_UNTRUSTED_LINE)
 bytes,e:=json.marshal(metadata,allocator=context.temp_allocator)
 if e!=nil do return "","",0,domain.domain_error(.Internal_Error,"cannot encode batch metadata")
 return strings.to_string(body),string(bytes),notice_count,{}
}
route_group :: proc(r:^Router,group:Target_Group) {
 first:=group.members[0]
 plan:=prompt_plan_with_rules(r,first.action,first.run,nil,group.rules,true)
 uow,ok,_:=iface.unit_of_work_begin(r.factory)
 if !ok do return
 defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
 repo:=&uow.repos.actions
 now:=platform.clock_now(r.clock)
 members:=make([dynamic]Prepared_Run)
 for &item in group.members {
  current,found,err:=repo.run_get(repo.ctx,item.run.run_id)
  if err.code!=.None do return
  if !found || current.state!=item.run.state do continue
  item.run=current
  if !plan.ok {
   if e:=finish_run(r,&uow,current,domain.ACTION_RUN_FAILED,plan.reason,now);e.code!=.None do return
  } else {append(&members,item)}
 }
 if !plan.ok || len(members)==0 {_,_=iface.unit_of_work_commit(&uow);uow.ctx=nil;return}
 open_id,expiry,open,err:=repo.target_open_delivery(repo.ctx,string(first.action.owner_user_id),plan.instance_id)
 if err.code!=.None do return
 // A lost terminal wake must not leave a target blocked forever. Expire in
 // this UoW, then recheck: expiry may replace/finalize the delivery through its sink.
 if open && expiry<=now && r.pipeline.expire!=nil {
  if _,e:=r.pipeline.expire(r.pipeline.ctx,&uow,open_id);e.code!=.None do return
  _,expiry,open,err=repo.target_open_delivery(repo.ctx,string(first.action.owner_user_id),plan.instance_id)
  if err.code!=.None do return
 }
 if open {
  if e:=park_members(repo,members[:],plan.instance_id,expiry);e.code!=.None do return
  _,_=iface.unit_of_work_commit(&uow);uow.ctx=nil;return
 }
 count:=min(len(members),BATCH_MAX_RUNS)
 body,metadata,notice_count,render_err:=batch_render(repo,members[:count])
 if render_err.code!=.None do return
 for count>1 && len(body)>BATCH_MAX_BYTES {
  count-=1
  body,metadata,notice_count,render_err=batch_render(repo,members[:count])
  if render_err.code!=.None do return
 }
 message,id,route_err:=route_prompt(r,&uow,members[0].action,members[0].run,plan,0,nil,body,metadata,notice_count)
 if route_err.code!=.None {
  reason:="delivery_failed"
  if route_err.message=="bridge_too_old" do reason="bridge_too_old"
  iface.unit_of_work_rollback(&uow);uow.ctx=nil
  for item in members do record_route_failure(r,item.run.run_id,item.run.state,reason)
  return
 }
 updates:=make([]iface.Action_Batch_Member,count,context.temp_allocator)
 for item,i in members[:count] do updates[i]={run_id=item.run.run_id,from_state=item.run.state}
 if e:=repo.runs_route_batch(repo.ctx,updates,id,message,plan.instance_id,now,plan.rule_position);e.code!=.None do return
 if plan.spawned {
  for item in members[:count] do if e:=repo.set_last_spawned(repo.ctx,item.action.id,plan.instance_id,now);e.code!=.None do return
 }
 if count<len(members) {
  delivery,found,e:=uow.repos.pipeline_deliveries.get(uow.repos.pipeline_deliveries.ctx,id)
  if e.code!=.None || !found do return
  if e:=park_members(repo,members[count:],plan.instance_id,delivery.expires_at);e.code!=.None do return
 }
 committed,_:=iface.unit_of_work_commit(&uow);uow.ctx=nil
 if committed && plan.stop_instance_id!="" && r.agents.stop!=nil do r.agents.stop(r.agents.ctx,string(first.action.owner_user_id),plan.stop_instance_id)
}
park_members :: proc(repo:^iface.Action_Repository,members:[]Prepared_Run,instance_id,expiry:string)->domain.Domain_Error {
 for item in members {
  next:=item.run
  next.state=domain.ACTION_RUN_DEFERRED;next.target_instance_id=instance_id;next.not_before=expiry
  changed,err:=repo.run_transition(repo.ctx,next,item.run.state)
  if err.code!=.None do return err
  if !changed do return domain.domain_error(.Conflict,"action changed during parking")
 }
 return {}
}
