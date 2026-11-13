package taskv2

import "core:testing"
import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

confirm_pending_ownership_stop_for_test :: proc(t:^testing.T,fx:^Fixture,task:domain.Task,instance_id:string) {
 for stop in ownership_pending_stops(&fx.svc,task) {
  if stop.instance_id!=instance_id do continue
  receipt:=fmt.tprintf(`{{"type":"command_result","command_id":"%s","ok":true,"payload":{{"status":"succeeded","result":{{"runtime_status":"stopped","agent_instance_id":"%s","expected_run_count":%d}}}}}}`,stop.command_id,stop.instance_id,stop.run_count)
  accepted,err:=confirm_ownership_stop_result(&fx.svc,stop.bridge_id,stop.command_id,receipt)
  testing.expect(t,accepted,fmt.tprintf("receipt %s; error %s",receipt,err.message))
 }
}

@(test)
test_explicit_claim_identity_cross_bridge_idempotency :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"explicit_identity")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_explicit")
 seed_bridge(fx,"br_remote")
 remote:=seed_instance(fx,chain,"inst_remote","agt_w","br_remote","running")
 remote.chain_id=""
 _,_,_=iface.agent_save_instance(&fx.agents,remote)
 task:=publish_task(t,fx,chain,"task_explicit",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`,bridge_pin="br_1")
 _,wrong,werr:=lease_claim(&fx.svc,inst_auth("inst_coord"),Lease_Claim_Input{task_id=task.task_id})
 testing.expect(t,!wrong && werr.code==.Forbidden,"coordinator self claim cannot bypass identity")
 first,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_remote"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,claimed,fmt.tprintf("remote matching identity authorized without fleet: %s",err.message)) do return
 testing.expect_value(t,first.role,domain.LEASE_KIND_WORK)
 testing.expect_value(t,first.lease.bridge_id,"br_remote")
 testing.expect(t,first.pack_json!="","self claim receives context")
 second,repeated,rerr:=lease_claim(&fx.svc,inst_auth("inst_remote"),Lease_Claim_Input{task_id=task.task_id})
 testing.expect(t,repeated && first.lease.lease_id==second.lease.lease_id,fmt.tprintf("repeat idempotent: %s",rerr.message))
 seed_instance(fx,chain,"inst_other","agt_w","br_1","running")
 _,duplicate,derr:=lease_claim(&fx.svc,inst_auth("inst_other"),Lease_Claim_Input{task_id=task.task_id})
 testing.expect(t,!duplicate && derr.code==.Conflict,"same identity second process needs transfer")
}

@(test)
test_explicit_claim_coordinator_target_and_transfer_stop_fence :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"explicit_transfer")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_transfer")
 seed_instance(fx,chain,"inst_old","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_w","br_1","running")
 task:=publish_task(t,fx,chain,"task_transfer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
 first,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_old"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,claimed,fmt.tprintf("initial claim: %s",err.message)) do return
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_new",reason="move device",request_id="transfer_once",expected_generation=task_control_generation(&fx.svc,get_task(fx,string(task.task_id)))}
 pending,transferred,terr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,transferred && pending.status=="stop_pending",fmt.tprintf("running transfer waits: %s",terr.message)) do return
 _,oldheld:=lease_of(fx,"inst_old");_,newheld:=lease_of(fx,"inst_new")
 testing.expect(t,!oldheld && newheld,"old authority revoked and named replacement reserved without execution")
 _,late,lerr:=lease_submit(&fx.svc,inst_auth("inst_old"),Submit_Input{lease_id=first.lease.lease_id,summary="late"})
 testing.expect(t,!late && lerr.code==.Conflict,"old writer fenced")
 for stop in ownership_pending_stops(&fx.svc,get_task(fx,string(task.task_id))) {
  wrong:=fmt.tprintf(`{{"type":"command_result","command_id":"%s","ok":true,"payload":{{"status":"succeeded","result":{{"runtime_status":"stopped","agent_instance_id":"%s","expected_run_count":%d}}}}}}`,stop.command_id,stop.instance_id,stop.run_count+1)
  _,_=confirm_ownership_stop_result(&fx.svc,stop.bridge_id,stop.command_id,wrong)
  testing.expect(t,ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"receipt for another generation cannot clear the fence")
  wrong_command:=fmt.tprintf(`{{"type":"command_result","command_id":"unrelated","ok":true,"payload":{{"status":"succeeded","result":{{"runtime_status":"stopped","agent_instance_id":"%s","expected_run_count":%d}}}}}}`,stop.instance_id,stop.run_count)
  _,_=confirm_ownership_stop_result(&fx.svc,stop.bridge_id,"unrelated",wrong_command)
  testing.expect(t,ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"unrelated successful command cannot clear the fence")
 }
 _,duplicate,derr:=lease_claim(&fx.svc,inst_auth("inst_new"),Lease_Claim_Input{task_id=task.task_id})
 testing.expect(t,!duplicate && derr.code==.Conflict,"new process cannot run until stop confirmation")
 old,_,_:=iface.agent_get_instance(&fx.agents,"inst_old")
 old.runtime_status="stopped"
 _,_,_=iface.agent_save_instance(&fx.agents,old)
 on_instance_terminal(&fx.svc,"inst_old")
 testing.expect(t,ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"generic terminal projection cannot confirm process death")
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_old")
 activated,active:=lease_of(fx,"inst_new")
 testing.expect(t,active && activated.phase==domain.LEASE_PHASE_ACTIVE,"successful stop receipt immediately activates named replacement")
 done,finished,ferr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 testing.expect(t,finished && done.lease.holder_instance_id=="inst_new",fmt.tprintf("retry after confirmed stop grants named target: %s",ferr.message))
 testing.expect(t,done.pack_json=="","coordinator must not overwrite its own TASK.md")
 testing.expect(t,!ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"cleanup clears only confirmed generation")
}

@(test)
test_explicit_transfer_waiting_worker_retains_role_and_reserves_target :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"explicit_waiting")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_waiting_transfer")
 seed_instance(fx,chain,"inst_old","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_w","br_1","running")
 task:=publish_task(t,fx,chain,"task_waiting_transfer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
 task.requires_user_approval=true
 _,_,_=iface.taskchain_save_task(&fx.repo,task)
 first,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_old"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,claimed,err.message) do return
 _,submitted,serr:=lease_submit(&fx.svc,inst_auth("inst_old"),Submit_Input{lease_id=first.lease.lease_id,summary="waiting review"})
 if !testing.expect(t,submitted,serr.message) do return
 task=get_task(fx,string(task.task_id))
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_new",reason="transfer waiting author",request_id="waiting_once",expected_generation=task_control_generation(&fx.svc,task)}
 pending,accepted,aerr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,accepted && pending.status=="stop_pending",aerr.message) do return
 testing.expect_value(t,pending.role,domain.LEASE_KIND_WORK)
 testing.expect_value(t,pending.task.state,domain.Task_State.In_Review)
 next,nok,nerr:=lease_next(&fx.svc,inst_auth("inst_new"),Lease_Next_Input{})
 testing.expect(t,nok && next.status=="waiting",fmt.tprintf("pending target cannot execute: %s",nerr.message))
 unrelated:=publish_task(t,fx,chain,"task_unrelated_transfer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
 _,stolen,sterr:=lease_claim(&fx.svc,inst_auth("inst_new"),Lease_Claim_Input{task_id=unrelated.task_id})
 testing.expect(t,!stolen && sterr.code==.Conflict,"target reserved against unrelated work")
 changed:=input;changed.reason="different"
 _,reused,rerr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),changed)
 testing.expect(t,!reused && rerr.code==.Conflict,"request id fingerprint includes reason")
 old,_,_:=iface.agent_get_instance(&fx.agents,"inst_old");old.runtime_status="stopped"
 _,_,_=iface.agent_save_instance(&fx.agents,old);on_instance_terminal(&fx.svc,"inst_old")
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_old")
 result,finished,ferr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 testing.expect(t,finished && result.status=="waiting" && result.role==domain.LEASE_KIND_WORK,fmt.tprintf("waiting worker never becomes reviewer: %s",ferr.message))
 testing.expect_value(t,result.task.state,domain.Task_State.In_Review)
}

@(test)
test_explicit_transfer_active_reviewer_resumes_after_offline_stop :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"explicit_review_transfer")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_review_transfer")
 seed_instance(fx,chain,"inst_author","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_review_old","agt_r","br_1","running")
 seed_instance(fx,chain,"inst_review_new","agt_r","br_1","running")
 task:=publish_task(t,fx,chain,"task_review_transfer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[],"reviewers":["agt_r"]}`)
 first,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_author"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,claimed,err.message) do return
 _,submitted,serr:=lease_submit(&fx.svc,inst_auth("inst_author"),Submit_Input{lease_id=first.lease.lease_id,summary="ready"})
 if !testing.expect(t,submitted,serr.message) do return
 review,reviewed,rerr:=lease_claim(&fx.svc,inst_auth("inst_review_old"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,reviewed,rerr.message) do return
 testing.expect_value(t,review.role,domain.LEASE_KIND_REVIEW)
 set_bridge_status(fx,"br_1",false)
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_review_new",reason="offline transfer",request_id="review_transfer_once",expected_generation=task_control_generation(&fx.svc,get_task(fx,string(task.task_id)))}
 pending,accepted,aerr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,accepted && pending.status=="stop_pending",aerr.message) do return
 old,_,_:=iface.agent_get_instance(&fx.agents,"inst_review_old")
 old.runtime_status="unreachable";_,_,_=iface.agent_save_instance(&fx.agents,old)
 on_instance_terminal(&fx.svc,"inst_review_old")
 testing.expect(t,ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"offline status is never stop confirmation")
 old.run_count+=1;old.runtime_status="stopped";_,_,_=iface.agent_save_instance(&fx.agents,old)
 on_instance_terminal(&fx.svc,"inst_review_old")
 testing.expect(t,ownership_cleanup_pending(&fx.svc,get_task(fx,string(task.task_id))),"another generation stopping cannot confirm the revoked generation")
 old.run_count-=1
 set_bridge_status(fx,"br_1",true)
 old.runtime_status="stopped";_,_,_=iface.agent_save_instance(&fx.agents,old);on_instance_terminal(&fx.svc,"inst_review_old")
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_review_old")
 activated,active:=lease_of(fx,"inst_review_new")
 testing.expect(t,active && activated.phase==domain.LEASE_PHASE_ACTIVE,"review replacement activates without another coordinator request")
 resumed,rok,e:=lease_next(&fx.svc,inst_auth("inst_review_new"),Lease_Next_Input{})
 testing.expect(t,rok && resumed.lease.kind==domain.LEASE_KIND_REVIEW && resumed.lease.phase==domain.LEASE_PHASE_ACTIVE,fmt.tprintf("active reviewer resumes same submission after confirmed stop: %s",e.message))
 testing.expect_value(t,resumed.lease.attempt_no,review.lease.attempt_no)
}

@(test)
test_explicit_transfer_waiting_reviewer_does_not_repeat_verdict :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"explicit_review_waiting_transfer")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_review_waiting_transfer")
 seed_instance(fx,chain,"inst_author","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_review_old","agt_r","br_1","running")
 seed_instance(fx,chain,"inst_review_new","agt_r","br_1","running")
 task:=publish_task(t,fx,chain,"task_review_waiting_transfer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[],"reviewers":["agt_r"]}`)
 task.requires_user_approval=true
 _,_,_=iface.taskchain_save_task(&fx.repo,task)
 first,claimed,err:=lease_claim(&fx.svc,inst_auth("inst_author"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,claimed,err.message) do return
 _,submitted,serr:=lease_submit(&fx.svc,inst_auth("inst_author"),Submit_Input{lease_id=first.lease.lease_id,summary="ready"})
 if !testing.expect(t,submitted,serr.message) do return
 _,reviewed,rerr:=lease_claim(&fx.svc,inst_auth("inst_review_old"),Lease_Claim_Input{task_id=task.task_id})
 if !testing.expect(t,reviewed,rerr.message) do return
 _,approved,aerr:=review_post(&fx.svc,inst_auth("inst_review_old"),Review_Input{verdict="approve",findings_json="[]"})
 if !testing.expect(t,approved,aerr.message) do return
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_review_new",reason="move waiting reviewer",request_id="waiting_review_once",expected_generation=task_control_generation(&fx.svc,get_task(fx,string(task.task_id)))}
 pending,accepted,terr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 if !testing.expect(t,accepted && pending.status=="stop_pending",terr.message) do return
 old,_,_:=iface.agent_get_instance(&fx.agents,"inst_review_old")
 old.runtime_status="stopped";_,_,_=iface.agent_save_instance(&fx.agents,old)
 on_instance_terminal(&fx.svc,"inst_review_old")
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_review_old")
 result,finished,ferr:=lease_transfer(&fx.svc,inst_auth("inst_coord"),input)
 testing.expect(t,finished && result.status=="waiting" && result.role==domain.LEASE_KIND_REVIEW,fmt.tprintf("completed reviewer remains waiting: %s",ferr.message))
 next,nok,nerr:=lease_next(&fx.svc,inst_auth("inst_review_new"),Lease_Next_Input{})
 testing.expect(t,nok && next.status=="waiting",nerr.message)
 _,again,again_err:=review_post(&fx.svc,inst_auth("inst_review_new"),Review_Input{verdict="approve"})
 testing.expect(t,!again && again_err.code==.Conflict,"replacement cannot post a second verdict through waiting ownership")
}

@(test)
test_simple_transfer_without_generation_self_target_and_quiet_retries :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"simple_transfer")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_simple_transfer")
 seed_instance(fx,chain,"inst_old","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_new","agt_w","br_1","running")
 seed_instance(fx,chain,"inst_competitor","agt_w","br_1","running")
 task:=publish_task(t,fx,chain,"task_simple_transfer",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":[]}`)
 auth:=inst_auth("inst_coord")
 // Coordinator self target is eligible only when its durable identity matches.
 wrong:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_coord",reason="assign self",request_id="wrong-self"}
 _,denied,derr:=lease_transfer(&fx.svc,auth,wrong)
 testing.expect(t,!denied && derr.code==.Forbidden,"self target cannot bypass assignee")
 initial:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_old",reason="assign named worker",request_id="initial"}
 _,claimed,cerr:=lease_transfer(&fx.svc,auth,initial)
 if !testing.expect(t,claimed,cerr.message) do return
 initial.request_id="repeat-initial"
 before:=count_all_events(fx,string(task.task_id))
 _,again,aerr:=lease_transfer(&fx.svc,auth,initial)
 testing.expect(t,again,aerr.message)
 testing.expect_value(t,count_all_events(fx,string(task.task_id)),before)
 input:=Lease_Claim_Input{task_id=task.task_id,instance_id="inst_new",reason="move responsibility",request_id="move"}
 pending,moved,merr:=lease_transfer(&fx.svc,auth,input)
 if !testing.expect(t,moved && pending.status=="stop_pending",merr.message) do return
 before=count_all_events(fx,string(task.task_id))
 input.request_id="fresh-retry"
 retry,retried,rerr:=lease_transfer(&fx.svc,auth,input)
 testing.expect(t,retried && retry.status=="stop_pending",rerr.message)
 testing.expect_value(t,count_all_events(fx,string(task.task_id)),before)
 competing:=input;competing.instance_id="inst_competitor";competing.request_id="competitor"
 _,competed,coerr:=lease_transfer(&fx.svc,auth,competing)
 testing.expect(t,!competed && coerr.code==.Conflict,"pending competing transfer is rejected")
 confirm_pending_ownership_stop_for_test(t,fx,task,"inst_old")
 before=count_all_events(fx,string(task.task_id))
 input.request_id="after-stop"
 _,resumed,serr:=lease_transfer(&fx.svc,auth,input)
 testing.expect(t,resumed,serr.message)
 testing.expect_value(t,count_all_events(fx,string(task.task_id)),before)
 input.request_id="stale";input.expected_generation=1
 _,stale,sterr:=lease_transfer(&fx.svc,auth,input)
 testing.expect(t,!stale && sterr.code==.Conflict,"same target with stale explicit generation rejected")
 // A matching coordinator may claim itself without fleet membership.
 self_task:=publish_task(t,fx,chain,"task_simple_self",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_c","review_roles":[]}`)
 self_input:=Lease_Claim_Input{task_id=self_task.task_id,instance_id="inst_coord",reason="work myself",request_id="self"}
 self,self_ok,self_err:=lease_transfer(&fx.svc,auth,self_input)
 testing.expect(t,self_ok && self.target_instance_id=="inst_coord" && self.pack_json!="",self_err.message)
}
