#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// One immutable stop target per reservation, including multi-task retirement.
execution_stop_kind :: proc(kind:string)->bool {return strings.has_prefix(kind,"executor.stop:")}
execution_stop_intent :: proc(tx:^Transaction,c:json.Object,child_raw:string,seq:i64,task:string)->(bool,bool) {
    rows,read:=query(tx.store.db,"SELECT prepare_json FROM owner_execution_journal WHERE chain_id=? AND task_id=? AND child_json=? AND state='committed'",
        field(c,"chain_id"),task,child_raw)
    if !read do return false,false
    if len(rows)==0 do return false,true
    if len(rows)!=1 do return true,false
    p,valid:=contracts.executor_parse(rows[0][0],"prepare")
    if !valid do return true,false
    if field(p,"executor_bridge_id")==tx.store.owner do return false,true
    return true,intent_enqueue(tx,{field(c,"chain_id"),field(c,"principal_id"),field(c,"operation_id"),seq,
        fmt.tprintf("executor.stop:%s",field(p,"reservation_id")),field(p,"executor_bridge_id"),rows[0][0],
        encode(struct{task_id,method,child:string}{task,field(c,"method"),child_raw})})
}

// Repair retained pre-fix generic stops, even if the wrong local observer
 // previously marked them settled. Preserve old evidence; append the exact
 // executor intent from its original committed cancellation and invalidate the
 // old consumer. Bounded and idempotent, with no new task authority.
execution_stop_recover :: proc(s:^Store)->bool {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,`SELECT i.intent_id,i.chain_id,i.principal_id,i.operation_id,i.commit_seq,i.exact_fence_json,
        j.task_id,r.method FROM runtime_intents i
      JOIN command_receipts r ON r.principal_id=i.principal_id AND r.operation_id=i.operation_id AND r.commit_seq=i.commit_seq AND r.chain_id=i.chain_id
      JOIN control_notices n ON n.principal_id=i.principal_id AND n.operation_id=i.operation_id AND n.kind='stop' AND n.child_json=i.exact_fence_json
      JOIN owner_execution_journal j ON j.chain_id=i.chain_id AND j.task_id=n.task_id AND j.child_json=n.child_json AND j.state='committed'
      JOIN local_leases l ON l.lease_id=j.lease_id AND l.retired_seq IS NOT NULL
      WHERE i.kind='stop' AND json_extract(j.prepare_json,'$.executor_bridge_id')!=?
        AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=i.intent_id)
      ORDER BY i.intent_id LIMIT 20`,s.owner)
    if !read do return false
    for row in rows {
        c:=doc(map[string]string{"chain_id"=row[1],"principal_id"=row[2],"operation_id"=row[3],"task_id"=row[6],"method"=row[7]})
        handled,ok:=execution_stop_intent(&tx,c,row[5],number(row[4]),row[6])
        if !handled || !ok do return false
        if _,written:=query(s.db,"INSERT OR IGNORE INTO intent_invalidations VALUES(?,?,?)",row[0],row[2],row[3]);!written do return false
    }
    return transaction_commit(&tx)
}

// Terminal retirement evidence, not an active assignment/lease fence. A new
// assignment must never retarget an old stop. Caller holds an owner transaction.
execution_stop_source :: proc(s:^Store,c:Intent_Claim)->(json.Object,string,i64,string) {
    if !transaction_current(s.active) || !execution_stop_kind(c.kind) || c.incarnation!=s.incarnation ||
       c.digest!=payload_hash(c.payload) {return nil,"",0,"invalid_scope"}
    rows,read:=query(s.db,`SELECT j.prepare_json,j.receipt_json,i.commit_seq
      FROM runtime_intents i JOIN command_receipts r ON r.principal_id=i.principal_id AND r.operation_id=i.operation_id
        AND r.commit_seq=i.commit_seq AND r.chain_id=i.chain_id
      JOIN control_notices n ON n.principal_id=i.principal_id AND n.operation_id=i.operation_id AND n.chain_id=i.chain_id AND n.kind='stop'
      JOIN owner_execution_journal j ON j.prepare_json=i.exact_fence_json AND j.chain_id=i.chain_id AND j.task_id=n.task_id
        AND j.child_json=n.child_json AND (j.state='committed' OR EXISTS(
          SELECT 1 FROM owner_execution_stop_steps z WHERE z.intent_id=i.intent_id AND z.outcome='released'))
      JOIN local_leases l ON l.lease_id=j.lease_id AND l.retired_seq IS NOT NULL
      WHERE i.intent_id=? AND i.kind=? AND i.state='claimed' AND i.claim_incarnation=? AND i.attempts=?
        AND i.payload_json=? AND i.payload_digest=? AND i.exact_fence_json=? AND i.destination_bridge=?
        AND json_extract(i.payload_json,'$.child')=n.child_json
        AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=i.intent_id)`,
        c.id,c.kind,fmt.tprintf("%d",c.incarnation),fmt.tprintf("%d",c.attempt),c.payload,c.digest,c.fence,c.destination)
    if !read do return nil,"",0,"storage_error"
    if len(rows)!=1 do return nil,"",0,"invalid_scope"
    p,parsed:=contracts.executor_parse(rows[0][0],"prepare")
    receipt,valid:=contracts.executor_parse(rows[0][1],"receipt")
    if !parsed || !valid || field(p,"executor_bridge_id")!=c.destination || field(p,"chain_id")!=c.chain ||
       c.kind!=fmt.tprintf("executor.stop:%s",field(p,"reservation_id")) {return nil,"",0,"invalid_scope"}
    return p,field(receipt,"launch_key"),number(rows[0][2]),"ok"
}

execution_stop_request :: proc(s:^Store,c:Intent_Claim,key:contracts.Owner_Verified_Key,now:i64,sign:Signer)->Result {
    if !execution_owner_key(s,key) || sign.sign==nil || now<0 || now>0x7fffffffffffffff-contracts.EXECUTOR_TRANSPORT_TTL_MS do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    p,_,seq,code:=execution_stop_source(s,c)
    if code!="ok" do return fail(code)
    prior,read:=query(s.db,"SELECT step,phase,request,receipt,outcome FROM owner_execution_stop_steps WHERE intent_id=? ORDER BY step DESC LIMIT 1",c.id)
    if !read do return fail("storage_error")
    step:i64=1
    phase:="query"
    observation:json.Object
    if len(prior)==1 {
        row:=prior[0];step=number(row[0])+1
        previous,parsed:=contracts.executor_parse(row[2],"action")
        if !parsed do return fail("storage_error")
        if row[4]=="released" {
            if !transaction_commit(&tx) do return fail("storage_error")
            return Result{code="released",body=row[3]}
        }
        if row[4]=="pending" && contracts.executor_number(previous,"owner_incarnation")==s.incarnation &&
           contracts.executor_number(previous,"request_expires_ms")>now {
            if !transaction_commit(&tx) do return fail("storage_error")
            return Result{code="ok",body=row[2],replay=true}
        }
        if row[1]=="query" && row[4]=="accepted" && contracts.executor_number(previous,"owner_incarnation")==s.incarnation &&
           contracts.executor_number(previous,"request_expires_ms")>now {
            observation,_=contracts.executor_parse(row[3],"receipt");phase="stop"
        }
    }
    count,checked:=query(s.db,"SELECT count(*) FROM owner_execution_stop_steps")
    if !checked || number(count[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    action:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"owner_bridge_id"=s.owner,"chain_id"=c.chain,
        "operation_id"=payload_hash(encode([3]string{c.id,fmt.tprintf("%d",step),phase})),
        "method"=phase,"owner_incarnation"=fmt.tprintf("%d",s.incarnation),"owner_commit_seq"=fmt.tprintf("%d",seq),
        "prepare_digest"="","key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator),
        "deadline_version"="1","expires_ms"=field(p,"prepare_until_ms"),
        "request_expires_ms"=fmt.tprintf("%d",now+contracts.EXECUTOR_TRANSPORT_TTL_MS)})
    for name in ([5]string{"executor_bridge_id","reservation_id","executor_incarnation","grant_generation","hard_ms"}) do action[name]=p[name]
    digest,_:=contracts.executor_digest("prepare",p);action["prepare_digest"]=json.String(digest)
    if phase=="stop" {
        for name in ([3]string{"executor_incarnation","deadline_version","expires_ms"}) do action[name]=observation[name]
    }
    signature,signed:=sign.sign(sign.ctx,"executor.action",action)
    if !signed do return fail("storage_error")
    action["signature"]=json.String(signature)
    if !contracts.executor_verify("action",action,key) do return fail("storage_error")
    raw:=encode(action)
    if _,ok:=query(s.db,"INSERT INTO owner_execution_stop_steps(intent_id,step,phase,request) VALUES(?,?,?,?)",c.id,fmt.tprintf("%d",step),phase,raw);!ok do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=raw}
}

// Persist a correlated signed query/stop outcome before the worker advances.
// Query refreshes only serving metadata. A stopping receipt is not absence.
execution_stop_accept :: proc(s:^Store,c:Intent_Claim,request,raw:string,key:contracts.Owner_Verified_Key,now:i64)->Result {
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    p,launch,seq,code:=execution_stop_source(s,c)
    if code!="ok" do return fail(code)
    if !remote_assignment_key_matches(s,p,key) do return fail("invalid_scope")
    rows,read:=query(s.db,"SELECT step,phase,request,outcome,receipt FROM owner_execution_stop_steps WHERE intent_id=? ORDER BY step DESC LIMIT 1",c.id)
    if !read do return fail("storage_error")
    if len(rows)!=1 || rows[0][2]!=request do return fail("operation_conflict")
    row:=rows[0]
    if row[3]!="pending" {
        if row[4]!=raw do return fail("operation_conflict")
        if !transaction_commit(&tx) do return fail("storage_error")
        return Result{code=("released" if row[3]=="released" else "accepted"),body=raw,replay=true}
    }
    q,parsed:=contracts.executor_parse(request,"action")
    r,valid:=contracts.executor_parse(raw,"receipt")
    if !parsed || !valid do return fail("invalid_scope")
    matched:=contracts.executor_query_receipt_matches(r,q,key,now,launch) if row[1]=="query" else
        contracts.executor_receipt_matches(r,q,"action",key,now,false) && field(r,"launch_key")==launch
    if !matched do return fail("invalid_scope")
    state:=field(r,"state")
    if row[1]=="stop" && state!="stopping" && state!="released" do return fail("invalid_scope")
    outcome:="released" if state=="released" else "accepted"
    if _,ok:=query(s.db,"UPDATE owner_execution_stop_steps SET receipt=?,outcome=? WHERE intent_id=? AND step=?",raw,outcome,c.id,row[0]);!ok do return fail("storage_error")
    if outcome=="released" {
        if _,ok:=query(s.db,"UPDATE owner_execution_journal SET state='retired',retired_seq=? WHERE prepare_json=? AND state='committed'",fmt.tprintf("%d",seq),c.fence);!ok do return fail("storage_error")
    }
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code=("released" if outcome=="released" else "accepted"),body=raw}
}
