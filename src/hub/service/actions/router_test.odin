package actions
import "core:encoding/json"
import "base:runtime"
import "core:thread"
import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import delivery "odin_test:hub/service/delivery"

action_test_prompt_count :: proc(t:^testing.T,f:^Action_Test)->int {
 rows,err:=iface.content_list_messages(&f.repos.content,"conversation","owner",200,"")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 for row in rows do testing.expect(t,row.direction=="user_to_agent" && row.message_type=="action")
 return len(rows)
}
router_atomic_scenario :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 testing.expect_value(t,action_test_prompt_count(t,f),1)
 rows:=action_test_rows(t,f)
 if !testing.expect_value(t,len(rows),1) do return
 run:=rows[0]
 testing.expect(t,run.state=="routed" && run.delivery_id!="" && run.message_id!="" && run.target_instance_id=="instance" && run.started_at!="")
 deliveries,err:=action_test_deliveries(f)
 testing.expect(t,err.code==.None && len(deliveries)==1)
 backlog,e:=action_test_backlog(f)
 testing.expect(t,e.code==.None && backlog==1)
}
router_failure_scenario :: proc(t:^testing.T,f:^Action_Test) {
 f.fail_prompt=true
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 testing.expect_value(t,action_test_prompt_count(t,f),0)
 rows:=action_test_rows(t,f)
 if testing.expect_value(t,len(rows),1) {testing.expect_value(t,rows[0].state,"failed");testing.expect_value(t,rows[0].reason,"delivery_failed")}
 deliveries,_:=action_test_deliveries(f)
 testing.expect_value(t,len(deliveries),0)
}
router_second_drain_scenario :: proc(t:^testing.T,f:^Action_Test) {
 router_atomic_scenario(t,f)
 drain_due(&f.runtime.router);drain_due(&f.runtime.router)
 testing.expect_value(t,action_test_prompt_count(t,f),1)
 testing.expect_value(t,f.routes,1)
}
router_flag_scenario :: proc(t:^testing.T,f:^Action_Test) {
 f.flag_off=true
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f)
 if testing.expect_value(t,len(rows),1) {testing.expect_value(t,rows[0].state,"skipped");testing.expect_value(t,rows[0].reason,"experiment_off")}
 testing.expect_value(t,f.routes,0);testing.expect_value(t,action_test_prompt_count(t,f),0)
}
router_metadata_scenario :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"cron","cron_expr":"0 * * * *","timezone":"UTC"}`)
 action_test_fire(t,f,"slot","1");drain_due(&f.runtime.router)
 run,found,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action");testing.expect(t,found)
 d,exists,err:=action_test_delivery(f,run.delivery_id)
 testing.expect(t,exists && err.code==.None)
 testing.expect_value(t,f.last_cause,"schedule");testing.expect_value(t,d.ref,fmt.tprintf("run:%s",run.run_id))
 testing.expect_value(t,f.last_notice,"message")
 at,_:=schedule_time(d.expires_at);start,_:=schedule_time(run.started_at)
 testing.expect_value(t,at-start,i64(3600000))
 message,ok,_:=iface.content_get_message(&f.repos.content,run.message_id);testing.expect(t,ok)
 metadata:=test_config(message.metadata_json)
 for key in ([]string{"action_id","action_name","run_id","trigger_id","event_type","joined_count","triggered_at","cron_expr","timezone"}) {
  _,present:=metadata[key];testing.expect(t,present,key)
 }
 action_test_done(t,f);f.now_ms+=31000;action_test_match(t,f,"event");drain_due(&f.runtime.router)
 run,_,_=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 d,_,_=action_test_delivery(f,run.delivery_id)
 testing.expect_value(t,f.last_cause,"event")
}
router_final_scenario :: proc(t:^testing.T,f:^Action_Test) {
 for outcome in ([]string{"started","notified","read"}) {
  action_test_match(t,f,outcome);drain_due(&f.runtime.router)
  run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
  uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
  err:=on_delivery_final(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id,state=domain.DELIVERY_DONE,outcome=outcome})
  testing.expect_value(t,err.code,domain.Error_Code.None)
  _,_=iface.unit_of_work_commit(&uow)
  stored,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,run.run_id)
  testing.expect(t,stored.state=="delivered" && stored.finished_at!="")
  f.now_ms+=31000
 }
}
router_final_mapping :: proc(t:^testing.T,f:^Action_Test) {
 cases:=[?]struct{reason,want:string}{
 {"not_read","not_read"},{"bridge_offline","bridge_offline"},{"no_answer","no_answer"},{"bridge_too_old","bridge_too_old"},{"target_missing","target_missing"},
 {"quota_exceeded","start_failed"},{"provider_unavailable","start_failed"},{"launch_failed","start_failed"},{"ledger_full","start_failed"},{"invalid_payload","start_failed"}}
 for c in cases {
  action_test_match(t,f,c.reason);drain_due(&f.runtime.router)
  run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
  uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
  err:=on_delivery_final(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id,state=domain.DELIVERY_FAILED,reason=c.reason})
  testing.expect_value(t,err.code,domain.Error_Code.None);_,_=iface.unit_of_work_commit(&uow)
  stored,_,_:=f.repos.actions.run_get(f.repos.actions.ctx,run.run_id)
  testing.expect(t,stored.state=="failed" && stored.reason==c.want && stored.finished_at!="")
  f.now_ms+=31000
 }
}
router_stale_final :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 testing.expect_value(t,on_delivery_final(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id="old",state=domain.DELIVERY_DONE}).code,domain.Error_Code.None)
 _,_=iface.unit_of_work_commit(&uow)
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
 action_test_done(t,f)
 uow,ok,_=iface.unit_of_work_begin(&f.factory);assert(ok)
 _=on_delivery_final(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id,state=domain.DELIVERY_FAILED,reason="no_answer"})
 _,_=iface.unit_of_work_commit(&uow)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1)
}
router_expired_match :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 f.now_ms+=3601000
 action_test_match(t,f,"two")
 action_test_expect(t,f,domain.ACTION_RUN_FAILED,1);action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1)
 rows:=action_test_rows(t,f)
 for row in rows do if row.state=="failed" do testing.expect_value(t,row.reason,"bridge_offline")
}
@(thread_local)
action_original_transition:proc(ctx:rawptr,next:domain.Action_Run,from:string)->(bool,domain.Domain_Error)
action_transition_fault :: proc(ctx:rawptr,next:domain.Action_Run,from:string)->(bool,domain.Domain_Error) {
 if next.state=="failed" || next.state=="delivered" do return false,domain.domain_error(.Internal_Error,"injected run transition failure")
 return action_original_transition(ctx,next,from)
}
router_expiry_failure :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 action_original_transition=f.repos.actions.run_transition
 f.repos.actions.run_transition=action_transition_fault
 f.now_ms+=3601000
 testing.expect(t,!handle_message(&f.runtime,{subject="ev.owner.chain.chain1.state",event_type="chain.state",event_id="two",
  stream_time_ms=f.now_ms,envelope=test_config(`{"entity":{"kind":"chain","id":"chain1"},"data":{}}`)}))
 _,err:=list_runs(&f.runtime.router,"owner","action",50,"")
 testing.expect(t,err.code!=.None)
 d,_,_:=action_test_delivery(f,run.delivery_id)
 testing.expect_value(t,d.state,"routed");action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
 f.repos.actions.run_transition=action_original_transition
 action_test_match(t,f,"two")
 action_test_expect(t,f,domain.ACTION_RUN_FAILED,1);action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1)
}
router_final_failure :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 action_original_transition=f.repos.actions.run_transition;f.repos.actions.run_transition=action_transition_fault
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 err:=on_delivery_final(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id,state=domain.DELIVERY_DONE})
 testing.expect(t,err.code!=.None);iface.unit_of_work_rollback(&uow)
 f.repos.actions.run_transition=action_original_transition
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
 action_test_done(t,f);action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1)
}
router_replace_refused :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 replaced,err:=on_delivery_replace(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id},.Bridge_Offline)
 testing.expect(t,!replaced && err.code==.None);iface.unit_of_work_rollback(&uow)
 testing.expect_value(t,action_test_prompt_count(t,f),1)
 action_test_done(t,f)
 uow,ok,_=iface.unit_of_work_begin(&f.factory);assert(ok)
 replaced,err=on_delivery_replace(&f.runtime.router,&uow,{ref=fmt.tprintf("run:%s",run.run_id),delivery_id=run.delivery_id},.Bridge_Offline)
 testing.expect(t,!replaced && err.code==.None);iface.unit_of_work_rollback(&uow)
}
@(test)
test_router_route_transaction_is_atomic :: proc(t:^testing.T) {action_test_case(t,router_atomic_scenario);action_test_case(t,router_before_commit_scenario)}
@(test)
test_router_prompt_failure_rolls_back :: proc(t:^testing.T) {action_test_case(t,router_failure_scenario)}
@(test)
test_router_crash_after_route_delivers_once :: proc(t:^testing.T) {action_test_case(t,router_second_drain_scenario)}
@(test)
test_router_flag_off :: proc(t:^testing.T) {action_test_case(t,router_flag_scenario)}
@(test)
test_router_metadata_and_cause :: proc(t:^testing.T) {action_test_case(t,router_metadata_scenario)}
@(test)
test_final_done_started_and_notified :: proc(t:^testing.T) {action_test_case(t,router_final_scenario)}
@(test)
test_final_failed_reason_mapping :: proc(t:^testing.T) {action_test_case(t,router_final_mapping)}
@(test)
test_final_stale_report_is_ignored :: proc(t:^testing.T) {action_test_case(t,router_stale_final)}
@(test)
test_matcher_joins_routed_run :: proc(t:^testing.T) {action_test_case(t,overlap_open_delivery)}
@(test)
test_matcher_expires_routed_run_before_join :: proc(t:^testing.T) {action_test_case(t,router_expired_match)}
@(test)
test_final_run_write_failure_rolls_back :: proc(t:^testing.T) {action_test_case(t,router_final_failure)}
@(test)
test_expiry_final_callback_failure_rolls_back :: proc(t:^testing.T) {action_test_case(t,router_expiry_failure)}
@(test)
test_replace_refuses_instance_target_and_closed_run :: proc(t:^testing.T) {action_test_case(t,router_replace_refused)}

action_test_delivery :: proc(f:^Action_Test,id:string)->(domain.Pipeline_Delivery,bool,domain.Domain_Error) {
 uow,ok,err:=iface.unit_of_work_begin(&f.factory)
 if !ok do return {},false,err
 defer iface.unit_of_work_rollback(&uow)
 return uow.repos.pipeline_deliveries.get(uow.repos.pipeline_deliveries.ctx,id)
}
action_test_deliveries :: proc(f:^Action_Test)->([]domain.Pipeline_Delivery,domain.Domain_Error) {
 uow,ok,err:=iface.unit_of_work_begin(&f.factory)
 if !ok do return nil,err
 defer iface.unit_of_work_rollback(&uow)
 return uow.repos.pipeline_deliveries.open_for_bridge(uow.repos.pipeline_deliveries.ctx,"bridge","",-1)
}
action_test_backlog :: proc(f:^Action_Test)->(i64,domain.Domain_Error) {
 uow,ok,err:=iface.unit_of_work_begin(&f.factory)
 if !ok do return 0,err
 defer iface.unit_of_work_rollback(&uow)
 return uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
}

@(thread_local)
action_commit_original:iface.Unit_Of_Work_Commit_Proc
@(thread_local)
action_rollback_original:iface.Unit_Of_Work_Rollback_Proc
@(thread_local)
action_commit_fixture:^Action_Test
action_test_begin_fault :: proc(ctx:rawptr)->(iface.Unit_Of_Work,bool,domain.Domain_Error) {
 f:=(^Action_Test)(ctx)
 uow,ok,err:=iface.unit_of_work_begin(&f.original_factory)
 if !ok do return uow,ok,err
 action_commit_original=uow.commit;action_rollback_original=uow.rollback;action_commit_fixture=f
 uow.commit=action_test_commit_fault
 return uow,true,{}
}
action_test_commit_fault :: proc(ctx:rawptr)->(bool,domain.Domain_Error) {
 f:=action_commit_fixture
 if f.crash_before_commit && f.route_written {
  f.crash_before_commit=false;f.route_written=false
  action_rollback_original(ctx)
  return false,domain.domain_error(.Internal_Error,"injected crash before route commit")
 }
 return action_commit_original(ctx)
}
router_before_commit_scenario :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one")
 f.original_factory=f.factory;f.factory={ctx=f,begin=action_test_begin_fault}
 f.crash_before_commit=true
 drain_due(&f.runtime.router)
 action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1)
 testing.expect_value(t,action_test_prompt_count(t,f),0)
 deliveries,e:=action_test_deliveries(f);testing.expect(t,e.code==.None && len(deliveries)==0)
 backlog,oe:=action_test_backlog(f);testing.expect(t,oe.code==.None && backlog==0)
 drain_due(&f.runtime.router)
 testing.expect_value(t,action_test_prompt_count(t,f),1)
 deliveries,e=action_test_deliveries(f);testing.expect(t,e.code==.None && len(deliveries)==1)
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
}
@(test)
test_router_crash_before_route_routes_again_once :: proc(t:^testing.T) {action_test_case(t,router_before_commit_scenario)}
router_thread_drain :: proc(ctx:rawptr) {drain_due(&((^Action_Test)(ctx)).runtime.router)}
router_exclusive_scenario :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one")
 context.allocator=runtime.heap_allocator()
 a:=thread.create_and_start_with_data(f,router_thread_drain,init_context=context)
 b:=thread.create_and_start_with_data(f,router_thread_drain,init_context=context)
 thread.join(a);thread.join(b);thread.destroy(a);thread.destroy(b)
 context.allocator=context.temp_allocator
 testing.expect_value(t,action_test_prompt_count(t,f),1)
 testing.expect_value(t,f.routes,1)
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
}
@(test)
test_router_claim_is_exclusive :: proc(t:^testing.T) {action_test_case(t,router_exclusive_scenario)}

matcher_disabled_scenario :: proc(t:^testing.T,f:^Action_Test) {
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"trigger");trigger.enabled=false
 _=f.repos.actions.trigger_save(f.repos.actions.ctx,trigger)
 action_test_match(t,f,"one");testing.expect_value(t,len(action_test_rows(t,f)),0)
 trigger.enabled=true;_=f.repos.actions.trigger_save(f.repos.actions.ctx,trigger)
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action");action.enabled=false;_=f.repos.actions.save(f.repos.actions.ctx,action)
 action_test_match(t,f,"two");testing.expect_value(t,len(action_test_rows(t,f)),0)
}
matcher_once_scenario :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"once","run_at":"2026-11-23T00:00:00Z"}`)
 action_test_fire(t,f,"one","1")
 trigger,found,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"schedule")
 testing.expect(t,found && !trigger.enabled && trigger.rev==2)
 action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1)
 backlog,err:=action_test_backlog(f);testing.expect(t,err.code==.None && backlog==1)
 action_test_fire(t,f,"one","1")
 backlog,err=action_test_backlog(f);testing.expect(t,err.code==.None && backlog==1)
}
matcher_window_scenario :: proc(t:^testing.T,f:^Action_Test) {
 configs:=[3]string{
 `{"mode":"interval","interval_s":60,"active_from":"2026-11-24T00:00:00Z"}`,
 `{"mode":"interval","interval_s":60,"active_until":"2026-11-22T00:00:00Z"}`,
 `{"mode":"interval","interval_s":60,"timezone":"America/New_York","blackout_dates":["2026-11-22"]}`}
 for config,i in configs {
  action_test_schedule(t,f,config)
  action_test_fire(t,f,fmt.tprintf("slot%d",i),"1")
  trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"schedule")
  if i==1 do testing.expect(t,!trigger.enabled && trigger.rev==2)
 }
 rows:=action_test_rows(t,f);window,blackout:=0,0
 for row in rows {
  testing.expect_value(t,row.state,"skipped")
  if row.reason=="outside_window" do window+=1
  if row.reason=="blackout" do blackout+=1
 }
 testing.expect_value(t,window,2);testing.expect_value(t,blackout,1)
}
router_retry_scenario :: proc(t:^testing.T,f:^Action_Test) {
 f.pipeline.max_deliver=8
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
 d,_,_:=uow.repos.pipeline_deliveries.get(uow.repos.pipeline_deliveries.ctx,run.delivery_id)
 d.state=domain.DELIVERY_FORWARDED;d.attempt=1;d.ack_reply="fake.reply"
 changed,err:=uow.repos.pipeline_deliveries.transition(uow.repos.pipeline_deliveries.ctx,d,domain.DELIVERY_ROUTED)
 testing.expect(t,changed && err.code==.None);_,_=iface.unit_of_work_commit(&uow)
 for i in 0..<3 {
  delivery.on_command_result(&f.pipeline,"bridge",fmt.tprintf("%s:1",run.delivery_id),`{"status":"failed","class":"retry","retry_after_ms":500}`)
  action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
 }
 action_test_match(t,f,"two");action_test_match(t,f,"three")
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,2)
 delivery.on_command_result(&f.pipeline,"bridge",fmt.tprintf("%s:1",run.delivery_id),`{"status":"succeeded","outcome":"notified"}`)
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
 ack_read(t,f,run)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1);testing.expect_value(t,f.routes,1)
}
prune_delivered :: proc(t:^testing.T,f:^Action_Test) {
 for i in 0..<210 {
  action_test_match(t,f,fmt.tprintf("finish%d",i));drain_due(&f.runtime.router);action_test_done(t,f);f.now_ms+=31000
 }
 testing.expect_value(t,len(action_test_rows(t,f)),200)
}
prune_skipped :: proc(t:^testing.T,f:^Action_Test) {
 f.flag_off=true
 for i in 0..<210 {action_test_match(t,f,fmt.tprintf("skip%d",i));drain_due(&f.runtime.router);f.now_ms+=1000}
 testing.expect_value(t,len(action_test_rows(t,f)),200)
}
prune_stale :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"interval","interval_s":60}`)
 for i in 0..<210 {action_test_fire(t,f,fmt.tprintf("stale%d",i),"0");f.now_ms+=1000}
 testing.expect_value(t,len(action_test_rows(t,f)),200)
}
prune_joined :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.now_ms+=1000
 action_test_match(t,f,"deferred");drain_due(&f.runtime.router)
 for i in 0..<210 {action_test_match(t,f,fmt.tprintf("join%d",i));f.now_ms+=1}
 testing.expect_value(t,len(action_test_rows(t,f)),200)
 action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,1)
}
@(test)
test_matcher_ignores_disabled_action_and_trigger :: proc(t:^testing.T) {action_test_case(t,matcher_disabled_scenario)}
@(test)
test_once_fire_retires_trigger :: proc(t:^testing.T) {action_test_case(t,matcher_once_scenario)}
@(test)
test_window_and_blackout :: proc(t:^testing.T) {action_test_case(t,matcher_window_scenario)}
@(test)
test_retried_busy_target_ends_delivered :: proc(t:^testing.T) {action_test_case(t,router_retry_scenario)}
@(test)
test_runs_pruned_after_finish :: proc(t:^testing.T) {
 action_test_case(t,prune_delivered);action_test_case(t,prune_skipped);action_test_case(t,prune_stale);action_test_case(t,prune_joined)
}

router_bot_flag_scenario :: proc(t:^testing.T,f:^Action_Test) {
 action,found,err:=f.repos.actions.get(f.repos.actions.ctx,"action")
 testing.expect(t,found && err.code==.None)
 action.target_kind=domain.ACTION_TARGET_BOT
 testing.expect_value(t,f.repos.actions.save(f.repos.actions.ctx,action).code,domain.Error_Code.None)
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f)
 if testing.expect_value(t,len(rows),1) {
  testing.expect_value(t,rows[0].state,domain.ACTION_RUN_SKIPPED)
  testing.expect_value(t,rows[0].reason,"experiment_off")
 }
 testing.expect_value(t,f.routes,0)
 testing.expect_value(t,action_test_prompt_count(t,f),0)
}
@(test)
test_router_bot_experiment_off :: proc(t:^testing.T) {action_test_case(t,router_bot_flag_scenario)}

// Read the persisted run from the hook, proving the routed transition is visible.
action_test_hint :: proc(ctx:rawptr,m:domain.Chat_Message) {
 f:=(^Action_Test)(ctx)
 f.hints+=1
 run,found,err:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 message,present,me:=iface.content_get_message(&f.repos.content,m.message_id)
 f.hint_valid=found && err.code==.None && run.state==domain.ACTION_RUN_ROUTED &&
  run.message_id==m.message_id && present && me.code==.None &&
  message.body!="" && m.body=="" && m.message_type=="action" && m.conversation_id=="conversation"
}
router_hint_scenario :: proc(t:^testing.T,f:^Action_Test) {
 f.runtime.router.message_created={ctx=f,created=action_test_hint}
 action_test_match(t,f,"one")
 f.original_factory=f.factory;f.factory={ctx=f,begin=action_test_begin_fault}
 f.crash_before_commit=true
 drain_due(&f.runtime.router)
 testing.expect_value(t,f.hints,0)
 testing.expect_value(t,action_test_prompt_count(t,f),0)
 drain_due(&f.runtime.router)
 testing.expect_value(t,f.hints,1)
 testing.expect(t,f.hint_valid,"hint contains only identifiers/type and sees committed routed run")
 drain_due(&f.runtime.router)
 testing.expect_value(t,f.hints,1)
 action_test_done(t,f)
 action_test_match(t,f,"two")
 f.flag_off=true
 drain_due(&f.runtime.router)
 action_test_expect(t,f,domain.ACTION_RUN_SKIPPED,1)
 testing.expect_value(t,f.hints,1)
}
@(test)
test_router_message_hint_commit_rollback_skip :: proc(t:^testing.T) {action_test_case(t,router_hint_scenario)}
router_hint_outer_scenario :: proc(t:^testing.T,f:^Action_Test) {
 f.runtime.router.message_created={ctx=f,created=action_test_hint}
 action_test_match(t,f,"one")
 outer,ok,_:=iface.unit_of_work_begin(&f.factory)
 if !testing.expect(t,ok) do return
 rows:=action_test_rows(t,f)
 drain_run(&f.runtime.router,rows[0].run_id,false)
 testing.expect_value(t,f.hints,0)
 iface.unit_of_work_rollback(&outer)
 testing.expect_value(t,f.hints,0)
 testing.expect_value(t,action_test_prompt_count(t,f),0)
 outer,ok,_=iface.unit_of_work_begin(&f.factory)
 if !testing.expect(t,ok) do return
 drain_run(&f.runtime.router,rows[0].run_id,false)
 testing.expect_value(t,f.hints,0)
 committed,_:=iface.unit_of_work_commit(&outer)
 testing.expect(t,committed)
 testing.expect_value(t,f.hints,1)
 testing.expect(t,f.hint_valid)
}
@(test)
test_router_message_hint_waits_for_outer_commit :: proc(t:^testing.T) {action_test_case(t,router_hint_outer_scenario)}
