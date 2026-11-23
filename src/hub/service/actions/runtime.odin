#+feature dynamic-literals
package actions

import "base:runtime"
import retry "odin_test:hub/service/pipelineretry"
import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import nats "odin_test:lib/nats"

Options :: struct {nats_url,creds_file,ca_file:string,max_deliver:int}
Runtime :: struct {
 svc:^Service,
 router:Router,
 options:Options,
 thread:^thread.Thread,
 stop_flag:i32,
 skipped_owner_mismatch,terminated:i64,
}
start :: proc(r:^Runtime,svc:^Service,router:Router,options:Options)->bool {
 if r.thread!=nil do return true
 context.allocator = runtime.heap_allocator()
 r.svc=svc; r.router=router; r.options=options
 r.options.nats_url=strings.clone(options.nats_url)
 r.options.creds_file=strings.clone(options.creds_file)
 r.options.ca_file=strings.clone(options.ca_file)
 sync.atomic_store(&r.stop_flag,0)
 r.thread=thread.create_and_start_with_data(r,runtime_entry,init_context=context)
 if r.thread==nil {
  delete(r.options.nats_url); delete(r.options.creds_file); delete(r.options.ca_file); r.options={}
  return false
 }
 return true
}
stop :: proc(r:^Runtime) {
 if r.thread==nil do return
 sync.atomic_store(&r.stop_flag,1)
 thread.join(r.thread); thread.destroy(r.thread); r.thread=nil
 context.allocator = runtime.heap_allocator()
 delete(r.options.nats_url); delete(r.options.creds_file); delete(r.options.ca_file); r.options={}
}
matcher_consumer_config :: proc(max_deliver:int)->nats.Consumer_Config {
 filters:=make([]string,1,context.temp_allocator)
 filters[0]="ev.>"
 return {stream="HEIM_EVENTS",durable="hub_action_matcher",filter_subjects=filters,
  deliver_new=true,ack_wait_ns=i64(time.Minute),max_deliver=i64(max_deliver)}
}
runtime_entry :: proc(data:rawptr) {
 r:=(^Runtime)(data)
 arena:virtual.Arena
 if virtual.arena_init_growing(&arena)!=nil do return
 defer virtual.arena_destroy(&arena)
 context.allocator=virtual.arena_allocator(&arena)
 context.temp_allocator=context.allocator
 conn:^nats.Connection
 pull:^nats.Pull
 defer {nats.pull_destroy(pull); nats.destroy(conn)}
 pending:=false
 was_unsupported:=false
 last_sweep:time.Tick
 retention_diagnostics:retry.State
 for sync.atomic_load(&r.stop_flag)==0 {
  if last_sweep._nsec==0 || time.tick_since(last_sweep)>=time.Minute {
   if err:=sweep_history(r.svc,time.now());err.code!=.None do _=retry.failed(&retention_diagnostics,"actions",.Retention,i32(err.code))
   last_sweep=time.tick_now()
  }
  if conn==nil {
   c,err:=nats.connect({url=r.options.nats_url,creds_file=r.options.creds_file,ca_file=r.options.ca_file,timeout_ms=1000})
   if err.status!=0 {runtime_wait(r); free_all(context.allocator); continue}
   conn=c
  }
  if pull==nil {
   _,err:=nats.stream_info(conn,"HEIM_EVENTS")
   if err.status!=0 {
    nats.destroy(conn); conn=nil; runtime_wait(r); free_all(context.allocator); continue
   }
   err=nats.consumer_add(conn,matcher_consumer_config(r.options.max_deliver))
   if err.status==0 do pull,err=nats.pull_bind(conn,"HEIM_EVENTS","hub_action_matcher")
   if err.status!=0 {
    nats.pull_destroy(pull); pull=nil; nats.destroy(conn); conn=nil
    runtime_wait(r); free_all(context.allocator); continue
   }
   pending=true
   drain_due(&r.router)
  }
  if pending {
   done,_:=reconcile(r.svc,conn)
   if done do pending=false
  }
  batch,err:=nats.fetch(pull,64,1000)
  hints:=make([dynamic]Resume_Hint)
  count:=nats.batch_count(batch)
  for i in 0..<count {
   msg:=nats.batch_message(batch,i)
   view,valid,poison:=runtime_event_view(msg)
   if poison {
    _=nats.term(msg)
    sync.atomic_add(&r.terminated,1)
    continue
   }
   if !valid {_=nats.ack(msg); continue}
   if handle_message(r,view) {
    _=nats.ack(msg)
    if view.event_type=="action.resume" {
     data,_:=view.envelope["data"].(json.Object)
     id,ok:=data["run_id"].(string)
     claimed,present:=view.envelope["owner_user_id"]
     allowed:=!present
     if present {owner,is_string:=claimed.(string); allowed=is_string && owner==view.owner}
     if ok && allowed do append(&hints,Resume_Hint{owner=strings.clone(view.owner),run_id=strings.clone(id)})
    }
   }
  }
  nats.batch_destroy(batch)
  unsupported:=r.router.support.get!=nil && r.router.support.get(r.router.support.ctx)==2
  if count>0 || (unsupported && !was_unsupported) do drain_due(&r.router,hints[:])
  was_unsupported=unsupported
  if err.status!=0 && err.status!=26 {
   nats.pull_destroy(pull); pull=nil; nats.destroy(conn); conn=nil
  }
  free_all(context.allocator)
 }
}
runtime_wait :: proc(r:^Runtime) {
 for _ in 0..<20 {
  if sync.atomic_load(&r.stop_flag)!=0 do return
  time.sleep(50*time.Millisecond)
 }
}
runtime_event_view :: proc(msg:^nats.Message)->(view:Event_View,valid,poison:bool) {
 view.subject=nats.message_subject(msg)
 parts:=strings.split(view.subject,".",context.temp_allocator)
 if len(parts)<3 || parts[0]!="ev" || parts[1]=="" || parts[1]=="dlq" do return view,false,false
 view.owner=parts[1]
 value:json.Value
 if json.unmarshal(nats.message_data(msg),&value,allocator=context.temp_allocator)!=nil do return view,false,true
 object,ok:=value.(json.Object)
 if !ok do return view,false,true
 view.envelope=object
 view.event_type,_=object["type"].(string)
 view.event_id,_=object["event_id"].(string)
 metadata,err:=nats.message_metadata(msg)
 if err.status!=0 do return view,false,false
 view.stream_sequence=metadata.stream_sequence
 view.stream_time_ms=metadata.timestamp_ns/1_000_000
 view.schedule_next,_=nats.message_header(msg,"Nats-Schedule-Next")
 view.trigger_rev,_=nats.message_header(msg,"Heim-Trigger-Rev")
 return view,true,false
}
