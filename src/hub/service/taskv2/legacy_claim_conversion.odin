package taskv2

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

EV_CLAIM_CONVERSION_PENDING :: "durable_claim_conversion_pending"
EV_CLAIM_CONVERSION_CHECKED :: "durable_claim_conversion_checked"

// Migration 203 snapshots candidates. Never infer them from later submissions:
// otherwise a deliberate post-cutover release would be undone on every restart.
// This runs inside boot's UoW before regating or dispatch, without launching work.
convert_legacy_review_claims_in_uow :: proc(svc: ^Service, u: ^Uow) -> (bool, domain.Domain_Error) {
 tasks, err := iface.taskchain_list_tasks_by_state(svc.repo, .In_Review)
 if err.code != .None do return false, err
 for task in tasks {
  events, eerr := iface.taskchain_list_events_by_task(svc.repo,task.task_id,task.owner_user_id)
  if eerr.code != .None do return false,eerr
  pending := ""
  checked := false
  for event in events {
   if event.kind == EV_CLAIM_CONVERSION_PENDING do pending=event.payload_json
   if event.kind == EV_CLAIM_CONVERSION_CHECKED do checked=true
  }
  if pending=="" || checked do continue
  holder:=jsonx.extract_string(pending,"holder_instance_id","",true,context.temp_allocator)
  attempt:=int(jsonx.extract_int(pending,"attempt_no",0,true))
  reason:=""
  inst,found,ierr:=iface.agent_get_instance(svc.agents,holder)
  if ierr.code != .None && ierr.code != .Not_Found do return false,ierr
  assignee:=brief_assignee(task.brief_json)
  worker_eligible:=assignee!="" && assignee==inst.agent_id
  if assignee=="" {
   fleets,ferr:=iface.taskchain_list_fleets_by_chain(svc.repo,task.chain_id,task.owner_user_id)
   if ferr.code!=.None do return false,ferr
   // Pausing new dispatch does not revoke retained responsibility.
   for fleet in fleets {
    if fleet.agent_id==inst.agent_id && fleet_row_has_role(fleet,domain.FLEET_ROLE_WORKER) do worker_eligible=true
   }
  }
  leases,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
  if lerr.code != .None do return false,lerr
  for lease in leases do if lease.kind==domain.LEASE_KIND_WORK do reason="work_owner_already_present"
  if reason=="" {
   if !found || holder=="" { reason="legacy_holder_missing"
   } else if inst.owner_user_id!=task.owner_user_id || inst.agent_id=="" || !worker_eligible || (assignee!="" && inst.agent_id!=assignee) { reason="legacy_identity_no_longer_eligible"
   } else if inst.stopped_by=="user" { reason="legacy_holder_deliberately_stopped"
   } else if attempt!=task.attempt_no { reason="legacy_attempt_changed"
   } else if other,held,herr:=iface.taskchain_get_lease_by_holder(svc.repo,holder);herr.code!=.None && herr.code!=.Not_Found { return false,herr
   } else if held { _=other; reason="legacy_holder_owns_another_responsibility"
   } else if inst.current_task_id!="" && inst.current_task_id!=string(task.task_id) { reason="legacy_holder_pointer_conflict"
   } else if ownership_cleanup_pending(svc,task) || instance_ownership_stop_pending(svc,inst) { reason="legacy_holder_stop_pending"
   }
  }
  if reason=="" {
   now:=platform.clock_now(svc.clock)
   claim:=domain.Task_Lease{
    lease_id=platform.generate_id(svc.ids,"lease_"),task_id=task.task_id,chain_id=task.chain_id,
    owner_user_id=task.owner_user_id,attempt_no=task.attempt_no,holder_instance_id=holder,
    kind=domain.LEASE_KIND_WORK,phase=domain.LEASE_PHASE_WAITING,bridge_id=inst.bridge_id,
    provider=inst.provider,provider_profile=inst.provider_profile,model=inst.model,
    granted_at=now,confirmed_at=now,last_beat_at=now,delivery=domain.LEASE_DELIVERY_INLINE,
   }
   if _,saved,serr:=iface.taskchain_save_lease(svc.repo,claim);!saved do return false,serr
   set_instance_pointer(svc,u,holder,string(task.task_id),.Work)
   reason="waiting_owner_restored"
  }
  payload:=json_begin()
  json_str(&payload,"holder_instance_id",holder)
  json_int(&payload,"attempt_no",i64(attempt))
  json_str(&payload,"reason",reason)
  json_bool(&payload,"repair_required",reason!="waiting_owner_restored" && reason!="work_owner_already_present")
  if _,saved,serr:=append_event(svc.repo,svc.clock,task,hub_actor(),EV_CLAIM_CONVERSION_CHECKED,json_end(&payload));!saved do return false,serr
  effect_publish_task(u,task,EV_CLAIM_CONVERSION_CHECKED)
 }
 return true,{}
}
