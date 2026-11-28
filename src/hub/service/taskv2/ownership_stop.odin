package taskv2

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

EV_OWNERSHIP_STOP_REQUESTED :: "ownership_stop_requested"
EV_OWNERSHIP_STOP_CONFIRMED :: "ownership_stop_confirmed"
Fenced_Stop :: struct {bridge_id,instance_id:string,run_count:int,command_id:string}

// Revocation is durable even while offline. The audit event is the fence;
// current_task_id is merely a projection and is never trusted as authority.
revoke_claim_in_uow :: proc(svc:^Service,u:^Uow,task:domain.Task,lease:domain.Task_Lease,actor:Actor,reason:string,continuation:=false)->(bool,domain.Domain_Error) {
 inst,found,err:=iface.agent_get_instance(svc.agents,lease.holder_instance_id)
 if !found do return false,err
 release:=json_begin();json_str(&release,"lease_id",lease.lease_id);json_str(&release,"kind",lease.kind);json_int(&release,"attempt_no",i64(lease.attempt_no));json_str(&release,"reason",EXPIRE_REPLACED);json_str(&release,"administrative_reason",reason)
 event_kind:=EV_LEASE_EXPIRED
 if lease.phase==domain.LEASE_PHASE_WAITING do event_kind=EV_CLAIM_RELEASED
 if lease.phase==domain.LEASE_PHASE_WAITING {
  if deleted,derr:=delete_claim(svc, lease);!deleted do return false,derr
  if _,_,written,werr:=record_event(svc,u,task,actor,event_kind,json_end(&release));!written do return false,werr
  mark_instance_idle(svc,u,inst.agent_instance_id,platform.clock_now(svc.clock))
 } else {
  if continuation do event_kind=EV_HANDOFF
  if _,released,rerr:=release_in_uow(svc,u,lease,actor,event_kind,json_end(&release),"handoff" if continuation else "replaced",false);!released do return false,rerr
 }
 command_id:=platform.generate_id(svc.ids,"cmd_ownership_stop_")
 p:=json_begin();json_str(&p,"lease_id",lease.lease_id);json_str(&p,"instance_id",inst.agent_instance_id);json_int(&p,"run_count",i64(inst.run_count));json_str(&p,"reason",reason);json_str(&p,"command_id",command_id);json_str(&p,"bridge_id",inst.bridge_id)
 // Runtime projections are not generation-tagged evidence of process death.
 // Even a terminal projection requires an acknowledged fenced stop.
 {
  _,_,written,werr:=record_event(svc,u,task,actor,EV_OWNERSHIP_STOP_REQUESTED,json_end(&p))
  if !written do return false,werr
  queue_fenced_stop_generation(u,Fenced_Stop{inst.bridge_id,inst.agent_instance_id,inst.run_count,command_id})
 }
 return true,{}
}

queue_fenced_stop_generation :: proc(u:^Uow,requested:Fenced_Stop) {
 for stop in u.effects.fenced_stops do if stop.instance_id==requested.instance_id && stop.run_count==requested.run_count do return
 append(&u.effects.fenced_stops,Fenced_Stop{effect_owned_string(&u.effects,requested.bridge_id),effect_owned_string(&u.effects,requested.instance_id),requested.run_count,effect_owned_string(&u.effects,requested.command_id)})
}

// Pending stop requests survive restarts. A later matching confirmation clears
// only that generation, never a subsequent process or another transfer.
ownership_pending_stops :: proc(svc:^Service,task:domain.Task)->[]Fenced_Stop {
 events,err:=iface.taskchain_list_events_by_task(svc.repo,task.task_id,task.owner_user_id)
 if err.code!=.None {failed:=make([]Fenced_Stop,1,context.temp_allocator);failed[0].instance_id="unknown";return failed}
 pending:=make([dynamic]Fenced_Stop,context.temp_allocator)
 fold_pending_stops(svc,events,&pending)
 return pending[:]
}
ownership_cleanup_pending :: proc(svc:^Service,task:domain.Task)->bool {return len(ownership_pending_stops(svc,task))>0}

// fold_pending_stops applies ONE task's events (ascending; other kinds are skipped)
// to `pending`: a request adds its generation, a matching confirmation removes it.
@(private="file")
fold_pending_stops :: proc(svc:^Service,events:[]domain.Task_Event,pending:^[dynamic]Fenced_Stop) {
 for ev in events {
  if ev.kind!=EV_OWNERSHIP_STOP_REQUESTED && ev.kind!=EV_OWNERSHIP_STOP_CONFIRMED do continue
  id:=jsonx.extract_string(ev.payload_json,"instance_id","",true,context.temp_allocator)
  run:=jsonx.extract_int(ev.payload_json,"run_count",-1,true)
  if ev.kind==EV_OWNERSHIP_STOP_REQUESTED {
   bridge:=jsonx.extract_string(ev.payload_json,"bridge_id","",true,context.temp_allocator)
   if bridge=="" {if inst,found,_:=iface.agent_get_instance(svc.agents,id);found do bridge=inst.bridge_id}
   command:=jsonx.extract_string(ev.payload_json,"command_id","",true,context.temp_allocator)
   append(pending,Fenced_Stop{bridge,id,run,command})
  } else {
   command:=jsonx.extract_string(ev.payload_json,"command_id","",true,context.temp_allocator)
   for i:=len(pending)-1;i>=0;i-=1 {if pending[i].instance_id==id && pending[i].run_count==run && pending[i].command_id==command do ordered_remove(pending,i)}
  }
 }
}

Owner_Pending_Stop :: struct {task_id:domain.Task_ID,stop:Fenced_Stop}

// owner_pending_stops: every still-pending fence across the owner's tasks, folded per
// task from ONE kind-filtered read. Walking chains -> tasks -> every event of every task
// (comments and payloads included) once per instance made a bridge hello with ~180
// instances allocate ~1.5 GB while holding the write transaction. ok=false: the read
// failed, so callers must treat the fence as unknown (fail closed).
owner_pending_stops :: proc(svc:^Service,owner:domain.User_ID)->(stops:[]Owner_Pending_Stop,ok:bool) {
 events,err:=iface.taskchain_list_ownership_stop_events(svc.repo,owner)
 if err.code!=.None do return nil,false
 defer delete(events)
 by_task:=make(map[domain.Task_ID][dynamic]domain.Task_Event,allocator=context.temp_allocator)
 order:=make([dynamic]domain.Task_ID,context.temp_allocator)
 for ev in events {
  if ev.task_id not_in by_task {by_task[ev.task_id]=make([dynamic]domain.Task_Event,context.temp_allocator);append(&order,ev.task_id)}
  append(&by_task[ev.task_id],ev)
 }
 out:=make([dynamic]Owner_Pending_Stop,context.temp_allocator)
 for task_id in order {
  pending:=make([dynamic]Fenced_Stop,context.temp_allocator)
  fold_pending_stops(svc,by_task[task_id][:],&pending)
  for stop in pending do append(&out,Owner_Pending_Stop{task_id,stop})
 }
 return out[:],true
}

instance_ownership_stop_pending :: proc(svc:^Service,inst:domain.Agent_Instance)->bool {
 stops,ok:=owner_pending_stops(svc,inst.owner_user_id)
 if !ok do return true
 for p in stops do if p.stop.instance_id==inst.agent_instance_id do return true
 return false
}

reconcile_ownership_stops_in_uow :: proc(svc:^Service,u:^Uow,inst:domain.Agent_Instance) {
 reconcile_ownership_stops_for_instances_in_uow(svc,u,[]domain.Agent_Instance{inst})
}

// reconcile_ownership_stops_for_instances_in_uow re-queues the pending fences of
// `instances` (one bridge hello), reading each owner's stop events once.
reconcile_ownership_stops_for_instances_in_uow :: proc(svc:^Service,u:^Uow,instances:[]domain.Agent_Instance) {
 owners:=make([dynamic]domain.User_ID,context.temp_allocator)
 for inst in instances {
  seen:=false
  for o in owners do if o==inst.owner_user_id {seen=true;break}
  if !seen do append(&owners,inst.owner_user_id)
 }
 for owner in owners {
  stops,ok:=owner_pending_stops(svc,owner)
  if !ok do continue
  for inst in instances {
   if inst.owner_user_id!=owner do continue
   for p in stops {
    if p.stop.instance_id!=inst.agent_instance_id do continue
    // Reconnect/status events only retry the original fence. They never prove
    // termination, and must never silently retarget it to a newer generation.
    queue_fenced_stop_generation(u,p.stop)
   }
  }
 }
}

// Called only for an authenticated successful stop_agent command result whose
// original request names this exact instance and expected_run_count.
confirm_ownership_stop_result :: proc(svc:^Service,bridge_id,command_id,result_json:string)->(bool,domain.Domain_Error) {
 if command_id=="" || bridge_id=="" do return false,domain.domain_error(.Validation_Failed,"stop confirmation requires bridge and command")
 if jsonx.extract_string(result_json,"type","",true,context.temp_allocator)!="command_result" ||
    jsonx.extract_string(result_json,"command_id","",true,context.temp_allocator)!=command_id ||
    !jsonx.extract_bool(result_json,"ok",false,true) {return false,{}}
 payload,pok:=jsonx.extract_raw_object(result_json,"payload",true,context.temp_allocator)
 if !pok || jsonx.extract_string(payload,"status","",true,context.temp_allocator)!="succeeded" do return false,{}
 result,rok:=jsonx.extract_raw_object(payload,"result",true,context.temp_allocator)
 if !rok || jsonx.extract_string(result,"runtime_status","",true,context.temp_allocator)!="stopped" do return false,{}
 instance_id:=jsonx.extract_string(result,"agent_instance_id","",true,context.temp_allocator)
 run_count:=jsonx.extract_int(result,"expected_run_count",-1,true)
 if instance_id=="" || run_count<0 do return false,{}
 inst,found,ierr:=iface.agent_get_instance(svc.agents,instance_id)
 if !found do return false,ierr
 if inst.bridge_id!=bridge_id do return false,domain.domain_error(.Forbidden,"ownership stop bridge mismatch")
 u,ok,uerr:=begin_uow(svc)
 if !ok do return false,uerr
 pending,stops_ok:=owner_pending_stops(svc,inst.owner_user_id)
 if !stops_ok {_,_=end_uow(svc,&u,false);return false,domain.domain_error(.Internal_Error,"failed to read ownership stop events")}
 // Only tasks holding this exact generation's fence can be confirmed.
 task_ids:=make([dynamic]domain.Task_ID,context.temp_allocator)
 for p in pending {
  if p.stop.bridge_id!=bridge_id || p.stop.command_id!=command_id || p.stop.instance_id!=instance_id || p.stop.run_count!=run_count do continue
  seen:=false
  for id in task_ids do if id==p.task_id {seen=true;break}
  if !seen do append(&task_ids,p.task_id)
 }
 matched:=false
 for task_id in task_ids {
  task,tfound,terr:=iface.taskchain_get_task(svc.repo,task_id)
  if !tfound {_,_=end_uow(svc,&u,false);return false,terr}
  task_matched:=false
  for stop in ownership_pending_stops(svc,task) {
   if stop.bridge_id!=bridge_id || stop.command_id!=command_id || stop.instance_id!=instance_id || stop.run_count!=run_count do continue
   matched=true
   task_matched=true
   p:=json_begin();json_str(&p,"instance_id",stop.instance_id);json_int(&p,"run_count",i64(stop.run_count));json_str(&p,"command_id",command_id)
   if _,_,written,werr:=record_event(svc,&u,task,hub_actor(),EV_OWNERSHIP_STOP_CONFIRMED,json_end(&p));!written {_,_=end_uow(svc,&u,false);return false,werr}
  }
  if task_matched && !ownership_cleanup_pending(svc,task) {
   claims,lerr:=iface.taskchain_list_leases_by_task(svc.repo,task.task_id)
   if lerr.code!=.None {_,_=end_uow(svc,&u,false);return false,lerr}
   for claim in claims {
    if !transfer_reservation_needs_activation(svc,task,claim) do continue
    // The durable transfer already authorized this beneficiary. Confirmation
    // delivers it immediately; ordinary identity/phase checks still apply.
    // A failed activation rolls back its own savepoint, preserving only
    // the confirmed stop; the coordinator can retry after repair.
    _,_,_=lease_claim(svc,contracts.Auth_Context{kind=.Internal_User,user_id=string(task.owner_user_id)},Lease_Claim_Input{task_id=task.task_id,instance_id=claim.holder_instance_id})
   }
  }
 }
 _,commit_err:=end_uow(svc,&u,true)
 return matched && commit_err.code==.None,commit_err
}

flush_fenced_stops :: proc(svc:^Service,e:^Effects) {
 for stop in e.fenced_stops {
  command:=stop.command_id
  if command=="" do continue // Older events fail closed until explicitly recovered.
  // The one stop builder (agent.stop_command_json); the fence is the
  // generation, and a revoked claim's holder is stopped at once.
  body:=agent.stop_command_json(command,stop.instance_id,agent.STOP_LEASE_REVOKED,force=true,expected_run_count=stop.run_count)
  defer delete(body)
  if svc.wake_observer!=nil do svc.wake_observer(svc.wake_observer_ctx,Wake_Command{bridge_id=stop.bridge_id,body_json=body})
  _,_=project.bridge_command_send_runtime(svc.bridge_command_sink,project.Runtime_Command{bridge_id=stop.bridge_id,command_id=command,body_json=body})
 }
}

effect_owned_string :: proc(e:^Effects,value:string)->string {owned:=strings.clone(value);append(&e.owned_strings,owned);return owned}
