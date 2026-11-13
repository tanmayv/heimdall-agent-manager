package taskv2

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

EV_TASK_CANCEL_REQUESTED :: "task_cancel_requested"

Task_Cancel_Input :: struct {
 reason, request_id: string,
 expected_generation: i64,
}
Task_Cancel_Result :: struct {
 task: domain.Task,
 changed, cleanup_pending: bool,
 message: string,
}

// Scalar lookup shared by optional ownership preconditions.
task_control_generation :: proc(svc:^Service,task:domain.Task)->i64 {
 generation,err:=iface.taskchain_latest_event_id(svc.repo,task.task_id,task.owner_user_id)
 if err.code!=.None do return -1
 return generation
}

task_cancel :: proc(svc:^Service,task:domain.Task,actor:Actor,input:Task_Cancel_Input)->(Task_Cancel_Result,bool,domain.Domain_Error) {
 if strings.trim_space(input.reason)=="" || strings.trim_space(input.request_id)=="" do return {},false,domain.domain_error(.Validation_Failed,"reason and request_id are required")
 if input.expected_generation<0 do return {},false,domain.domain_error(.Validation_Failed,"expected_generation cannot be negative")
 u,ok,err:=begin_uow(svc)
 if !ok do return {},false,err
 result,accepted,aerr:=task_cancel_in_uow(svc,&u,task,actor,input)
 _,cerr:=end_uow(svc,&u,accepted)
 if !accepted do return {},false,aerr
 return result,cerr.code==.None,cerr
}

task_cancel_in_uow :: proc(svc:^Service,u:^Uow,task_in:domain.Task,actor:Actor,input:Task_Cancel_Input)->(Task_Cancel_Result,bool,domain.Domain_Error) {
 task,found,err:=iface.taskchain_get_task(svc.repo,task_in.task_id)
 if !found do return {},false,err
 if task.owner_user_id!=task_in.owner_user_id do return {},false,domain.domain_error(.Not_Found,"task not found")
 if _,allowed,aerr:=work_control_chain(svc,task.owner_user_id,actor,task.chain_id);!allowed do return {},false,aerr
 if task.workflow_run_id!="" do return {},false,domain.domain_error(.Conflict,"cancel the owning workflow run",`{"code":"workflow_task_managed"}`)
 events,eerr:=iface.taskchain_list_events_by_task(svc.repo,task.task_id,task.owner_user_id)
 if eerr.code!=.None do return {},false,eerr
 for event in events {
  if event.kind!=EV_TASK_CANCEL_REQUESTED || event.actor_kind!=actor.kind || event.actor_id!=actor.id do continue
  if jsonx.extract_string(event.payload_json,"request_id","",true,context.temp_allocator)!=input.request_id do continue
  if jsonx.extract_string(event.payload_json,"reason","",true,context.temp_allocator)!=input.reason || i64(jsonx.extract_int(event.payload_json,"expected_generation",-1,true))!=input.expected_generation do return {},false,domain.domain_error(.Conflict,"request_id already used with different cancellation arguments")
  return Task_Cancel_Result{task=task,cleanup_pending=ownership_cleanup_pending(svc,task),message="request already applied"},true,{}
 }
 if input.expected_generation>0 {
  generation:=task_control_generation(svc,task)
  if generation<0 do return {},false,domain.domain_error(.Internal_Error,"cannot read task generation")
  if generation!=input.expected_generation do return {},false,domain.domain_error(.Conflict,"task generation changed")
 }
 if task.state==.Cancelled do return Task_Cancel_Result{task=task,cleanup_pending=ownership_cleanup_pending(svc,task),message="task already cancelled"},true,{}
 if cerr:=cancel_task(svc,task,actor,input.reason);cerr.code!=.None do return {},false,cerr
 fresh,fok,ferr:=iface.taskchain_get_task(svc.repo,task.task_id)
 if !fok do return {},false,ferr
 audit:=json_begin()
 json_str(&audit,"request_id",input.request_id)
 json_str(&audit,"reason",input.reason)
 json_int(&audit,"expected_generation",input.expected_generation)
 if _,saved,serr:=append_event(svc.repo,svc.clock,fresh,actor,EV_TASK_CANCEL_REQUESTED,json_end(&audit));!saved do return {},false,serr
 return Task_Cancel_Result{task=fresh,changed=true,cleanup_pending=ownership_cleanup_pending(svc,fresh)},true,{}
}
