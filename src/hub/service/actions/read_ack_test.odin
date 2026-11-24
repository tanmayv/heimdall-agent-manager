package actions

import "core:fmt"
import "core:encoding/json"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import content "odin_test:hub/service/content"
import delivery "odin_test:hub/service/delivery"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

ack_read_hook :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner:domain.User_ID,ids:[]string)->domain.Domain_Error {
 return delivery.on_messages_read((^delivery.Service)(ctx),uow,owner,ids)
}
ack_unread_hook :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,id:string)->domain.Domain_Error {
 return delivery.on_unread(&((^Action_Test)(ctx)).pipeline,uow,owner,id)
}
ack_prompt :: proc(t:^testing.T,f:^Action_Test)->domain.Action_Run {
 action_test_match(t,f,"ack"); drain_due(&f.runtime.router)
 run,found,err:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 testing.expect(t,found && err.code==.None)
 uow,ok,_:=iface.unit_of_work_begin(&f.factory); assert(ok)
 repo:=&uow.repos.pipeline_deliveries
 d,exists,e:=repo.get(repo.ctx,run.delivery_id); assert(exists && e.code==.None)
 next:=d; next.state=domain.DELIVERY_FORWARDED; next.attempt=1
 changed,te:=repo.transition(repo.ctx,next,d.state)
 testing.expect(t,changed && te.code==.None)
 domain.pipeline_delivery_destroy(&d)
 _,_=iface.unit_of_work_commit(&uow)
 return run
}
ack_succeed :: proc(f:^Action_Test,run:domain.Action_Run) {
 delivery.on_command_result(&f.pipeline,"bridge",fmt.tprintf("%s:1",run.delivery_id),`{"status":"succeeded","outcome":"notified"}`)
}
ack_read :: proc(t:^testing.T,f:^Action_Test,run:domain.Action_Run) {
 svc:=content.Content_Service{content=&f.repos.content,uow_factory=&f.factory,clock=&f.clock,
  messages_read={ctx=&f.pipeline,read=ack_read_hook}}
 ids:=[1]string{run.message_id}
 count,err:=content.mark_messages_read_by_ids(&svc,contracts.Auth_Context{kind=.Instance_Token,user_id="owner",agent_instance_id="instance"},ids[:])
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,count,1)
}
ack_assert :: proc(t:^testing.T,f:^Action_Test,run:domain.Action_Run,state,outcome,reason:string) {
 d,found,err:=action_test_delivery(f,run.delivery_id)
 testing.expect(t,found && err.code==.None)
 testing.expect_value(t,d.state,state);testing.expect_value(t,d.outcome,outcome);testing.expect_value(t,d.reason,reason)
}
ack_fire :: proc(t:^testing.T,f:^Action_Test,run:domain.Action_Run,owner:string="owner") {
 f.runtime.router.pipeline.unread=ack_unread_hook
 data:=make(json.Object);data["delivery_id"]=run.delivery_id
 envelope:=make(json.Object);envelope["type"]=string("delivery.unread");envelope["owner_user_id"]=owner;envelope["data"]=data
 testing.expect(t,handle_message(&f.runtime,{
  subject=fmt.tprintf("ev.%s.delivery.%s.unread",owner,run.delivery_id),owner=owner,event_type="delivery.unread",
  envelope=envelope}))
}
ack_backlog_rows :: proc(t:^testing.T,f:^Action_Test)->[]domain.Event_Outbox_Row {
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 repo:=&uow.repos.event_outbox
 rows: [dynamic]domain.Event_Outbox_Row
 for {
  row,found,err:=repo.next(repo.ctx)
  testing.expect_value(t,err.code,domain.Error_Code.None)
  if !found do break
  append(&rows,row)
  testing.expect_value(t,repo.mark_published(repo.ctx,row.outbox_seq,"now").code,domain.Error_Code.None)
 }
 iface.unit_of_work_rollback(&uow)
 return rows[:]
}
ack_lifecycle :: proc(t:^testing.T,f:^Action_Test) {
 run:=ack_prompt(t,f);ack_succeed(f,run)
 ack_assert(t,f,run,"delivered","","")
 action_test_expect(t,f,"routed",1)
 history,err:=list_runs(&f.runtime.router,"owner","action",10,"")
 testing.expect(t,err.code==.None && len(history)==1)
 testing.expect_value(t,history[0].delivery_state,"delivered")
 rows:=ack_backlog_rows(t,f)
 testing.expect_value(t,len(rows),2)
 testing.expect_value(t,rows[1].subject,fmt.tprintf("sched.def.unread.%s",run.delivery_id))
 headers:=test_config(rows[1].headers_json)
 testing.expect_value(t,headers["Nats-Schedule"].(string),"@at 2026-11-23T00:30:00Z")
 testing.expect_value(t,headers["Nats-Schedule-Target"].(string),fmt.tprintf("ev.owner.delivery.%s.unread",run.delivery_id))
 ack_read(t,f,run)
 ack_assert(t,f,run,"done","read","")
 action_test_expect(t,f,"delivered",1)
 ack_succeed(f,run);ack_fire(t,f,run)
 ack_assert(t,f,run,"done","read","")
 after:=ack_backlog_rows(t,f)
 testing.expect_value(t,len(after),3)
 purge:=test_config(after[2].headers_json)
 testing.expect_value(t,purge["Heim-Op"].(string),"purge")
}
ack_before_result :: proc(t:^testing.T,f:^Action_Test) {
 run:=ack_prompt(t,f);ack_read(t,f,run)
 ack_assert(t,f,run,"forwarded","","")
 ack_succeed(f,run)
 ack_assert(t,f,run,"done","read","")
 action_test_expect(t,f,"delivered",1)
 rows:=ack_backlog_rows(t,f);testing.expect_value(t,len(rows),1)
}
ack_timeout :: proc(t:^testing.T,f:^Action_Test) {
 run:=ack_prompt(t,f);ack_succeed(f,run)
 f.now_ms+=i64(30*time.Minute/time.Millisecond)
 ack_fire(t,f,run,"intruder")
 ack_assert(t,f,run,"delivered","","")
 ack_fire(t,f,run)
 ack_assert(t,f,run,"failed","","not_read")
 stored,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,run.run_id)
 testing.expect_value(t,stored.state,"failed");testing.expect_value(t,stored.reason,"not_read")
 backlog,_:=action_test_backlog(f)
 ack_fire(t,f,run);ack_succeed(f,run)
 repeated,_:=action_test_backlog(f);testing.expect_value(t,repeated,backlog)
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 repo:=&uow.repos.pipeline_deliveries
 notices,err:=repo.open_for_bridge(repo.ctx,"bridge","",100)
 testing.expect(t,err.code==.None && len(notices)==1)
 if len(notices)>0 {
  testing.expect_value(t,notices[0].kind,"notice")
  testing.expect_value(t,notices[0].message_id,run.message_id)
 }
 iface.unit_of_work_rollback(&uow)
 ack_read(t,f,run);ack_assert(t,f,run,"failed","","not_read")
}
ack_rollback :: proc(t:^testing.T,f:^Action_Test) {
 run:=ack_prompt(t,f);ack_succeed(f,run)
 svc:=content.Content_Service{content=&f.repos.content,uow_factory=&f.factory,clock=&f.clock,
  messages_read={read=proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner:domain.User_ID,ids:[]string)->domain.Domain_Error {
   return domain.domain_error(.Internal_Error,"injected read hook failure")
  }}}
 ids:=[1]string{run.message_id}
 _,err:=content.mark_messages_read_by_ids(&svc,{kind=.Instance_Token,user_id="owner",agent_instance_id="instance"},ids[:])
 testing.expect_value(t,err.code,domain.Error_Code.Internal_Error)
 message,_,_:=iface.content_get_message(&f.repos.content,run.message_id)
 testing.expect_value(t,message.read_at,"")
 ack_assert(t,f,run,"delivered","","")
}
@(test)
test_prompt_delivery_read_lifecycle :: proc(t:^testing.T) {action_test_case(t,ack_lifecycle)}
@(test)
test_prompt_read_before_bridge_result :: proc(t:^testing.T) {action_test_case(t,ack_before_result)}
@(test)
test_prompt_unread_event_fails_once :: proc(t:^testing.T) {action_test_case(t,ack_timeout)}
@(test)
test_prompt_read_hook_rolls_back_receipt :: proc(t:^testing.T) {action_test_case(t,ack_rollback)}

ack_nats_schedule :: proc(t:^testing.T,f:^Action_Test) {
 run:=ack_prompt(t,f);ack_succeed(f,run)
 rows:=ack_backlog_rows(t,f)
 if !testing.expect_value(t,len(rows),2) do return
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 testing.expect_value(t,nats.consumer_add(conn,matcher_consumer_config(8)).status,i32(0))
 pull,err:=nats.pull_bind(conn,"HEIM_EVENTS","hub_action_matcher")
 if !testing.expect_value(t,err.status,i32(0)) do return
 defer nats.pull_destroy(pull)
 config:=test_config(rows[1].headers_json)
 // The production 30m expression is asserted above. Advance only the broker
 // deadline for this real scheduling test so it completes without a hub tick.
 headers:=[3]nats.Header{
  {"Nats-Schedule",fmt.tprintf("@at %s",platform.format_rfc3339_utc(time.Time{_nsec=time.now()._nsec+i64(2*time.Second)}))},
  {"Nats-Schedule-Target",config["Nats-Schedule-Target"].(string)},
  {"Nats-Schedule-TTL",config["Nats-Schedule-TTL"].(string)},
 }
 _,err=nats.publish(conn,rows[1].subject,transmute([]u8)rows[1].envelope_json,headers=headers[:])
 if !testing.expect_value(t,err.status,i32(0)) do return
 batch,fetch_err:=nats.fetch(pull,1,5000)
 defer nats.batch_destroy(batch)
 testing.expect_value(t,fetch_err.status,i32(0))
 if !testing.expect_value(t,nats.batch_count(batch),1) do return
 msg:=nats.batch_message(batch,0)
 view,valid,poison:=runtime_event_view(msg)
 testing.expect(t,valid && !poison)
 testing.expect_value(t,view.event_type,"delivery.unread")
 f.runtime.router.pipeline.unread=ack_unread_hook
 testing.expect(t,handle_message(&f.runtime,view))
 testing.expect_value(t,nats.ack(msg).status,i32(0))
 ack_assert(t,f,run,"failed","","not_read")
}
@(test)
test_prompt_unread_fires_via_nats_schedule :: proc(t:^testing.T) {
 action_test_case(t,ack_nats_schedule)
 testing.expect_value(t,nats.shutdown(5000).status,i32(0))
}
