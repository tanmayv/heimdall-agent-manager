#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

source_fact_test :: proc(episode,version,resolved:string)->string {
    return encode(doc(map[string]string{"origin_kind"="attention","origin_id"="origin","episode_id"=episode,"source_version"=version,"resolved"=resolved,"deadline_ms"="0","body"="sourcerecoveryneedle"}))
}
source_action_test :: proc(episode,version:string,fence:string="")->string {
    hash:=fence
    if hash=="" do hash=strings.repeat("0",64,context.temp_allocator)
    return encode(doc(map[string]string{"origin_kind"="attention","origin_id"="origin","episode_id"=episode,"source_version"=version,"consumer_fence_hash"=hash,"result"="exact result"}))
}
@(test)
source_resolved_card_is_discoverable_after_cold_restart :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"source.observe","fact",source_fact_test("old","7","0")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.escalate","escalate",source_action_test("old","7")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.observe","resolved",source_fact_test("old","8","1")).code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    r:=source_inventory(&f.store,"chain","",100)
    testing.expect(t,r.code=="ok" && strings.contains(r.body,"old") && strings.contains(r.body,"sourcerecoveryneedle"),"resolved producer with pending card survives cache/process loss")
    testing.expect(t,!exec(f.store.db,"DELETE FROM source_episodes"),"pending cards cannot be pruned as merely resolved")
    rows,_:=query(f.store.db,"SELECT resolved,ack_floor,retired_floor,delivered_floor,card_closed FROM source_episodes")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="0" && rows[0][2]=="0" && rows[0][3]=="0" && rows[0][4]=="0")
    claims,ok:=intent_claim_due(&f.store,1000);testing.expect(t,ok)
    for claim in claims {
        if claim.kind=="source.delivery" do testing.expect(t,intent_result(&f.store,claim,true,"local inbox materialized",1000))
    }
    rows,_=query(f.store.db,"SELECT resolved,ack_floor,retired_floor,delivered_floor,card_closed FROM source_episodes")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="0" && rows[0][2]=="0" && rows[0][3]=="7" && rows[0][4]=="0","delivery does not imply ACK, retirement or card closure")
    testing.expect_value(t,advanced_call(f,"source.resolve","close",source_action_test("old","8")).code,"ok")
    testing.expect(t,!strings.contains(source_inventory(&f.store,"chain","",100).body,"sourcerecoveryneedle"))
}
@(test)
source_old_resolved_episode_closes_independently_after_same_origin_recurrence :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"source.observe","fact",source_fact_test("old","7","0")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.escalate","escalate",source_action_test("old","7")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.observe","resolved",source_fact_test("old","8","1")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.observe","recurrence",source_fact_test("new","9","0")).code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,advanced_call(f,"source.resolve","stale_close",source_action_test("old","7")).code,"stale_revision")
    testing.expect_value(t,advanced_call(f,"source.resolve","close",source_action_test("old","8")).code,"ok")
    rows,_:=query(f.store.db,"SELECT episode_id,resolved,card_closed FROM source_episodes ORDER BY episode_id")
    testing.expect(t,len(rows)==2 && rows[0][0]=="new" && rows[0][1]=="0" && rows[0][2]=="0" && rows[1][0]=="old" && rows[1][1]=="1" && rows[1][2]=="1")
}
@(test)
source_exact_consumption_ack_retirement_and_commit_rollback :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    testing.expect_value(t,advanced_call(f,"source.observe","fact",source_fact_test("episode","1","0")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.consume","forged",source_action_test("episode","1")).code,"invalid_scope")
    action:=source_action_test("episode","1",payload_hash(cap))
    testing.expect(t,exec(f.store.db,`CREATE TABLE source_failure(id INTEGER PRIMARY KEY);
      CREATE TABLE source_failure_ref(id INTEGER REFERENCES source_failure(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER source_commit_failure AFTER INSERT ON source_consumptions BEGIN INSERT INTO source_failure_ref VALUES(1); END;`))
    testing.expect_value(t,advanced_call(f,"source.consume","consume",action).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM source_consumptions),(SELECT count(*) FROM command_receipts WHERE operation_id='consume'),(SELECT count(*) FROM runtime_intents WHERE operation_id='consume')")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER source_commit_failure"))
    testing.expect_value(t,advanced_call(f,"source.consume","consume",action).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.consume","duplicate",action).code,"operation_conflict")
    rows,_=query(f.store.db,"SELECT resolved,ack_floor,retired_floor,delivered_floor FROM source_episodes")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="0" && rows[0][3]=="0")
    testing.expect_value(t,advanced_call(f,"source.ack","ack_source",action).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.retire","retire_source",action).code,"ok")
    rows,_=query(f.store.db,"SELECT resolved,ack_floor,retired_floor,delivered_floor FROM source_episodes")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="1" && rows[0][2]=="1" && rows[0][3]=="0")
    testing.expect(t,strings.contains(search_for(f,"sourcerecoveryneedle").body,"source"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,strings.contains(search_for(f,"sourcerecoveryneedle").body,"source"))
}

@(test)
source_pending_card_pins_receipts_after_delivery_and_producer_resolution :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"source.observe","pin_fact",source_fact_test("old","7","0")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.escalate","pin_card",source_action_test("old","7")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.observe","pin_resolved",source_fact_test("old","8","1")).code,"ok")
    claims,ok:=intent_claim_due(&f.store,1000);testing.expect(t,ok)
    for claim in claims do testing.expect(t,intent_result(&f.store,claim,true,"settled",1000))
    _,ok=compact_receipts(&f.store,RECEIPT_RETENTION_MS+100000)
    testing.expect(t,ok)
    rows,_:=query(f.store.db,"SELECT count(*) FROM command_receipts WHERE operation_id IN('pin_fact','pin_card','pin_resolved')")
    testing.expect_value(t,rows[0][0],"3")
    testing.expect(t,strings.contains(source_inventory(&f.store,"chain","",100).body,"old"))
}

source_review_action_test :: proc(task,version,fence:string)->string {
    return encode(doc(map[string]string{"origin_kind"="local.review","origin_id"=task,"episode_id"="1","source_version"=version,"consumer_fence_hash"=fence,"result"="Exact committed review result"}))
}

@(test)
source_completed_review_consumption_ack_and_retire_survive_producer_advance :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Completed work"}`,cap).code,"ok")
    verdict:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","approve",verdict,result_cap(opened),"5").code,"ok")
    consumed,ok:=query(f.store.db,"SELECT source_version,consumer_fence_hash FROM source_consumptions WHERE origin_kind='local.review' AND origin_id='task'")
    producer,read:=query(f.store.db,"SELECT source_version,resolved,ack_floor,retired_floor FROM source_episodes WHERE origin_kind='local.review' AND origin_id='task'")
    if !testing.expect(t,ok && read && len(consumed)==1 && len(producer)==1) do return
    testing.expect(t,number(consumed[0][0])<number(producer[0][0]) && producer[0][1]=="1")
    action:=source_review_action_test("task",consumed[0][0],consumed[0][1])
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,advanced_call(f,"source.ack","exact_ack",action).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.retire","exact_retire",action).code,"ok")
    rows,_:=query(f.store.db,"SELECT source_version,resolved,ack_floor,retired_floor,(SELECT count(*) FROM source_consumptions) FROM source_episodes WHERE origin_kind='local.review' AND origin_id='task'")
    testing.expect(t,rows[0][0]==producer[0][0] && rows[0][1]=="1" && rows[0][2]==consumed[0][0] && rows[0][3]==consumed[0][0] && rows[0][4]=="1")
    latest:=source_review_action_test("task",producer[0][0],consumed[0][1])
    testing.expect_value(t,advanced_call(f,"source.ack","unconsumed_latest",latest).code,"invalid_scope")
    future:=source_review_action_test("task",fmt.tprintf("%d",number(producer[0][0])+1),consumed[0][1])
    testing.expect_value(t,advanced_call(f,"source.retire","future",future).code,"stale_revision")
    wrong:=source_review_action_test("task",consumed[0][0],strings.repeat("0",64,context.temp_allocator))
    testing.expect_value(t,advanced_call(f,"source.ack","wrong_fence",wrong).code,"invalid_scope")
    for method in ([3]string{"source.consume","source.escalate","source.resolve"}) {
        testing.expect_value(t,advanced_call(f,method,method,action).code,"stale_revision")
    }
}

@(test)
source_unresolved_producer_advance_preserves_exact_historical_consumption_floors :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    testing.expect_value(t,advanced_call(f,"source.observe","v7",source_fact_test("episode","7","0")).code,"ok")
    action:=source_action_test("episode","7",payload_hash(cap))
    testing.expect_value(t,advanced_call(f,"source.consume","consume_v7",action).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.observe","v8",source_fact_test("episode","8","0")).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.ack","ack_v7",action).code,"ok")
    testing.expect_value(t,advanced_call(f,"source.retire","retire_v7",action).code,"ok")
    rows,_:=query(f.store.db,"SELECT source_version,resolved,ack_floor,retired_floor FROM source_episodes WHERE origin_kind='attention'")
    testing.expect(t,rows[0][0]=="8" && rows[0][1]=="0" && rows[0][2]=="7" && rows[0][3]=="7")
    testing.expect_value(t,advanced_call(f,"source.consume","late_consume",action).code,"stale_revision")
}

source_workflow_lifecycle_test :: proc(f:^Fixture,task,method,op,payload,cap:string,child:Child={},revision:string="3",now:i64=1000)->Result {
    observed:=child
    if observed.instance=="" do observed=lease_child()
    raw:=lifecycle_raw(f,observed,method,op,payload,cap,revision)
    c,_:=contracts.owner_parse(raw,"lifecycle_command")
    c["task_id"]=json.String(task)
    c["request_expires_ms"]=json.String(fmt.tprintf("%d",now+1000))
    sig,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
    return execute_lifecycle(&f.store,encode(c),payload,cap,observed,f.owner,now,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
}

@(test)
source_workflow_retry_resolves_superseded_reviews_and_preserves_pending_cards :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    for pending in ([2]bool{false,true}) {
        f:=fixture(t);defer destroy(f);seed(t,f)
        testing.expect_value(t,advanced_call(f,"workflow.define","define",workflow_test_definition()).code,"ok")
        testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
        task:=workflow_task_id("chain","run","1","first")
        workflow_bind(t,f,task)
        claimed:=lease_invoke(f,workflow_lease_raw(f,task,"lease","claim"),"",lease_child())
        if !testing.expect_value(t,claimed.code,"ok") do return
        cap:=result_cap(claimed)
        for method in ([2]string{"requirements.present","requirements.ack"}) {
            testing.expect_value(t,source_workflow_lifecycle_test(f,task,method,method,`{"requirements_revision":"1"}`,cap).code,"ok")
        }
        testing.expect_value(t,source_workflow_lifecycle_test(f,task,"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Submitted old generation"}`,cap).code,"ok")
        opened:=source_workflow_lifecycle_test(f,task,"review.open","review_open",lifecycle_verdict(),"",child=lifecycle_reviewer(),revision="4")
        if !testing.expect_value(t,opened.code,"ok") do return
        before,_:=query(f.store.db,"SELECT source_version,deadline_ms FROM source_episodes WHERE origin_kind='local.review' AND origin_id=?",task)
        now:=i64(1000)
        if pending {
            now=number(before[0][1])
            testing.expect_value(t,advanced_call(f,"source.escalate","card",source_review_action_test(task,before[0][0],strings.repeat("0",64,context.temp_allocator)),now=now).code,"ok")
        }
        card_before,_:=query(f.store.db,"SELECT card_id,card_closed FROM source_episodes WHERE origin_kind='local.review' AND origin_id=?",task)
        testing.expect(t,exec(f.store.db,`CREATE TABLE retry_source_failure(id INTEGER PRIMARY KEY);
          CREATE TABLE retry_source_ref(id INTEGER REFERENCES retry_source_failure(id) DEFERRABLE INITIALLY DEFERRED);
          CREATE TRIGGER retry_source_commit_failure AFTER INSERT ON local_workflow_tasks WHEN NEW.execution=2 BEGIN INSERT INTO retry_source_ref VALUES(1); END;`))
        retry:=`{"run_id":"run","execution":"1"}`
        testing.expect_value(t,advanced_call(f,"workflow.retry","retry_failed",retry,now=now).code,"storage_error")
        unchanged,_:=query(f.store.db,"SELECT resolved,source_version,(SELECT current_execution FROM local_workflow_runs),(SELECT count(*) FROM command_receipts WHERE operation_id='retry_failed'),(SELECT count(*) FROM local_review_sessions) FROM source_episodes WHERE origin_kind='local.review' AND origin_id=?",task)
        testing.expect(t,unchanged[0][0]=="0" && unchanged[0][1]==before[0][0] && unchanged[0][2]=="1" && unchanged[0][3]=="0" && unchanged[0][4]=="1")
        testing.expect(t,exec(f.store.db,"DROP TRIGGER retry_source_commit_failure"))
        retried:=advanced_call(f,"workflow.retry","retry",retry,now=now)
        testing.expect_value(t,retried.code,"ok")
        close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
        rows,_:=query(f.store.db,"SELECT resolved,source_version,card_id,card_closed,ack_floor,retired_floor,(SELECT count(*) FROM source_consumptions) FROM source_episodes WHERE origin_kind='local.review' AND origin_id=?",task)
        testing.expect(t,rows[0][0]=="1" && number(rows[0][1])==retried.seq && rows[0][3]=="0" && rows[0][4]=="0" && rows[0][5]=="0" && rows[0][6]=="0","retry resolves the producer without inventing ACK, retirement, consumption or closure")
        testing.expect(t,rows[0][2]==card_before[0][0] && rows[0][3]==card_before[0][1])
        sessions,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_review_sessions),(SELECT count(*) FROM local_reviews)")
        testing.expect(t,sessions[0][0]=="0" && sessions[0][1]=="0")
        testing.expect_value(t,source_workflow_lifecycle_test(f,task,"review.post","late_review",lifecycle_verdict(),result_cap(opened),child=lifecycle_reviewer(),revision="4",now=now).code,"stale_revision")
        inventory:=source_inventory(&f.store,"chain","",100)
        testing.expect(t,strings.contains(inventory.body,task)==pending)
        if pending {
            testing.expect(t,rows[0][2]!="")
            testing.expect_value(t,advanced_call(f,"source.resolve","stale_close_old",source_review_action_test(task,before[0][0],strings.repeat("0",64,context.temp_allocator)),now=now).code,"stale_revision")
            testing.expect_value(t,advanced_call(f,"source.resolve","close_old",source_review_action_test(task,rows[0][1],strings.repeat("0",64,context.temp_allocator)),now=now).code,"ok")
            testing.expect(t,!strings.contains(source_inventory(&f.store,"chain","",100).body,task))
        }
    }
}
