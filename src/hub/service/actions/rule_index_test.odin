package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:sync"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_compiled_rule_index_warm_300 :: proc(t:^testing.T) {action_test_case(t,compiled_index_warm)}
compiled_index_warm :: proc(t:^testing.T,f:^Action_Test) {
 for i in 1..<300 do action_test_seed(t,f,fmt.tprintf("a-%03d",i),fmt.tprintf("t-%03d",i),"owner")
 checks:=make(json.Array,16,context.temp_allocator)
 for i in 0..<16 do checks[i]=test_config(`{"field":"data.state","op":"eq","value":"completed"}`)
 tree:=make(json.Object,context.temp_allocator);tree["all"]=checks
 encoded,_:=json.marshal(tree,allocator=context.temp_allocator)
 testing.expect(t,sqlite.exec(&f.db,fmt.tprintf("UPDATE action_triggers SET data_filter='%s';",string(encoded))))
 count:=0
 perf_trace(rawptr(f.db.db),1,perf_count,&count)
 action_test_match(t,f,"cold")
 perf_trace(rawptr(f.db.db),0,nil,nil)
 testing.expect_value(t,count,2) // One expiry sweep + one owner trigger load.
 count=0
 perf_trace(rawptr(f.db.db),1,perf_count,&count)
 started:=time.tick_now()
 action_test_match(t,f,"warm")
 elapsed:=time.tick_since(started)
 perf_trace(rawptr(f.db.db),0,nil,nil)
 testing.expect_value(t,count,1) // Only the indexed expiry sweep; zero trigger reads.
 fmt.printf("F2 300 matching rules warm event: %v (0 trigger SELECTs, 1 expiry SELECT)\n",elapsed)
 started=time.tick_now()
 testing.expect_value(t,expire_prompt_deliveries(&f.runtime.router).code,domain.Error_Code.None)
 fmt.printf("F2 no-op indexed expiry sweep: %v (1 query per batch)\n",time.tick_since(started))
 // Measure just the compiled evaluator independently of insert/storage cost.
 owner:=f.runtime.rule_index.owners["owner"]
 envelope:=test_config(`{"data":{"state":"completed"}}`)
 started=time.tick_now()
 for _ in 0..<1000 do for rule in owner.rules {
  matched,_:=filter_evaluate(rule.tree,envelope)
  if !matched do testing.expect(t,false)
 }
 fmt.printf("F2 compiled evaluation of 300 rules x 16 checks, mean: %v\n",time.tick_since(started)/1000)
 action_test_match(t,f,"warm")
 rows:=action_test_rows(t,f)
 defer domain.action_runs_destroy(rows)
 testing.expect_value(t,len(rows),2)
 testing.expect_value(t,rows[0].state,domain.ACTION_RUN_JOINED)
 testing.expect_value(t,rows[1].state,domain.ACTION_RUN_QUEUED)
 testing.expect_value(t,rows[0].joined_run_id,rows[1].run_id)
 value:json.Value
 testing.expect_value(t,json.unmarshal(transmute([]u8)rows[0].event_params_json,&value,allocator=context.temp_allocator),nil)
 object,_:=value.(json.Object)
 trace,_:=object["_match"].(json.Object)
 rev,_:=trace["rev"].(json.Integer)
 testing.expect_value(t,rev,json.Integer(1))
 nodes,_:=trace["nodes"].(string)
 testing.expect_value(t,nodes,"TTTTTTTTTTTTTTTTT")
 // Cache survives complete replacement of scratch allocations in production;
 // explicit refresh must reload and retain the same matching behavior.
 rule_index_clear(&f.runtime.rule_index)
 action_test_match(t,f,"refresh")
}
@(test)
test_compiled_rule_index_service_invalidation :: proc(t:^testing.T) {action_test_case(t,compiled_index_invalidation)}
compiled_index_invalidation :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"first")
 old_epoch:=sync.atomic_load(&f.runtime.svc.rule_epoch)
 input:=Action_Input{triggers=[]Trigger_Input{{id="trigger",kind="event",config=test_config(`{"event_type":"chain.state","filter":{"all":[{"field":"data.state","op":"eq","value":"active"},{"not":{"field":"actor","op":"eq","value":"blocked"}}]}}`)}}}
 view,err:=update(f.runtime.svc,"owner","action",input)
 action_view_destroy(&view)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect(t,sync.atomic_load(&f.runtime.svc.rule_epoch)>old_epoch)
 action_test_match(t,f,"edited-no-match")
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,0)
 input.triggers=[]Trigger_Input{{id="trigger",kind="event",config=test_config(`{"event_type":"chain.state","filter":{"all":[{"field":"data.state","op":"eq","value":"completed"},{"not":{"field":"actor","op":"eq","value":"blocked"}}]}}`)}}
 view,err=update(f.runtime.svc,"owner","action",input);action_view_destroy(&view)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 action_test_match(t,f,"edited-match")
 rows:=action_test_rows(t,f)
 value:json.Value
 _=json.unmarshal(transmute([]u8)rows[0].event_params_json,&value,allocator=context.temp_allocator)
 obj,_:=value.(json.Object);trace,_:=obj["_match"].(json.Object)
 nodes,_:=trace["nodes"].(string)
 testing.expect_value(t,nodes,"TTTF")
 domain.action_runs_destroy(rows)
 view,err=set_enabled(f.runtime.svc,"owner","action",false);action_view_destroy(&view)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 action_test_match(t,f,"disabled")
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,1)
 view,err=set_enabled(f.runtime.svc,"owner","action",true);action_view_destroy(&view)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 action_test_match(t,f,"enabled")
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,2)
 // Trigger disable uses the same transactional service invalidation path.
 disabled_inputs,_:=input.triggers.?
 disabled_inputs[0].enabled=false
 input.triggers=disabled_inputs
 view,err=update(f.runtime.svc,"owner","action",input);action_view_destroy(&view)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 action_test_match(t,f,"trigger-disabled")
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,2)
 input.triggers=[]Trigger_Input{}
 view,err=update(f.runtime.svc,"owner","action",input);action_view_destroy(&view)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 action_test_match(t,f,"trigger-deleted")
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,2)
 testing.expect_value(t,delete_action(f.runtime.svc,"owner","action").code,domain.Error_Code.None)
 action_test_match(t,f,"action-deleted")
 rows=action_test_rows(t,f)
 testing.expect_value(t,len(rows),0)
 domain.action_runs_destroy(rows)
}


// Cache strings, subject tokens and compiled nodes must outlive the scratch
// arena reset after every fetched batch.
@(test)
test_compiled_rule_index_scratch_lifetime :: proc(t:^testing.T) {action_test_case(t,compiled_index_scratch)}
compiled_index_scratch :: proc(t:^testing.T,f:^Action_Test) {
 scratch:virtual.Arena
 testing.expect_value(t,virtual.arena_init_growing(&scratch),nil)
 defer virtual.arena_destroy(&scratch)
 {
  context.temp_allocator=virtual.arena_allocator(&scratch)
  action_test_match(t,f,"scratch-one")
 }
 virtual.arena_free_all(&scratch)
 {
  context.temp_allocator=virtual.arena_allocator(&scratch)
  action_test_match(t,f,"scratch-two")
 }
 action_test_expect(t,f,domain.ACTION_RUN_JOINED,1)
}
@(test)
test_compiled_rule_index_schedule_retire :: proc(t:^testing.T) {action_test_case(t,compiled_index_schedule)}
compiled_index_schedule :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"once","run_at":"2026-11-23T00:00:00Z"}`)
 action_test_fire(t,f,"stale","0")
 action_test_expect(t,f,domain.ACTION_RUN_SKIPPED,1)
 epoch:=sync.atomic_load(&f.runtime.svc.rule_epoch)
 action_test_fire(t,f,"once","1")
 testing.expect(t,sync.atomic_load(&f.runtime.svc.rule_epoch)>epoch)
 trigger,found,err:=f.repos.actions.trigger_get(f.repos.actions.ctx,"schedule")
 defer domain.action_trigger_destroy(&trigger)
 testing.expect(t,err.code==.None && found && !trigger.enabled && trigger.rev==2)
 action_test_fire(t,f,"once","1")
 action_test_fire(t,f,"later","1")
 rows:=action_test_rows(t,f)
 defer domain.action_runs_destroy(rows)
 testing.expect_value(t,len(rows),2)
}

@(test)
test_compiled_rule_index_retire_cas_preserves_edit :: proc(t:^testing.T) {action_test_case(t,compiled_retire_cas)}
compiled_retire_cas :: proc(t:^testing.T,f:^Action_Test) {
 action_test_schedule(t,f,`{"mode":"once","run_at":"2026-11-23T00:00:00Z"}`)
 // Load rev 1, then bypass the service to simulate an invalidation failure.
 _,e:=rule_index_owner(&f.runtime,&f.repos.actions,"owner")
 testing.expect_value(t,e.code,domain.Error_Code.None)
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"schedule")
 defer domain.action_trigger_destroy(&trigger)
 trigger.rev=2
 delete(trigger.config_json)
 trigger.config_json=strings.clone(`{"mode":"interval","interval_s":120}`)
 testing.expect_value(t,f.repos.actions.trigger_save(f.repos.actions.ctx,trigger).code,domain.Error_Code.None)
 view:=Event_View{subject="ev.owner.sched.schedule",owner="owner",event_type="schedule.fired",event_id="old",trigger_rev="1",schedule_next="once",stream_time_ms=f.now_ms,envelope=test_config(`{"type":"schedule.fired","data":{}}`)}
 testing.expect(t,!handle_message(&f.runtime,view))
 testing.expect(t,handle_message(&f.runtime,view))
 stored,found,err:=f.repos.actions.trigger_get(f.repos.actions.ctx,"schedule")
 defer domain.action_trigger_destroy(&stored)
 testing.expect(t,found && err.code==.None && stored.enabled && stored.rev==2)
 testing.expect_value(t,stored.config_json,trigger.config_json)
 action_test_expect(t,f,domain.ACTION_RUN_SKIPPED,1)
 action_test_expect(t,f,domain.ACTION_RUN_QUEUED,0)
}

@(test)
test_compiled_rule_index_history_cap_sweep :: proc(t:^testing.T) {action_test_case(t,compiled_history_sweep)}
compiled_history_sweep :: proc(t:^testing.T,f:^Action_Test) {
 testing.expect(t,sqlite.exec(&f.db,"WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<330) INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,created_at) SELECT 'skip-'||x,'action','trigger','owner','skip-'||x,'chain.state','skipped','2026-11-23T00:00:00Z' FROM n;"))
 for want in ([]int{202,200}) {
  testing.expect_value(t,sweep_history(f.runtime.svc,time.Time{_nsec=f.now_ms*1_000_000}).code,domain.Error_Code.None)
  rows:=action_test_rows(t,f)
  testing.expect_value(t,len(rows),want)
  domain.action_runs_destroy(rows)
 }
}
@(test)
test_compiled_rule_index_idle_expiry_drain :: proc(t:^testing.T) {action_test_case(t,compiled_idle_expiry)}
compiled_idle_expiry :: proc(t:^testing.T,f:^Action_Test) {
 run:=ack_prompt(t,f)
 ack_succeed(f,run)
 delivery,found,err:=action_test_delivery(f,run.delivery_id)
 defer domain.pipeline_delivery_destroy(&delivery)
 testing.expect(t,found && err.code==.None)
 f.now_ms,_=schedule_time(delivery.expires_at)
 // No later event and no queued work: the periodic drain still closes it.
 drain_due(&f.runtime.router)
 ack_assert(t,f,run,"failed","","not_read")
 action_test_expect(t,f,domain.ACTION_RUN_FAILED,1)
}

@(test)
test_compiled_rule_index_read_after_deadline_before_sweep :: proc(t:^testing.T) {action_test_case(t,compiled_read_before_sweep)}
compiled_read_before_sweep :: proc(t:^testing.T,f:^Action_Test) {
 run:=ack_prompt(t,f);ack_succeed(f,run)
 delivery,_,_:=action_test_delivery(f,run.delivery_id)
 defer domain.pipeline_delivery_destroy(&delivery)
 f.now_ms,_=schedule_time(delivery.expires_at)
 ack_read(t,f,run)
 action_test_match(t,f,"after-read")
 ack_assert(t,f,run,"done","read","")
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1)
 action_test_expect(t,f,domain.ACTION_RUN_QUEUED,1)
 action_test_expect(t,f,domain.ACTION_RUN_FAILED,0)
 drain_due(&f.runtime.router)
 action_test_expect(t,f,domain.ACTION_RUN_ROUTED,1)
}
