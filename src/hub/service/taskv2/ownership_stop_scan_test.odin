package taskv2

import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"

// Revoke inst_old's claim (a running transfer to inst_new): leaves one pending fence.
@(private = "file")
seed_pending_stop :: proc(t:^testing.T,fx:^Fixture,chain:domain.Task_Chain,task_id:string) -> (domain.Task,bool) {
 task:=publish_task(t,fx,chain,task_id,brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`)
 _,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_old"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,claimed,fmt.tprintf("initial claim: %s",err.message)) do return {},false
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_new",reason="move device",request_id=fmt.tprintf("transfer_%s",task_id),expected_generation=task_control_generation(&fx.svc,get_task(fx,task_id))}
 pending,transferred,terr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,transferred && pending.status=="stop_pending",fmt.tprintf("running transfer waits: %s",terr.message)) do return {},false
 return get_task(fx,task_id),true
}

@(test)
test_bridge_hello_reconciles_stops_from_one_owner_read :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"hello_stop_scan")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_hello_scan")
 old:=seed_instance(fx,chain,"inst_old","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_w","br_1","running")
 // Many historical instances on the same bridge: each one used to rescan every task.
 hist:domain.Agent_Instance
 for i in 0..<40 {h:=seed_instance(fx,chain,fmt.tprintf("inst_hist_%d",i),"agt_w","br_1","stopped");if i==0 do hist=h}
 task,seeded:=seed_pending_stop(t,fx,chain,"task_hello_scan")
 if !seeded do return
 testing.expect(t,ownership_cleanup_pending(&fx.svc,task),"transfer left a pending fence")

 // Hello must not walk every task's full history: per-task listing is unavailable.
 saved_history:=fx.repo.list_events_by_task
 fx.repo.list_events_by_task=nil
 wake_log_reset(log)
 on_bridge_hello(&fx.svc,"br_1",nil)
 fx.repo.list_events_by_task=saved_history
 testing.expect(t,wake_log_has_stop(log,"inst_old"),"hello re-sends the original fenced stop")
 testing.expect(t,!wake_log_has_stop(log,"inst_new"),"hello never fences the replacement")
 testing.expect(t,!wake_log_has_stop(log,"inst_hist_0"),"instances without a fence are untouched")

 testing.expect(t,instance_ownership_stop_pending(&fx.svc,old),"fenced instance stays pending")
 testing.expect(t,!instance_ownership_stop_pending(&fx.svc,hist),"unfenced instance is not pending")

 // The re-sent stop keeps the original command id: its receipt still confirms it.
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_old")
 testing.expect(t,!ownership_cleanup_pending(&fx.svc,get_task(fx,"task_hello_scan")),"confirmed fence clears")
 testing.expect(t,!instance_ownership_stop_pending(&fx.svc,old),"confirmed instance no longer pending")
 wake_log_reset(log)
 on_bridge_hello(&fx.svc,"br_1",nil)
 testing.expect(t,!wake_log_has_stop(log,"inst_old"),"a confirmed generation is not re-fenced on reconnect")
}

@(test)
test_ownership_stop_read_failure_fails_closed :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"hello_stop_fail_closed")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_fail_closed")
 inst:=seed_instance(fx,chain,"inst_free","agt_w","br_1","running")
 saved:=fx.repo.list_ownership_stop_events
 fx.repo.list_ownership_stop_events=nil
 testing.expect(t,instance_ownership_stop_pending(&fx.svc,inst),"unreadable fences are treated as pending")
 fx.repo.list_ownership_stop_events=saved
 testing.expect(t,!instance_ownership_stop_pending(&fx.svc,inst),"readable and empty: not pending")
}

@(test)
test_owner_pending_stops_folds_per_task_and_generation :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"owner_stop_fold")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_owner_fold")
 seed_instance(fx,chain,"inst_old","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_w","br_1","running")
 a,aok:=seed_pending_stop(t,fx,chain,"task_fold_a")
 if !aok do return
 stops,read:=owner_pending_stops(&fx.svc,"u1")
 if !testing.expect(t,read,"owner read") do return
 testing.expect_value(t,len(stops),1)
 if len(stops)==1 {
  testing.expect_value(t,stops[0].task_id,a.task_id)
  // The batched fold must agree with the per-task fold it replaces.
  per_task:=ownership_pending_stops(&fx.svc,a)
  testing.expect(t,len(per_task)==1 && per_task[0]==stops[0].stop,"owner fold matches per-task fold")
 }
 confirm_pending_ownership_stop_for_test(t,fx,a,"inst_old")
 after,_:=owner_pending_stops(&fx.svc,"u1")
 testing.expect_value(t,len(after),0)
}
