#+feature dynamic-literals
package owner_local

import "core:fmt"
import "core:encoding/json"
import contracts "odin_test:contracts"

payload_hash :: contracts.owner_payload_digest
Intent_Input :: struct {
    chain,principal,operation:string,
    seq:i64,
    kind,destination,fence,payload:string,
}
Intent_Claim :: struct {
    id,chain,kind,destination,fence,payload,digest:string,
    incarnation,attempt:i64,
}

// Only a current transaction may enqueue. The source receipt must already be
// present in that transaction. A deterministic target identity prevents a
// caller from minting a new effect when a prior outcome is unknown.
intent_enqueue :: proc(tx:^Transaction,input:Intent_Input) -> bool {
    if !transaction_current(tx) || input.seq<1 || input.kind=="" || len(input.payload)>contracts.OWNER_DOCUMENT_MAX || len(input.fence)>8192 do return false
    s:=tx.store
    rows,ok:=query(s.db,"SELECT commit_seq FROM command_receipts WHERE principal_id=? AND operation_id=? AND chain_id=?",input.principal,input.operation,input.chain)
    if !ok || len(rows)!=1 || number(rows[0][0])!=input.seq do return false
    id:=payload_hash(encode([6]string{s.account,input.chain,input.principal,input.operation,input.kind,input.destination}))
    digest:=payload_hash(input.payload)
    existing,found:=query(s.db,"SELECT payload_digest,exact_fence_json,commit_seq FROM runtime_intents WHERE principal_id=? AND operation_id=? AND kind=? AND destination_bridge=?",input.principal,input.operation,input.kind,input.destination)
    if !found do return false
    if len(existing)>0 do return existing[0][0]==digest && existing[0][1]==input.fence && number(existing[0][2])==input.seq
    _,ok=query(s.db,`INSERT INTO runtime_intents(intent_id,chain_id,commit_seq,payload_json,principal_id,operation_id,
     kind,destination_bridge,exact_fence_json,payload_digest) VALUES(?,?,?,?,?,?,?,?,?,?)`,id,input.chain,fmt.tprintf("%d",input.seq),input.payload,
     input.principal,input.operation,input.kind,input.destination,input.fence,digest)
    return ok
}

// Separate consumers claim only their own effects. Filtering happens before
// LIMIT so an offline executor cannot starve registry/control delivery.
Intent_Consumer :: enum { All, Owner, Executor }
intent_claim_due :: proc(s:^Store,now:i64,limit:=20,consumer:Intent_Consumer=.All) -> (claims:[dynamic]Intent_Claim,ok:bool) {
    now:=store_now(s,now) // C1: monotonic clamp, never refuse on the clock
    if now<0 || limit<1 || limit>20 do return nil,false
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,false
    defer transaction_rollback(&tx)
    state,read:=query(s.db,"SELECT clock_high_ms,recovery_state FROM runtime_database WHERE singleton=1")
    if !read || len(state)!=1 do return nil,false
    if now<number(state[0][0]) { _=mark_clock_uncertain(&tx);return nil,false }
    if state[0][1]!="ready" do return nil,false
    rows,rows_ok:=query(s.db,`SELECT intent_id,chain_id,kind,destination_bridge,exact_fence_json,payload_json,payload_digest,attempts
     FROM runtime_intents WHERE state='pending' AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=runtime_intents.intent_id) AND next_retry_ms<=?
       AND (?='0' OR (?='2' AND (kind IN('executor.activate','executor.heartbeat','executor.notification') OR kind LIKE 'executor.stop:%')) OR
         (?='1' AND kind IN('registry','registry.prepare','source.delivery','merge','stop','checkpoint')))
     ORDER BY commit_seq,intent_id LIMIT ?`,fmt.tprintf("%d",now),fmt.tprintf("%d",int(consumer)),fmt.tprintf("%d",int(consumer)),fmt.tprintf("%d",int(consumer)),fmt.tprintf("%d",limit))
    if !rows_ok do return nil,false
    claims=make([dynamic]Intent_Claim,context.temp_allocator)
    for row in rows {
        if payload_hash(row[5])!=row[6] || number(row[7])==0x7fffffffffffffff do return nil,false
        attempt:=number(row[7])+1
        if _,updated:=query(s.db,"UPDATE runtime_intents SET state='claimed',attempts=?,claim_incarnation=? WHERE intent_id=?",fmt.tprintf("%d",attempt),fmt.tprintf("%d",s.incarnation),row[0]);!updated do return nil,false
        append(&claims,Intent_Claim{row[0],row[1],row[2],row[3],row[4],row[5],row[6],s.incarnation,attempt})
    }
    if len(claims)>0 {
        if _,updated:=query(s.db,"UPDATE runtime_database SET clock_high_ms=max(clock_high_ms,CAST(? AS INTEGER)) WHERE singleton=1",fmt.tprintf("%d",now));!updated do return nil,false
    }
    if !transaction_commit(&tx) do return nil,false
    return claims,true
}

// Successful results are immutable. A failed/unknown external outcome retries
// the same effect with a bounded delay; no payload may be replaced on retry.
intent_result :: proc(s:^Store,claim:Intent_Claim,success:bool,result:string,now:i64) -> bool {
    now:=store_now(s,now) // C1: decide and stamp with max(caller clock, store clock)
    context.allocator=context.temp_allocator
    if now<0 || now>0x7fffffffffffffff-60000 || len(result)>8192 do return false
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    if claim.incarnation!=s.incarnation do return false
    metadata,meta_ok:=query(s.db,"SELECT kind,chain_id,exact_fence_json FROM runtime_intents WHERE intent_id=?",claim.id)
    if !meta_ok || len(metadata)!=1 do return false
    if metadata[0][0]=="merge" {
        exact:=claim;exact.kind="merge";exact.chain=metadata[0][1];exact.fence=metadata[0][2]
        if !merge_claim_current(s,exact) do return false
    }
    state:="pending";published:="0"
    if success {state="settled";published="1"}
    // Retry floor persists across restarts. Never decrement the clock watermark
    // or permit a delayed completion to overwrite the current claimant.
    delay:=min(i64(60000),1000*min(claim.attempt,i64(60)))
    rows,ok:=query(s.db,`UPDATE runtime_intents SET state=?,published=?,result_json=?,next_retry_ms=?
     WHERE intent_id=? AND state='claimed' AND claim_incarnation=? AND attempts=? AND payload_digest=?
       AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=runtime_intents.intent_id)
     RETURNING intent_id,kind,chain_id,exact_fence_json`,
     state,published,result,fmt.tprintf("%d",now+delay),claim.id,fmt.tprintf("%d",claim.incarnation),fmt.tprintf("%d",claim.attempt),claim.digest)
    if !ok || len(rows)!=1 do return false
    if rows[0][1]=="source.delivery" && success && !source_delivered(s,rows[0][2],rows[0][3]) do return false
    if rows[0][1]=="source.delivery" && success {
        runtime,read:=query(s.db,"SELECT commit_seq,clock_high_ms,(SELECT count(*) FROM local_changes) FROM runtime_database")
        if !read || len(runtime)!=1 || number(runtime[0][2])>=1000000 do return false
        seq:=number(runtime[0][0])+1
        if !workflow_refresh(s) do return false
        if !event_record(&tx,seq,now,rows[0][2],"","bridge",s.owner,"source.delivered",claim.id,"",rows[0][3],"",result) do return false
        if _,ok:=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),rows[0][2],"source.delivered",claim.id,"1",claim.id);!ok do return false
        if _,ok:=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=max(clock_high_ms,CAST(? AS INTEGER)) WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",max(now,number(runtime[0][1]))));!ok do return false
    }
    if rows[0][1]=="merge" {
        v,valid:=contracts.owner_request_document(rows[0][3])
        f,obj:=v.(json.Object)
        if !valid || !obj do return false
        next:="merge_blocked"
        if success {
            if result!=merge_prepared(s,claim) || result=="" do return false
            next="done"
        }
        updated,read:=query(s.db,"UPDATE lifecycle_state SET state=?,merge_receipt=? WHERE chain_id=? AND task_id=? AND attempt=? AND state IN('merge_pending','merge_blocked') RETURNING attempt",next,result,rows[0][2],field(f,"task_id"),field(f,"attempt"))
        if !read || len(updated)!=1 do return false
        task_rows,task_ok:=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=? RETURNING revision",rows[0][2],field(f,"task_id"))
        if !task_ok || len(task_rows)!=1 do return false
        runtime,runtime_ok:=query(s.db,"SELECT commit_seq,clock_high_ms,(SELECT count(*) FROM local_changes) FROM runtime_database WHERE singleton=1")
        if !runtime_ok || len(runtime)!=1 || number(runtime[0][2])>=1000000 do return false
        seq:=number(runtime[0][0])+1
        kind:="merge.failed"
        if success do kind="merge.merged"
        if success && !workflow_settle_deferred(s,claim.id,seq,result) do return false
        if _,ok:=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),rows[0][2],kind,field(f,"task_id"),task_rows[0][0],claim.id);!ok do return false
        if _,ok:=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=max(clock_high_ms,CAST(? AS INTEGER)) WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",max(now,number(runtime[0][1]))));!ok do return false
        if !workflow_refresh(s) do return false
        if !event_record(&tx,seq,now,rows[0][2],field(f,"task_id"),"bridge",s.owner,kind,claim.id,"",rows[0][3],"",result) do return false
        command:=doc(map[string]string{"chain_id"=rows[0][2],"task_id"=field(f,"task_id"),"method"="merge.result"})
        if !source_lifecycle(&tx,command,nil,seq,now) do return false
    }
    if !workflow_refresh(s) do return false
    return transaction_commit(&tx)
}
