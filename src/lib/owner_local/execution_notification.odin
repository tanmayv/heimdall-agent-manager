#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// Only the existing task.hold producer can make this intent. The immutable
// original prepare is selected in the same transaction as its control notice.
execution_notification_intent :: proc(tx:^Transaction,c:json.Object,child_raw:string,seq:i64)->(handled,ok:bool) {
    if field(c,"method")!="task.hold" do return false,true
    rows,read:=query(tx.store.db,`SELECT j.prepare_json FROM owner_execution_journal j
      JOIN local_leases l ON l.lease_id=j.lease_id
      WHERE j.chain_id=? AND j.task_id=? AND j.child_json=? AND j.state='committed' AND l.retired_seq IS NULL`,
      field(c,"chain_id"),field(c,"task_id"),child_raw)
    if !read do return false,false
    if len(rows)==0 do return false,true
    if len(rows)!=1 do return true,false
    p,parsed:=contracts.executor_parse(rows[0][0],"prepare")
    if !parsed do return true,false
    if field(p,"executor_bridge_id")==tx.store.owner do return false,true
    payload:=encode(doc(map[string]string{"task_id"=field(c,"task_id"),"method"="task.hold","child"=child_raw}))
    return true,intent_enqueue(tx,Intent_Input{chain=field(c,"chain_id"),principal=field(c,"principal_id"),operation=field(c,"operation_id"),
      seq=seq,kind="executor.notification",destination=field(p,"executor_bridge_id"),fence=rows[0][0],payload=payload})
}

// Caller holds an owner transaction. This checks checkpoint authority only;
// it never requests new work admission or retargets a replacement assignment.
execution_notification_current_locked :: proc(s:^Store,c:Intent_Claim,now:i64)->(json.Object,i64,string) {
    now:=store_now(s,now) // C1: decide and stamp with max(caller clock, store clock)
    if !transaction_current(s.active) || c.kind!="executor.notification" || c.incarnation!=s.incarnation ||
       c.digest!=payload_hash(c.payload) {return nil,0,"no_current_target"}
    // The held-control join below bypasses control_active, so apply the same
    // migration quarantine gate here: no notice is signed or fenced for it.
    if migration_quarantined(s,c.chain) do return nil,0,"no_current_target"
    rows,read:=query(s.db,`SELECT b.document,i.commit_seq,l.expires_ms,l.hard_ms,l.deadline_version,j.lease_command,j.child_json,
        d.clock_high_ms,d.recovery_state
      FROM runtime_intents i JOIN command_receipts r
        ON r.principal_id=i.principal_id AND r.operation_id=i.operation_id AND r.commit_seq=i.commit_seq
      JOIN control_notices n ON n.principal_id=i.principal_id AND n.operation_id=i.operation_id
        AND n.chain_id=i.chain_id AND n.task_id=r.task_id AND n.kind='checkpoint'
      JOIN owner_execution_journal j ON j.prepare_json=i.exact_fence_json AND j.chain_id=i.chain_id
        AND j.task_id=n.task_id AND j.child_json=n.child_json AND j.state='committed'
      JOIN local_leases l ON l.lease_id=j.lease_id
      JOIN owner_execution_bootstraps b ON b.reservation_id=j.reservation_id
      JOIN local_controls h ON h.chain_id=j.chain_id AND h.task_id=j.task_id AND h.mode='held'
      JOIN runtime_database d ON d.singleton=1
      WHERE i.intent_id=? AND i.kind='executor.notification' AND i.state='claimed' AND i.claim_incarnation=? AND i.attempts=?
        AND i.payload_digest=? AND i.payload_json=? AND i.exact_fence_json=? AND i.destination_bridge=?
        AND r.method='task.hold' AND r.chain_id=i.chain_id AND l.retired_seq IS NULL
        AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=i.intent_id)`,
        c.id,fmt.tprintf("%d",c.incarnation),fmt.tprintf("%d",c.attempt),c.digest,c.payload,c.fence,c.destination)
    if !read do return nil,0,"storage_error"
    if len(rows)!=1 do return nil,0,"no_current_target"
    row:=rows[0]
    p,parsed:=contracts.executor_parse(c.fence,"prepare")
    b,valid:=contracts.executor_parse(row[0],"bootstrap")
    lease,leased:=contracts.owner_parse(row[5],"lease_command")
    value,payload_ok:=contracts.owner_content_document(c.payload);payload,obj:=value.(json.Object)
    if !parsed || !valid || !leased || !payload_ok || !obj || field(payload,"method")!="task.hold" ||
       field(payload,"task_id")!=field(p,"task_id") || field(payload,"child")!=row[6] ||
       field(p,"executor_bridge_id")!=c.destination || field(p,"chain_id")!=c.chain ||
       contracts.executor_number(b,"owner_incarnation")!=s.incarnation || now<0 || now<number(row[7]) || row[8]!="ready" ||
       now>=number(row[2]) || now>=number(row[3]) {return nil,0,"no_current_target"}
    _,assigned:=execution_assignment(s,p,lease,false)
    if !assigned do return nil,0,"no_current_target"
    b["expires_ms"]=json.String(row[2]);b["hard_ms"]=json.String(row[3]);b["deadline_version"]=json.String(row[4])
    return b,number(row[1]),"ok"
}

execution_notification :: proc(s:^Store,c:Intent_Claim,key:contracts.Owner_Verified_Key,now:i64,sign:Signer)->Result {
    now:=store_now(s,now) // C1: the store's single clock source
    if !execution_owner_key(s,key) || sign.sign==nil do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    b,seq,code:=execution_notification_current_locked(s,c,now)
    if code!="ok" do return fail(code)
    // Enter is a separate transport boundary. A one-line notice needs no
    // trailing LF, which native Codex trims from its submitted user record.
    message:=fmt.tprintf("[owner-local] task.hold on task %s; inspect owner-local runtime.",field(b,"task_id"))
    n:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("notification") do n[f.name]=json.String(field(b,f.name))
    n["intent_id"]=json.String(c.id);n["owner_commit_seq"]=json.String(fmt.tprintf("%d",seq))
    n["message_digest"]=json.String(payload_hash(message));n["issued_ms"]=json.String(fmt.tprintf("%d",now))
    n["request_expires_ms"]=json.String(fmt.tprintf("%d",min(now+contracts.EXECUTOR_FENCE_TTL_MS,contracts.executor_number(b,"expires_ms"))))
    n["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    signature,signed:=sign.sign(sign.ctx,"executor.notification",n)
    if !signed do return fail("signer_unavailable")
    n["signature"]=json.String(signature)
    if !contracts.executor_verify("notification",n,key) do return fail("invalid_scope")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=encode(struct{notification,message:string}{encode(n),message}),seq=seq}
}


// This callback runs on another owner thread while exchange holds no owner
// mutex. It validates only the original held checkpoint and signs no grant.
execution_notification_fence_reply :: proc(s:^Store,raw:string,executor_key,key:contracts.Owner_Verified_Key,
    directory_version:i64,directory_hash:string,now:i64,sign:Signer)->Result {
    now:=store_now(s,now) // C1: the store's single clock source
    q,parsed:=contracts.executor_parse(raw,"notification_fence_request")
    n,valid:=contracts.executor_parse(field(q,"notification"),"notification")
    if !parsed || !valid || !execution_owner_key(s,key) || sign.sign==nil ||
       !contracts.executor_verify("notification_fence_request",q,executor_key) ||
       !contracts.executor_verify("notification",n,key) || field(q,"account_id")!=s.account ||
       field(q,"owner_bridge_id")!=s.owner || contracts.executor_number(q,"owner_incarnation")!=s.incarnation ||
       !contracts.executor_peer_issued(contracts.executor_number(q,"issued_ms"),now) || !contracts.executor_peer_unexpired(contracts.executor_number(q,"request_expires_ms"),now) ||
       now<contracts.executor_number(n,"issued_ms") || now>=contracts.executor_number(n,"request_expires_ms") {return fail("invalid_scope")}
    nd,_:=contracts.executor_digest("notification",n)
    if field(q,"action_digest")!=nd || field(q,"intent_id")!=field(n,"intent_id") do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    directory,read:=query(s.db,"SELECT directory_version,directory_hash FROM runtime_database")
    if !read || len(directory)!=1 do return fail("storage_error")
    if number(directory[0][0])!=directory_version || directory[0][1]!=directory_hash do return fail("invalid_scope")
    rows,ok:=query(s.db,"SELECT chain_id,kind,destination_bridge,exact_fence_json,payload_json,payload_digest,claim_incarnation,attempts FROM runtime_intents WHERE intent_id=? AND state='claimed'",field(q,"intent_id"))
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("no_current_target")
    row:=rows[0]
    if field(q,"claim_attempt")!=row[7] do return fail("invalid_scope")
    c:=Intent_Claim{field(q,"intent_id"),row[0],row[1],row[2],row[3],row[4],row[5],number(row[6]),number(row[7])}
    b,seq,code:=execution_notification_current_locked(s,c,now)
    if code!="ok" do return fail(code)
    p,_:=contracts.executor_parse(c.fence,"prepare")
    if !remote_assignment_key_matches(s,p,executor_key) do return fail("invalid_scope")
    for name in ([7]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation","owner_incarnation"}) {
        if field(q,name)!=field(n,name) do return fail("invalid_scope")
    }
    for f in contracts.executor_schema("notification") {
        switch f.name {
        case "intent_id","owner_commit_seq","message_digest","issued_ms","request_expires_ms","signature":
        case: if field(n,f.name)!=field(b,f.name) do return fail("no_current_target")
        }
    }
    // Enter is a separate transport boundary. A one-line notice needs no
    // trailing LF, which native Codex trims from its submitted user record.
    message:=fmt.tprintf("[owner-local] task.hold on task %s; inspect owner-local runtime.",field(b,"task_id"))
    if field(n,"message_digest")!=payload_hash(message) || contracts.executor_number(n,"owner_commit_seq")!=seq do return fail("invalid_scope")
    r:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("notification_fence_reply") do r[f.name]=json.String(field(q,f.name))
    qd,_:=contracts.executor_digest("notification_fence_request",q)
    r["request_digest"]=json.String(qd);r["prepare_digest"]=n["prepare_digest"]
    r["owner_commit_seq"]=n["owner_commit_seq"];r["checked_ms"]=json.String(fmt.tprintf("%d",now))
    r["key_id"]=json.String(s.owner_key);r["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    signature,signed:=sign.sign(sign.ctx,"executor.notification_fence_reply",r)
    if !signed do return fail("signer_unavailable")
    r["signature"]=json.String(signature)
    if !contracts.executor_notification_fence_matches(r,q,n,key,executor_key,now) do return fail("invalid_scope")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=encode(r),seq=seq}
}

execution_notification_current :: proc(s:^Store,c:Intent_Claim,now:i64)->string {
    now:=store_now(s,now) // C1: the store's single clock source
    tx:Transaction
    if !transaction_begin(s,&tx) do return "storage_error"
    defer transaction_rollback(&tx)
    _,_,code:=execution_notification_current_locked(s,c,now)
    if code!="ok" do return code
    if !transaction_commit(&tx) do return "storage_error"
    return "ok"
}
