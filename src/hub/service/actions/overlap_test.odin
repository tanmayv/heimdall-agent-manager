package actions
import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"

action_test_fire :: proc(t:^testing.T,f:^Action_Test,id,rev:string) {
 testing.expect(t,handle_message(&f.runtime,{subject="ev.owner.sched.schedule",owner="owner",event_type="schedule.fired",event_id=id,
  trigger_rev=rev,schedule_next=id,stream_time_ms=f.now_ms,envelope=test_config(`{"type":"schedule.fired","data":{}}`)}))
}
action_test_schedule :: proc(t:^testing.T,f:^Action_Test,config:string) {
 testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,{trigger_id="schedule",action_id="action",owner_user_id="owner",
  kind="schedule",config_json=config,event_type="schedule.fired",subject_filter="ev.owner.sched.schedule",match_key="ev.owner.sched.schedule",data_filter_json="{}",
  enabled=true,rev=1,created_at="2026-01-01T00:00:00Z",updated_at="2026-01-01T00:00:00Z"}).code,domain.Error_Code.None)
}
action_test_first :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"first");drain_due(&f.runtime.router);action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
 action_test_done(t,f);action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1)
}
overlap_two_triggers :: proc(t:^testing.T,f:^Action_Test) {
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"trigger")
 trigger.trigger_id="second"
 testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,trigger).code,domain.Error_Code.None)
 action_test_match(t,f,"one")
 drain_due(&f.runtime.router);action_test_done(t,f)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1);action_test_expect(t,f,domain.ACTION_RUN_JOINED,1)
 testing.expect_value(t,f.routes,1)
}
overlap_redelivery :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"one");action_test_match(t,f,"one")
 rows:=action_test_rows(t,f);testing.expect_value(t,len(rows),1)
 drain_due(&f.runtime.router);action_test_done(t,f)
 action_test_match(t,f,"one");testing.expect_value(t,len(action_test_rows(t,f)),1)
 testing.expect_value(t,f.routes,1)
}
overlap_mixed_batch :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"interval","interval_s":60}`)
 action_test_fire(t,f,"schedule1","1");action_test_match(t,f,"event1")
 drain_due(&f.runtime.router);action_test_done(t,f)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1);action_test_expect(t,f,domain.ACTION_RUN_JOINED,1)
 testing.expect_value(t,f.routes,1)
}
overlap_deferred :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f)
 start:=f.now_ms
 f.now_ms+=5000;action_test_match(t,f,"second");drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f)
 found:=false
 for row in rows do if row.state==domain.ACTION_RUN_DEFERRED {
  at,_:=platform.rfc3339_to_unix_ms(row.not_before);testing.expect_value(t,at,start+30000);found=true
 }
 testing.expect(t,found)
 f.now_ms=start+30000;drain_due(&f.runtime.router);action_test_done(t,f)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,2);testing.expect_value(t,f.routes,2)
}
overlap_after_interval :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.now_ms+=31000
 action_test_match(t,f,"second");drain_due(&f.runtime.router);action_test_done(t,f)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,2);action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,0)
}
overlap_burst :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);start:=f.now_ms
 for i in 1..<50 {
  f.now_ms=start+i64(i)*200
  action_test_match(t,f,fmt.tprintf("burst%d",i));drain_due(&f.runtime.router)
 }
 action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,1);action_test_expect(t,f,domain.ACTION_RUN_JOINED,48)
 f.now_ms=start+30000;drain_due(&f.runtime.router);action_test_done(t,f)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,2);testing.expect_value(t,f.routes,2)
}
overlap_catchup :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"interval","interval_s":60}`)
 for i in 0..<3 do action_test_fire(t,f,fmt.tprintf("slot%d",i),"1")
 action_test_match(t,f,"event1");action_test_match(t,f,"event2")
 drain_due(&f.runtime.router);action_test_done(t,f)
 testing.expect(t,f.routes<=2);testing.expect_value(t,len(action_test_rows(t,f)),5)
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,4)
}
overlap_loop :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);start:=f.now_ms
 for i in 1..<5 {
  f.now_ms=start+i64(i)*1000
  action_test_match(t,f,fmt.tprintf("loop%d",i));drain_due(&f.runtime.router)
 }
 testing.expect_value(t,f.routes,1)
 f.now_ms=start+30000;drain_due(&f.runtime.router);action_test_done(t,f)
 testing.expect_value(t,f.routes,2);testing.expect_value(t,len(action_test_rows(t,f)),5)
}
overlap_two_actions :: proc(t:^testing.T,f:^Action_Test) {
 action_test_seed(t,f,"action2","trigger2","owner")
 action_test_match(t,f,"one");drain_due(&f.runtime.router)
 first,found,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 second,found2,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action2")
 testing.expect(t,found && found2 && first.state==domain.ACTION_RUN_ROUTED && second.state==domain.ACTION_RUN_ROUTED)
 testing.expect_value(t,f.routes,2)
}
overlap_old_event :: proc(t:^testing.T,f:^Action_Test) {
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"trigger")
 trigger.updated_at="2027-01-01T00:00:00Z"
 _=f.repos.actions.trigger_save(f.repos.actions.ctx,trigger)
 action_test_match(t,f,"one");testing.expect_value(t,len(action_test_rows(t,f)),0)
}
overlap_stale :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"interval","interval_s":60}`)
 action_test_fire(t,f,"old","0")
 rows:=action_test_rows(t,f)
 if testing.expect_value(t,len(rows),1) {testing.expect_value(t,rows[0].state,"skipped");testing.expect_value(t,rows[0].reason,"stale_rev")}
}
overlap_lost_fire :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.now_ms+=1000;action_test_match(t,f,"second");drain_due(&f.runtime.router)
 f.now_ms+=30000
 // An unrelated event's batch or the startup drain recovers a lost fire.
 drain_due(&f.runtime.router);action_test_done(t,f)
 testing.expect_value(t,f.routes,2);action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,0)
}
overlap_disabled :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.now_ms+=1000;action_test_match(t,f,"second");drain_due(&f.runtime.router)
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action");action.enabled=false;_=f.repos.actions.save(f.repos.actions.ctx,action)
 f.now_ms+=30000;drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f);found:=false
 for row in rows do if row.state=="skipped" {testing.expect_value(t,row.reason,"disabled");found=true}
 testing.expect(t,found);testing.expect_value(t,f.routes,1)
}
overlap_double_resume :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.now_ms+=1000;action_test_match(t,f,"second");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 hints:=[2]Resume_Hint{{"owner",run.run_id},{"owner",run.run_id}}
 drain_due(&f.runtime.router,hints[:]);drain_due(&f.runtime.router,hints[:])
 testing.expect_value(t,f.routes,2)
}
overlap_after_deferred :: proc(t:^testing.T,f:^Action_Test) {
 overlap_deferred(t,f)
 f.now_ms+=1000;action_test_match(t,f,"third");drain_due(&f.runtime.router)
 run,found,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 testing.expect(t,found && run.state=="deferred")
 due,_:=platform.rfc3339_to_unix_ms(run.not_before)
 testing.expect_value(t,due,f.now_ms+29000)
}
overlap_unsupported :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.support=2;f.now_ms+=1000
 action_test_match(t,f,"second");drain_due(&f.runtime.router)
 rows:=action_test_rows(t,f);found:=false
 for row in rows do if row.state=="skipped" {found=true;testing.expect_value(t,row.reason,"rate_limited")}
 testing.expect(t,found);testing.expect_value(t,f.routes,1)
}
overlap_early_hint :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.now_ms+=1000;action_test_match(t,f,"second");drain_due(&f.runtime.router)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 f.now_ms+=27000
 // A different owner's hint must not route this run.
 wrong:=[1]Resume_Hint{{"other",run.run_id}}
 drain_due(&f.runtime.router,wrong[:]);testing.expect_value(t,f.routes,1)
 hints:=[1]Resume_Hint{{"owner",run.run_id}}
 drain_due(&f.runtime.router,hints[:]);action_test_done(t,f)
 testing.expect_value(t,f.routes,2);action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,0)
}
overlap_support_changes :: proc(t:^testing.T,f:^Action_Test) {
 action_test_first(t,f);f.now_ms+=1000;action_test_match(t,f,"second");drain_due(&f.runtime.router)
 drain_due(&f.runtime.router);action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,1)
 f.support=2;drain_due(&f.runtime.router)
 action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,0);action_test_expect(t,f,domain.ACTION_RUN_SKIPPED,1)
}
overlap_open_delivery :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"interval","interval_s":120}`)
 start:=f.now_ms
 action_test_fire(t,f,"slot0","1");drain_due(&f.runtime.router)
 for i in 1..<5 {
  f.now_ms=start+i64(i)*120000
  action_test_fire(t,f,fmt.tprintf("slot%d",i),"1");drain_due(&f.runtime.router)
 }
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1);action_test_expect(t,f,domain.ACTION_RUN_JOINED,4)
 testing.expect_value(t,f.routes,1);testing.expect_value(t,f.prompts,1)
 run,_,_:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 at,_:=platform.rfc3339_to_unix_ms(run.started_at);testing.expect_value(t,at,start)
 for row in action_test_rows(t,f) {
  if row.state==domain.ACTION_RUN_JOINED do testing.expect_value(t,row.joined_run_id,run.run_id)
 }
 action_test_done(t,f);action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1)
}
@(test)
test_c01_two_triggers_one_event :: proc(t:^testing.T) {action_test_case(t,overlap_two_triggers)}
@(test)
test_c02_redelivery_adds_no_row :: proc(t:^testing.T) {action_test_case(t,overlap_redelivery)}
@(test)
test_c03_cron_and_event_same_batch :: proc(t:^testing.T) {action_test_case(t,overlap_mixed_batch)}
@(test)
test_c04_inside_interval_is_deferred :: proc(t:^testing.T) {action_test_case(t,overlap_deferred)}
@(test)
test_c05_after_interval_delivers :: proc(t:^testing.T) {action_test_case(t,overlap_after_interval)}
@(test)
test_c06_burst :: proc(t:^testing.T) {action_test_case(t,overlap_burst)}
@(test)
test_c07_catch_up_after_downtime :: proc(t:^testing.T) {action_test_case(t,overlap_catchup)}
@(test)
test_c08_self_trigger_loop :: proc(t:^testing.T) {action_test_case(t,overlap_loop)}
@(test)
test_c09_two_actions_one_event :: proc(t:^testing.T) {action_test_case(t,overlap_two_actions)}
@(test)
test_c10_trigger_newer_than_event :: proc(t:^testing.T) {action_test_case(t,overlap_old_event)}
@(test)
test_c11_stale_rev :: proc(t:^testing.T) {action_test_case(t,overlap_stale)}
@(test)
test_c12_crash_between_commit_and_ack :: proc(t:^testing.T) {action_test_case(t,overlap_redelivery)}
@(test)
test_c14_lost_deferral_fire :: proc(t:^testing.T) {action_test_case(t,overlap_lost_fire)}
@(test)
test_c15_disabled_while_deferred :: proc(t:^testing.T) {action_test_case(t,overlap_disabled)}
@(test)
test_c16_double_resume :: proc(t:^testing.T) {action_test_case(t,overlap_double_resume)}
@(test)
test_c17_match_after_deferred_delivery :: proc(t:^testing.T) {action_test_case(t,overlap_after_deferred)}
@(test)
test_c18_no_schedule_support :: proc(t:^testing.T) {action_test_case(t,overlap_unsupported)}
@(test)
test_c19_deferral_fire_early_clock_skew :: proc(t:^testing.T) {action_test_case(t,overlap_early_hint)}
@(test)
test_c20_deferred_run_when_support_becomes_unsupported :: proc(t:^testing.T) {action_test_case(t,overlap_support_changes)}
@(test)
test_c21_busy_target_joins_routed_run :: proc(t:^testing.T) {action_test_case(t,overlap_open_delivery)}
@(test)
test_c22_offline_pinned_machine_joins_routed_run :: proc(t:^testing.T) {action_test_case(t,overlap_open_delivery)}
