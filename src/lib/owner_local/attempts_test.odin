#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"

attempt_read_test :: proc(t:^testing.T,f:^Fixture,n:string,now:i64=1000) -> contracts.Owner_Native_Attempt {
    p:=encode(doc(map[string]string{"attempt"=n}))
    r:=invoke(f,command(f,"attempt.read",fmt.tprintf("read%s",n),"task",p,"0",now+1000),p,now)
    testing.expect_value(t,r.code,"ok")
    record:contracts.Owner_Native_Attempt
    testing.expect(t,json.unmarshal(transmute([]byte)r.body,&record)==nil)
    _,valid:=contracts.owner_parse(r.body,"native_attempt");testing.expect(t,valid)
    return record
}

attempt_call_test :: proc(f:^Fixture,method,op,lease,p,cap,rev:string,now:i64=1000) -> Result {
    c,_:=contracts.owner_parse(lifecycle_raw(f,lease_child(),method,op,p,cap,rev),"lifecycle_command")
    c["lease_id"]=json.String(lease)
    sig,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
    return execute_lifecycle(&f.store,encode(c),p,cap,lease_child(),f.owner,now,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
}

@(test)
attempt_records_preserve_native_continuation_times_mapping_and_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    initial:=attempt_read_test(t,f,"1")
    testing.expect(t,initial.started_ms=="1000" && initial.ended_ms=="" && initial.outcome=="")
    p:=`{"requirements_revision":"1","summary":"continue","next_steps":"finish"}`
    testing.expect_value(t,attempt_call_test(f,"lease.handoff","handoff","lease",p,cap,"4",1100).code,"ok")
    handed:=attempt_read_test(t,f,"1",1100)
    testing.expect(t,handed.started_ms=="1000" && handed.ended_ms=="1100" && handed.outcome=="handoff")
    claimed:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim2","lease2","","5"),"",lease_child(),1200)
    testing.expect_value(t,claimed.code,"ok");cap=result_cap(claimed)
    continued:=attempt_read_test(t,f,"1",1200)
    testing.expect(t,continued.started_ms==initial.started_ms && continued.ended_ms=="" && continued.outcome=="" && continued.work_lease_id=="lease2")
    p=`{"requirements_revision":"1"}`
    testing.expect_value(t,attempt_call_test(f,"requirements.present","present2","lease2",p,cap,"5",1200).code,"ok")
    testing.expect_value(t,attempt_call_test(f,"requirements.ack","ack2","lease2",p,cap,"5",1200).code,"ok")
    p=`{"requirements_revision":"1","head":"","summary":"done"}`
    testing.expect_value(t,attempt_call_test(f,"lease.submit","submit2","lease2",p,cap,"5",1300).code,"ok")
    submitted:=attempt_read_test(t,f,"1",1300)
    testing.expect(t,submitted.started_ms=="1000" && submitted.ended_ms=="1300" && submitted.outcome=="submitted" && submitted.holder_instance_id=="instance")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,encode(attempt_read_test(t,f,"1",1300)),encode(submitted))
    p=`{"attempt":"1","offset":"0"}`
    r:=invoke(f,command(f,"submission.read","subread","task",p,"0"),p,1300)
    testing.expect_value(t,r.code,"ok")
    value,_:=contracts.owner_request_document(r.body);obj,_:=value.(json.Object)
    testing.expect_value(t,field(obj,"native_attempt"),"1")
    rows,ok:=query(f.store.db,"SELECT (SELECT attempt FROM local_work_attempts WHERE lease_id='lease2'),(SELECT attempt FROM local_submissions WHERE lease_id='lease2')")
    testing.expect(t,ok && rows[0][0]=="2" && rows[0][1]=="1","compatibility IDs remain unchanged")
    f.creator.revoked=true // the device itself is revoked (account-level trust; no per-chain grant)
    p=`{"attempt":"1"}`
    testing.expect_value(t,invoke(f,command(f,"attempt.read","revoked_record","task",p,"0"),p,1300).code,"invalid_scope")
}

@(test)
attempt_records_separate_submission_ordinals_from_native_attempts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    p:=`{"requirements_revision":"1","summary":"blocked","next_steps":"resolve","waiting_on":"human"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.block","block",p,cap).code,"ok")
    testing.expect_value(t,control_call(f,"task.resolve","resolve","5").code,"ok")
    r:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim2","lease2","","6"),"",lease_child())
    testing.expect_value(t,r.code,"ok");cap=result_cap(r)
    p=`{"requirements_revision":"1"}`
    testing.expect_value(t,attempt_call_test(f,"requirements.present","present2","lease2",p,cap,"6").code,"ok")
    testing.expect_value(t,attempt_call_test(f,"requirements.ack","ack2","lease2",p,cap,"6").code,"ok")
    p=`{"requirements_revision":"1","head":"","summary":"done"}`
    testing.expect_value(t,attempt_call_test(f,"lease.submit","submit2","lease2",p,cap,"6").code,"ok")
    testing.expect_value(t,attempt_read_test(t,f,"1").outcome,"blocked")
    testing.expect_value(t,attempt_read_test(t,f,"2").outcome,"submitted")
    p=`{"attempt":"1","offset":"0"}`
    r=invoke(f,command(f,"submission.read","mapping","task",p,"0"),p)
    value,_:=contracts.owner_request_document(r.body);obj,_:=value.(json.Object)
    testing.expect_value(t,field(obj,"native_attempt"),"2")
    testing.expect(t,exec(f.store.db,`DROP TRIGGER local_events_no_update;
      UPDATE local_events SET evidence_json='',completeness='legacy_tag',actor_kind='unknown',actor_id='',ts_ms=NULL WHERE kind='lease.claim' AND operation_id='claim';
      CREATE TRIGGER local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;`))
    r=invoke(f,command(f,"submission.read","legacy_mapping","task",p,"0"),p)
    value,_=contracts.owner_request_document(r.body);obj,_=value.(json.Object)
    testing.expect_value(t,field(obj,"native_attempt"),"")
    testing.expect_value(t,field(obj,"attempt_completeness"),"incomplete")
}

@(test)
attempt_records_retain_exact_expiry_reason_and_flag_legacy_reason_gap :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"short deadline","acceptance":["explicit reason"],"budget":{"hard_deadline":1}}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","short_deadline","task",p,"4"),p).code,"ok")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim","lease","","5"),"",lease_child()).code,"ok")
    testing.expect(t,expire_leases(&f.store,2000))
    record:=attempt_read_test(t,f,"1",2000)
    testing.expect(t,record.outcome=="expired:hard_cap" && record.ended_ms=="2000" && record.completeness=="full")
    testing.expect(t,exec(f.store.db,`DROP TRIGGER local_events_no_update;
      UPDATE local_events SET evidence_json=json_set(evidence_json,'$.content','{"lease_id":"lease"}') WHERE kind='lease.expired';
      CREATE TRIGGER local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;`))
    record=attempt_read_test(t,f,"1",2000)
    testing.expect(t,record.outcome=="expired" && record.completeness=="incomplete","old missing expiry reason is not invented")
}

attempt_expect :: proc(t:^testing.T,f:^Fixture,attempt:i64,release:string,complete:=true) {
    v,ok:=attempt_view(&f.store,"chain","task")
    testing.expect(t,ok)
    testing.expect_value(t,v.attempt_no,attempt)
    testing.expect_value(t,v.last_release,release)
    testing.expect_value(t,v.incomplete,!complete)
    _,valid:=contracts.owner_parse(encode(attempt_document(v)),"attempt_state")
    testing.expect(t,valid)
}

@(test)
attempts_native_handoff_continuation_replay_restart_and_output_keys :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    attempt_expect(t,f,1,"")
    p:=`{"requirements_revision":"1","summary":"continue","next_steps":"finish checks"}`
    raw:=lifecycle_raw(f,lease_child(),"lease.handoff","checkpoint",p,cap)
    first:=execute_lifecycle(&f.store,raw,p,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect_value(t,first.code,"ok")
    attempt_expect(t,f,1,"handoff")
    replay:=execute_lifecycle(&f.store,raw,p,cap,lease_child(),f.owner,4000000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    attempt_expect(t,f,1,"handoff")
    claimed:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","continue","lease2","","5"),"",lease_child())
    testing.expect_value(t,claimed.code,"ok")
    attempt_expect(t,f,1,"")
    // The compatibility ordinal is still 2. It must never be mistaken for the
    // native attempt number 1, nor replace existing immutable submission keys.
    rows,ok:=query(f.store.db,"SELECT attempt FROM local_work_attempts WHERE lease_id='lease2'")
    testing.expect(t,ok && len(rows)==1 && rows[0][0]=="2")
    page:=invoke(f,command(f,"runtime.read","attempts_read","task",`{"cursor":"","limit":"1"}`,"0"),`{"cursor":"","limit":"1"}`)
    testing.expect_value(t,page.code,"ok")
    value,_:=contracts.owner_request_document(page.body);obj,_:=value.(json.Object);view,_:=obj["attempts"].(json.Object)
    testing.expect_value(t,field(view,"attempt_no"),"1")
    testing.expect(t,!("counting_attempts" in view) && !("budget" in obj),"runtime.read reports no attempt budget")
    testing.expect_value(t,field(view,"completeness"),"full")
    // Current read revocation still precedes native history inspection.
    f.creator.revoked=true // the device itself is revoked (account-level trust; no per-chain grant)
    testing.expect_value(t,invoke(f,command(f,"runtime.read","revoked_attempts","task",`{"cursor":"","limit":"1"}`,"0"),`{"cursor":"","limit":"1"}`).code,"invalid_scope")
}

@(test)
attempts_native_block_expiry_and_structural_release :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    p:=`{"requirements_revision":"1","summary":"blocked","next_steps":"resolve","waiting_on":"human"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.block","block",p,cap).code,"ok")
    attempt_expect(t,f,1,"blocked")
    testing.expect_value(t,control_call(f,"task.resolve","resolve","5").code,"ok")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim2","lease2","","6"),"",lease_child()).code,"ok")
    attempt_expect(t,f,2,"")
    testing.expect_value(t,control_call(f,"task.cancel","cancel","6").code,"ok")
    testing.expect_value(t,attempt_read_test(t,f,"2").outcome,"expired:cancelled")
    testing.expect_value(t,control_call(f,"task.reopen","reopen","7").code,"ok")
    attempt_expect(t,f,2,"reopened")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim3","lease3","","8"),"",lease_child()).code,"ok")
    attempt_expect(t,f,3,"")
    testing.expect_value(t,attempt_read_test(t,f,"3").outcome,"")
    testing.expect(t,expire_leases(&f.store,902000))
    attempt_expect(t,f,3,"expired")
    expired:=attempt_read_test(t,f,"3",902000)
    testing.expect(t,expired.ended_ms=="902000" && expired.outcome=="expired:ttl")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim4","lease4","","8",904000),"",lease_child(),902000).code,"ok")
    attempt_expect(t,f,4,"")
}

@(test)
attempts_switch_records_both_native_histories_and_rollback :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f);control_destination_seed(t,f)
    _,before,_,before_ok:=attempt_scan(&f.store,"chain","task",1)
    testing.expect(t,before_ok)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER attempt_fail BEFORE INSERT ON local_events WHEN NEW.kind='lease.switch' BEGIN SELECT RAISE(ABORT,'failure'); END"))
    p:=control_switch_payload()
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.switch","switch_fail",p,cap).code,"storage_error")
    attempt_expect(t,f,1,"")
    _,after,_,after_ok:=attempt_scan(&f.store,"chain","task",1)
    testing.expect(t,after_ok && encode(before)==encode(after),"event write failure rolls back the native record too")
    dest,ok:=attempt_view(&f.store,"chain","dest")
    testing.expect(t,ok && !dest.incomplete && dest.attempt_no==0)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER attempt_fail"))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.switch","switch",p,cap).code,"ok")
    attempt_expect(t,f,1,"handoff")
    dest,ok=attempt_view(&f.store,"chain","dest")
    testing.expect(t,ok && !dest.incomplete && dest.attempt_no==1 && dest.work_lease_id=="destination_lease")
    _,destination,_,record_ok:=attempt_scan(&f.store,"chain","dest",1)
    testing.expect(t,record_ok && destination.holder_instance_id==lease_child().instance && destination.started_ms=="1000" && destination.outcome=="")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    dest,ok=attempt_view(&f.store,"chain","dest")
    testing.expect(t,ok && !dest.incomplete && dest.attempt_no==1)
    testing.expect(t,exec(f.store.db,`DROP TRIGGER local_events_no_update;
      UPDATE local_events SET evidence_json='',completeness='legacy_tag',actor_kind='unknown',actor_id='',ts_ms=NULL WHERE kind='lease.switch';
      CREATE TRIGGER local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;`))
    dest,ok=attempt_view(&f.store,"chain","dest")
    testing.expect(t,ok && dest.incomplete,"a legacy switch has unknown destination evidence, not malformed JSON")
}

@(test)
attempts_incomplete_history_is_never_reconstructed_from_rows :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);_=lifecycle_ready(t,f)
    // Reconstruct V13's documented legacy-tag boundary rather than fabricating
    // a native event or treating the V7 lease ordinal as a native attempt.
    testing.expect(t,exec(f.store.db,`DROP TRIGGER local_events_no_update;
      UPDATE local_events SET evidence_json='',completeness='legacy_tag',actor_kind='unknown',actor_id='',ts_ms=NULL;
      CREATE TRIGGER local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;`))
    attempt_expect(t,f,0,"",false)
    // An unrepresented workflow-wide retirement is also explicit.
    g:=fixture(t);defer destroy(g);lifecycle_seed(t,g);_=lifecycle_ready(t,g)
    _,ok:=query(g.store.db,"UPDATE local_leases SET retired_seq=99 WHERE retired_seq IS NULL")
    testing.expect(t,ok)
    attempt_expect(t,g,1,"",false)
    h:=fixture(t);defer destroy(h);lifecycle_seed(t,h);_=lifecycle_ready(t,h)
    testing.expect_value(t,control_call(h,"task.hold","hold","4").code,"ok")
    attempt_expect(t,h,1,"")
    // Reconstruct old full-but-revoking hold evidence without rewriting its
    // interpretation to the newly accepted semantics.
    testing.expect(t,exec(h.store.db,`DROP TRIGGER local_events_no_update;
      UPDATE local_events SET evidence_json=json_set(evidence_json,'$.content','{}') WHERE kind='task.hold';
      CREATE TRIGGER local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;`))
    attempt_expect(t,h,1,"",false)
}

@(test)
attempts_native_release_matrix_matches_original_fold_rules :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    // Source-backed native grant semantics: a handoff continues the attempt;
    // every other release starts a new attempt number on the next grant.
    releases:=[?]string{"replaced","dep_added","reopened","user_stopped","released_noncounting","handoff","blocked","expired","changes_requested","submitted"}
    for release in releases {
        v:=Attempt_View{last_release=release,attempt_no=4}
        attempt_grant(&v,"next")
        expected_attempt:=i64(5)
        if release=="handoff" do expected_attempt=4
        testing.expect_value(t,v.attempt_no,expected_attempt)
        testing.expect_value(t,v.last_release,"")
    }
}

@(test)
attempts_projection_pages_structural_history_without_spending_attempts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);_=lifecycle_ready(t,f)
    for i in 0..<130 {
        lifecycle_edit(t,f,fmt.tprintf("%d",i+2),fmt.tprintf("%d",i+4))
    }
    attempt_expect(t,f,1,"")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    attempt_expect(t,f,1,"")
}
