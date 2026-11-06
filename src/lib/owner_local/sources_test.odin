#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:strings"
import "core:testing"

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
