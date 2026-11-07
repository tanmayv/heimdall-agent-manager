package owner_local

import "core:fmt"
import "core:testing"

@(test)
outbox_consumers_filter_before_limit_and_preserve_unknown_effects :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    tx:Transaction
    if !testing.expect(t,transaction_begin(&f.store,&tx)) do return
    // More executor effects than one batch must not starve registry work.
    for i in 0..<25 {
        testing.expect(t,intent_enqueue(&tx,{"chain","device","create",1,"executor.activate",fmt.tprintf("executor_%d",i),"{}","original action"}))
    }
    testing.expect(t,intent_enqueue(&tx,{"chain","device","create",1,"future.effect","","{}","future payload"}))
    testing.expect(t,transaction_commit(&tx))
    registry,read:=intent_claim_due(&f.store,1000,20,.Owner)
    testing.expect(t,read && len(registry)==2)
    for c in registry do testing.expect_value(t,c.kind,"registry")
    activations,claimed:=intent_claim_due(&f.store,1000,20,.Executor)
    testing.expect(t,claimed && len(activations)==20)
    for c in activations do testing.expect_value(t,c.kind,"executor.activate")
    more,ok:=intent_claim_due(&f.store,1000,20,.Owner)
    testing.expect(t,ok && len(more)==0)
    more,ok=intent_claim_due(&f.store,1000,20,.Executor)
    testing.expect(t,ok && len(more)==5)
    rows,queried:=query(f.store.db,"SELECT state,attempts FROM runtime_intents WHERE kind='future.effect'")
    testing.expect(t,queried && len(rows)==1 && rows[0][0]=="pending" && rows[0][1]=="0")
    // Unknown external outcomes retry the original identity in the same lane.
    first:=activations[0]
    testing.expect(t,intent_result(&f.store,first,false,"lost reply",1000))
    more,ok=intent_claim_due(&f.store,1999,20,.Executor)
    testing.expect(t,ok && len(more)==0)
    more,ok=intent_claim_due(&f.store,2000,20,.Executor)
    testing.expect(t,ok && len(more)==1 && more[0].id==first.id && more[0].attempt==2 &&
        more[0].payload==first.payload && more[0].digest==first.digest)
}

@(test)
outbox_invalidation_during_delivery_cannot_settle_or_retry_obsolete_claim :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for success in ([2]bool{false,true}) {
        f:=fixture(t);defer destroy(f);seed(t,f)
        claims,ok:=intent_claim_due(&f.store,1000,1,.Owner)
        if !testing.expect(t,ok && len(claims)==1) do continue
        claim:=claims[0]
        current,checked:=intent_claim_exact(&f.store,claim)
        testing.expect(t,checked && current)
        changed:=claim;changed.destination="different"
        current,checked=intent_claim_exact(&f.store,changed)
        testing.expect(t,checked && !current)
        changed=claim;changed.payload="different"
        current,checked=intent_claim_exact(&f.store,changed)
        testing.expect(t,checked && !current)
        _,invalidated:=query(f.store.db,"INSERT INTO intent_invalidations VALUES(?,'device','cancel')",claim.id)
        testing.expect(t,invalidated)
        testing.expect(t,!intent_result(&f.store,claim,success,"late result",1001))
        q:Intent_Completions;defer intent_completions_destroy(&q)
        testing.expect(t,intent_completion_keep(&q,claim,success,"late result",1001))
        testing.expect(t,intent_completions_flush(&f.store,&q) && q.count==0)
        rows,read:=query(f.store.db,"SELECT state,result_json,next_retry_ms FROM runtime_intents WHERE intent_id=?",claim.id)
        testing.expect(t,read && len(rows)==1 && rows[0][0]=="claimed" && rows[0][1]=="" && rows[0][2]=="0")
        current,checked=intent_claim_exact(&f.store,claim)
        testing.expect(t,checked && !current)
    }
}
