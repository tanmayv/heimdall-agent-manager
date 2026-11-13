package taskv2

import "core:testing"
import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_integrated_answer_resumes_retained_blocked_worker :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"integrated_block_answer")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_block_answer")
 seed_instance(fx,chain,"inst_worker","agt_w","br_1","running")
 task:=publish_task(t,fx,chain,"task_block_answer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
 first,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_worker"),{task_id=task.task_id})
 if !testing.expect(t,claimed,err.message) do return
 _,blocked,berr:=lease_block(&fx.svc,inst_auth("inst_worker"),{lease_id=first.lease.lease_id,waiting_on_json=`{"kind":"human","reason":"choose target"}`})
 if !testing.expect(t,blocked,berr.message) do return
 waiting,held:=lease_of(fx,"inst_worker")
 testing.expect(t,held && waiting.phase==domain.LEASE_PHASE_WAITING && waiting.lease_id==first.lease.lease_id,"blocking keeps exact worker responsibility")
 _,answered,aerr:=task_answer(&fx.svc,get_task(fx,string(task.task_id)),actor_from_auth(user_auth()),"use staging")
 if !testing.expect(t,answered,aerr.message) do return
 resumed,resumed_ok,rerr:=lease_claim(&fx.svc,inst_auth("inst_worker"),{task_id=task.task_id})
 testing.expect(t,resumed_ok && resumed.lease.phase==domain.LEASE_PHASE_ACTIVE && resumed.role==domain.LEASE_KIND_WORK,rerr.message)
 testing.expect_value(t,resumed.task.state,domain.Task_State.In_Progress)
 testing.expect_value(t,count_reviews(fx,string(task.task_id)),0)
 testing.expect_value(t,count_events(fx,string(task.task_id),EV_APPROVED),0)
 assert_projection_matches_fold(t,fx,chain.chain_id,"u1","answer retained worker")
}

// Integrate transfer revocation with late writer operations and cancellation:
// a valid receipt can finish cleanup, but cannot revive a cancelled target.
@(test)
test_integrated_transfer_cancel_late_receipt_never_revives_owner :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"integrated_transfer_cancel")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_integrated_transfer_cancel")
 seed_instance(fx,chain,"inst_old","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_w","br_1","running")
 task:=publish_task(t,fx,chain,"task_transfer_cancel",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
 first,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_old"),{task_id=task.task_id})
 if !testing.expect(t,claimed,err.message) do return
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_new",reason="move",request_id="move-once",expected_generation=task_control_generation(&fx.svc,get_task(fx,string(task.task_id)))}
 pending,moved,merr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,moved && pending.status=="stop_pending",merr.message) do return
 _,heartbeat,herr:=lease_heartbeat(&fx.svc,inst_auth("inst_old"),{lease_id=first.lease.lease_id,note="stale"})
 testing.expect(t,!heartbeat && herr.code==.Conflict,"revoked holder cannot heartbeat")
 _,blocked,berr:=lease_block(&fx.svc,inst_auth("inst_old"),{lease_id=first.lease.lease_id,waiting_on_json=`{"kind":"human","reason":"stale question"}`})
 testing.expect(t,!blocked && berr.code==.Conflict,"revoked holder cannot block replacement")
 stops:=ownership_pending_stops(&fx.svc,get_task(fx,string(task.task_id)))
 if !testing.expect(t,len(stops)>0,"transfer has an exact stop receipt obligation") do return
 stop:=stops[0]
 failed_receipt:=fmt.tprintf(`{{"type":"command_result","command_id":"%s","ok":false,"payload":{{"status":"failed"}}}}`,stop.command_id)
 failed,_:=confirm_ownership_stop_result(&fx.svc,stop.bridge_id,stop.command_id,failed_receipt)
 testing.expect(t,!failed && ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"failed stop never releases execution fence")
 receipt:=fmt.tprintf(`{{"type":"command_result","command_id":"%s","ok":true,"payload":{{"status":"succeeded","result":{{"runtime_status":"stopped","agent_instance_id":"%s","expected_run_count":%d}}}}}}`,stop.command_id,stop.instance_id,stop.run_count)
 wrong,_:=confirm_ownership_stop_result(&fx.svc,"br_wrong",stop.command_id,receipt)
 testing.expect(t,!wrong && ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"wrong bridge receipt cannot release execution fence")
 control:=controls_input(t,fx,string(task.task_id),"cancel","cancel-pending-transfer")
 _,cancelled,cerr:=task_control(&fx.svc,get_task(fx,string(task.task_id)),actor_from_auth(inst_auth("inst_coord")),control)
 if !testing.expect(t,cancelled,cerr.message) do return
 _,_=confirm_ownership_stop_result(&fx.svc,stop.bridge_id,stop.command_id,receipt)
 for instance in ([]string{"inst_old","inst_new"}) {
  _,held:=lease_of(fx,instance)
  testing.expect(t,!held,"late successful receipt cannot recreate cancelled ownership")
 }
 testing.expect_value(t,get_task(fx,string(task.task_id)).state,domain.Task_State.Cancelled)
 testing.expect_value(t,count_events(fx,string(task.task_id),EV_SUBMITTED),0)
 assert_projection_matches_fold(t,fx,chain.chain_id,"u1","transfer cancellation and late receipt")
}

@(test)
test_integrated_cancel_backlog_ready_held_blocked_offline :: proc(t:^testing.T) {
 for scenario in ([]string{"backlog","ready","held","blocked"}) {
  fx,log,ok:=lease_fixture(t,fmt.tprintf("integrated_cancel_%s",scenario))
  if !ok {lease_fixture_close(fx,log);continue}
  chain:=seed_live_chain(t,fx,"chain_cancel_matrix")
  task:=seed_task(t,fx,chain,"task_matrix",`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
  if scenario!="backlog" do task=publish_task(t,fx,chain,"task_matrix",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
  actor:=actor_from_auth(inst_auth("inst_coord"))
  if scenario=="held" {_,held,herr:=task_hold(&fx.svc,task,actor,"pause");testing.expect(t,held,herr.message)}
  if scenario=="blocked" {
   seed_instance(fx,chain,"inst_blocked","agt_w","br_1","running")
   _,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_blocked"),{task_id=task.task_id})
   testing.expect(t,claimed,err.message)
   _,blocked,berr:=lease_block(&fx.svc,inst_auth("inst_blocked"),{waiting_on_json=`{"kind":"human","reason":"need answer"}`})
   testing.expect(t,blocked,berr.message)
   set_bridge_status(fx,"br_1",false)
  }
  before:=count_all_events(fx,"task_matrix")
  input:=controls_input(t,fx,"task_matrix","cancel","matrix-cancel")
  _,cancelled,cerr:=task_control(&fx.svc,get_task(fx,"task_matrix"),actor,input)
  testing.expect(t,cancelled,cerr.message)
  testing.expect_value(t,get_task(fx,"task_matrix").state,domain.Task_State.Cancelled)
  testing.expect(t,count_all_events(fx,"task_matrix")>before,"history retained with new cancellation evidence")
  leases,lerr:=iface.taskchain_list_leases_by_task(&fx.repo,task.task_id)
  testing.expect(t,lerr.code==.None && len(leases)==0,"cancel removes every ownership")
  after:=count_all_events(fx,"task_matrix")
  _,repeated,rerr:=task_control(&fx.svc,get_task(fx,"task_matrix"),actor,input)
  testing.expect(t,repeated,rerr.message)
  testing.expect_value(t,count_all_events(fx,"task_matrix"),after)
  if scenario=="blocked" {
   testing.expect(t,ownership_cleanup_pending(&fx.svc,get_task(fx,"task_matrix")),"offline cleanup stays inspectable")
   _,answered,_:=task_answer(&fx.svc,get_task(fx,"task_matrix"),actor,"late answer")
   testing.expect(t,!answered,"late answer cannot revive cancelled task")
   testing.expect_value(t,get_task(fx,"task_matrix").state,domain.Task_State.Cancelled)
  }
  snapshot,sok,serr:=work_item_snapshot(&fx.svc,chain.chain_id,"u1",{kind=domain.WORK_ITEM_TASK,id="task_matrix"})
  testing.expect(t,sok && snapshot.terminal && !snapshot.succeeded,serr.message)
  assert_projection_matches_fold(t,fx,chain.chain_id,"u1",scenario)
  lease_fixture_close(fx,log)
 }
}

@(test)
test_integrated_reviewer_transfer_fences_verdict_and_stale_competitor :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"integrated_review_stale_transfer")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_review_stale")
 seed_instance(fx,chain,"inst_author","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_old","agt_r","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_r","br_1","running")
 seed_instance(fx,chain,"inst_competing","agt_r","br_1","running")
 task:=publish_task(t,fx,chain,"task_review_stale",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[],"reviewers":["agt_r"]}`)
 _,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_author"),{task_id=task.task_id})
 if !testing.expect(t,claimed,err.message) do return
 _,submitted,serr:=lease_submit(&fx.svc,inst_auth("inst_author"),{summary="review result"})
 if !testing.expect(t,submitted,serr.message) do return
 review,reviewed,rerr:=lease_claim(&fx.svc,inst_auth("inst_old"),{task_id=task.task_id})
 if !testing.expect(t,reviewed,rerr.message) do return
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_new",reason="first transfer",request_id="first",expected_generation=task_control_generation(&fx.svc,get_task(fx,string(task.task_id)))}
 _,moved,merr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,moved,merr.message) do return
 stale:=input;stale.instance_id="inst_competing";stale.request_id="competing"
 _,competed,cerr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),stale)
 testing.expect(t,!competed && cerr.code==.Conflict,"serialized competitor using original generation loses")
 _,late,lerr:=review_post(&fx.svc,inst_auth("inst_old"),{lease_id=review.lease.lease_id,verdict="approve"})
 testing.expect(t,!late && lerr.code==.Conflict,"revoked reviewer cannot vote while replacement pending")
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_old")
 _,late_again,laerr:=review_post(&fx.svc,inst_auth("inst_old"),{lease_id=review.lease.lease_id,verdict="approve"})
 testing.expect(t,!late_again && laerr.code==.Conflict,"revoked reviewer cannot vote after replacement activates")
 replacement,held:=lease_of(fx,"inst_new")
 testing.expect(t,held && replacement.kind==domain.LEASE_KIND_REVIEW && replacement.phase==domain.LEASE_PHASE_ACTIVE,"single intended replacement is active")
 _,other:=lease_of(fx,"inst_competing")
 testing.expect(t,!other,"stale competitor never owns work")
 testing.expect_value(t,count_reviews(fx,string(task.task_id)),0)
}

@(test)
test_integrated_stopped_projection_requires_receipt_then_retry_is_quiet :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"integrated_stopped_transfer")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_stopped_transfer")
 seed_instance(fx,chain,"inst_old","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_w","br_1","running")
 task:=publish_task(t,fx,chain,"task_stopped_transfer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
 _,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_old"),{task_id=task.task_id})
 if !testing.expect(t,claimed,err.message) do return
 old,_,_:=iface.agent_get_instance(&fx.agents,"inst_old")
 old.runtime_status="stopped"
 _,_,_=iface.agent_save_instance(&fx.agents,old)
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_new",reason="stopped projection",request_id="stopped-once",expected_generation=task_control_generation(&fx.svc,get_task(fx,string(task.task_id)))}
 result,moved,merr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,moved && result.status=="stop_pending",merr.message) do return
 testing.expect_value(t,count_events(fx,string(task.task_id),EV_OWNERSHIP_STOP_REQUESTED),1)
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_old")
 before:=count_all_events(fx,string(task.task_id))
 _,retried,rerr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 testing.expect(t,retried,rerr.message)
 testing.expect_value(t,count_all_events(fx,string(task.task_id)),before)
 testing.expect_value(t,count_events(fx,string(task.task_id),EV_OWNERSHIP_STOP_REQUESTED),1)
 testing.expect(t,!ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"confirmed stop does not create redundant cleanup on retry")
}
