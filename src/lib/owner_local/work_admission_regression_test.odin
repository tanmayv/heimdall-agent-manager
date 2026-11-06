#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"

work_legacy_plan :: proc()->string {
    v,_:=contracts.owner_content_document(work_plan());p,_:=v.(json.Object)
    p["auto_approve"]=json.Boolean(true)
    tasks,_:=p["tasks"].(json.Array);second,_:=tasks[1].(json.Object);delete_key(&second,"depends_on")
    return encode(p)
}
@(test)
work_switch_rejects_draft_destination_without_source_or_destination_mutation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);control_destination_seed(t,f,"task.draft")
    testing.expect(t,!work_task_published(&f.store,"chain","dest"))
    before:=work_state(f)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.switch","draft_switch",control_switch_payload(),cap).code,"operation_conflict")
    testing.expect(t,work_state(f)==before,"rejected switch must leave the transaction unchanged")
}
@(test)
work_legacy_dependency_claim_freezes_generation_and_blocks_producer_reopen :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    testing.expect_value(t,work_call(f,"chain.propose","plan",work_legacy_plan()).code,"ok")
    testing.expect_value(t,advanced_call(f,"dependency.edit","legacy_edge",`{"prerequisite":"first","enabled":"1"}`,"second").code,"ok")
    work_finish(t,f,"first");work_finish(t,f,"second")
    rows,_:=query(f.store.db,"SELECT dependent_id,dependent_generation,prerequisite_id,prerequisite_generation FROM local_work_inputs")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"second","1","first","1"}}))
    testing.expect_value(t,work_call(f,"task.reopen","consumed_reopen","Replace output","first",work_task_revision(f,"first")).code,"operation_conflict")
}

work_other_chain_command :: proc(f:^Fixture,method,op,task,p,revision:string)->string {
    return grant_command(f,f.creator,&f.creator_priv,method,op,task,p,revision,chain="other_chain")
}
work_other_destination :: proc(t:^testing.T,f:^Fixture) {
    g,_:=contracts.owner_parse(f.genesis,"genesis")
    g["chain_id"]=json.String("other_chain");g["creation_op"]=json.String("other_create")
    g["creator_signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    g["owner_signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    sig,_:=test_sign(&f.creator_priv,"genesis",g);g["creator_signature"]=json.String(sig)
    sig,_=test_sign(&f.owner_priv,"genesis",g);g["owner_signature"]=json.String(sig)
    digest,_:=contracts.owner_digest("genesis",g)
    p:=encode(doc(map[string]string{"genesis_digest"=digest,"title_cipher"=cipher(f,"Other chain"),"description_cipher"=cipher(f,"Unpublished destination")}))
    c:=work_other_chain_command(f,"chain.create","other_create","",p,"0")
    testing.expect_value(t,execute(&f.store,c,p,encode(g),f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign}).code,"ok")
    p=encode(doc(map[string]string{"title_cipher"=cipher(f,"Other destination"),"body_cipher"=cipher(f,"Same owner")}))
    testing.expect_value(t,invoke(f,work_other_chain_command(f,"task.create","other_dest","other_dest",p,"1"),p).code,"ok")
    p=`{"instance_id":"instance","configuration_revision":"1","enabled":"1"}`
    testing.expect_value(t,execute(&f.store,work_other_chain_command(f,"fleet.edit","other_fleet","other_dest",p,"1"),p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},lease_child()).code,"ok")
    config,_,_:=lifecycle_config(&f.store,"chain","task");p=encode(config)
    testing.expect_value(t,execute(&f.store,work_other_chain_command(f,"lifecycle.configure","other_config","other_dest",p,"2"),p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{lease_child(),lifecycle_reviewer(),true}).code,"ok")
    p=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,`{"goal":"Other","acceptance":["Done"]}`)}))
    testing.expect_value(t,invoke(f,work_other_chain_command(f,"requirements.edit","other_req","other_dest",p,"3"),p).code,"ok")
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='other_chain'")
    p=encode(doc(map[string]string{"body_cipher"=cipher(f,"{}")}))
    testing.expect_value(t,invoke(f,work_other_chain_command(f,"chain.draft","other_draft","",p,rows[0][0]),p).code,"ok")
}
@(test)
work_switch_rejects_unpublished_chain_then_publishes_and_replays_after_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);work_other_destination(t,f)
    testing.expect(t,!work_task_published(&f.store,"other_chain","other_dest"))
    p,_:=contracts.owner_parse(control_switch_payload(),"switch_payload")
    p["destination_chain_id"]=json.String("other_chain");p["destination_task_id"]=json.String("other_dest")
    payload:=encode(p);raw:=lifecycle_raw(f,lease_child(),"lease.switch","other_switch",payload,cap)
    before:=work_state(f)
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"operation_conflict")
    testing.expect(t,work_state(f)==before,"unpublished target rejects before source retirement, handoff, attempt or receipt")
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='other_chain'")
    publication:=encode(doc(map[string]string{"body_cipher"=cipher(f,"{}")}))
    testing.expect_value(t,invoke(f,work_other_chain_command(f,"chain.publish","other_publish","",publication,rows[0][0]),publication).code,"ok")
    accepted:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    if !testing.expect_value(t,accepted.code,"ok") do return
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    replay:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,4000000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==accepted.body)
    rows,_=query(f.store.db,"SELECT chain_id,task_id FROM local_leases WHERE retired_seq IS NULL")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"other_chain","other_dest"}}))
}
work_second_claim_raw :: proc(f:^Fixture)->string {
    c,_:=contracts.owner_parse(lease_request(f,lease_child(),"lease.claim","legacy_claim","legacy_lease","",work_task_revision(f,"second")),"lease_command")
    c["task_id"]=json.String("second")
    sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
    return encode(c)
}
@(test)
work_legacy_claim_overlap_receipt_statement_commit_rollback_and_restart_replay :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for overlap in ([2]bool{false,true}) {
        f:=fixture(t);defer destroy(f);work_seed(t,f)
        testing.expect_value(t,work_call(f,"chain.propose","plan",work_legacy_plan()).code,"ok")
        testing.expect_value(t,advanced_call(f,"dependency.edit","legacy_edge",`{"prerequisite":"first","enabled":"1"}`,"second").code,"ok")
        if overlap {
            testing.expect_value(t,work_call(f,"work.dependency.add","mixed_overlap",`{"dependency_id":"mixed","dependent":{"kind":"task","id":"second"},"prerequisite":{"kind":"task","id":"first"}}`).code,"ok")
        }
        work_finish(t,f,"first");work_bind(t,f,"second")
        raw:=work_second_claim_raw(f)
        testing.expect(t,exec(f.store.db,"CREATE TRIGGER legacy_capture_fail BEFORE INSERT ON local_work_inputs BEGIN SELECT RAISE(ABORT,'receipt failure'); END"))
        before:=work_state(f)
        testing.expect_value(t,lease_invoke(f,raw,"",lease_child()).code,"storage_error")
        testing.expect(t,work_state(f)==before,"receipt statement failure rolls back claim, attempt, events and outbox")
        testing.expect(t,exec(f.store.db,"DROP TRIGGER legacy_capture_fail; CREATE TABLE legacy_parent(id INTEGER PRIMARY KEY); CREATE TABLE legacy_ref(id INTEGER REFERENCES legacy_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER legacy_capture_fail AFTER INSERT ON local_work_inputs BEGIN INSERT INTO legacy_ref VALUES(1); END"))
        before=work_state(f)
        testing.expect_value(t,lease_invoke(f,raw,"",lease_child()).code,"storage_error")
        testing.expect(t,work_state(f)==before,"receipt deferred commit failure rolls back all claim state")
        testing.expect(t,exec(f.store.db,"DROP TRIGGER legacy_capture_fail"))
        accepted:=lease_invoke(f,raw,"",lease_child())
        if !testing.expect_value(t,accepted.code,"ok") do return
        rows,_:=query(f.store.db,"SELECT dependent_id,dependent_generation,prerequisite_id,prerequisite_generation,output_manifest_json,accepted_seq FROM local_work_inputs")
        testing.expect(t,len(rows)==1 && rows[0][0]=="second" && rows[0][1]=="1" && rows[0][2]=="first" && rows[0][3]=="1","overlapping graph dialects produce one immutable generation receipt")
        receipt:=encode(rows)
        testing.expect_value(t,work_call(f,"task.reopen","consumed","Replace producer","first",work_task_revision(f,"first")).code,"operation_conflict")
        cap:=result_cap(accepted);revision:=work_task_revision(f,"second")
        for method in ([2]string{"requirements.present","requirements.ack"}) {
            testing.expect_value(t,dependency_lifecycle_call(f,"second","legacy_lease",lease_child(),method,method,`{"requirements_revision":"1"}`,cap,revision).code,"ok")
        }
        submit:=`{"requirements_revision":"1","head":"","summary":"Legacy inputs consumed"}`
        testing.expect_value(t,dependency_lifecycle_call(f,"second","legacy_lease",lease_child(),"lease.submit","legacy_submit",submit,cap,revision).code,"ok")
        rows,_=query(f.store.db,"SELECT dependent_id,dependent_generation,prerequisite_id,prerequisite_generation,output_manifest_json,accepted_seq FROM local_work_inputs")
        testing.expect_value(t,encode(rows),receipt)
        close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
        replay:=lease_invoke(f,raw,"",lease_child(),4000000)
        testing.expect(t,replay.code=="ok" && replay.replay && replay.body==accepted.body)
        rows,_=query(f.store.db,"SELECT dependent_id,dependent_generation,prerequisite_id,prerequisite_generation,output_manifest_json,accepted_seq FROM local_work_inputs")
        testing.expect_value(t,encode(rows),receipt)
        testing.expect_value(t,work_call(f,"task.reopen","still_consumed","Replace producer","first",work_task_revision(f,"first")).code,"operation_conflict")
    }
}
@(test)
work_legacy_switch_receipts_roll_back_source_retirement_and_replay_once :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);control_destination_seed(t,f)
    plan:=`{"kind":"task","auto_approve":true,"tasks":[{"id":"first","title":"Producer","brief":{"goal":"Produce","acceptance":["Done"]}}]}`
    testing.expect_value(t,work_call(f,"chain.propose","producer",plan).code,"ok")
    testing.expect_value(t,advanced_call(f,"dependency.edit","legacy_edge",`{"prerequisite":"first","enabled":"1"}`,"dest").code,"ok")
    work_finish(t,f,"first")
    cap:=lifecycle_ready(t,f);payload:=control_switch_payload("5")
    raw:=lifecycle_raw(f,lease_child(),"lease.switch","legacy_switch",payload,cap)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER switch_receipt_fail BEFORE INSERT ON local_work_inputs BEGIN SELECT RAISE(ABORT,'receipt failure'); END"))
    before:=work_state(f)
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"storage_error")
    testing.expect(t,work_state(f)==before,"capture failure rolls back source retirement and handoff, destination lease/attempt and event")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER switch_receipt_fail; CREATE TABLE switch_capture_parent(id INTEGER PRIMARY KEY); CREATE TABLE switch_capture_ref(id INTEGER REFERENCES switch_capture_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER switch_receipt_fail AFTER INSERT ON local_work_inputs BEGIN INSERT INTO switch_capture_ref VALUES(1); END"))
    before=work_state(f)
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"storage_error")
    testing.expect(t,work_state(f)==before,"deferred COMMIT failure also preserves complete source state")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER switch_receipt_fail"))
    accepted:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    if !testing.expect_value(t,accepted.code,"ok") do return
    rows,_:=query(f.store.db,"SELECT dependent_id,dependent_generation,prerequisite_id,prerequisite_generation FROM local_work_inputs")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"dest","1","first","1"}}))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    replay:=execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,4000000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==accepted.body)
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_work_inputs),(SELECT count(*) FROM local_handoffs WHERE kind='lease.switch'),(SELECT count(*) FROM local_work_attempts WHERE task_id='dest')")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"1","1","1"}}))
    testing.expect_value(t,work_call(f,"task.reopen","consumed","Replace producer","first",work_task_revision(f,"first")).code,"operation_conflict")
}

@(test)
work_dynamic_legacy_edge_retires_old_consumer_and_pins_new_attempt_inputs :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    testing.expect_value(t,work_call(f,"chain.propose","plan",work_legacy_plan()).code,"ok")
    third:=`{"kind":"task","auto_approve":true,"tasks":[{"id":"third","title":"Dynamic producer","brief":{"goal":"Produce","acceptance":["Done"]}}]}`
    testing.expect_value(t,work_call(f,"chain.propose","extra_producer",third).code,"ok")
    testing.expect_value(t,advanced_call(f,"dependency.edit","first_edge",`{"prerequisite":"first","enabled":"1"}`,"second").code,"ok")
    work_finish(t,f,"first");work_bind(t,f,"second")
    old_raw:=work_second_claim_raw(f);old:=lease_invoke(f,old_raw,"",lease_child())
    if !testing.expect_value(t,old.code,"ok") do return
    testing.expect_value(t,advanced_call(f,"dependency.edit","dynamic_edge",`{"prerequisite":"third","enabled":"1"}`,"second").code,"ok")
    submit:=`{"requirements_revision":"1","head":"","summary":"Stale consumer"}`
    testing.expect_value(t,dependency_lifecycle_call(f,"second","legacy_lease",lease_child(),"lease.submit","old_submit",submit,result_cap(old),work_task_revision(f,"second")).code,"operation_conflict")
    c,_:=contracts.owner_parse(work_second_claim_raw(f),"lease_command")
    c["operation_id"]=json.String("new_claim");c["lease_id"]=json.String("new_lease")
    sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
    raw:=encode(c)
    testing.expect_value(t,lease_invoke(f,raw,"",lease_child()).code,"operation_conflict")
    work_finish(t,f,"third")
    accepted:=lease_invoke(f,raw,"",lease_child())
    if !testing.expect_value(t,accepted.code,"ok") do return
    rows,_:=query(f.store.db,"SELECT dependent_generation,prerequisite_id,prerequisite_generation FROM local_work_inputs ORDER BY dependent_generation,prerequisite_id")
    testing.expect_value(t,encode(rows),encode([3][3]string{{"1","first","1"},{"2","first","1"},{"2","third","1"}}))
    testing.expect_value(t,work_call(f,"task.reopen","dynamic_consumed","Replace dynamic output","third",work_task_revision(f,"third")).code,"operation_conflict")
    replay:=lease_invoke(f,old_raw,"",lease_child(),4000000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==old.body)
}
