package owner_local

import "core:fmt"
import "core:mem"
import "core:strings"

// A delivery owner retains every external outcome until it has been persisted
// or its exact claim is durably obsolete. Capacity matches one claim batch.
// The queue contains only result/fence identifiers, never the payload body.
Intent_Completion :: struct {
    claim:Intent_Claim,
    success:bool,
    result:string,
    completed_ms:i64,
}
Intent_Completions :: struct {
    items:[20]Intent_Completion,
    count:int,
    allocator:mem.Allocator,
}

intent_completion_keep :: proc(q:^Intent_Completions,claim:Intent_Claim,success:bool,result:string,now:i64,allocator:=context.allocator) -> bool {
    if q.count>=len(q.items) || len(result)>8192 || now<0 || now>0x7fffffffffffffff-60000 do return false
    if q.count==0 do q.allocator=allocator
    retained:=Intent_Claim{id=strings.clone(claim.id,q.allocator),digest=strings.clone(claim.digest,q.allocator),incarnation=claim.incarnation,attempt=claim.attempt}
    q.items[q.count]=Intent_Completion{retained,success,strings.clone(result,q.allocator),now}
    q.count+=1
    return true
}

intent_completion_remove :: proc(q:^Intent_Completions,index:int) {
    item:=q.items[index]
    delete(item.claim.id,q.allocator);delete(item.claim.digest,q.allocator);delete(item.result,q.allocator)
    for i:=index;i<q.count-1;i+=1 do q.items[i]=q.items[i+1]
    q.count-=1;q.items[q.count]={}
}
intent_completions_destroy :: proc(q:^Intent_Completions) {
    for q.count>0 do intent_completion_remove(q,q.count-1)
}

// Recheck under the writer transaction. A failed COMMIT may be ambiguous to a
// caller; a durable nonmatching claim must not be overwritten by an old result.
intent_claim_current :: proc(s:^Store,claim:Intent_Claim) -> (bool,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false,false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT state,claim_incarnation,attempts,payload_digest FROM runtime_intents WHERE intent_id=? AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=runtime_intents.intent_id)",claim.id)
    if !ok do return false,false
    if len(rows)==0 { if !transaction_commit(&tx) do return false,false; return false,true }
    row:=rows[0]
    current:=row[0]=="claimed" && row[1]==fmt.tprintf("%d",claim.incarnation) && row[2]==fmt.tprintf("%d",claim.attempt) && row[3]==claim.digest
    if !transaction_commit(&tx) do return false,false
    return current,true
}

// Run before claiming another batch. Failure retains the original completion,
// including its retry floor, across request temp-allocator resets. It never
// repeats external I/O. Process death instead uses Store.open's durable recovery.
intent_completions_flush :: proc(s:^Store,q:^Intent_Completions) -> bool {
    for q.count>0 {
        item:=q.items[0]
        if !intent_result(s,item.claim,item.success,item.result,item.completed_ms) {
            current,read:=intent_claim_current(s,item.claim)
            if !read || current do return false
        }
        intent_completion_remove(q,0)
    }
    return true
}

// Full immutable dispatch snapshot recheck after releasing the owner mutex.
// Unlike the minimal retained completion identity, this also binds the route,
// payload and exact fence supplied to external I/O.
intent_claim_exact :: proc(s:^Store,claim:Intent_Claim)->(current:bool,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false,false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,"SELECT 1 FROM runtime_intents WHERE intent_id=? AND chain_id=? AND kind=? AND destination_bridge=? AND exact_fence_json=? AND payload_json=? AND payload_digest=? AND claim_incarnation=? AND attempts=? AND state='claimed' AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=runtime_intents.intent_id)",
        claim.id,claim.chain,claim.kind,claim.destination,claim.fence,claim.payload,claim.digest,fmt.tprintf("%d",claim.incarnation),fmt.tprintf("%d",claim.attempt))
    if !read || !transaction_commit(&tx) do return false,false
    return claim.incarnation==s.incarnation && len(rows)==1,true
}
