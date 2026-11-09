#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

lifecycle_reviewer :: proc()->Child {return {"review_instance","review_epoch",strings.repeat("b",64,context.temp_allocator),1,"reviewer"}}
lifecycle_seed :: proc(t:^testing.T,f:^Fixture,git:=false) {
    child:=lease_child();fleet_seed(t,f,child)
    p:=doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""})
    if git {
        p["merge_policy"]=json.String("git");p["repository"]=json.String("/repo");p["worktree"]=json.String("/repo/.heimdall/worktrees/task");p["source_branch"]=json.String("heimdall/task");p["target_branch"]=json.String("target");p["base_head"]=json.String(strings.repeat("b",40,context.temp_allocator))
    }
    raw:=encode(p)
    c:=command(f,"lifecycle.configure","config","task",raw,"2")
    testing.expect_value(t,execute(&f.store,c,raw,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
    lifecycle_edit(t,f,"1","3")
}
lifecycle_edit :: proc(t:^testing.T,f:^Fixture,req,revision:string) {
    p:=encode(doc(map[string]string{"requirements_revision"=req,"body_cipher"=cipher(f,`{"goal":"Complete scoped work","acceptance":["Tests pass"]}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit",fmt.tprintf("req%s",req),"task",p,revision),p).code,"ok")
}
lifecycle_raw :: proc(f:^Fixture,child:Child,method,op,payload,cap:string,revision:="4") -> string {
    raw:=lease_request(f,child,"lease.heartbeat",op,"lease",cap,revision)
    c,_:=contracts.owner_parse(raw,"lease_command")
    c["method"]=json.String(method);c["payload_digest"]=json.String(contracts.owner_payload_digest(payload))
    signature,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(signature)
    return encode(c)
}
lifecycle_call :: proc(f:^Fixture,child:Child,method,op,payload,cap:string,revision:="4",proof:Source_Proof={"",true},now:i64=1000) -> Result {
    raw:=lifecycle_raw(f,child,method,op,payload,cap,revision)
    return execute_lifecycle(&f.store,raw,payload,cap,child,f.owner,now,Signer{&f.owner_priv,test_sign},proof)
}
lifecycle_ready :: proc(t:^testing.T,f:^Fixture) -> string {
    child:=lease_child()
    r:=lease_invoke(f,lease_request(f,child,"lease.claim","claim","lease","","4"),"",child)
    if !testing.expect_value(t,r.code,"ok") do return ""
    cap:=result_cap(r)
    p:=`{"requirements_revision":"1"}`
    testing.expect_value(t,lifecycle_call(f,child,"requirements.ack","unread",p,cap).code,"stale_revision")
    testing.expect_value(t,lifecycle_call(f,child,"requirements.present","present",p,cap).code,"ok")
    testing.expect_value(t,lifecycle_call(f,child,"requirements.ack","ack",p,cap).code,"ok")
    return cap
}
lifecycle_verdict :: proc(head:="")->string {
    return encode(doc(map[string]string{"requirements_revision"="1","attempt"="1","head"=head,"verdict"="approve","summary"="Independent review passed"}))
}
@(test)
lifecycle_submit_replay_and_independent_bound_review :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    p:=`{"requirements_revision":"1","head":"","summary":"Checks pass"}`
    raw:=lifecycle_raw(f,lease_child(),"lease.submit","submit",p,cap)
    first:=execute_lifecycle(&f.store,raw,p,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
    if !testing.expect_value(t,first.code,"ok") do return
    before,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    replay:=execute_lifecycle(&f.store,raw,p,cap,lease_child(),f.owner,4000000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    after,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    testing.expect(t,before[0][0]==after[0][0],"replay is read-only after release and expiry")
    forged:=lease_child();forged.epoch="new_epoch"
    testing.expect_value(t,execute_lifecycle(&f.store,raw,p,cap,forged,f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
    verdict:=lifecycle_verdict()
    testing.expect_value(t,lifecycle_call(f,lease_child(),"review.open","self",verdict,"","5").code,"invalid_scope")
    bad:=doc(map[string]string{"requirements_revision"="1","attempt"="2","head"="","verdict"="approve","summary"="stale"})
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.open","stale",encode(bad),"","5").code,"stale_revision")
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    if !testing.expect_value(t,opened.code,"ok") do return
    rcap:=result_cap(opened)
    approved:=lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,rcap,"5")
    testing.expect_value(t,approved.code,"ok")
    states,_:=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM local_submissions),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL) FROM lifecycle_state")
    testing.expect(t,states[0][0]=="done" && states[0][1]=="1" && states[0][2]=="1" && states[0][3]=="0")
    replay=lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,rcap,"5",{},4000000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    _,_=query(f.store.db,"UPDATE local_fleet SET enabled=0,configuration_revision=configuration_revision+1")
    testing.expect_value(t,execute_lifecycle(&f.store,raw,p,cap,lease_child(),f.owner,4000000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
}
@(test)
lifecycle_changed_requirements_need_exact_new_presentation_and_ack :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    lifecycle_edit(t,f,"2","4")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.ack","stale_ack",`{"requirements_revision":"1"}`,cap,"5").code,"stale_revision")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.ack","unread_new",`{"requirements_revision":"2"}`,cap,"5").code,"stale_revision")
    p:=`{"requirements_revision":"2","head":"","summary":"New requirements checked"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","early",p,cap,"5").code,"stale_revision")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","new_present",`{"requirements_revision":"2"}`,cap,"5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.ack","new_ack",`{"requirements_revision":"2"}`,cap,"5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap,"5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.open","old",lifecycle_verdict(),"","6").code,"stale_revision")
}
@(test)
lifecycle_submit_commit_failure_is_atomic :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    testing.expect(t,exec(f.store.db,`CREATE TABLE submit_failure(id INTEGER PRIMARY KEY);
      CREATE TABLE submit_failure_ref(id INTEGER REFERENCES submit_failure(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER submit_commit_failure AFTER INSERT ON local_submissions BEGIN INSERT INTO submit_failure_ref VALUES(1); END;`))
    before,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    p:=`{"requirements_revision":"1","head":"","summary":"Checks pass"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_submissions),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM command_receipts WHERE operation_id='submit'),commit_seq FROM runtime_database")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="1" && rows[0][2]=="0" && rows[0][3]==before[0][0])
    testing.expect(t,exec(f.store.db,"DROP TRIGGER submit_commit_failure"))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap).code,"ok")
}
@(test)
lifecycle_human_approval_does_not_replace_independent_reviewer :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Done"}`,cap).code,"ok")
    p:=lifecycle_verdict()
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,"5"),p).code,"ok")
    state,_:=query(f.store.db,"SELECT state FROM lifecycle_state")
    testing.expect_value(t,state[0][0],"in_review")
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",p,"","6")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","review",p,result_cap(opened),"6").code,"ok")
}
@(test)
lifecycle_merge_failure_stays_blocking_and_completion_queue_folds_exact_result :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f,true)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    head:=strings.repeat("a",40,context.temp_allocator)
    p:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Done"}))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap,"4",Source_Proof{head,true}).code,"ok")
    verdict:=lifecycle_verdict(head)
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,result_cap(opened),"5").code,"ok")
    claims,ok:=intent_claim_due(&f.store,1000);testing.expect(t,ok)
    merge:Intent_Claim
    for c in claims do if c.kind=="merge" do merge=c
    if !testing.expect(t,merge.id!="") do return
    testing.expect(t,intent_result(&f.store,merge,false,"merge_conflict",1000))
    rows,_:=query(f.store.db,"SELECT state FROM lifecycle_state");testing.expect_value(t,rows[0][0],"merge_blocked")
    claims,ok=intent_claim_due(&f.store,3000);testing.expect(t,ok)
    for c in claims do if c.kind=="merge" do merge=c
    testing.expect(t,merge_prepare(&f.store,merge,head))
    q:Intent_Completions;defer intent_completions_destroy(&q)
    testing.expect(t,intent_completion_keep(&q,merge,true,head,3000))
    testing.expect(t,exec(f.store.db,`CREATE TABLE merge_failure(id INTEGER PRIMARY KEY);
      CREATE TABLE merge_failure_ref(id INTEGER REFERENCES merge_failure(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER merge_commit_failure AFTER INSERT ON local_changes WHEN NEW.kind='merge.merged' BEGIN INSERT INTO merge_failure_ref VALUES(1); END;`))
    testing.expect(t,!intent_completions_flush(&f.store,&q))
    testing.expect_value(t,q.count,1)
    rows,_=query(f.store.db,"SELECT state,(SELECT state FROM runtime_intents WHERE kind='merge') FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="merge_blocked" && rows[0][1]=="claimed","failed settlement COMMIT retains complete effect and gate")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER merge_commit_failure"))
    testing.expect(t,intent_completions_flush(&f.store,&q))
    rows,_=query(f.store.db,"SELECT state,merge_receipt FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="done" && rows[0][1]==head && q.count==0)
}

@(test)
lifecycle_review_commit_failure_rolls_back_verdict_gate_and_intent :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f,true)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    head:=strings.repeat("a",40,context.temp_allocator)
    p:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Done"}))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap,"4",Source_Proof{head,true}).code,"ok")
    verdict:=lifecycle_verdict(head)
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect(t,exec(f.store.db,`CREATE TABLE review_failure(id INTEGER PRIMARY KEY);
      CREATE TABLE review_failure_ref(id INTEGER REFERENCES review_failure(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER review_commit_failure AFTER INSERT ON local_reviews BEGIN INSERT INTO review_failure_ref VALUES(1); END;`))
    before,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,result_cap(opened),"5").code,"storage_error")
    rows,_:=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM runtime_intents WHERE kind='merge'),(SELECT count(*) FROM command_receipts WHERE operation_id='review'),(SELECT commit_seq FROM runtime_database) FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="in_review" && rows[0][1]=="0" && rows[0][2]=="0" && rows[0][3]=="0" && rows[0][4]==before[0][0])
    testing.expect(t,exec(f.store.db,"DROP TRIGGER review_commit_failure"))
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,result_cap(opened),"5").code,"ok")
}


@(test)
rich_requirements_validate_nested_policy_and_apply_lease_deadline :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    raw:=`{"goal":"Rich native brief","acceptance":["Round trip"],"inputs":["#1"],"budget":{"max_attempts":9,"hard_deadline":2},"reviewers":["reviewer"],"output":{"schema":"inline","required":["summary"]}}`
    p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,raw)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","rich_req","task",p,"4"),p).code,"ok")
    req,_:=lifecycle_requirements(&f.store,"chain","task")
    testing.expect_value(t,req[1],raw)
    bad:=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"Bad","acceptance":["done"],"budget":{"max_attempts":false}}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","bad_budget","task",bad,"5"),bad).code,"invalid_content")
    // Reviewers are agent ids in brief.reviewers; the legacy role key is refused.
    roles:=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"Roles","acceptance":["done"],"review_roles":["reviewer"]}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","bad_roles","task",roles,"5"),roles).code,"invalid_content")
    child:=lease_child()
    claimed:=lease_invoke(f,lease_request(f,child,"lease.claim","rich_claim","rich_lease","","5"),"",child)
    testing.expect_value(t,claimed.code,"ok")
    rows,_:=query(f.store.db,"SELECT expires_ms,hard_ms FROM local_leases WHERE lease_id='rich_lease'")
    if testing.expect_value(t,len(rows),1) {
        testing.expect_value(t,rows[0][0],"3000")
        testing.expect_value(t,rows[0][1],"3000")
    }
    heartbeat:=lease_request(f,child,"lease.heartbeat","short_beat","rich_lease",result_cap(claimed),"5")
    testing.expect_value(t,lease_invoke(f,heartbeat,result_cap(claimed),child,1500).code,"ok")
    rows,_=query(f.store.db,"SELECT expires_ms,hard_ms FROM local_leases WHERE lease_id='rich_lease'")
    testing.expect(t,rows[0][0]=="3000" && rows[0][1]=="3000","heartbeat cannot extend the brief hard deadline")
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    req,_=lifecycle_requirements(&f.store,"chain","task")
    testing.expect_value(t,req[1],raw)
    replay:=lease_invoke(f,lease_request(f,child,"lease.claim","rich_claim","rich_lease","","5"),"",child)
    testing.expect(t,replay.code=="ok" && replay.replay)
}
