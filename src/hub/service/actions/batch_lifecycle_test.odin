package actions

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import delivery "odin_test:hub/service/delivery"

batch_ready_count :: proc(t:^testing.T,f:^Action_Test)->int {
 count:=0
 for row in ack_backlog_rows(t,f) do if strings.has_suffix(row.subject,".ready") do count+=1
 return count
}
batch_assert_members :: proc(t:^testing.T,f:^Action_Test,ids:[]string,state,reason:string) {
 for id in ids {
  run,found,err:=f.repos.actions.run_get(f.repos.actions.ctx,id)
  testing.expect(t,found && err.code==.None)
  testing.expect_value(t,run.state,state);testing.expect_value(t,run.reason,reason)
  if state=="delivered" || state=="failed" do testing.expect(t,run.finished_at!="")
 }
}
// Start a three-member prompt, then create two more actions while it awaits read.
batch_awaiting_read :: proc(t:^testing.T,f:^Action_Test)->(domain.Action_Run,[]string,[]string) {
 batch_seed(t,f,3)
 run:=ack_prompt(t,f);ack_succeed(f,run)
 members,err:=f.repos.actions.runs_for_delivery(f.repos.actions.ctx,run.delivery_id)
 testing.expect(t,err.code==.None && len(members)==3)
 ids:=make([]string,len(members),context.temp_allocator)
 for row,i in members do ids[i]=row.run_id
 for i in 3..<5 do action_test_seed(t,f,fmt.tprintf("action%d",i),fmt.tprintf("trigger%d",i),"owner")
 action_test_match(t,f,"waiting");drain_due(&f.runtime.router)
 parked:=make([]string,2,context.temp_allocator)
 for i in 0..<2 {
  row,found,e:=f.repos.actions.run_open(f.repos.actions.ctx,domain.Action_ID(fmt.tprintf("action%d",i+3)))
  testing.expect(t,found && e.code==.None)
  testing.expect_value(t,row.state,"deferred")
  testing.expect_value(t,row.target_instance_id,"instance")
  parked[i]=row.run_id
 }
 testing.expect_value(t,f.routes,1)
 return run,ids,parked
}
batch_read_release :: proc(t:^testing.T,f:^Action_Test) {
 run,ids,parked:=batch_awaiting_read(t,f)
 testing.expect_value(t,batch_ready_count(t,f),0)
 ack_read(t,f,run)
 batch_assert_members(t,f,ids,"delivered","")
 testing.expect_value(t,batch_ready_count(t,f),1)
 for id in parked {
  row,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,id)
  testing.expect_value(t,row.not_before,action_test_clock(f))
 }
 history,e:=list_runs(&f.runtime.router,"owner","action",10,"")
 testing.expect_value(t,e.code,domain.Error_Code.None)
 found_history:=false
 for row in history do if row.run.run_id==run.run_id {found_history=true;testing.expect_value(t,row.batch_size,3)}
 testing.expect(t,found_history)
 // Duplicate read/final callbacks must not add another wake.
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 testing.expect_value(t,on_delivery_final(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id,state=domain.DELIVERY_DONE}).code,domain.Error_Code.None)
 _,_=iface.unit_of_work_commit(&uow)
 testing.expect_value(t,batch_ready_count(t,f),1)
 drain_due(&f.runtime.router)
 batch_assert_members(t,f,parked,"routed","")
 next,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,parked[0])
 other,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,parked[1])
 testing.expect_value(t,next.delivery_id,other.delivery_id)
 message,_,_:=iface.content_get_message(&f.repos.content,next.message_id)
 testing.expect(t,strings.has_prefix(message.body,"2 actions fired for you."))
 testing.expect_value(t,f.routes,2)
}
batch_not_read_release :: proc(t:^testing.T,f:^Action_Test) {
 run,ids,parked:=batch_awaiting_read(t,f)
 f.now_ms+=i64(30*time.Minute/time.Millisecond)
 ack_fire(t,f,run)
 batch_assert_members(t,f,ids,"failed","not_read")
 testing.expect_value(t,batch_ready_count(t,f),1)
 history,e:=list_runs(&f.runtime.router,"owner","action",10,"")
 testing.expect_value(t,e.code,domain.Error_Code.None)
 found_history:=false
 for row in history do if row.run.run_id==run.run_id {found_history=true;testing.expect_value(t,row.batch_size,3)}
 testing.expect(t,found_history)
 drain_due(&f.runtime.router)
 batch_assert_members(t,f,parked,"routed","")
 testing.expect_value(t,f.routes,2)
}
batch_lazy_expiry :: proc(t:^testing.T,f:^Action_Test) {
 run,ids,parked:=batch_awaiting_read(t,f)
 d,_,_:=action_test_delivery(f,run.delivery_id)
 ms,_:=schedule_time(d.expires_at)
 f.now_ms=ms
 // No unread event arrives: due parked runs must expire the target delivery.
 drain_due(&f.runtime.router)
 batch_assert_members(t,f,ids,"failed","not_read")
 batch_assert_members(t,f,parked,"routed","")
 testing.expect_value(t,f.routes,2)
}
batch_no_schedules :: proc(t:^testing.T,f:^Action_Test) {
 run,_,parked:=batch_awaiting_read(t,f)
 f.support=2
 // Fill the first deferred page with parked rows. A real timer behind it
 // must still be swept; filtering only inside the drain would starve it.
 for i in 5..<40 do action_test_seed(t,f,fmt.tprintf("action%d",i),fmt.tprintf("trigger%d",i),"owner")
 action_test_match(t,f,"more-waiting");drain_due(&f.runtime.router)
 batch_assert_members(t,f,parked,"deferred","")
 action_test_seed(t,f,"timer","timer-trigger","owner")
 _,err:=f.repos.actions.run_insert(f.repos.actions.ctx,{run_id="timer-run",action_id="timer",owner_user_id="owner",occurrence_key="timer-run",event_params_json="{}",state="deferred",not_before="2027-01-01T00:00:00Z",created_at="2026-12-01T00:00:00Z"})
 testing.expect_value(t,err.code,domain.Error_Code.None)
 drain_due(&f.runtime.router)
 batch_assert_members(t,f,[]string{"timer-run"},"skipped","rate_limited")
 batch_assert_members(t,f,parked,"deferred","")
 ack_read(t,f,run);drain_due(&f.runtime.router)
 batch_assert_members(t,f,parked,"routed","")
}
batch_replace_all :: proc(t:^testing.T,f:^Action_Test) {
 batch_seed(t,f,3)
 p:=routing_place_setup(t,f);defer action_place_fixture_destroy(p)
 actions,_:=f.repos.actions.list(f.repos.actions.ctx,"owner")
 for &a in actions {
  a.target_kind=domain.ACTION_TARGET_AGENT;a.target_agent_id="agent"
  _=f.repos.actions.save(f.repos.actions.ctx,a)
  _=f.repos.actions.rules_replace(f.repos.actions.ctx,a.id,[]domain.Action_Target_Rule{{0,"bridge1","alpha","m1"},{1,"bridge2","alpha","m1"}})
 }
 action_test_match(t,f,"replace");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 delivery.on_bridge_offline(&f.pipeline,"bridge1")
 testing.expect_value(t,p.created,2);testing.expect_value(t,f.routes,2)
 next_id:=""
 for a in actions {
  next,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,a.id)
  testing.expect_value(t,next.target_instance_id,"created2")
  testing.expect(t,next.delivery_id!=run.delivery_id)
  if next_id=="" do next_id=next.delivery_id
  testing.expect_value(t,next.delivery_id,next_id)
  message,_,_:=iface.content_get_message(&f.repos.content,next.message_id)
  testing.expect(t,strings.has_prefix(message.body,"3 actions fired for you."))
 }
 old,_,_:=action_test_delivery(f,run.delivery_id)
 testing.expect_value(t,old.state,"replaced")
}
@(test) test_batch_lifecycle_read_releases_once :: proc(t:^testing.T) {action_test_case(t,batch_read_release)}
@(test) test_batch_lifecycle_not_read_releases :: proc(t:^testing.T) {action_test_case(t,batch_not_read_release)}
@(test) test_batch_lifecycle_lost_wake_expires :: proc(t:^testing.T) {action_test_case(t,batch_lazy_expiry)}
@(test) test_batch_lifecycle_unsupported_preserves_parked :: proc(t:^testing.T) {action_test_case(t,batch_no_schedules)}
@(test) test_batch_lifecycle_replacement_moves_all :: proc(t:^testing.T) {action_test_case(t,batch_replace_all)}
