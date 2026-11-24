#+feature dynamic-literals
package actions

import "core:fmt"
import "core:encoding/json"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

settle_test_chain :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
 f := (^Action_Test)(ctx)
 f.validity_reads += 1
 // No owned fields: literals are safe in the callback's scoped read arena.
 return {chain_id=id,owner_user_id="owner",status=f.chain_status,work_revision=f.chain_revision,
  completed_at="2026-11-23T00:00:00Z",updated_at="2026-11-23T00:00:00Z"}, true, {}
}
settle_test_instance :: proc(ctx: rawptr, owner, id: string) -> (string, string, string, bool) {
 f := (^Action_Test)(ctx)
 f.settle_plans += 1
 return action_test_instance(ctx, owner, id)
}
settle_test_setup :: proc(t: ^testing.T, f: ^Action_Test, delay: int) {
 trigger, found, err := f.repos.actions.trigger_get(f.repos.actions.ctx, "trigger")
 testing.expect(t, found && err.code==.None)
 trigger.delay_s=delay
 testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,trigger).code,domain.Error_Code.None)
 f.runtime.router.agents.instance=settle_test_instance
 f.repos.taskchains.ctx=f
 f.repos.taskchains.get_chain=settle_test_chain
 f.chain_status=.Completed
}
settle_test_event :: proc(t: ^testing.T, f: ^Action_Test, chain, id: string, seq: u64) {
 envelope := test_config(`{"data":{"state":"completed","completed_at":"2026-11-23T00:00:00Z"}}`)
 envelope["chain_id"]=chain
 testing.expect(t, len(envelope)>0, "valid event envelope")
 testing.expect(t,handle_message(&f.runtime,{
  subject=fmt.tprintf("ev.owner.chain.%s.state",chain),event_type="chain.state",event_id=id,
  stream_time_ms=f.now_ms,stream_sequence=seq,
  envelope=envelope,
 }))
}
@(test)
test_settle_debounce_isolation_and_stale_hint :: proc(t: ^testing.T) { action_test_case(t,settle_debounce_scenario) }
settle_debounce_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_test_setup(t,f,10)
 settle_test_event(t,f,"chain1","first",1)
 original,found,err:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain1")
 testing.expect(t,found && err.code==.None && original.delay_s==10)
 f.now_ms+=5000
 settle_test_event(t,f,"chain1","latest",2)
 pending,_,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain1")
 testing.expect(t,pending.run_id==original.run_id && pending.event_id=="latest" && pending.not_before>original.not_before)
 // Old occurrence redelivery does not restart the latest timer.
 f.now_ms+=1000
 settle_test_event(t,f,"chain1","first",1)
 repeated,_,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain1")
 testing.expect_value(t,repeated.not_before,pending.not_before)
 settle_test_event(t,f,"chain2","second-chain",3)
 action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,2)
 sc:=Sync_Context{clock=&f.clock,ids=&f.ids}
 one,_:=settle_deferral_row(&sc,pending)
 other:=pending;other.settle_key="chain2"
 two,_:=settle_deferral_row(&sc,other)
 testing.expect(t,one.subject!=two.subject)
 other.settle_key="chain1";same,_:=settle_deferral_row(&sc,other)
 testing.expect_value(t,one.subject,same.subject)
 f.now_ms+=4000
 drain_run(&f.runtime.router,pending.run_id,true)
 testing.expect_value(t,f.routes,0)
 testing.expect_value(t,f.validity_reads,0)
 f.now_ms+=5000
 drain_run(&f.runtime.router,pending.run_id,true)
 testing.expect_value(t,f.routes,1)
 testing.expect_value(t,f.validity_reads,1)
 // The other key waits until the action slot is released, then delivers separately.
 f.now_ms+=1000
 remaining,_,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain2")
 drain_run(&f.runtime.router,remaining.run_id,true)
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,1) // debounce receipt only
 testing.expect_value(t,f.routes,1)
 waiting,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,remaining.run_id)
 testing.expect(t,waiting.state==domain.ACTION_RUN_DEFERRED && waiting.settle_pending)
 action_test_done(t,f)
 wake_found:=false
 wake_uow,wake_ok,_:=iface.unit_of_work_begin(&f.factory)
 testing.expect(t,wake_ok)
 outbox:=&wake_uow.repos.event_outbox
 for {
  row,found,err:=outbox.next(outbox.ctx)
  testing.expect_value(t,err.code,domain.Error_Code.None)
  if !found do break
  if row.subject=="ev.owner.action.action.ready" do wake_found=true
  testing.expect_value(t,outbox.mark_published(outbox.ctx,row.outbox_seq,"2026-11-23T00:01:00Z").code,domain.Error_Code.None)
 }
 _,_=iface.unit_of_work_commit(&wake_uow)
 testing.expect(t,wake_found,"terminal run must persist the queued-key wake")
 // Completion persists an action.ready event, whose arrival invokes drain_due.
 f.now_ms+=30000
 drain_due(&f.runtime.router)
 testing.expect_value(t,f.routes,2)
 delivered,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,remaining.run_id)
 testing.expect_value(t,delivered.state,domain.ACTION_RUN_ROUTED)
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 metadata,metadata_err:=prompt_metadata(&f.repos.actions,action,delivered,0)
 testing.expect_value(t,metadata_err.code,domain.Error_Code.None)
 value:json.Value
 testing.expect_value(t,json.unmarshal(transmute([]u8)metadata,&value),nil)
 object,_:=value.(json.Object)
 testing.expect_value(t,object["chain_id"].(string),"chain2")
 testing.expect_value(t,object["event_id"].(string),"second-chain")
}
@(test)
test_settle_reopen_superseded_and_zero_delay_no_check :: proc(t: ^testing.T) { action_test_case(t,settle_reopen_scenario) }
settle_reopen_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_test_setup(t,f,10)
 settle_test_event(t,f,"chain1","completed",1)
 pending,_,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain1")
 f.chain_status=.Active
 f.now_ms+=10000
 drain_run(&f.runtime.router,pending.run_id,false)
 run,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,pending.run_id)
 testing.expect(t,run.state==domain.ACTION_RUN_SKIPPED && run.reason=="superseded")
 testing.expect_value(t,f.validity_reads,1)
 testing.expect_value(t,f.routes,0)
 testing.expect_value(t,f.settle_plans,0)
 settle_test_setup(t,f,0)
 f.chain_status=.Active
 settle_test_event(t,f,"chain1","immediate",2)
 for row in action_test_rows(t,f) do if row.state==domain.ACTION_RUN_QUEUED do drain_run(&f.runtime.router,row.run_id,false)
 testing.expect_value(t,f.routes,1)
 testing.expect_value(t,f.validity_reads,1)
 testing.expect_value(t,f.settle_plans,1)
}
@(test)
test_settle_rate_limit_keeps_original_deferral_subject :: proc(t: ^testing.T) { action_test_case(t,settle_rate_scenario) }
settle_rate_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_test_setup(t,f,0)
 settle_test_event(t,f,"chain1","immediate",1)
 for row in action_test_rows(t,f) do drain_run(&f.runtime.router,row.run_id,false)
 action_test_done(t,f)
 settle_test_setup(t,f,5)
 f.now_ms+=1000
 settle_test_event(t,f,"chain1","delayed",2)
 pending,_,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain1")
 f.now_ms+=5000
 drain_run(&f.runtime.router,pending.run_id,false)
 deferred,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,pending.run_id)
 testing.expect(t,deferred.state==domain.ACTION_RUN_DEFERRED && !deferred.settle_pending)
 testing.expect_value(t,f.validity_reads,0)
 testing.expect_value(t,f.routes,1)
 // The rate-limit timer must also tolerate the hub clock lagging 1 second.
 f.now_ms+=23000
 drain_due(&f.runtime.router,{{owner="owner",run_id=pending.run_id,not_before=deferred.not_before}})
 testing.expect_value(t,f.routes,2)
 testing.expect_value(t,f.validity_reads,1)
}
@(test)
test_settle_work_revision_and_optional_callbacks :: proc(t: ^testing.T) { action_test_case(t,settle_work_scenario) }
settle_work_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_test_setup(t,f,5)
 f.chain_revision=7
 run:=domain.Action_Run{owner_user_id="owner",event_params_json=`{"chain_id":"chain1","data":{"work_revision":"7"}}`}
 valid,reason:=chain_work_finished_still_valid(&f.repos,run)
 testing.expect(t,valid && reason=="")
 f.chain_revision=8
 valid,reason=chain_work_finished_still_valid(&f.repos,run)
 testing.expect(t,!valid && reason=="superseded")
 testing.expect_value(t,f.validity_reads,2)
 // A delayed kind without callbacks passes and uses the empty settle key.
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"trigger")
 trigger.event_type="future.kind";trigger.subject_filter="ev.owner.future.kind"
 testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,trigger).code,domain.Error_Code.None)
 testing.expect(t,handle_message(&f.runtime,{subject="ev.owner.future.kind",event_type="future.kind",event_id="future",stream_time_ms=f.now_ms,stream_sequence=1,envelope=test_config("{}")}))
 pending,found,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","")
 testing.expect(t,found)
 f.now_ms+=5000
 drain_run(&f.runtime.router,pending.run_id,false)
 testing.expect_value(t,f.routes,1)
 testing.expect_value(t,f.validity_reads,2)
}


@(test)
test_settle_current_hint_tolerates_clock_skew :: proc(t:^testing.T) { action_test_case(t,settle_skew_scenario) }
settle_skew_scenario :: proc(t:^testing.T,f:^Action_Test) {
 settle_test_setup(t,f,10)
 settle_test_event(t,f,"chain1","early",1)
 run,_,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain1")
 sc:=Sync_Context{clock=&f.clock,ids=&f.ids}
 row,_:=settle_deferral_row(&sc,run)
 value:json.Value
 _=json.unmarshal(transmute([]u8)row.envelope_json,&value)
 body,_:=value.(json.Object);data,_:=body["data"].(json.Object)
 deadline,_:=data["not_before"].(string)
 testing.expect_value(t,deadline,run.not_before)
 f.now_ms+=9000
 drain_due(&f.runtime.router,{{owner="owner",run_id=run.run_id,not_before=deadline}})
 testing.expect_value(t,f.routes,1)
}

@(test)
test_settle_trigger_changes_cancel_pending :: proc(t:^testing.T) { action_test_case(t,settle_cancel_scenario) }
settle_cancel_scenario :: proc(t:^testing.T,f:^Action_Test) {
 settle_test_setup(t,f,5)
 for mode in 0..<3 {
  trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"trigger")
  trigger.enabled=true
  testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,trigger).code,domain.Error_Code.None)
  settle_test_event(t,f,"chain1",fmt.tprintf("cancel%d",mode),u64(mode+1))
  run,_,_:=f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain1")
  switch mode {
  case 0: trigger.enabled=false
  case 1: trigger.rev+=1
  case 2:
   testing.expect_value(t,f.repos.actions.trigger_delete(f.repos.actions.ctx,"trigger").code,domain.Error_Code.None)
  }
  if mode!=2 do testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,trigger).code,domain.Error_Code.None)
  f.now_ms+=5000
  drain_run(&f.runtime.router,run.run_id,false)
  finished,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,run.run_id)
  testing.expect(t,finished.state==domain.ACTION_RUN_SKIPPED && finished.reason=="stale_rev")
 }
 testing.expect_value(t,f.routes,0)
 testing.expect_value(t,f.settle_plans,0)
}


@(test)
test_settle_unsupported_reason :: proc(t:^testing.T) { action_test_case(t,settle_unsupported_scenario) }
settle_unsupported_scenario :: proc(t:^testing.T,f:^Action_Test) {
 settle_test_setup(t,f,5)
 settle_test_event(t,f,"chain1","unsupported",1)
 f.support=2
 drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f)
 testing.expect(t,len(rows)==1 && rows[0].state==domain.ACTION_RUN_SKIPPED && rows[0].reason=="schedules_unsupported")
 testing.expect_value(t,f.settle_plans,0)
}


@(test)
test_settle_finish_without_waiter_has_no_wake :: proc(t:^testing.T) { action_test_case(t,settle_no_wake_scenario) }
settle_no_wake_scenario :: proc(t:^testing.T,f:^Action_Test) {
 settle_test_setup(t,f,0)
 settle_test_event(t,f,"chain1","immediate",1)
 for row in action_test_rows(t,f) do drain_run(&f.runtime.router,row.run_id,false)
 before_uow,_,_:=iface.unit_of_work_begin(&f.factory)
 before,_:=before_uow.repos.event_outbox.backlog(before_uow.repos.event_outbox.ctx)
 iface.unit_of_work_rollback(&before_uow)
 action_test_done(t,f)
 uow,ok,_:=iface.unit_of_work_begin(&f.factory)
 testing.expect(t,ok)
 defer iface.unit_of_work_rollback(&uow)
 count,err:=uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,count,before)
}
