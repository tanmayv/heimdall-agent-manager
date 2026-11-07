#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

control_call :: proc(f:^Fixture,method,op,revision:string,reason:="operator reason") -> Result {
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,reason)}))
    return invoke(f,command(f,method,op,"task",p,revision),p)
}
@(test)
controls_hold_release_cancel_reopen_replay_and_revocation :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"holdneedle")}))
    raw:=command(f,"task.hold","hold","task",payload,"4")
    testing.expect_value(t,invoke(f,raw,payload).code,"ok")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT mode FROM local_controls),(SELECT count(*) FROM runtime_intents WHERE kind='checkpoint')")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="held" && rows[0][2]=="1")
    testing.expect_value(t,control_call(f,"task.release","stale","4").code,"stale_revision")
    testing.expect_value(t,control_call(f,"task.release","release","5").code,"ok")
    testing.expect_value(t,control_call(f,"task.cancel","cancel","6").code,"ok")
    testing.expect_value(t,control_call(f,"task.release","wrong_release","7").code,"operation_conflict")
    testing.expect_value(t,control_call(f,"task.reopen","reopen","7").code,"ok")
    before,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    replay:=invoke(f,raw,payload,4000000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    after,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    testing.expect_value(t,before[0][0],after[0][0])
    testing.expect(t,strings.contains(search_for(f,"holdneedle").body,"handoff"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,strings.contains(search_for(f,"holdneedle").body,"handoff"))
}
@(test)
controls_block_explicit_resolution_and_handoff_history :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    payload:=`{"requirements_revision":"1","summary":"blockedneedle","next_steps":"Ask coordinator","waiting_on":"human"}`
    raw:=lifecycle_raw(f,lease_child(),"lease.block","block",payload,cap)
    first:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect_value(t,first.code,"ok")
    testing.expect_value(t,control_call(f,"task.release","not_answer","5").code,"operation_conflict")
    testing.expect_value(t,control_call(f,"task.resolve","empty","5","").code,"invalid_content")
    testing.expect_value(t,control_call(f,"task.resolve","resolve","5","Signed explicit answer").code,"ok")
    replay:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,4000000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_handoffs),(SELECT count(*) FROM runtime_intents WHERE kind='stop'),(SELECT count(*) FROM local_reviews),(SELECT mode FROM local_controls)")
    testing.expect(t,rows[0][0]=="2" && rows[0][1]=="1" && rows[0][2]=="0" && rows[0][3]=="ready")
    testing.expect(t,strings.contains(search_for(f,"blockedneedle").body,"handoff"))
}
// Set up a second eligible task for the same exact child using signed device
// operations; this is an assignment, never a synthetic live lease.
control_destination_seed :: proc(t:^testing.T,f:^Fixture,creation:string="task.create") {
    chains,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"destination"),"body_cipher"=cipher(f,"switch target")}))
    testing.expect_value(t,invoke(f,command(f,creation,"dest","dest",p,chains[0][0]),p).code,"ok")
    p=`{"instance_id":"instance","configuration_revision":"1","enabled":"1"}`
    testing.expect_value(t,execute(&f.store,command(f,"fleet.edit","dest_fleet","dest",p,"1"),p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},lease_child()).code,"ok")
    config,_,_:=lifecycle_config(&f.store,"chain","task")
    p=encode(config)
    testing.expect_value(t,execute(&f.store,command(f,"lifecycle.configure","dest_config","dest",p,"2"),p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{lease_child(),lifecycle_reviewer(),true}).code,"ok")
    p=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,`{"goal":"Destination work","acceptance":["Pass"]}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","dest_req","dest",p,"3"),p).code,"ok")
}
control_switch_payload :: proc(revision:="4")->string {
    return encode(doc(map[string]string{"requirements_revision"="1","summary"="switchneedle","next_steps"="Continue destination","destination_chain_id"="chain","destination_task_id"="dest","destination_revision"=revision,"destination_configuration_revision"="1","destination_requirements_revision"="1","destination_lease_id"="destination_lease"}))
}
@(test)
controls_switch_atomic_rollback_restart_and_lost_reply :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f);control_destination_seed(t,f)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.switch","stale_switch",control_switch_payload("3"),cap).code,"stale_revision")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases WHERE lease_id='lease' AND retired_seq IS NULL),(SELECT count(*) FROM local_handoffs),(SELECT count(*) FROM control_notices)")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="0" && rows[0][2]=="0")
    payload:=control_switch_payload()
    raw:=lifecycle_raw(f,lease_child(),"lease.switch","switch",payload,cap)
    testing.expect(t,exec(f.store.db,`CREATE TABLE switch_fk(id INTEGER PRIMARY KEY);
      CREATE TABLE switch_ref(id INTEGER REFERENCES switch_fk(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER switch_failure AFTER INSERT ON command_receipts WHEN NEW.method='lease.switch' BEGIN INSERT INTO switch_ref VALUES(1); END;`))
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"storage_error")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM local_handoffs),(SELECT count(*) FROM command_receipts WHERE method='lease.switch')")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="0" && rows[0][2]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER switch_failure"))
    first:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect_value(t,first.code,"ok")
    rows,_=query(f.store.db,"SELECT task_id,requirements_revision,(SELECT count(*) FROM local_work_attempts) FROM local_leases WHERE retired_seq IS NULL")
    testing.expect(t,len(rows)==1 && rows[0][0]=="dest" && rows[0][1]=="1" && rows[0][2]=="2")
    rows,_=query(f.store.db,"SELECT count(*) FROM runtime_intents WHERE kind='stop'")
    testing.expect_value(t,rows[0][0],"0")
    rows,_=query(f.store.db,"SELECT count(*) FROM lease_receipt_pins WHERE principal_id='instance' AND operation_id='switch' AND lease_id='destination_lease'")
    testing.expect_value(t,rows[0][0],"1")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    replay:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,4000000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    testing.expect(t,strings.contains(search_for(f,"switchneedle").body,"handoff"))
    changed:=lease_child();changed.epoch="restarted"
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,changed,f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
}
@(test)
controls_live_assignment_revokes_old_capability_and_preserves_history :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    next:=lease_child();next.epoch="replacement";next.run_count=2
    p:=`{"instance_id":"instance","configuration_revision":"2","enabled":"1"}`
    raw:=command(f,"fleet.edit","reassign","task",p,"4")
    testing.expect_value(t,execute(&f.store,raw,p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},next).code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","old",`{"requirements_revision":"1","head":"","summary":"old"}`,cap,"5").code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM control_notices),(SELECT count(*) FROM command_receipts WHERE method='lease.claim')")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="0" && rows[0][2]=="1" && rows[0][3]=="1")
    replay:=execute(&f.store,raw,p,"",f.creator,f.owner,1,"head",4000000,&f.kr,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay)
}
@(test)
controls_review_checkpoint_has_no_verdict_and_invalidates_session :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    p:=`{"requirements_revision":"1","head":"","summary":"submitted"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap).code,"ok")
    verdict:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    p=`{"requirements_revision":"1","attempt":"1","head":"","summary":"reviewcheckpointneedle","next_steps":"Continue inspection"}`
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.checkpoint","checkpoint",p,result_cap(opened),"5").code,"ok")
    rows,_:=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM local_review_sessions),(SELECT count(*) FROM local_handoffs) FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="in_review" && rows[0][1]=="0" && rows[0][2]=="0" && rows[0][3]=="1")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","late",verdict,result_cap(opened),"6").code,"invalid_scope")
}

@(test)
controls_v6_upgrade_collision_and_commit_rollback_preserve_live_fences :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,V9_TEST_DROP+"DROP TABLE IF EXISTS local_chain_context;"+"DROP TABLE IF EXISTS local_grant_audit; DROP TABLE IF EXISTS local_grant_policy;"+"DROP INDEX IF EXISTS local_review_holder; DROP TRIGGER search_local_handoffs_insert; DROP TABLE local_checkpoints; DROP TABLE local_work_attempts; DROP TABLE local_assignment_history; DROP TABLE intent_invalidations; DROP TABLE control_notices; DROP TABLE local_handoffs; DROP TABLE local_controls;"))
    prefix:=string(MIGRATION_006)
    prefix=prefix[:strings.index(prefix,"DROP TRIGGER search_local_submissions_insert;")]
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=6; CREATE VIEW local_controls AS SELECT 1;"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL) FROM runtime_database")
    testing.expect(t,rows[0][0]=="6" && rows[0][1]=="6" && rows[0][2]=="1")
    testing.expect(t,exec(db,"DROP VIEW local_controls"))
    testing.expect(t,exec(db,`CREATE TABLE upgrade_fk(id INTEGER PRIMARY KEY);
      CREATE TABLE upgrade_ref(id INTEGER REFERENCES upgrade_fk(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER upgrade_failure AFTER UPDATE ON schema_migrations WHEN NEW.version=7 BEGIN INSERT INTO upgrade_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_controls') FROM runtime_database")
    testing.expect(t,rows[0][0]=="6" && rows[0][1]=="6" && rows[0][2]=="0")
    testing.expect(t,exec(db,"DROP TRIGGER upgrade_failure"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM local_assignment_history),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL) FROM runtime_database")
    testing.expect(t,rows[0][0]=="33" && rows[0][1]=="33" && rows[0][2]=="1" && rows[0][3]=="1")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","after_upgrade",`{"requirements_revision":"1"}`,cap).code,"ok")
}
@(test)
controls_merge_retry_preserves_exact_fence_and_reopen_invalidates_old_results :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f,true);cap:=lifecycle_ready(t,f)
    head:=strings.repeat("a",40,context.temp_allocator)
    p:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Submitted"}))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap,"4",Source_Proof{head,true}).code,"ok")
    verdict:=lifecycle_verdict(head)
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,result_cap(opened),"5").code,"ok")
    claims,ok:=intent_claim_due(&f.store,1000);testing.expect(t,ok)
    old:Intent_Claim
    for claim in claims do if claim.kind=="merge" do old=claim
    testing.expect(t,intent_result(&f.store,old,false,"merge_conflict",1000))
    p=encode(doc(map[string]string{"attempt"="1","requirements_revision"="1","head"=head,"configuration_revision"="1","body_cipher"=cipher(f,"Retry unchanged target after external repair")}))
    raw:=command(f,"merge.retry","retry","task",p,"7")
    testing.expect_value(t,invoke(f,raw,p).code,"ok")
    claims,ok=intent_claim_due(&f.store,3000);testing.expect(t,ok)
    fresh:Intent_Claim
    for claim in claims do if claim.kind=="merge" do fresh=claim
    testing.expect(t,fresh.id==old.id && fresh.attempt==old.attempt+1 && fresh.payload==old.payload && fresh.fence==old.fence)
    testing.expect(t,!merge_prepare(&f.store,old,head),"obsolete claim attempt cannot prepare or settle")
    testing.expect(t,intent_result(&f.store,fresh,false,"source_changed",3000))
    repair:=encode(doc(map[string]string{"body_cipher"=cipher(f,"Rebind reviewed source after repairing worktree")}))
    testing.expect_value(t,invoke(f,command(f,"task.reopen","repair","task",repair,"9",4000),repair,3000).code,"ok")
    testing.expect(t,!merge_prepare(&f.store,fresh,head))
    rows,_:=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM local_submissions),(SELECT count(*) FROM intent_invalidations) FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="ready" && rows[0][1]=="1" && rows[0][2]=="1" && rows[0][3]=="1")
}

@(test)
controls_hold_retains_live_authority_until_one_exact_checkpoint_or_cancel :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,control_call(f,"task.hold","hold","4").code,"ok")
    payload:=`{"requirements_revision":"1","summary":"Saved held checkpoint","next_steps":"Resume after release"}`
    first:=lifecycle_call(f,lease_child(),"lease.handoff","checkpoint",payload,cap,"5")
    testing.expect_value(t,first.code,"ok")
    rows,_:=query(f.store.db,"SELECT (SELECT mode FROM local_controls),(SELECT count(*) FROM local_checkpoints),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM local_handoffs WHERE kind='lease.handoff')")
    testing.expect(t,rows[0][0]=="held" && rows[0][1]=="0" && rows[0][2]=="0" && rows[0][3]=="1")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.handoff","second_checkpoint",payload,cap,"6").code,"invalid_scope")
    replay:=lifecycle_call(f,lease_child(),"lease.handoff","checkpoint",payload,cap,"5",{},4000000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    g:=fixture(t);defer destroy(g);lifecycle_seed(t,g);_=lifecycle_ready(t,g)
    testing.expect_value(t,control_call(g,"task.hold","hold","4").code,"ok")
    testing.expect_value(t,control_call(g,"task.cancel","cancel","5").code,"ok")
    rows,_=query(g.store.db,"SELECT count(*) FROM runtime_intents WHERE kind='stop'")
    testing.expect_value(t,rows[0][0],"1")
}
@(test)
controls_held_reviewer_checkpoint_preserves_gate_without_verdict :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Done"}`,cap).code,"ok")
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",lifecycle_verdict(),"","5")
    testing.expect_value(t,control_call(f,"task.hold","hold","5").code,"ok")
    p:=`{"requirements_revision":"1","attempt":"1","head":"","summary":"Unfinished held review","next_steps":"Inspect tests"}`
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.checkpoint","checkpoint",p,result_cap(opened),"6").code,"ok")
    rows,_:=query(f.store.db,"SELECT state,(SELECT mode FROM local_controls),(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM local_checkpoints) FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="in_review" && rows[0][1]=="held" && rows[0][2]=="0" && rows[0][3]=="0")
    testing.expect_value(t,control_call(f,"task.release","release","7").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","stale_verdict",lifecycle_verdict(),result_cap(opened),"8").code,"invalid_scope")
}

@(test)
controls_new_work_attempt_records_current_requirements_revision :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    lifecycle_edit(t,f,"2","4")
    result:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","new_claim","new_lease","","5"),"",lease_child())
    testing.expect_value(t,result.code,"ok")
    rows,_:=query(f.store.db,"SELECT requirements_revision,(SELECT attempt FROM local_work_attempts WHERE lease_id='new_lease') FROM local_leases WHERE lease_id='new_lease'")
    testing.expect(t,rows[0][0]=="2" && rows[0][1]=="1")
}


@(test)
controls_switch_uses_destination_brief_deadline :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);control_destination_seed(t,f)
    p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"Short target","acceptance":["done"],"budget":{"hard_deadline":2}}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","short_dest","dest",p,"4"),p).code,"ok")
    value,_:=contracts.owner_parse(control_switch_payload("5"),"switch_payload")
    value["destination_requirements_revision"]=json.String("2")
    result:=lifecycle_call(f,lease_child(),"lease.switch","short_switch",encode(value),cap)
    testing.expect_value(t,result.code,"ok")
    rows,_:=query(f.store.db,"SELECT expires_ms,hard_ms FROM local_leases WHERE lease_id='destination_lease'")
    if testing.expect_value(t,len(rows),1) {
        testing.expect_value(t,rows[0][0],"3000")
        testing.expect_value(t,rows[0][1],"3000")
    }
}
