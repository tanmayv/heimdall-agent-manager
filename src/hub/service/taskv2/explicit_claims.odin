package taskv2

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Explicit claims authenticate the beneficiary's durable identity. Fleet rows
// resolve review roles, but are not placement permissions for named identities.
Lease_Claim_Input :: struct {
 task_id: domain.Task_ID,
 instance_id, reason, request_id, vcs_base: string,
 expected_generation: i64,
}
Lease_Claim_Result :: struct {
 status, pack_json, target_instance_id, agent_id, role, delivery: string,
 lease: domain.Task_Lease,
 task: domain.Task,
}

lease_claim :: proc(svc:^Service, auth:contracts.Auth_Context, input:Lease_Claim_Input)->(Lease_Claim_Result,bool,domain.Domain_Error) {
 u,ok,err:=begin_uow(svc)
 if !ok do return {},false,err
 result,accepted,e:=lease_claim_in_uow(svc,&u,auth,input)
 _,cerr:=end_uow(svc,&u,accepted)
 if !accepted do return {},false,e
 if cerr.code!=.None do return {},false,cerr
 return result,true,{}
}

lease_claim_in_uow :: proc(svc:^Service,u:^Uow,auth:contracts.Auth_Context,input:Lease_Claim_Input)->(Lease_Claim_Result,bool,domain.Domain_Error) {
 task,found,err:=iface.taskchain_get_task(svc.repo,input.task_id)
 if !found || string(task.owner_user_id)!=auth.user_id do return {},false,domain.domain_error(.Not_Found,"task not found")
 if input.expected_generation<0 do return {},false,domain.domain_error(.Validation_Failed,"expected_generation cannot be negative")
 if input.expected_generation>0 {
  generation:=task_control_generation(svc,task)
  if generation<0 do return {},false,domain.domain_error(.Internal_Error,"cannot read task generation")
  if input.expected_generation!=generation do return {},false,domain.domain_error(.Conflict,"task generation changed")
 }
 chain,cfound,cerr:=iface.taskchain_get_chain(svc.repo,task.chain_id)
 if !cfound do return {},false,cerr
 target:=input.instance_id
 if target=="" do target=auth.agent_instance_id
 actor:=actor_from_auth(auth)
 if target!=auth.agent_instance_id || contracts.is_user_auth(auth) {
  if _,authorized,aerr:=work_control_chain(svc,task.owner_user_id,actor,task.chain_id);!authorized do return {},false,aerr
 } else if auth.kind!=.Instance_Token do return {},false,domain.domain_error(.Forbidden,"instance token required")
 inst,ifound,ierr:=iface.agent_get_instance(svc.agents,target)
 if !ifound || inst.owner_user_id!=task.owner_user_id do return {},false,domain.domain_error(.Not_Found,"target instance not found")
 if inst.agent_id=="" do return {},false,domain.domain_error(.Forbidden,"target has no durable agent identity")
 if domain.task_state_is_terminal(task.state) do return {},false,domain.domain_error(.Conflict,"task is terminal; reopen it explicitly before claiming")
 if held,exists,_:=iface.taskchain_get_lease_by_holder(svc.repo,target);exists && held.task_id!=task.task_id do return {},false,domain.domain_error(.Conflict,"target already owns another task; use an explicit switch")
 // A waiting participant keeps its existing worker responsibility during review.
 if held,exists,_:=iface.taskchain_get_lease_by_holder(svc.repo,target);exists && held.task_id==task.task_id {
  if held.phase!=domain.LEASE_PHASE_WAITING || (task.state!=.Ready && !transfer_reservation_needs_activation(svc,task,held)) {
   result:=Lease_Claim_Result{status="current",lease=held,task=task,target_instance_id=target,agent_id=inst.agent_id,role=held.kind,delivery=held.delivery}
   if held.phase==domain.LEASE_PHASE_WAITING do result.status="waiting"
   if ownership_cleanup_pending(svc,task) {result.status="stop_pending";result.delivery="stop_pending"}
   if target==auth.agent_instance_id && held.phase!=domain.LEASE_PHASE_WAITING do result.pack_json=build_pack_json(svc,chain,task,held,inst)
   return result,true,{}
  }
 }
 kind:=domain.LEASE_KIND_WORK
 review_role:=""
 if task.state==.In_Review {
  kind=domain.LEASE_KIND_REVIEW
  if requirements_stale_review(svc,task) do return {},false,domain.domain_error(.Conflict,"submission requirements are stale")
  author:=""
  if holder:=last_attempt_holder(svc,task);holder!="" {if h,hfound,_:=iface.agent_get_instance(svc.agents,holder);hfound do author=h.agent_id}
  fleets,ferr:=iface.taskchain_list_fleets_by_chain(svc.repo,task.chain_id,task.owner_user_id)
  if ferr.code!=.None do return {},false,ferr
  reviews,rerr:=iface.taskchain_list_reviews_by_task(svc.repo,task.task_id,task.owner_user_id)
  if rerr.code!=.None do return {},false,rerr
  owed:=owed_review_roles(required_review_pairs(task,fleets,author),reviews,task,inst.agent_id)
  if len(owed)==0 do return {},false,domain.domain_error(.Forbidden,"target durable identity is not an eligible current reviewer")
  review_role=join_review_roles(owed)
 } else if brief_assignee(task.brief_json)!=inst.agent_id {
  return {},false,domain.domain_error(.Forbidden,"target durable identity does not match the task assignee")
 }
 claims,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
 if lerr.code!=.None do return {},false,lerr
 for claim in claims {
  if claim.holder_instance_id==target do continue
  other,ofound,_:=iface.agent_get_instance(svc.agents,claim.holder_instance_id)
  if claim.kind==kind && (kind==domain.LEASE_KIND_WORK || (ofound && other.agent_id==inst.agent_id)) {
   detail:=json_begin();json_str(&detail,"code","transfer_required");json_str(&detail,"holder_instance_id",claim.holder_instance_id);json_str(&detail,"lease_id",claim.lease_id)
   return {},false,domain.domain_error(.Conflict,"another instance owns this responsibility; use explicit transfer",json_end(&detail))
  }
 }
 delivery:=domain.LEASE_DELIVERY_INLINE
 if target!=auth.agent_instance_id do delivery=domain.LEASE_DELIVERY_WAKE
 lease,granted,gerr:=grant_in_uow(svc,u,Grant_Request{chain=chain,task=task,instance=inst,kind=kind,review_role=review_role,delivery=delivery,placement=Placement{bridge_id=inst.bridge_id,provider=inst.provider,model=inst.model,provider_profile=inst.provider_profile},actor=actor,trigger=.Lease_Next,explicit_identity=true})
 if !granted do return {},false,gerr
 fresh,_,_:=iface.taskchain_get_task(svc.repo,task.task_id)
 result:=Lease_Claim_Result{status="granted",lease=lease,task=fresh,target_instance_id=target,agent_id=inst.agent_id,role=kind,delivery=delivery}
 if target==auth.agent_instance_id {
  record_attempt_started(svc,fresh,lease,input.vcs_base)
  if perr:=requirements_present(svc,fresh,lease);perr.code!=.None do return {},false,perr
  result.pack_json=build_pack_json(svc,chain,fresh,lease,inst)
 }
 return result,true,{}
}


EV_OWNERSHIP_TRANSFER_REQUESTED :: "ownership_transfer_requested"

// A WAITING target lease reserves both the responsibility and its named
// beneficiary atomically. It conveys no execution until the previous generation
// is confirmed stopped. This also preserves waiting work during review.
lease_transfer :: proc(svc:^Service,auth:contracts.Auth_Context,input:Lease_Claim_Input)->(Lease_Claim_Result,bool,domain.Domain_Error) {
 u,ok,err:=begin_uow(svc)
 if !ok do return {},false,err
 result,accepted,e:=lease_transfer_in_uow(svc,&u,auth,input)
 _,cerr:=end_uow(svc,&u,accepted)
 if !accepted do return {},false,e
 return result,cerr.code==.None,cerr
}

lease_transfer_in_uow :: proc(svc:^Service,u:^Uow,auth:contracts.Auth_Context,input:Lease_Claim_Input)->(Lease_Claim_Result,bool,domain.Domain_Error) {
 task,found,terr:=iface.taskchain_get_task(svc.repo,input.task_id)
 if !found || string(task.owner_user_id)!=auth.user_id do return {},false,domain.domain_error(.Not_Found,"task not found")
 actor:=actor_from_auth(auth)
 if _,allowed,aerr:=work_control_chain(svc,task.owner_user_id,actor,task.chain_id);!allowed do return {},false,aerr
 if input.expected_generation<0 do return {},false,domain.domain_error(.Validation_Failed,"expected_generation cannot be negative")
 if input.reason=="" || input.request_id=="" || input.instance_id=="" do return {},false,domain.domain_error(.Validation_Failed,"transfer requires target instance, reason and request_id")
 if domain.task_state_is_terminal(task.state) do return {},false,domain.domain_error(.Conflict,"terminal task cannot be transferred; reopen explicitly")
 if task_is_held(task) do return {},false,domain.domain_error(.Conflict,"task is held; release the hold before transfer")
 target,tfound,_:=iface.agent_get_instance(svc.agents,input.instance_id)
 if !tfound || target.owner_user_id!=task.owner_user_id do return {},false,domain.domain_error(.Not_Found,"target instance not found")
 events,events_err:=iface.taskchain_list_events_by_task(svc.repo,task.task_id,task.owner_user_id)
 if events_err.code!=.None do return {},false,events_err
 prior_request:=false
 reservation:=""
 for ev in events {
  if ev.kind!=EV_OWNERSHIP_TRANSFER_REQUESTED || ev.actor_id!=actor.id || ev.actor_kind!=actor.kind do continue
  if jsonx.extract_string(ev.payload_json,"request_id","",true,context.temp_allocator)!=input.request_id do continue
  if jsonx.extract_string(ev.payload_json,"target_instance_id","",true,context.temp_allocator)!=input.instance_id ||
     jsonx.extract_string(ev.payload_json,"reason","",true,context.temp_allocator)!=input.reason ||
     i64(jsonx.extract_int(ev.payload_json,"expected_generation",-1,true))!=input.expected_generation {return {},false,domain.domain_error(.Conflict,"transfer request_id was used with different arguments")}
  reservation=jsonx.extract_string(ev.payload_json,"reservation_lease_id","",true,context.temp_allocator)
  prior_request=true
 }
 if prior_request {
  bound,held,_:=iface.taskchain_get_lease_by_holder(svc.repo,input.instance_id)
  if !held || bound.task_id!=task.task_id do return {},false,domain.domain_error(.Conflict,"transfer request is historical; inspect current ownership and use a new request_id")
  // An activated grant replaces the waiting reservation's lease id. It is
  // idempotent while still bound to this task, never a fresh transfer.
  if bound.lease_id!=reservation && bound.phase==domain.LEASE_PHASE_WAITING do return {},false,domain.domain_error(.Conflict,"transfer reservation has been superseded")
  if ownership_cleanup_pending(svc,task) do return Lease_Claim_Result{status="stop_pending",task=task,lease=bound,target_instance_id=input.instance_id,agent_id=target.agent_id,role=bound.kind,delivery="stop_pending"},true,{}
  return lease_claim_in_uow(svc,u,auth,Lease_Claim_Input{task_id=input.task_id,instance_id=input.instance_id,reason=input.reason,request_id=input.request_id,vcs_base=input.vcs_base})
 }
 if input.expected_generation>0 {
  generation:=task_control_generation(svc,task)
  if generation<0 do return {},false,domain.domain_error(.Internal_Error,"cannot read task generation")
  if input.expected_generation!=generation do return {},false,domain.domain_error(.Conflict,"task generation changed")
 }
 if bound,held,_:=iface.taskchain_get_lease_by_holder(svc.repo,input.instance_id);held {
  if bound.task_id==task.task_id {
   if ownership_cleanup_pending(svc,task) do return Lease_Claim_Result{status="stop_pending",task=task,lease=bound,target_instance_id=input.instance_id,agent_id=target.agent_id,role=bound.kind,delivery="stop_pending"},true,{}
   return lease_claim_in_uow(svc,u,auth,Lease_Claim_Input{task_id=input.task_id,instance_id=input.instance_id,reason=input.reason,request_id=input.request_id,vcs_base=input.vcs_base})
  }
  return {},false,domain.domain_error(.Conflict,"target already owns another task; use explicit switch")
 }
 if ownership_cleanup_pending(svc,task) || instance_ownership_stop_pending(svc,target) do return {},false,domain.domain_error(.Conflict,"a previous process stop remains pending")
 claims,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
 if lerr.code!=.None do return {},false,lerr
 old_claim:domain.Task_Lease
 for claim in claims {
  old,ofound,_:=iface.agent_get_instance(svc.agents,claim.holder_instance_id)
  if ofound && old.agent_id==target.agent_id {old_claim=claim;break}
 }
 if old_claim.lease_id=="" {
  // Normal state-derived identity checks still apply to initial assignment.
  return lease_claim_in_uow(svc,u,auth,Lease_Claim_Input{task_id=input.task_id,instance_id=input.instance_id,reason=input.reason,request_id=input.request_id,vcs_base=input.vcs_base})
 }
 // Existing waiting participants retain their role, without acquiring review
 // authority. Active work/review must still be actionable in its current phase.
 if old_claim.phase!=domain.LEASE_PHASE_WAITING {
  if old_claim.kind==domain.LEASE_KIND_WORK && task.state!=.In_Progress do return {},false,domain.domain_error(.Conflict,"worker responsibility is not currently actionable")
  if old_claim.kind==domain.LEASE_KIND_REVIEW && task.state!=.In_Review do return {},false,domain.domain_error(.Conflict,"review responsibility is not currently actionable")
 }
 if old_claim.kind==domain.LEASE_KIND_WORK && brief_assignee(task.brief_json)!=target.agent_id do return {},false,domain.domain_error(.Forbidden,"target identity does not match current assignee")
 if revoked,rerr:=revoke_claim_in_uow(svc,u,task,old_claim,actor,input.reason,true);!revoked do return {},false,rerr
 reserved:=old_claim
 reserved.lease_id=platform.generate_id(svc.ids,"lease_")
 reserved.holder_instance_id=input.instance_id
 reserved.bridge_id=target.bridge_id
 reserved.phase=domain.LEASE_PHASE_WAITING
 reserved.delivery=domain.LEASE_DELIVERY_WAKE
 reserved.confirmed_at=""
 if _,saved,serr:=iface.taskchain_save_lease(svc.repo,reserved);!saved do return {},false,serr
 set_instance_pointer(svc,u,target.agent_instance_id,string(task.task_id),.Work if reserved.kind==domain.LEASE_KIND_WORK else .Review)
 p:=json_begin()
 json_str(&p,"request_id",input.request_id);json_str(&p,"target_instance_id",input.instance_id);json_str(&p,"reason",input.reason);json_int(&p,"expected_generation",input.expected_generation);json_str(&p,"reservation_lease_id",reserved.lease_id);json_str(&p,"previous_phase",old_claim.phase)
 if _,_,written,werr:=record_event(svc,u,task,actor,EV_OWNERSHIP_TRANSFER_REQUESTED,json_end(&p));!written do return {},false,werr
 fresh,_,_:=iface.taskchain_get_task(svc.repo,task.task_id)
 if ownership_cleanup_pending(svc,fresh) do return Lease_Claim_Result{status="stop_pending",task=fresh,lease=reserved,target_instance_id=input.instance_id,agent_id=target.agent_id,role=reserved.kind,delivery="stop_pending"},true,{}
 return lease_claim_in_uow(svc,u,auth,Lease_Claim_Input{task_id=input.task_id,instance_id=input.instance_id,reason=input.reason,request_id=input.request_id,vcs_base=input.vcs_base})
}


// Only an originally active reservation resumes execution. A worker waiting for
// review and a reviewer whose verdict is already posted remain waiting.
transfer_reservation_needs_activation :: proc(svc:^Service,task:domain.Task,lease:domain.Task_Lease)->bool {
 if lease.phase!=domain.LEASE_PHASE_WAITING do return false
 events,err:=iface.taskchain_list_events_by_task(svc.repo,task.task_id,task.owner_user_id)
 if err.code!=.None do return false
 for ev in events {
  if ev.kind==EV_OWNERSHIP_TRANSFER_REQUESTED &&
     jsonx.extract_string(ev.payload_json,"reservation_lease_id","",true,context.temp_allocator)==lease.lease_id &&
     jsonx.extract_string(ev.payload_json,"previous_phase","",true,context.temp_allocator)==domain.LEASE_PHASE_ACTIVE {return true}
 }
 return false
}
