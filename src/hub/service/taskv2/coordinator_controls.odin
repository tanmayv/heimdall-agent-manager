package taskv2

import "core:strings"
import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

EV_CONTROL_APPLIED :: "control_applied"
EV_ADMIN_COMPLETED :: "administratively_completed"

// The generation is the latest event ID, not a wall-clock deadline. Requests
// carry an actor-scoped idempotency key and compare this generation in the UoW.
Task_Control_Input :: struct {
 operation, reason, request_id: string,
 expected_generation: i64,
 target_instance_id: string,
 obligations: []string,
}
Task_Control_Result :: struct {
 task: domain.Task,
 changed: bool,
 generation: i64,
 outcome, message: string,
 obligations: []string,
 cleanup_pending: bool,
 owners_json, actions_json, cleanup_json, wait_reason: string,
}

task_control_generation :: proc(svc: ^Service, task: domain.Task) -> i64 {
 events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
 if err.code != .None do return -1
 generation: i64
 for e in events do generation = max(generation, e.event_id)
 return generation
}

task_administratively_completed :: proc(svc: ^Service, task: domain.Task) -> bool {
 events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
 if err.code != .None do return true // dependency evaluation fails closed
 overridden := false
 for e in events {
  if e.kind == EV_REOPENED do overridden = false
  if e.kind == EV_ADMIN_COMPLETED do overridden = true
 }
 return overridden
}

task_control_inspect :: proc(svc: ^Service, task_in: domain.Task, actor: Actor) -> (Task_Control_Result, bool, domain.Domain_Error) {
 task, found, err := iface.taskchain_get_task(svc.repo, task_in.task_id)
 if !found do return {}, false, err
 if task.owner_user_id != task_in.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "task not found")
 if _, allowed, aerr := recheck_authorize(svc, task.owner_user_id, actor, task.chain_id); !allowed do return {}, false, aerr
 result := Task_Control_Result{task=task, generation=task_control_generation(svc,task), outcome=domain.task_state_string(task.state), cleanup_pending=ownership_cleanup_pending(svc,task)}
 if result.generation < 0 do return {}, false, domain.domain_error(.Internal_Error,"cannot read task generation")
 result.wait_reason = task.blocked_on_json
 leases,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
 if lerr.code!=.None do return {},false,lerr
 owners:=make([dynamic]string,context.temp_allocator)
 for lease in leases {
  owner:=json_begin()
  json_str(&owner,"instance_id",lease.holder_instance_id);json_str(&owner,"lease_id",lease.lease_id)
  json_str(&owner,"role",lease.kind);json_str(&owner,"phase",lease.phase)
  if inst,iok,_:=iface.agent_get_instance(svc.agents,lease.holder_instance_id);iok {
   json_str(&owner,"agent_id",inst.agent_id);json_str(&owner,"runtime_status",inst.runtime_status)
   json_str(&owner,"bridge_id",inst.bridge_id);json_int(&owner,"run_count",i64(inst.run_count))
  }
  append(&owners,json_end(&owner))
 }
 result.owners_json=fmt.tprintf("[%s]",strings.join(owners[:],",",context.temp_allocator))
 cleanup:=make([dynamic]string,context.temp_allocator)
 for stop in ownership_pending_stops(svc,task) {
  pending:=json_begin();json_str(&pending,"instance_id",stop.instance_id);json_str(&pending,"bridge_id",stop.bridge_id)
  json_int(&pending,"run_count",i64(stop.run_count));json_str(&pending,"state","stop_pending")
  append(&cleanup,json_end(&pending))
 }
 result.cleanup_json=fmt.tprintf("[%s]",strings.join(cleanup[:],",",context.temp_allocator))
 actions:=make([dynamic]string,context.temp_allocator)
 chain,control_allowed,control_err:=work_control_chain(svc,task.owner_user_id,actor,task.chain_id)
 for operation in ([]string{"cancel","reopen","hold","resume","unblock","release-owner","rereview","force-complete","recheck","allow-coordinator-override","deny-coordinator-override"}) {
  reason:=""
  if !control_allowed {reason=control_err.message} else if task.workflow_run_id!="" {reason="use whole-run retry/cancel controls"} else if chain.status!=.Active {reason="chain must be active"} else {
   switch operation {
   case "cancel":
    merge:=task_merge_status(svc,task)
    if task.state==.Done && (merge.state=="none" || merge.state=="merged") do reason="already completed; reopen first"
   case "reopen","hold":
    guard:=task_control_precondition(svc,task,actor,operation)
    if guard.code!=.None do reason=guard.message
   case "unblock":
    guard:=task_control_precondition(svc,task,actor,"answer")
    if guard.code!=.None do reason=guard.message
   case "release-owner":
    if len(leases)==0 do reason="no current owner"
   case "rereview":
    if task.state!=.In_Review do reason="requires an in-review task; reopen terminal work first"
   case "force-complete":
    policy,_:=jsonx.extract_bool_literal(chain.defaults_json,"allow_coordinator_override",true)
    if actor.kind!=ACTOR_USER && !policy do reason="chain policy does not allow coordinator overrides"
    if domain.task_state_is_terminal(task.state) do reason="terminal task must be reopened first"
   case "allow-coordinator-override","deny-coordinator-override":
    if actor.kind!=ACTOR_USER do reason="only the chain owner can configure override policy"
   }
  }
  action:=json_begin();json_str(&action,"operation",operation);json_bool(&action,"allowed",reason=="");json_str(&action,"reason",reason)
  append(&actions,json_end(&action))
 }
 result.actions_json=fmt.tprintf("[%s]",strings.join(actions[:],",",context.temp_allocator))
 if task_administratively_completed(svc,task) {
  result.outcome = "overridden"
  result.message = "Administrative completion is not verified success; dependents require an explicit dependency change."
  events, _ := iface.taskchain_list_events_by_task(svc.repo,task.task_id,task.owner_user_id)
  for e in events do if e.kind==EV_ADMIN_COMPLETED do result.obligations=jsonx.extract_string_array(e.payload_json,"obligations",true,context.temp_allocator)[:]
 }
 return result,true,{}
}

control_fingerprint :: proc(input: Task_Control_Input) -> string {
 p:=json_begin()
 json_str(&p,"operation",input.operation); json_str(&p,"reason",input.reason)
 json_int(&p,"expected_generation",input.expected_generation)
 json_str(&p,"target_instance_id",input.target_instance_id)
 // Canonical string encoding preserves order and prevents concatenation collisions.
 for item,i in input.obligations { json_str(&p,control_obligation_key(i),item) }
 return json_end(&p)
}

control_obligation_key :: proc(i:int)->string {
 return fmt.tprintf("obligation_%d",i)
}

task_control :: proc(svc:^Service, task_in:domain.Task, actor:Actor, input:Task_Control_Input)->(Task_Control_Result,bool,domain.Domain_Error) {
 if strings.trim_space(input.reason)=="" || strings.trim_space(input.request_id)=="" do return {},false,domain.domain_error(.Validation_Failed,"reason and request_id are required")
 u,uok,uerr:=begin_uow(svc)
 if !uok do return {},false,uerr
 result,ok,err:=task_control_in_uow(svc,&u,task_in,actor,input)
 _,cerr:=end_uow(svc,&u,ok)
 if !ok do return {},false,err
 if cerr.code!=.None do return {},false,cerr
 return result,true,{}
}

task_control_in_uow :: proc(svc:^Service,u:^Uow,task_in:domain.Task,actor:Actor,input:Task_Control_Input)->(Task_Control_Result,bool,domain.Domain_Error) {
 task,found,err:=iface.taskchain_get_task(svc.repo,task_in.task_id)
 if !found do return {},false,err
 if task.owner_user_id!=task_in.owner_user_id do return {},false,domain.domain_error(.Not_Found,"task not found")
 chain,allowed,aerr:=work_control_chain(svc,task.owner_user_id,actor,task.chain_id)
 if !allowed do return {},false,aerr
 events,eerr:=iface.taskchain_list_events_by_task(svc.repo,task.task_id,task.owner_user_id)
 if eerr.code!=.None do return {},false,eerr
 fingerprint:=control_fingerprint(input)
 generation:i64
 for e in events {
  generation=max(generation,e.event_id)
  if e.kind!=EV_CONTROL_APPLIED || e.actor_kind!=actor.kind || e.actor_id!=actor.id do continue
  if jsonx.extract_string(e.payload_json,"request_id","",true,context.temp_allocator)!=input.request_id do continue
  if jsonx.extract_string(e.payload_json,"fingerprint","",true,context.temp_allocator)!=fingerprint do return {},false,domain.domain_error(.Conflict,"request_id already used with different control arguments")
  result,rok,rerr:=task_control_inspect(svc,task,actor)
  result.changed=false; result.message="request already applied"
  return result,rok,rerr
 }
 if input.expected_generation!=generation do return {},false,domain.domain_error(.Conflict,"task generation changed; inspect current state before retrying")
 if task.workflow_run_id!="" do return {},false,domain.domain_error(.Conflict,"task is workflow-managed; use whole-run retry/cancel controls",`{"code":"workflow_task_managed"}`)
 before:=domain.task_state_string(task.state)
 ok:=true
 op_err:=domain.Domain_Error{}
 switch input.operation {
 case "allow-coordinator-override","deny-coordinator-override":
  if actor.kind!=ACTOR_USER do return {},false,domain.domain_error(.Forbidden,"only the chain owner can configure override policy")
  defaults:=json_begin()
  for key,raw in jsonx_top_level_members(chain.defaults_json) {
   if key!="allow_coordinator_override" do json_raw(&defaults,key,raw)
  }
  json_bool(&defaults,"allow_coordinator_override",input.operation=="allow-coordinator-override")
  chain.defaults_json=json_end(&defaults)
  _,ok,op_err=iface.taskchain_save_chain(svc.repo,chain)
  if ok do effect_tasks_changed(u,chain.chain_id,chain.owner_user_id)
 case "cancel":
  op_err=cancel_task(svc,task,actor,input.reason);ok=op_err.code==.None
 case "reopen":
  _,ok,op_err=task_reopen(svc,task,actor)
 case "hold":
  _,ok,op_err=task_hold(svc,task,actor,input.reason)
 case "resume":
  _,ok,op_err=task_release(svc,task,actor)
 case "unblock":
  _,ok,op_err=task_answer(svc,task,actor,input.reason)
 case "recheck":
  _,ok,op_err=task_recheck_in_uow(svc,u,task,actor)
 case "release-owner":
  leases,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
  if lerr.code!=.None do return {},false,lerr
  matched:=false
  for lease in leases {
   if input.target_instance_id!="" && lease.holder_instance_id!=input.target_instance_id do continue
   matched=true
   if released,rerr:=revoke_claim_in_uow(svc,u,task,lease,actor,input.reason);!released do return {},false,rerr
  }
  if !matched do return {},false,domain.domain_error(.Conflict,"no matching current owner")
  // Prevent immediate automatic reclamation. Resuming is an explicit operation.
  if !domain.task_state_is_terminal(task.state) { _,ok,op_err=task_hold(svc,task,actor,input.reason) }
 case "rereview":
  if task.state!=.In_Review do return {},false,domain.domain_error(.Conflict,"re-review requires an in-review task; reopen terminal work first")
  p:=json_begin();json_str(&p,"reason",input.reason)
  _,_,ok,op_err=record_event(svc,u,task,actor,EV_REQUIREMENTS_REWORK,json_end(&p))
  if ok {
   leases,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
   if lerr.code!=.None do return {},false,lerr
   for lease in leases do if !claim_wait_in_uow(svc,lease) do return {},false,domain.domain_error(.Internal_Error,"cannot retain review responsibility")
  }
 case "force-complete":
  if domain.task_state_is_terminal(task.state) do return {},false,domain.domain_error(.Conflict,"terminal task must be reopened before administrative completion")
  policy,_:=jsonx.extract_bool_literal(chain.defaults_json,"allow_coordinator_override",true)
  if actor.kind!=ACTOR_USER && !policy do return {},false,domain.domain_error(.Forbidden,"chain policy does not allow coordinator overrides")
  if len(input.obligations)==0 do return {},false,domain.domain_error(.Validation_Failed,"explicit affected obligations are required")
  obligations:=make([dynamic]string,context.temp_allocator)
  append(&obligations,..input.obligations)
  // Caller annotations supplement the server's obligations; they cannot hide
  // a pending approval or convert missing evidence into a successful result.
  append(&obligations,"administrative outcome is not verified prerequisite success")
  if task.state!=.In_Review do append(&obligations,"unfinished work or missing current submission")
  if requirements_stale_review(svc,task) do append(&obligations,"submission does not cover current requirements")
  unmet,gerr:=gate_unmet_components(svc,task)
  if gerr.code!=.None do return {},false,gerr
  for gate in unmet do append(&obligations,fmt.tprintf("pending %s: %s %s",gate.kind,gate.agent_id,gate.role))
  merge:=task_merge_status(svc,task)
  append(&obligations,fmt.tprintf("merge evidence remains unchanged (%s); administrative completion performs no merge",merge.state))
  if ready,derr:=task_dependencies_ready(svc,task);derr.code!=.None {return {},false,derr} else if !ready {append(&obligations,"unsatisfied prerequisites")}
  p:=json_begin();json_str(&p,"reason",input.reason)
  arr:=strings.builder_make(context.temp_allocator);strings.write_byte(&arr,'[')
  for obligation,i in obligations {
   if strings.trim_space(obligation)=="" do return {},false,domain.domain_error(.Validation_Failed,"obligations must be non-empty")
   if i>0 do strings.write_byte(&arr,',')
   item:=json_begin();json_str(&item,"value",obligation)
   raw:=json_end(&item)
   strings.write_string(&arr,raw[len(`{"value":`):len(raw)-1])
  }
  strings.write_byte(&arr,']');json_raw(&p,"obligations",strings.to_string(arr))
  leases,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
  if lerr.code!=.None do return {},false,lerr
  for lease in leases do if released,rerr:=revoke_claim_in_uow(svc,u,task,lease,actor,input.reason);!released do return {},false,rerr
  if fresh,fok,_:=iface.taskchain_get_task(svc.repo,task.task_id);fok do task=fresh
  _,_,ok,op_err=record_event(svc,u,task,actor,EV_ADMIN_COMPLETED,json_end(&p))
 case:
  return {},false,domain.domain_error(.Validation_Failed,"unknown task control operation")
 }
 if !ok do return {},false,op_err
 fresh,fok,ferr:=iface.taskchain_get_task(svc.repo,task.task_id)
 if !fok do return {},false,ferr
 audit:=json_begin()
 json_str(&audit,"operation",input.operation);json_str(&audit,"reason",input.reason)
 json_str(&audit,"request_id",input.request_id);json_str(&audit,"fingerprint",fingerprint)
 json_str(&audit,"before",before);json_str(&audit,"after",domain.task_state_string(fresh.state))
 if _,saved,serr:=append_event(svc.repo,svc.clock,fresh,actor,EV_CONTROL_APPLIED,json_end(&audit));!saved do return {},false,serr
 if changed,cerr:=after_chain_change(svc,u,task.chain_id,task.owner_user_id,.Task_Updated);!changed do return {},false,cerr
 result,rok,rerr:=task_control_inspect(svc,fresh,actor)
 result.changed=true
 return result,rok,rerr
}
