#+feature dynamic-literals
package actions

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import delivery "odin_test:hub/service/delivery"
import placement "odin_test:hub/service/placement"

Effect :: struct {kind: string, plan: proc(r:^Router, action:domain.Action, run:domain.Action_Run, exclude:[]string) -> Plan}
EFFECTS := [?]Effect{prompt_effect}
Plan :: struct {
 ok: bool,
 reason, bridge_id, instance_id, conversation_id: string,
 rule_position: int,
 stop_instance_id: string,
 spawned: bool,
}
Route_Port :: struct {
 ctx: rawptr,
 route: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,input:delivery.Route_Input)->(string,domain.Domain_Error),
 expire: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,delivery_id:string)->(bool,domain.Domain_Error),
 unread: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,delivery_id:string)->domain.Domain_Error,
}
Agent_Port :: struct {
 ctx: rawptr,
 find: proc(ctx:rawptr,owner,agent_id,project_id,prefer_instance:string,c:placement.Candidate)->(string,string,bool),
 create: proc(ctx:rawptr,owner,agent_id,project_id:string,c:placement.Candidate)->(string,string,domain.Domain_Error),
 stop: proc(ctx:rawptr,owner,instance_id:string),
 instance: proc(ctx:rawptr,owner,instance_id:string)->(string,string,string,bool),
 persist_prompt: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,conversation_id,body,metadata_json:string)->(string,domain.Domain_Error),
 retire_prompt: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,message_id,moved_to_instance_id:string)->domain.Domain_Error,
}
Message_Created_Hook :: struct {
 ctx:rawptr,
 created:proc(ctx:rawptr,message:domain.Chat_Message),
}
Prompt_Hint :: struct {hook:Message_Created_Hook,message:domain.Chat_Message}
prompt_hint_discard :: proc(ctx:rawptr) {
 context.allocator=runtime.heap_allocator()
 hint:=(^Prompt_Hint)(ctx)
 delete(hint.message.message_id)
 delete(hint.message.conversation_id)
 delete(string(hint.message.owner_user_id))
 delete(hint.message.message_type)
 delete(hint.message.direction)
 delete(hint.message.created_at)
 free(hint)
}
prompt_hint_run :: proc(ctx:rawptr) {
 hint:=(^Prompt_Hint)(ctx)
 defer prompt_hint_discard(ctx)
 hint.hook.created(hint.hook.ctx,hint.message)
}
Router :: struct {
 message_created:Message_Created_Hook,
 factory:^iface.Unit_Of_Work_Factory,
 experiments:^iface.Experiment_Repository,
 placement:^placement.Service,
 agents:Agent_Port,
 pipeline:Route_Port,
 support:Schedule_Support_Port,
 clock:^platform.Clock,
 ids:^platform.ID_Generator,
}
Resume_Hint :: struct {owner,run_id,not_before:string}
history_cutoff :: proc(now:string)->string {
 ms,ok:=platform.rfc3339_to_unix_ms(now)
 if !ok do return ""
 return platform.format_rfc3339_utc(time.Time{_nsec=(ms-i64(30*24*time.Hour/time.Millisecond))*1_000_000})
}
finish_run :: proc(r:^Router,uow:^iface.Unit_Of_Work,run:domain.Action_Run,state,reason,now:string)->domain.Domain_Error {
 repo:=&uow.repos.actions
 next:=run
 next.state=state; next.reason=reason; next.finished_at=now
 changed,err:=repo.run_transition(repo.ctx,next,run.state)
 if err.code!=.None do return err
 if !changed do return domain.domain_error(.Conflict,"action run changed")
 if err:=repo.runs_prune(repo.ctx,run.action_id,200,history_cutoff(now)); err.code!=.None do return err
 // A terminal open run frees the action slot. Persist a wake in the same
 // transaction so different-key settle runs resume even on a quiet hub.
 if !run.settle_pending {
  waiting,read_err:=repo.run_settle_waiting(repo.ctx,run.action_id,now)
  if read_err.code!=.None do return read_err
  if !waiting do return {}
  sc:=Sync_Context{outbox=&uow.repos.event_outbox,clock=r.clock,ids=r.ids}
  row:=schedule_row(&sc,string(run.owner_user_id),fmt.tprintf("ev.%s.action.%s.ready",run.owner_user_id,run.action_id),"action.ready",string(run.action_id),"","",0,json.Object{})
  defer domain.event_outbox_row_destroy(&row)
  return sc.outbox.append(sc.outbox.ctx,row)
 }
 return {}
}
expire_open_run :: proc(r:^Router,uow:^iface.Unit_Of_Work,action_id:domain.Action_ID)->(bool,domain.Domain_Error) {
 repo:=&uow.repos.actions
 run,found,err:=repo.run_open(repo.ctx,action_id)
 defer domain.action_run_destroy(&run)
 if err.code!=.None do return false,err
 if found && run.state==domain.ACTION_RUN_ROUTED && r.pipeline.expire!=nil do return r.pipeline.expire(r.pipeline.ctx,uow,run.delivery_id)
 return false,{}
}

on_delivery_final :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,d:domain.Pipeline_Delivery)->domain.Domain_Error {
 r:=(^Router)(ctx)
 if !strings.has_prefix(d.ref,"run:") do return {}
 repo:=&uow.repos.actions
 run,found,err:=repo.run_get(repo.ctx,d.ref[4:])
 defer domain.action_run_destroy(&run)
 if err.code!=.None do return err
 if !found || run.state!=domain.ACTION_RUN_ROUTED || run.delivery_id!=d.delivery_id do return {}
 state,reason:=domain.ACTION_RUN_FAILED,d.reason
 switch d.state {
 case domain.DELIVERY_DONE: state=domain.ACTION_RUN_DELIVERED; reason=""
 case domain.DELIVERY_FAILED:
  switch reason {case "bridge_offline","no_answer","bridge_too_old","target_missing","not_read": case: reason="start_failed"}
 case: return {}
 }
 return finish_run(r,uow,run,state,reason,platform.clock_now(r.clock))
}
prompt_plan :: proc(r:^Router,action:domain.Action,run:domain.Action_Run,exclude:[]string)->Plan {
 owner:=string(action.owner_user_id)
 features:=[]string{contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1}
 req:=placement.Requirements{owner=owner,agent_id=string(action.target_agent_id),features=features,exclude=exclude}
 if action.target_kind==domain.ACTION_TARGET_INSTANCE do return instance_plan(r,owner,string(action.target_instance_id),req)
 if action.target_kind==domain.ACTION_TARGET_BOT {
  uow,opened,_:=iface.unit_of_work_begin(r.factory)
  if !opened do return {reason="delivery_failed"}
  bot,err:=owned_bot(&uow.repos.bots,owner,action.target_bot_id)
  defer domain.bot_destroy(&bot)
  instance_id:=strings.clone(bot.agent_instance_id,context.temp_allocator)
  committed,_:=iface.unit_of_work_commit(&uow)
  if !committed do return {reason="delivery_failed"}
  if err.code!=.None && err.code!=.Not_Found do return {reason="delivery_failed"}
  if err.code==.Not_Found || instance_id=="" do return {reason="target_missing"}
  return instance_plan(r,owner,instance_id,req)
 }
 if action.target_kind!=domain.ACTION_TARGET_AGENT do return {reason="target_missing"}
 uow,opened,_:=iface.unit_of_work_begin(r.factory)
 if !opened do return {reason="delivery_failed"}
 rules,err:=uow.repos.actions.rules_list(uow.repos.actions.ctx,action.id)
 committed,_:=iface.unit_of_work_commit(&uow)
 defer domain.action_rules_destroy(rules)
 if !committed || err.code!=.None do return {reason="delivery_failed"}
 prules:=make([]placement.Rule,len(rules),context.temp_allocator)
 for rule,i in rules do prules[i]={position=rule.position,bridge_id=rule.bridge_id,provider=rule.provider,model=rule.model}
 selector:=action.placement_selector
 if selector=="" do selector="first"
 c,selected,_:=placement.select(r.placement,req,prules,selector)
 if !selected {
  // A single pinned offline machine may reuse a stored instance, never create.
  if len(rules)>0 && rules[0].bridge_id!=placement.ANY {
   pinned:=rules[0].bridge_id
   same:=true
   for rule in rules do if rule.bridge_id!=pinned do same=false
   for id in exclude do if id==pinned do same=false
   if same {
    b,found,e:=iface.bridge_get_bridge(r.placement.bridges,pinned)
    defer domain.bridge_destroy(&b)
    _,why:=placement.bridge_eligible(r.placement,b,req)
    if found && e.code==.None && why==placement.REASON_OFFLINE {
     if !placement.bridge_has_feature(b,contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1) do return {reason="bridge_too_old"}
     c={bridge_id=pinned,provider=rules[0].provider,model=rules[0].model,rule_position=rules[0].position}
     id,conversation,exists:=r.agents.find(r.agents.ctx,owner,string(action.target_agent_id),string(action.target_project_id),string(action.last_spawned_instance_id),c)
     if exists do return {ok=true,bridge_id=strings.clone(pinned,context.temp_allocator),instance_id=id,conversation_id=conversation,rule_position=c.rule_position}
     return {reason="no_placement"}
    }
   }
  }
  req.features=nil
  _,without_feature,_:=placement.select(r.placement,req,prules,selector)
  if without_feature do return {reason="bridge_too_old"}
  return {reason="no_placement"}
 }
 plan:=Plan{bridge_id=c.bridge_id,rule_position=c.rule_position}
 if action.instance_strategy!=domain.ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN {
  id,conversation,found:=r.agents.find(r.agents.ctx,owner,string(action.target_agent_id),string(action.target_project_id),string(action.last_spawned_instance_id),c)
  if found {plan.ok=true; plan.instance_id=id; plan.conversation_id=conversation; return plan}
 }
 id,conversation,e:=r.agents.create(r.agents.ctx,owner,string(action.target_agent_id),string(action.target_project_id),c)
 if e.code!=.None do return {reason="delivery_failed"}
 plan.ok=true; plan.spawned=true; plan.instance_id=id; plan.conversation_id=conversation
 if action.instance_strategy==domain.ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN do plan.stop_instance_id=string(action.last_spawned_instance_id)
 return plan
}
prompt_effect:=Effect{kind="prompt",plan=prompt_plan}

prompt_metadata :: proc(repo:^iface.Action_Repository,action:domain.Action,run:domain.Action_Run,joined:int)->(string,domain.Domain_Error) {
 metadata:=make(json.Object,context.temp_allocator)
 metadata["action_id"]=string(action.id); metadata["action_name"]=action.name
 metadata["run_id"]=run.run_id; metadata["trigger_id"]=run.trigger_id
 metadata["event_type"]=run.event_type; metadata["joined_count"]=json.Integer(joined)
 params:json.Value
 _=json.unmarshal(transmute([]u8)run.event_params_json,&params,allocator=context.temp_allocator)
 object,_:=params.(json.Object)
 metadata["triggered_at"]=object["fired_at"]
 entity,_:=object["entity"].(json.Object)
 if entity!=nil {metadata["entity_kind"]=entity["kind"]; metadata["entity_id"]=entity["id"]}
 if id,ok:=object["id"].(string);ok && id!="" do metadata["event_id"]=id
 trigger,found,err:=repo.trigger_get(repo.ctx,run.trigger_id)
 defer domain.action_trigger_destroy(&trigger)
 if err.code!=.None do return "",err
 if found {
  config:json.Value
  _=json.unmarshal(transmute([]u8)trigger.config_json,&config,allocator=context.temp_allocator)
  obj,_:=config.(json.Object)
  mode,_:=obj["mode"].(string)
  if mode=="cron" {metadata["cron_expr"]=obj["cron_expr"]; metadata["timezone"]=obj["timezone"]}
 }
 bytes,e:=json.marshal(metadata,allocator=context.temp_allocator)
 if e!=nil do return "",domain.domain_error(.Internal_Error,"cannot encode action metadata")
 return string(bytes),{}
}
route_prompt :: proc(r:^Router,uow:^iface.Unit_Of_Work,action:domain.Action,run:domain.Action_Run,plan:Plan,round:int,exclude:[]string)->(message_id,delivery_id:string,err:domain.Domain_Error) {
 repo:=&uow.repos.actions
 joined,e:=repo.run_joined_count(repo.ctx,run.run_id)
 if e.code!=.None do return "","",e
 body:=render(action.prompt_text,action,run,joined,context.temp_allocator)
 metadata,me:=prompt_metadata(repo,action,run,joined)
 if me.code!=.None do return "","",me
 message_id,err=r.agents.persist_prompt(r.agents.ctx,uow,string(action.owner_user_id),plan.conversation_id,body,metadata)
 if err.code!=.None do return
 if r.message_created.created!=nil {
  context.allocator=context.temp_allocator
  stored,found,read_err:=iface.content_get_message(&uow.repos.content,message_id)
  if read_err.code!=.None do return "","",read_err
  if !found do return "","",domain.domain_error(.Internal_Error,"action message not found")
  // Own only hint fields until the outer transaction commits; never copy the prompt.
  hint:=new(Prompt_Hint,runtime.heap_allocator())
  hint.hook=r.message_created
  hint.message={message_id=strings.clone(message_id,runtime.heap_allocator()),
   conversation_id=strings.clone(plan.conversation_id,runtime.heap_allocator()),
   owner_user_id=domain.User_ID(strings.clone(string(action.owner_user_id),runtime.heap_allocator())),
   message_type=strings.clone("action",runtime.heap_allocator()),
   direction=strings.clone(stored.direction,runtime.heap_allocator()),
   created_at=strings.clone(stored.created_at,runtime.heap_allocator())}
  if !iface.unit_of_work_after_commit(uow,{ctx=hint,run=prompt_hint_run,discard=prompt_hint_discard}) {
   prompt_hint_discard(hint)
   return "","",domain.domain_error(.Internal_Error,"cannot defer action message hint")
  }
 }
 cause:="event"
 if run.event_type=="schedule.fired" do cause="schedule"
 delivery_id,err=r.pipeline.route(r.pipeline.ctx,uow,{
  kind="prompt",owner_user_id=string(action.owner_user_id),bridge_id=plan.bridge_id,
  agent_instance_id=plan.instance_id,cause=cause,ref=fmt.tprintf("run:%s",run.run_id),
  conversation_id=plan.conversation_id,message_id=message_id,notice_line="message",notice_count=joined+1,
  lifetime=delivery.LIFETIME_PROMPT,round=round,excluded_bridges=exclude,
 })
 return
}
on_delivery_replace :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,d:domain.Pipeline_Delivery,why:delivery.Replace_Why)->(bool,domain.Domain_Error) {
 r:=(^Router)(ctx)
 if !strings.has_prefix(d.ref,"run:") do return false,{}
 repo:=&uow.repos.actions
 run,found,err:=repo.run_get(repo.ctx,d.ref[4:])
 defer domain.action_run_destroy(&run)
 if err.code!=.None do return false,err
 if !found || run.state!=domain.ACTION_RUN_ROUTED || run.delivery_id!=d.delivery_id do return false,{}
 action,exists,e:=repo.get(repo.ctx,run.action_id)
 defer domain.action_destroy(&action)
 if e.code!=.None do return false,e
 if !exists || action.target_kind!=domain.ACTION_TARGET_AGENT do return false,{}
 excluded:[]string
 if d.excluded_bridges_json!="" {
  if json.unmarshal(transmute([]u8)d.excluded_bridges_json,&excluded,allocator=context.temp_allocator)!=nil do return false,domain.domain_error(.Internal_Error,"invalid excluded bridges")
 }
 ids:=make([]string,len(excluded)+1,context.temp_allocator)
 copy(ids,excluded); ids[len(excluded)]=d.bridge_id
 plan:=EFFECTS[0].plan(r,action,run,ids)
 if !plan.ok do return false,{}
 message,id,route_err:=route_prompt(r,uow,action,run,plan,d.round+1,ids)
 if route_err.code!=.None do return false,route_err
 if e:=r.agents.retire_prompt(r.agents.ctx,uow,string(action.owner_user_id),d.message_id,plan.instance_id); e.code!=.None do return false,e
 next:=run
 next.message_id=message; next.delivery_id=id; next.target_instance_id=plan.instance_id; next.rule_position=plan.rule_position
 changed,transition_err:=repo.run_transition(repo.ctx,next,domain.ACTION_RUN_ROUTED)
 if transition_err.code!=.None do return false,transition_err
 if !changed do return false,domain.domain_error(.Conflict,"action run changed during replacement")
 return true,{}
}


drain_due :: proc(r:^Router,hints:[]Resume_Hint=nil) {
 arena:virtual.Arena
 if virtual.arena_init_growing(&arena)!=nil do return
 defer virtual.arena_destroy(&arena)
 context.allocator=virtual.arena_allocator(&arena)
 context.temp_allocator=context.allocator
 seen:=make(map[string]bool)
 for hint in hints {
  uow,ok,_:=iface.unit_of_work_begin(r.factory)
  if !ok do return
  run,found,err:=uow.repos.actions.run_get(uow.repos.actions.ctx,hint.run_id)
  iface.unit_of_work_rollback(&uow)
  if err.code==.None && found && string(run.owner_user_id)==hint.owner && run.state==domain.ACTION_RUN_DEFERRED {
   seen[strings.clone(run.run_id)]=true
   drain_run(r,run.run_id,true,hint.not_before)
  }
 }
 now:=platform.clock_now(r.clock)
 for {
  uow,ok,_:=iface.unit_of_work_begin(r.factory)
  if !ok do return
  rows,err:=uow.repos.actions.runs_due(uow.repos.actions.ctx,now,32)
  iface.unit_of_work_rollback(&uow)
  if err.code!=.None do return
  progress:=false
  for row in rows {
   if seen[row.run_id] do continue
   seen[strings.clone(row.run_id)]=true
   progress=true
   drain_run(r,row.run_id,false)
  }
  if !progress do break
 }
 if r.support.get!=nil && r.support.get(r.support.ctx)==2 {
  for {
   uow,ok,_:=iface.unit_of_work_begin(r.factory)
   if !ok do return
   repo:=&uow.repos.actions
   rows,err:=repo.runs_deferred(repo.ctx,32)
   if err.code!=.None {iface.unit_of_work_rollback(&uow); return}
   progress:=false
   for run in rows {
    if run.not_before<=now do continue
    why:="rate_limited"
    if run.delay_s>0 do why="schedules_unsupported"
    if e:=finish_run(r,&uow,run,domain.ACTION_RUN_SKIPPED,why,now); e.code!=.None {
     iface.unit_of_work_rollback(&uow); return
    }
    progress=true
   }
   _,_=iface.unit_of_work_commit(&uow)
   if !progress do break
  }
 }
}
drain_run :: proc(r:^Router,id:string,hinted:bool,hint_deadline:string="") {
 uow,ok,_:=iface.unit_of_work_begin(r.factory)
 if !ok do return
 defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
 repo:=&uow.repos.actions
 run,found,err:=repo.run_get(repo.ctx,id)
 if err.code!=.None || !found || (run.state!=domain.ACTION_RUN_QUEUED && run.state!=domain.ACTION_RUN_DEFERRED) do return
 now:=platform.clock_now(r.clock)
 trusted_hint := hinted && (run.delay_s==0 || (hint_deadline!="" && hint_deadline==run.not_before))
 if run.state==domain.ACTION_RUN_DEFERRED && !trusted_hint && run.not_before>now do return
 action,exists,e:=repo.get(repo.ctx,run.action_id)
 if e.code!=.None || !exists do return
 reason:=""
 if !actions_gate_on(r.experiments,string(action.owner_user_id),"actions") {reason="experiment_off"
 } else if !action.enabled {reason="disabled"
 } else if action.target_kind==domain.ACTION_TARGET_BOT && !actions_gate_on(r.experiments,string(action.owner_user_id),"bots") {reason="experiment_off"}
 if reason!="" {
  if e:=finish_run(r,&uow,run,domain.ACTION_RUN_SKIPPED,reason,now); e.code!=.None do return
  _,_=iface.unit_of_work_commit(&uow); uow.ctx=nil
  return
 }
 if run.delay_s>0 {
  trigger,present,trigger_err:=repo.trigger_get(repo.ctx,run.trigger_id)
  defer domain.action_trigger_destroy(&trigger)
  if trigger_err.code!=.None do return
  snapshot:json.Value
  _=json.unmarshal(transmute([]u8)run.event_params_json,&snapshot,allocator=context.temp_allocator)
  object,_:=snapshot.(json.Object)
  revision,_:=object["_trigger_rev"].(json.Integer)
  if !present || !trigger.enabled || i64(revision)!=i64(trigger.rev) {
   if e:=finish_run(r,&uow,run,domain.ACTION_RUN_SKIPPED,"stale_rev",now); e.code!=.None do return
   _,_=iface.unit_of_work_commit(&uow);uow.ctx=nil
   return
  }
 }
 // A pending timer occupies only its trigger/key slot. Claim the action's
 // ordinary slot once the settle window has elapsed. Different settle keys
 // wait for a transactional action.ready wake; only same-key runs may join.
 if run.settle_pending {
  if _, expiry_err := expire_open_run(r, &uow, action.id); expiry_err.code != .None do return
  open, exists, open_err := repo.run_open(repo.ctx, action.id)
  if open_err.code != .None do return
  if exists {
   if open.settle_key!=run.settle_key {
    // A trusted timer is already ready even when the hub clock trails NATS.
    // Persist that fact so the terminal wake can find it without another timer.
    if trusted_hint && run.not_before>now {
     next:=run
     next.not_before=now
     changed,e:=repo.run_transition(repo.ctx,next,run.state)
     if e.code!=.None || !changed do return
     _,_=iface.unit_of_work_commit(&uow);uow.ctx=nil
    }
    return
   }
   next := run
   next.joined_run_id = open.run_id
   if e := finish_run(r,&uow, next, domain.ACTION_RUN_JOINED, "", now); e.code != .None do return
   _, _ = iface.unit_of_work_commit(&uow); uow.ctx=nil
   return
  }
  next := run
  next.settle_pending=false
  next.state=domain.ACTION_RUN_QUEUED
  changed, transition_err := repo.run_transition(repo.ctx, next, run.state)
  if transition_err.code != .None || !changed do return
  run=next
 }
 if run.state==domain.ACTION_RUN_QUEUED {
  last,e:=repo.run_last_started_at(repo.ctx,action.id)
  if e.code!=.None do return
  last_ms,valid:=platform.rfc3339_to_unix_ms(last)
  now_ms,now_valid:=platform.rfc3339_to_unix_ms(now)
  if last!="" && valid && now_valid && now_ms-last_ms<i64(action.min_interval_s)*1000 {
   if r.support.get!=nil && r.support.get(r.support.ctx)==2 {
    if e:=finish_run(r,&uow,run,domain.ACTION_RUN_SKIPPED,"rate_limited",now); e.code!=.None do return
   } else {
    next:=run
    next.state=domain.ACTION_RUN_DEFERRED
    next.not_before=platform.format_rfc3339_utc(time.Time{_nsec=(last_ms+i64(action.min_interval_s)*1000)*1_000_000})
    changed,te:=repo.run_transition(repo.ctx,next,run.state)
    if te.code!=.None || !changed do return
    sc:=Sync_Context{outbox=&uow.repos.event_outbox,clock=r.clock,ids=r.ids}
    row,re:=deferral_row(&sc,string(action.owner_user_id),string(action.id),run.run_id,next.not_before)
    if re.code!=.None do return
    if re=uow.repos.event_outbox.append(uow.repos.event_outbox.ctx,row); re.code!=.None do return
   }
   _,_=iface.unit_of_work_commit(&uow); uow.ctx=nil
   return
  }
 }
 // Validate before planning: planning can spawn or start an instance.
 // Immediate and rate-limit-only runs never perform this lookup.
 if run.delay_s > 0 {
  valid, why := event_still_valid(uow.repos, run)
  if !valid {
   if why == "" do why = "superseded"
   if e := finish_run(r,&uow, run, domain.ACTION_RUN_SKIPPED, why, now); e.code != .None do return
   _, _ = iface.unit_of_work_commit(&uow); uow.ctx=nil
   return
  }
 }
 committed,_:=iface.unit_of_work_commit(&uow); uow.ctx=nil
 if !committed do return
 plan:=EFFECTS[0].plan(r,action,run,nil)
 uow,ok,_=iface.unit_of_work_begin(r.factory)
 if !ok do return
 repo=&uow.repos.actions
 current,present,ce:=repo.run_get(repo.ctx,id)
 if ce.code!=.None || !present || current.state!=run.state do return
 if !plan.ok {
  if e:=finish_run(r,&uow,current,domain.ACTION_RUN_FAILED,plan.reason,now); e.code!=.None do return
  _,_=iface.unit_of_work_commit(&uow); uow.ctx=nil
  return
 }
 message,delivery_id,route_err:=route_prompt(r,&uow,action,current,plan,0,nil)
 if route_err.code!=.None {
  reason:="delivery_failed"
  if route_err.message=="bridge_too_old" do reason="bridge_too_old"
  iface.unit_of_work_rollback(&uow); uow.ctx=nil
  record_route_failure(r,id,run.state,reason)
  return
 }
 next:=current
 next.state=domain.ACTION_RUN_ROUTED; next.started_at=platform.clock_now(r.clock)
 next.delivery_id=delivery_id; next.message_id=message; next.target_instance_id=plan.instance_id; next.rule_position=plan.rule_position
 changed,te:=repo.run_transition(repo.ctx,next,current.state)
 if te.code!=.None || !changed do return
 if plan.spawned {
  if e:=repo.set_last_spawned(repo.ctx,action.id,plan.instance_id,next.started_at); e.code!=.None do return
 }
 committed,_=iface.unit_of_work_commit(&uow); uow.ctx=nil
 if committed && plan.stop_instance_id!="" && r.agents.stop!=nil do r.agents.stop(r.agents.ctx,string(action.owner_user_id),plan.stop_instance_id)
}
record_route_failure :: proc(r:^Router,id,from,reason:string) {
 uow,ok,_:=iface.unit_of_work_begin(r.factory)
 if !ok do return
 defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
 repo:=&uow.repos.actions
 run,found,err:=repo.run_get(repo.ctx,id)
 if err.code!=.None || !found || run.state!=from do return
 if err=finish_run(r,&uow,run,domain.ACTION_RUN_FAILED,reason,platform.clock_now(r.clock)); err.code!=.None do return
 _,_=iface.unit_of_work_commit(&uow); uow.ctx=nil
}


Run_View :: iface.Action_Run_History
run_views_destroy :: proc(rows:[]Run_View) {
 for &row in rows {domain.action_run_destroy(&row.run); delete(row.delivery_expires_at); delete(row.delivery_state); delete(row.delivery_outcome)}
 delete(rows)
}
list_runs :: proc(r:^Router,owner,action_id:string,limit:int,before:string,before_id:string="")->([]Run_View,domain.Domain_Error) {
 uow,ok,err:=iface.unit_of_work_begin(r.factory)
 if !ok do return nil,err
 defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
 repo:=&uow.repos.actions
 action,found,e:=repo.get(repo.ctx,domain.Action_ID(action_id))
 defer domain.action_destroy(&action)
 if e.code!=.None do return nil,e
 if !found || string(action.owner_user_id)!=owner do return nil,domain.domain_error(.Not_Found,"action not found")
 if _,expiry_err:=expire_open_run(r,&uow,action.id);expiry_err.code!=.None do return nil,expiry_err
 rows,re:=repo.runs_history(repo.ctx,action.id,limit,before,before_id)
 if re.code!=.None do return nil,re
 success:=false
 defer if !success do run_views_destroy(rows)
 committed,commit_err:=iface.unit_of_work_commit(&uow);uow.ctx=nil
 if !committed do return nil,commit_err
 success=true
 return rows,{}
}

instance_plan :: proc(r:^Router,owner,instance_id:string,req:placement.Requirements)->Plan {
  _,bridge,conversation,found:=r.agents.instance(r.agents.ctx,owner,instance_id)
  if !found do return {reason="target_missing"}
  for id in req.exclude do if id==bridge do return {reason="no_placement"}
  b,exists,err:=iface.bridge_get_bridge(r.placement.bridges,bridge)
  defer domain.bridge_destroy(&b)
  if err.code!=.None || !exists do return {reason="no_placement"}
  eligible,why:=placement.bridge_eligible(r.placement,b,req)
  if !eligible {
   switch why {
   case placement.REASON_MISSING_FEATURE: return {reason="bridge_too_old"}
   case placement.REASON_NOT_OWNER,placement.REASON_REVOKED,placement.REASON_ENROLLMENT_PENDING,placement.REASON_PLAN_DISABLED: return {reason="no_placement"}
   }
   // Connectivity is not evidence of capability. Even offline targets must
   // have advertised the feature before they receive a pipeline delivery.
   if !placement.bridge_has_feature(b,contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1) do return {reason="bridge_too_old"}
  }
  return {ok=true,bridge_id=bridge,instance_id=instance_id,conversation_id=conversation,rule_position=-1}
}
