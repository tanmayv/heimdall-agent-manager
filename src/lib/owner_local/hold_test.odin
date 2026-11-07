#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
hold_live_heartbeat_restart_checkpoint_release_continues_native_attempt :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,control_call(f,"task.hold","hold","4").code,"ok")
    rows,_:=query(f.store.db,"SELECT expires_ms,hard_ms,capability_json,(SELECT count(*) FROM local_checkpoints) FROM local_leases WHERE retired_seq IS NULL")
    if !testing.expect_value(t,len(rows),1) do return
    testing.expect(t,rows[0][0]=="901000" && rows[0][1]=="3601000" && rows[0][2]==cap && rows[0][3]=="0")
    attempt_expect(t,f,1,"")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","held_claim","other","","5"),"",lease_child()).code,"invalid_scope")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    hb:=lease_request(f,lease_child(),"lease.heartbeat","held_heartbeat","lease",cap,"5")
    renewed:=lease_invoke(f,hb,cap,lease_child(),1100)
    if !testing.expect_value(t,renewed.code,"ok") do return
    replay:=lease_invoke(f,hb,cap,lease_child(),4000000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==renewed.body)
    new_cap:=result_cap(renewed)
    rows,_=query(f.store.db,"SELECT expires_ms,hard_ms,retired_seq FROM local_leases")
    testing.expect(t,rows[0][0]=="901100" && rows[0][1]=="3601000" && rows[0][2]=="")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","old_cap",`{"requirements_revision":"1"}`,cap,"5",{},1100).code,"invalid_scope")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","held_present",`{"requirements_revision":"1"}`,new_cap,"5",{},1100).code,"ok")
    p:=`{"requirements_revision":"1","summary":"native checkpoint","next_steps":"continue after release"}`
    first:=lifecycle_call(f,lease_child(),"lease.handoff","held_checkpoint",p,new_cap,"5",{},1100)
    testing.expect_value(t,first.code,"ok")
    attempt_expect(t,f,1,"handoff")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.heartbeat","after_checkpoint","lease",new_cap,"6"),new_cap,lease_child(),1100).code,"invalid_scope")
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"release checkpoint")}))
    testing.expect_value(t,invoke(f,command(f,"task.release","release","task",payload,"6"),payload,1100).code,"ok")
    claimed:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","continue","lease2","","7"),"",lease_child(),1100)
    testing.expect_value(t,claimed.code,"ok")
    attempt_expect(t,f,1,"")
    rows,_=query(f.store.db,"SELECT count(*) FROM local_work_attempts")
    testing.expect(t,rows[0][0]=="2","compatibility lease ordinal remains distinct from native attempt")
}

@(test)
hold_expiry_and_failed_hold_preserve_ttl_and_attempt_history :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);_=lifecycle_ready(t,f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER hold_fail BEFORE INSERT ON local_events WHEN NEW.kind='task.hold' BEGIN SELECT RAISE(ABORT,'failure'); END"))
    testing.expect_value(t,control_call(f,"task.hold","failed","4").code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_controls),(SELECT count(*) FROM control_notices),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="1")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER hold_fail"))
    testing.expect_value(t,control_call(f,"task.hold","hold","4").code,"ok")
    testing.expect(t,expire_leases(&f.store,901000))
    attempt_expect(t,f,1,"expired")
    rows,_=query(f.store.db,"SELECT mode,(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL) FROM local_controls")
    testing.expect(t,rows[0][0]=="held" && rows[0][1]=="0")
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"release after expiry")}))
    testing.expect_value(t,invoke(f,command(f,"task.release","release","task",p,"5",903000),p,901000).code,"ok")
    claimed:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","after_expiry","lease2","","6",903000),"",lease_child(),901000)
    testing.expect_value(t,claimed.code,"ok")
    attempt_expect(t,f,2,"")
}

@(test)
hold_submit_then_live_verdict_waits_for_release_and_preserves_current_state :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,control_call(f,"task.hold","work_hold","4").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"completed while held"}`,cap,"5").code,"ok")
    verdict:=lifecycle_verdict()
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.open","held_open",verdict,"","6").code,"operation_conflict")
    testing.expect_value(t,control_call(f,"task.release","work_release","6").code,"ok")
    rows,_:=query(f.store.db,"SELECT state FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="in_review","release must not restore pre-submit ready state")
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","7")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,control_call(f,"task.hold","review_hold","7").code,"ok")
    rows,_=query(f.store.db,"SELECT count(*) FROM local_review_sessions")
    testing.expect_value(t,rows[0][0],"1")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    approved:=lifecycle_call(f,lifecycle_reviewer(),"review.post","approve",verdict,result_cap(opened),"8")
    testing.expect_value(t,approved.code,"ok")
    rows,_=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM local_review_sessions),(SELECT count(*) FROM runtime_intents WHERE kind='merge') FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="in_review" && rows[0][1]=="1" && rows[0][2]=="0" && rows[0][3]=="0")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","second_vote",verdict,result_cap(opened),"9").code,"invalid_scope")
    testing.expect_value(t,control_call(f,"task.release","review_release","9").code,"ok")
    rows,_=query(f.store.db,"SELECT state,(SELECT resolved FROM source_episodes WHERE origin_kind='local.review') FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="done" && rows[0][1]=="1")
}

@(test)
hold_request_changes_settles_only_on_release :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"submitted"}`,cap).code,"ok")
    p,_:=contracts.owner_parse(lifecycle_verdict(),"review_payload")
    p["verdict"]=json.String("request_changes")
    verdict:=encode(p)
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,control_call(f,"task.hold","hold","5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","changes",verdict,result_cap(opened),"6").code,"ok")
    attempt_expect(t,f,1,"submitted")
    rows,_:=query(f.store.db,"SELECT state FROM lifecycle_state")
    testing.expect_value(t,rows[0][0],"in_review")
    testing.expect_value(t,control_call(f,"task.release","release","7").code,"ok")
    attempt_expect(t,f,1,"changes_requested")
    rows,_=query(f.store.db,"SELECT state FROM lifecycle_state")
    testing.expect_value(t,rows[0][0],"ready")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","rework","lease2","","8"),"",lease_child()).code,"ok")
    attempt_expect(t,f,2,"")
}

@(test)
hold_nested_block_survives_release_and_cannot_be_answered_while_held :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,control_call(f,"task.hold","hold","4").code,"ok")
    p:=`{"requirements_revision":"1","summary":"needs external input","next_steps":"ask coordinator","waiting_on":"human"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.block","block",p,cap,"5").code,"ok")
    attempt_expect(t,f,1,"blocked")
    testing.expect_value(t,control_call(f,"task.resolve","held_answer","6").code,"operation_conflict")
    testing.expect_value(t,control_call(f,"task.release","release","6").code,"ok")
    rows,_:=query(f.store.db,"SELECT mode,reason,waiting_on FROM local_controls")
    testing.expect(t,rows[0][0]=="blocked" && rows[0][1]=="needs external input" && rows[0][2]=="human")
    testing.expect_value(t,control_call(f,"task.hold","blocked_hold","7").code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,control_call(f,"task.release","blocked_release","8").code,"ok")
    rows,_=query(f.store.db,"SELECT mode,reason,waiting_on FROM local_controls")
    testing.expect(t,rows[0][0]=="blocked" && rows[0][1]=="needs external input" && rows[0][2]=="human")
    testing.expect_value(t,control_call(f,"task.resolve","answer","9").code,"ok")
}

@(test)
hold_release_merge_gate_rolls_back_then_pins_exact_submission_once :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f,true);cap:=lifecycle_ready(t,f)
    head:=strings.repeat("a",40,context.temp_allocator)
    p:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="submitted"}))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap,"4",Source_Proof{head,true}).code,"ok")
    verdict:=lifecycle_verdict(head)
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,control_call(f,"task.hold","hold","5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","approve",verdict,result_cap(opened),"6").code,"ok")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER release_fail BEFORE INSERT ON runtime_intents WHEN NEW.kind='merge' BEGIN SELECT RAISE(ABORT,'failure'); END"))
    testing.expect_value(t,control_call(f,"task.release","release","7").code,"storage_error")
    rows,_:=query(f.store.db,"SELECT state,(SELECT mode FROM local_controls),(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM command_receipts WHERE operation_id='release') FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="in_review" && rows[0][1]=="held" && rows[0][2]=="1" && rows[0][3]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER release_fail"))
    p=encode(doc(map[string]string{"body_cipher"=cipher(f,"release reviewed head")}))
    raw:=command(f,"task.release","release","task",p,"7")
    first:=invoke(f,raw,p)
    testing.expect_value(t,first.code,"ok")
    replay:=invoke(f,raw,p,4000000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    rows,_=query(f.store.db,"SELECT state,(SELECT count(*) FROM runtime_intents WHERE kind='merge'),(SELECT json_extract(exact_fence_json,'$.head') FROM runtime_intents WHERE kind='merge'),(SELECT json_extract(exact_fence_json,'$.attempt') FROM runtime_intents WHERE kind='merge') FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="merge_pending" && rows[0][1]=="1" && rows[0][2]==head && rows[0][3]=="1")
}

@(test)
hold_legacy_checkpoint_binding_does_not_resurrect_retired_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,control_call(f,"task.hold","hold","4").code,"ok")
    // Reconstruct the exact durable pre-fix state, including the already
    // retired lease. The new implementation must not turn it live again.
    _,ok:=query(f.store.db,"INSERT INTO local_checkpoints SELECT chain_id,task_id,lease_id,?,capability_json,expires_ms FROM local_leases",encode(lease_child()))
    testing.expect(t,ok)
    _,ok=query(f.store.db,"UPDATE local_leases SET retired_seq=99 WHERE retired_seq IS NULL")
    testing.expect(t,ok)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.heartbeat","legacy_heartbeat","lease",cap,"5"),cap,lease_child()).code,"invalid_scope")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","legacy_submit",`{"requirements_revision":"1","head":"","summary":"not authorized"}`,cap,"5").code,"invalid_scope")
    p:=`{"requirements_revision":"1","summary":"legacy checkpoint","next_steps":"continue after release"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.handoff","legacy_checkpoint",p,cap,"5").code,"ok")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_checkpoints),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.handoff","second_legacy_checkpoint",p,cap,"6").code,"invalid_scope")
}

@(test)
hold_requirements_rework_clears_deferred_rejection_and_starts_next_attempt :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"submitted"}`,cap).code,"ok")
    p,_:=contracts.owner_parse(lifecycle_verdict(),"review_payload")
    p["verdict"]=json.String("request_changes")
    verdict:=encode(p)
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,control_call(f,"task.hold","hold","5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","changes",verdict,result_cap(opened),"6").code,"ok")
    lifecycle_edit(t,f,"2","7")
    attempt_expect(t,f,1,"replaced")
    testing.expect_value(t,control_call(f,"task.release","release","8").code,"ok")
    attempt_expect(t,f,1,"replaced")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","replanned","lease2","","9"),"",lease_child()).code,"ok")
    attempt_expect(t,f,2,"")
}
