package taskv2

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
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
  if deleted,derr:=iface.taskchain_delete_lease(svc.repo,lease.lease_id);!deleted do return false,derr
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
 for ev in events {
  if ev.kind!=EV_OWNERSHIP_STOP_REQUESTED && ev.kind!=EV_OWNERSHIP_STOP_CONFIRMED do continue
  id:=jsonx.extract_string(ev.payload_json,"instance_id","",true,context.temp_allocator)
  run:=jsonx.extract_int(ev.payload_json,"run_count",-1,true)
  if ev.kind==EV_OWNERSHIP_STOP_REQUESTED {
   bridge:=jsonx.extract_string(ev.payload_json,"bridge_id","",true,context.temp_allocator)
   if bridge=="" {if inst,found,_:=iface.agent_get_instance(svc.agents,id);found do bridge=inst.bridge_id}
   command:=jsonx.extract_string(ev.payload_json,"command_id","",true,context.temp_allocator)
   append(&pending,Fenced_Stop{bridge,id,run,command})
  } else {
   command:=jsonx.extract_string(ev.payload_json,"command_id","",true,context.temp_allocator)
   for i:=len(pending)-1;i>=0;i-=1 {if pending[i].instance_id==id && pending[i].run_count==run && pending[i].command_id==command do ordered_remove(&pending,i)}
  }
 }
 return pending[:]
}
ownership_cleanup_pending :: proc(svc:^Service,task:domain.Task)->bool {return len(ownership_pending_stops(svc,task))>0}

instance_ownership_stop_pending :: proc(svc:^Service,inst:domain.Agent_Instance)->bool {
 chains,err:=iface.taskchain_list_chains_by_owner(svc.repo,inst.owner_user_id)
 if err.code!=.None do return true
 for chain in chains {
  tasks,terr:=iface.taskchain_list_tasks_by_chain(svc.repo,chain.chain_id,inst.owner_user_id)
  if terr.code!=.None do return true
  for task in tasks {for stop in ownership_pending_stops(svc,task) do if stop.instance_id==inst.agent_instance_id || stop.instance_id=="unknown" do return true}
 }
 return false
}

reconcile_ownership_stops_in_uow :: proc(svc:^Service,u:^Uow,inst:domain.Agent_Instance) {
 chains,err:=iface.taskchain_list_chains_by_owner(svc.repo,inst.owner_user_id)
 if err.code!=.None do return
 for chain in chains {
  tasks,terr:=iface.taskchain_list_tasks_by_chain(svc.repo,chain.chain_id,inst.owner_user_id)
  if terr.code!=.None do continue
  for task in tasks {
   for stop in ownership_pending_stops(svc,task) {
    if stop.instance_id!=inst.agent_instance_id do continue
    // Reconnect/status events only retry the original fence. They never prove
    // termination, and must never silently retarget it to a newer generation.
    queue_fenced_stop_generation(u,stop)
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
 chains,cerr:=iface.taskchain_list_chains_by_owner(svc.repo,inst.owner_user_id)
 if cerr.code!=.None {_,_=end_uow(svc,&u,false);return false,cerr}
 matched:=false
 for chain in chains {
  tasks,terr:=iface.taskchain_list_tasks_by_chain(svc.repo,chain.chain_id,chain.owner_user_id)
  if terr.code!=.None {_,_=end_uow(svc,&u,false);return false,terr}
  for task in tasks {
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
 }
 _,commit_err:=end_uow(svc,&u,true)
 return matched && commit_err.code==.None,commit_err
}

flush_fenced_stops :: proc(svc:^Service,e:^Effects) {
 for stop in e.fenced_stops {
  command:=stop.command_id
  if command=="" do continue // Older events fail closed until explicitly recovered.
  p:=json_begin();json_str(&p,"type","stop_agent");json_str(&p,"command_id",command);json_str(&p,"agent_instance_id",stop.instance_id);json_int(&p,"expected_run_count",i64(stop.run_count));json_bool(&p,"force",true)
  body:=json_end(&p)
  if svc.wake_observer!=nil do svc.wake_observer(svc.wake_observer_ctx,Wake_Command{bridge_id=stop.bridge_id,body_json=body})
  _,_=project.bridge_command_send_runtime(svc.bridge_command_sink,project.Runtime_Command{bridge_id=stop.bridge_id,command_id=command,body_json=body})
 }
}

effect_owned_string :: proc(e:^Effects,value:string)->string {owned:=strings.clone(value);append(&e.owned_strings,owned);return owned}
