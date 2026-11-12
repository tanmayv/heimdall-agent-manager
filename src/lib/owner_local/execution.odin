#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// This journal is owned by the authoritative owner database. It records remote
// resource effects; executor replies never execute lease commands themselves.
execution_owner_key :: proc(s:^Store,key:contracts.Owner_Verified_Key)->bool {
    return key.enrolled && !key.revoked && key.kind=="bridge" && key.account_id==s.account &&
        key.principal_id==s.owner && key.key_id==s.owner_key
}
execution_clock :: proc(tx:^Transaction,now:i64)->string {
    s:=tx.store
    rows,ok:=query(s.db,"SELECT clock_high_ms,recovery_state FROM runtime_database")
    if !ok || len(rows)!=1 do return "storage_error"
    // C1: callers pass effective_now, which is never behind clock_high_ms.
    if now<0 do return "expired"
    if now>0x7fffffffffffffff-LEASE_HARD_MS do return "expired"
    return "ok" if rows[0][1]=="ready" else "clock_uncertain"
}
// The child is pinned by accepted assignment history, not supplied by an
// executor or inferred to be a live local PTY. A separate remote enrollment
// path must establish that assignment before this API can admit a reservation.
execution_assignment :: proc(s:^Store,p,c:json.Object,current_admission:=true)->(Child,bool) {
    for name in ([10]string{"account_id","owner_bridge_id","chain_id","task_id","lease_id",
        "instance_id","launch_epoch","run_count","token_generation","configuration_revision"}) {
        if field(p,name)!=field(c,name) do return {},false
    }
    chain,task:=field(p,"chain_id"),field(p,"task_id")
    rows,ok:=query(s.db,"SELECT f.instance_id,f.launch_epoch,f.run_count,f.token_generation,h.child_json,h.command_json,h.payload_json FROM local_fleet f JOIN local_assignment_history h ON h.chain_id=f.chain_id AND h.task_id=f.task_id AND h.revision=f.configuration_revision WHERE f.chain_id=? AND f.task_id=? AND f.enabled=1 AND f.configuration_revision=?",chain,task,field(p,"configuration_revision"))
    if !ok || len(rows)!=1 do return {},false
    child:Child
    if json.unmarshal_string(rows[0][4],&child,.JSON,context.temp_allocator)!=nil ||
       rows[0][0]!=field(p,"instance_id") || rows[0][1]!=field(p,"launch_epoch") ||
       rows[0][2]!=field(p,"run_count") || rows[0][3]!=field(p,"token_generation") ||
       !lease_scope(p,child) || !member_authorized(s,chain,child) || !lifecycle_path_current(s,chain,task) {return {},false}
    assigned,parsed:=contracts.owner_parse(rows[0][5],"command")
    if !parsed do return {},false
    if field(p,"executor_bridge_id")!=s.owner {
        if field(assigned,"method")!="fleet.reserve" || !remote_assignment_prepare_matches(s,p,rows[0][6],current_admission) do return {},false
    } else if field(assigned,"method")!="fleet.edit" {return {},false}
    return child,true
}
execution_change :: proc(tx:^Transaction,seq,now:i64,p:json.Object,kind,operation,result:string)->bool {
    s:=tx.store;chain,task:=field(p,"chain_id"),field(p,"task_id")
    if !event_record(tx,seq,now,chain,task,"bridge",s.owner,kind,operation,"","",encode(p),result) do return false
    if _,ok:=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),chain,kind,task,"1",operation);!ok do return false
    _,ok:=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=max(clock_high_ms,CAST(? AS INTEGER)) WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",now))
    return ok
}
// Persist before prepare I/O. Retrying uses exactly these signed bytes, including
// reservation/operation IDs. No lease or activation intent exists at this stage.
execution_prepare_start :: proc(s:^Store,prepare_raw,lease_raw:string,key:contracts.Owner_Verified_Key,now:i64)->Result {
    now:=effective_now(s,now) // C1: monotonic clamp, never refuse on the clock
    context.allocator=context.temp_allocator
    p,valid:=contracts.executor_parse(prepare_raw,"prepare")
    c,c_valid:=contracts.owner_parse(lease_raw,"lease_command")
    if !valid || !c_valid do return fail("malformed")
    if !execution_owner_key(s,key) || !contracts.executor_verify("prepare",p,key) ||
       !contracts.owner_verify_signature("lease_command",c,"signature",key) ||
       field(p,"account_id")!=s.account || field(p,"owner_bridge_id")!=s.owner ||
       field(c,"method")!="lease.claim" || field(c,"capability_digest")!=contracts.owner_payload_digest("") ||
       field(p,"purpose")!="work" { return fail("invalid_scope") }
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    child,current:=execution_assignment(s,p,c,false)
    if !current do return fail("invalid_scope")
    digest,_:=contracts.executor_digest("prepare",p);lease_digest,_:=contracts.owner_digest("lease_command",c)
    rows,read:=query(s.db,"SELECT prepare_digest,lease_digest,state,prepare_seq FROM owner_execution_journal WHERE reservation_id=? OR (instance_id=? AND operation_id=?)",
        field(p,"reservation_id"),child.instance,field(c,"operation_id"))
    if !read do return fail("storage_error")
    if len(rows)>0 {
        if len(rows)!=1 || rows[0][0]!=digest || rows[0][1]!=lease_digest do return fail("operation_conflict")
        return Result{code="ok",body=rows[0][2],seq=number(rows[0][3]),replay=true}
    }
    if _,admitted:=execution_assignment(s,p,c);!admitted do return fail("invalid_scope")
    if code:=execution_clock(&tx,now);code!="ok" do return fail(code)
    if contracts.executor_number(p,"owner_incarnation")!=s.incarnation do return fail("stale_incarnation")
    if contracts.executor_number(p,"prepare_until_ms")<=now || contracts.executor_number(p,"prepare_until_ms")-now>contracts.EXECUTOR_PREPARE_TTL_MS ||
       number(field(c,"request_expires_ms"))<=now || number(field(c,"request_expires_ms"))-now>contracts.OWNER_REQUEST_TTL_MS ||
       contracts.executor_number(p,"request_expires_ms")<=now || contracts.executor_number(p,"request_expires_ms")-now>contracts.OWNER_REQUEST_TTL_MS { return fail("expired") }
    chain,task:=field(p,"chain_id"),field(p,"task_id")
    task_rows,task_ok:=query(s.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
    if !task_ok do return fail("storage_error")
    if len(task_rows)!=1 || task_rows[0][0]!=field(c,"expected_revision") do return fail("stale_revision")
    if !workflow_task_current(s,chain,task) || !work_task_published(s,chain,task) ||
       !control_active(s,chain,task) || !control_ready(s,chain,task) ||
       !dependency_ready(s,chain,task) || !language_claim_ready(s,chain,task) { return fail("operation_conflict") }
    _,hard,deadline_ok:=lease_deadlines(s,chain,task,now)
    if !deadline_ok || contracts.executor_number(p,"hard_ms")!=hard do return fail("invalid_scope")
    conflicts,checked:=query(s.db,"SELECT 1 FROM local_leases WHERE lease_id=? OR (retired_seq IS NULL AND (instance_id=? OR task_id=?)) UNION ALL SELECT 1 FROM owner_execution_journal WHERE state!='retired' AND (instance_id=? OR task_id=?)",
        field(p,"lease_id"),child.instance,task,child.instance,task)
    if !checked do return fail("storage_error")
    if len(conflicts)>0 do return fail("operation_conflict")
    quota,q_ok:=query(s.db,"SELECT commit_seq,(SELECT count(*) FROM owner_execution_journal),(SELECT count(*) FROM local_changes) FROM runtime_database")
    if !q_ok || len(quota)!=1 do return fail("storage_error")
    if number(quota[0][1])>=MAX_RECORDS || number(quota[0][2])>=1000000 do return fail("retention_capacity")
    seq:=number(quota[0][0])+1
    if _,ok:=query(s.db,"INSERT INTO owner_execution_journal(reservation_id,chain_id,task_id,instance_id,lease_id,operation_id,prepare_digest,lease_digest,prepare_json,lease_command,child_json,prepare_seq,prepare_until_ms,owner_incarnation,state) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,'preparing')",
        field(p,"reservation_id"),chain,task,child.instance,field(p,"lease_id"),field(c,"operation_id"),digest,lease_digest,prepare_raw,lease_raw,encode(child),fmt.tprintf("%d",seq),field(p,"prepare_until_ms"),fmt.tprintf("%d",s.incarnation));!ok do return fail("storage_error")
    if !execution_change(&tx,seq,now,p,"execution.prepare",field(p,"reservation_id"),digest) || !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body="preparing",seq=seq}
}
// A lost prepare reply replays historical evidence. It needs a fresh signed
// exact query proving the same reservation is still prepared before grant.
execution_prepared_receipt :: proc(s:^Store,p:json.Object,receipt_raw,query_raw,query_receipt_raw:string,
    owner_key,executor_key:contracts.Owner_Verified_Key,now:i64)->bool {
    r,valid:=contracts.executor_parse(receipt_raw,"receipt")
    if !valid || !contracts.executor_receipt_matches(r,p,"prepare",executor_key,now,false) do return false
    if query_raw=="" && contracts.executor_receipt_matches(r,p,"prepare",executor_key,now) do return true
    q,q_ok:=contracts.executor_parse(query_raw,"action")
    qr,qr_ok:=contracts.executor_parse(query_receipt_raw,"receipt")
    if !q_ok || !qr_ok || !contracts.executor_verify("action",q,owner_key) ||
       !contracts.executor_receipt_matches(qr,q,"action",executor_key,now,false) ||
       field(q,"method")!="query" || contracts.executor_number(q,"owner_incarnation")!=s.incarnation ||
       contracts.executor_number(q,"request_expires_ms")<=now || contracts.executor_number(q,"request_expires_ms")-now>contracts.OWNER_REQUEST_TTL_MS ||
       field(qr,"historical")!="0" || field(qr,"state")!="prepared" || field(qr,"deadline_version")!="1" ||
       field(qr,"expires_ms")!=field(p,"prepare_until_ms") || contracts.executor_number(qr,"expires_ms")<=now ||
       field(qr,"launch_key")!=field(r,"launch_key") || field(qr,"child_incarnation")!=field(p,"executor_incarnation") { return false }
    for name in ([6]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","grant_generation"}) {
        if field(q,name)!=field(p,name) do return false
    }
    digest,_:=contracts.executor_digest("prepare",p)
    return field(q,"prepare_digest")==digest && field(q,"hard_ms")==field(p,"hard_ms") &&
        field(q,"executor_incarnation")==field(p,"executor_incarnation")
}
// The verified reservation replaces live-local-child proof ONLY within this
// explicit path. The owner still executes all normal lease admission guards.
execution_prepare_commit :: proc(s:^Store,reservation,receipt_raw:string,owner_key,executor_key:contracts.Owner_Verified_Key,
    now:i64,sign:Signer,query_raw:string="",query_receipt_raw:string="")->Result {
    now:=effective_now(s,now) // C1: monotonic clamp, never refuse on the clock
    context.allocator=context.temp_allocator
    if !execution_owner_key(s,owner_key) || !executor_key.enrolled || executor_key.revoked do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT prepare_json,lease_command,state,activation_json,grant_seq,child_json FROM owner_execution_journal WHERE reservation_id=?",reservation)
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    row:=rows[0]
    p,valid:=contracts.executor_parse(row[0],"prepare");c,c_ok:=contracts.owner_parse(row[1],"lease_command")
    if !valid || !c_ok || !contracts.executor_verify("prepare",p,owner_key) ||
       !contracts.owner_verify_signature("lease_command",c,"signature",owner_key) {return fail("invalid_scope")}
    if field(p,"executor_bridge_id")!=s.owner && !remote_assignment_key_matches(s,p,executor_key) do return fail("invalid_scope")
    child,current:=execution_assignment(s,p,c,false)
    // A retired reservation may also have been released (its fleet row is no
    // longer current): it still answers 'retired' to its exact executor.
    if (!current || encode(child)!=row[5]) && row[2]!="retired" do return fail("invalid_scope")
    // Require authenticated exact executor evidence before even replaying a
    // committed journal result. Revoked executor credentials cannot read it.
    r,r_ok:=contracts.executor_parse(receipt_raw,"receipt")
    if !r_ok || !contracts.executor_receipt_matches(r,p,"prepare",executor_key,now,false) do return fail("invalid_scope")
    if row[2]=="retired" do return fail("retired")
    if row[2]=="committed" do return Result{code="ok",body=row[3],seq=number(row[4]),replay=true}
    if _,admitted:=execution_assignment(s,p,c);!admitted do return fail("invalid_scope")
    if code:=execution_clock(&tx,now);code!="ok" do return fail(code)
    if contracts.executor_number(p,"prepare_until_ms")<=now do return fail("expired")
    if !execution_prepared_receipt(s,p,receipt_raw,query_raw,query_receipt_raw,owner_key,executor_key,now) do return fail("reservation_not_current")
    lease:=execute_lease(s,row[1],"",child,owner_key,now,sign,&tx,contracts.executor_number(p,"hard_ms"))
    if lease.code!="ok" || lease.replay do return fail(lease.code if lease.code!="ok" else "operation_conflict")
    cap,cap_ok:=contracts.owner_parse(result_capability(lease.body),"capability")
    if !cap_ok do return fail("storage_error")
    digest,_:=contracts.executor_digest("prepare",p)
    activation:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"executor_bridge_id"=field(p,"executor_bridge_id"),
        "owner_bridge_id"=s.owner,"chain_id"=field(p,"chain_id"),"reservation_id"=reservation,
        "operation_id"=contracts.owner_payload_digest(encode([2]string{reservation,"activate"})),
        "method"="activate","prepare_digest"=digest,"executor_incarnation"=field(p,"executor_incarnation"),
        "owner_incarnation"=fmt.tprintf("%d",s.incarnation),"owner_commit_seq"=fmt.tprintf("%d",lease.seq),
        "grant_generation"=field(p,"grant_generation"),"deadline_version"="1","expires_ms"=field(cap,"expires_ms"),
        "hard_ms"=field(cap,"hard_ms"),"request_expires_ms"=fmt.tprintf("%d",min(now+contracts.OWNER_REQUEST_TTL_MS,contracts.executor_number(p,"prepare_until_ms"))),
        "key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
    if sign.sign==nil do return fail("storage_error")
    signature,signed:=sign.sign(sign.ctx,"executor.action",activation)
    if !signed do return fail("storage_error")
    activation["signature"]=json.String(signature)
    if !contracts.executor_verify("action",activation,owner_key) do return fail("storage_error")
    raw:=encode(activation)
    if _,written:=query(s.db,"UPDATE owner_execution_journal SET state='committed',receipt_json=?,activation_json=?,grant_seq=? WHERE reservation_id=?",receipt_raw,raw,fmt.tprintf("%d",lease.seq),reservation);!written do return fail("storage_error")
    if !intent_enqueue(&tx,{field(p,"chain_id"),child.instance,field(c,"operation_id"),lease.seq,"executor.activate",field(p,"executor_bridge_id"),row[0],raw}) ||
       !transaction_commit(&tx) {return fail("storage_error")}
    return Result{code="ok",body=raw,seq=lease.seq}
}
result_capability :: proc(raw:string)->string {
    v,ok:=contracts.owner_request_document(raw);o,obj:=v.(json.Object)
    return field(o,"capability") if ok && obj else ""
}

// Saved documents are the only identities a reconciliation worker may query or
// retry. Bounded enumeration is observation, not fresh admission.
Execution_Preparation :: struct {reservation,prepare,lease_command:string,seq:i64}
execution_preparations :: proc(s:^Store,after:string="",limit:int=20)->([]Execution_Preparation,bool) {
    if limit<1 || limit>20 do return nil,false
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT reservation_id,prepare_json,lease_command,prepare_seq FROM owner_execution_journal WHERE state='preparing' AND reservation_id>? ORDER BY reservation_id LIMIT ?",after,fmt.tprintf("%d",limit))
    if !ok do return nil,false
    result:=make([]Execution_Preparation,len(rows),context.temp_allocator)
    for row,i in rows do result[i]={row[0],row[1],row[2],number(row[3])}
    if !transaction_commit(&tx) do return nil,false
    return result,true
}
// This is the owner database check used to produce a fresh fence attestation.
// A transport adapter must authenticate the requesting executor, bind a fresh
// challenge, and sign/seal its response. It must not cache this result as a
// launch permission. No SQLite lock is held across remote I/O.
execution_activation_fence :: proc(s:^Store,claim:Intent_Claim,now:i64)->(current:bool,digest:string,owner_incarnation,commit_seq:i64) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false,"",0,0
    defer transaction_rollback(&tx)
    current,digest,owner_incarnation,commit_seq=execution_activation_fence_locked(s,claim,now)
    if !current || !transaction_commit(&tx) do return false,"",0,0
    return
}
execution_activation_fence_locked :: proc(s:^Store,claim:Intent_Claim,now:i64)->(current:bool,digest:string,owner_incarnation,commit_seq:i64) {
    if !transaction_current(s.active) do return false,"",0,0
    if (claim.kind!="executor.activate" && claim.kind!="executor.heartbeat") || claim.incarnation!=s.incarnation || claim.digest!=contracts.owner_payload_digest(claim.payload) do return false,"",0,0
    rows,ok:=query(s.db, `SELECT j.prepare_json,j.lease_command,i.payload_json,i.commit_seq,l.expires_ms,l.hard_ms,l.deadline_version,
        (SELECT clock_high_ms FROM runtime_database),(SELECT recovery_state FROM runtime_database),e.evidence_json,r.input_digest
      FROM owner_execution_journal j JOIN local_leases l ON l.lease_id=j.lease_id
      JOIN runtime_intents i ON i.chain_id=j.chain_id AND i.principal_id=j.instance_id AND i.kind=?
      JOIN command_receipts r ON r.principal_id=i.principal_id AND r.operation_id=i.operation_id AND r.commit_seq=i.commit_seq
        AND r.chain_id=j.chain_id AND r.task_id=j.task_id
        AND ((i.kind='executor.activate' AND r.method='lease.claim' AND i.operation_id=j.operation_id)
          OR (i.kind='executor.heartbeat' AND r.method='lease.heartbeat'))
      JOIN local_events e ON e.seq=r.commit_seq AND e.chain_id=r.chain_id AND e.task_id=r.task_id
        AND e.actor_id=r.principal_id AND e.kind=r.method AND e.operation_id=r.operation_id
      WHERE j.state='committed' AND l.retired_seq IS NULL AND i.intent_id=? AND i.state='claimed'
        AND i.claim_incarnation=? AND i.attempts=? AND i.payload_digest=? AND i.payload_json=?
        AND i.destination_bridge=? AND i.exact_fence_json=?
        AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=i.intent_id)`,
        claim.kind,claim.id,fmt.tprintf("%d",s.incarnation),fmt.tprintf("%d",claim.attempt),claim.digest,claim.payload,claim.destination,claim.fence)
    if !ok || len(rows)!=1 do return false,"",0,0
    row:=rows[0]
    p,p_ok:=contracts.executor_parse(row[0],"prepare");c,c_ok:=contracts.owner_parse(row[1],"lease_command")
    a,a_ok:=contracts.executor_parse(row[2],"action")
    if !p_ok || !c_ok || !a_ok || field(a,"method")!=("activate" if claim.kind=="executor.activate" else "heartbeat") ||
       contracts.executor_number(a,"owner_commit_seq")!=number(row[3]) ||
       field(a,"hard_ms")!=row[5] || row[2]!=claim.payload || claim.fence!=row[0] || claim.chain!=field(p,"chain_id") ||
       field(a,"executor_bridge_id")!=claim.destination || now<0 || now<number(row[7]) || row[8]!="ready" ||
       number(row[4])<=now || number(row[5])<=now || number(row[6])!=contracts.executor_number(a,"deadline_version") ||
       number(row[4])!=contracts.executor_number(a,"expires_ms") ||
       contracts.executor_number(a,"owner_incarnation")!=s.incarnation ||
       contracts.executor_number(a,"request_expires_ms")<=now {return false,"",0,0}
    _,current=execution_assignment(s,p,c)
    if !current || !control_active(s,claim.chain,field(p,"task_id")) || !workflow_task_current(s,claim.chain,field(p,"task_id")) do return false,"",0,0
    expected:=field(c,"expected_revision")
    if claim.kind=="executor.heartbeat" {
        value,valid:=contracts.owner_request_document(row[9]);e,obj:=value.(json.Object)
        heartbeat,parsed:=contracts.owner_parse(field(e,"command"),"lease_command")
        hd,digested:=contracts.owner_digest("lease_command",heartbeat)
        if !valid || !obj || !parsed || !digested || hd!=row[10] || field(heartbeat,"method")!="lease.heartbeat" ||
           field(heartbeat,"lease_id")!=field(c,"lease_id") || field(heartbeat,"instance_id")!=field(c,"instance_id") {return false,"",0,0}
        expected=field(heartbeat,"expected_revision")
    }
    tasks,read:=query(s.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id=?",claim.chain,field(p,"task_id"))
    if !read || len(tasks)!=1 || tasks[0][0]!=expected do return false,"",0,0
    return true,field(a,"prepare_digest"),s.incarnation,number(row[3])
}

// The executor key is resolved from the current enrolled directory before this
// call. Claimed intent data is loaded locally, never supplied by the requester.
// This read signs no negative answer and creates no task/resource authority.
execution_fence_reply :: proc(s:^Store,request_raw:string,executor_key,owner_key:contracts.Owner_Verified_Key,
    directory_version:i64,directory_hash:string,now:i64,sign:Signer)->Result {
    context.allocator=context.temp_allocator
    request,valid:=contracts.executor_parse(request_raw,"fence_request")
    if !valid do return fail("malformed")
    if !execution_owner_key(s,owner_key) || !contracts.executor_verify("fence_request",request,executor_key) ||
       field(request,"account_id")!=s.account || field(request,"owner_bridge_id")!=s.owner ||
       field(request,"owner_incarnation")!=fmt.tprintf("%d",s.incarnation) {return fail("invalid_scope")}
    if !contracts.executor_peer_issued(contracts.executor_number(request,"issued_ms"),now) || !contracts.executor_peer_unexpired(contracts.executor_number(request,"request_expires_ms"),now) do return fail("expired")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    directory,read:=query(s.db,"SELECT directory_version,directory_hash FROM runtime_database WHERE singleton=1")
    if !read || len(directory)!=1 do return fail("storage_error")
    if number(directory[0][0])!=directory_version || directory[0][1]!=directory_hash do return fail("invalid_scope")
    rows,ok:=query(s.db,`SELECT chain_id,kind,destination_bridge,exact_fence_json,payload_json,payload_digest,claim_incarnation,attempts
      FROM runtime_intents WHERE intent_id=? AND state='claimed'`,field(request,"intent_id"))
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    row:=rows[0]
    claim:=Intent_Claim{field(request,"intent_id"),row[0],row[1],row[2],row[3],row[4],row[5],number(row[6]),number(row[7])}
    action,a_ok:=contracts.executor_parse(claim.payload,"action")
    if !a_ok || !contracts.executor_verify("action",action,owner_key) || field(request,"claim_attempt")!=row[7] do return fail("invalid_scope")
    prepared,p_ok:=contracts.executor_parse(claim.fence,"prepare")
    if !p_ok || (field(action,"executor_bridge_id")!=s.owner && !remote_assignment_key_matches(s,prepared,executor_key)) do return fail("invalid_scope")
    for name in ([7]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation","owner_incarnation"}) {
        if field(request,name)!=field(action,name) do return fail("invalid_scope")
    }
    digest,_:=contracts.executor_digest("action",action)
    if field(request,"action_digest")!=digest do return fail("invalid_scope")
    current,prepare,incarnation,seq:=execution_activation_fence_locked(s,claim,now)
    if !current do return fail("owner_fence_not_current")
    request_digest,_:=contracts.executor_digest("fence_request",request)
    reply:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"executor_bridge_id"=field(request,"executor_bridge_id"),
        "owner_bridge_id"=s.owner,"chain_id"=claim.chain,"reservation_id"=field(request,"reservation_id"),
        "executor_incarnation"=field(request,"executor_incarnation"),"owner_incarnation"=fmt.tprintf("%d",incarnation),
        "request_digest"=request_digest,"action_digest"=digest,"prepare_digest"=prepare,"challenge"=field(request,"challenge"),
        "owner_commit_seq"=fmt.tprintf("%d",seq),"checked_ms"=fmt.tprintf("%d",now),
        "request_expires_ms"=field(request,"request_expires_ms"),"key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
    if sign.sign==nil do return fail("storage_error")
    signature,signed:=sign.sign(sign.ctx,"executor.fence_reply",reply)
    if !signed do return fail("storage_error")
    reply["signature"]=json.String(signature)
    if !contracts.executor_fence_reply_matches(reply,request,action,owner_key,executor_key,now) do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=encode(reply),seq=seq}
}

// A remote reservation released because it never launched: the Bridge
// places the task's agent again (owner_local_leases.odin).
Reservation_Release :: struct { chain,task,agent,instance:string }

// Expiring an uncommitted preparation spends no lease/attempt and grants no
// remote refund. The executor expires its own prepared charge independently.
// A fleet.reserve whose instance never got a grant and has no preparation left
// is released in the same transaction (see execution_release_stale): its
// reservation id is stable, so it would otherwise replay 'retired' forever.
execution_expire_preparations :: proc(s:^Store,now:i64,released:^[dynamic]Reservation_Release=nil)->bool {
    now:=effective_now(s,now) // C1: monotonic clamp, never refuse on the clock
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    if execution_clock(&tx,now)!="ok" do return false
    rows,ok:=query(s.db,"SELECT reservation_id,prepare_json FROM owner_execution_journal WHERE state='preparing' AND prepare_until_ms<=? ORDER BY prepare_until_ms,reservation_id LIMIT 100",fmt.tprintf("%d",now))
    if !ok do return false
    runtime,read:=query(s.db,"SELECT commit_seq,(SELECT count(*) FROM local_changes) FROM runtime_database")
    if !read || len(runtime)!=1 || number(runtime[0][1])+i64(len(rows))>1000000 do return false
    seq:=number(runtime[0][0])
    for row in rows {
        p,valid:=contracts.executor_parse(row[1],"prepare")
        if !valid do return false
        seq+=1
        if _,written:=query(s.db,"UPDATE owner_execution_journal SET state='retired',retired_seq=? WHERE reservation_id=? AND state='preparing'",fmt.tprintf("%d",seq),row[0]);!written do return false
        if !execution_change(&tx,seq,now,p,"execution.prepare_expired",row[0],"no_grant") do return false
    }
    if !execution_retire_ended(&tx,&seq,now) do return false
    if !execution_release_stale(&tx,&seq,now,released) do return false
    return transaction_commit(&tx)
}

// G3: a committed journal row lives exactly as long as its lease. Once the
// lease has ended (expiry, submit, rework, release, a launch that never
// came up) the row is retired, so the task can be prepared again for a new
// lease (a new reservation, execution_prepare_assignment) instead of every
// later prepare answering operation_conflict forever. The executor's charge
// lapses on its own deadline: no renewal follows an ended lease. Bounded per
// pass; runs in each maintenance pass.
execution_retire_ended :: proc(tx:^Transaction,seq:^i64,now:i64)->bool {
    s:=tx.store
    rows,ok:=query(s.db,`SELECT j.reservation_id,j.prepare_json FROM owner_execution_journal j JOIN local_leases l ON l.lease_id=j.lease_id
      WHERE j.state='committed' AND l.retired_seq IS NOT NULL ORDER BY j.reservation_id LIMIT 100`)
    if !ok do return false
    for row in rows {
        p,valid:=contracts.executor_parse(row[1],"prepare")
        if !valid do return false
        seq^+=1
        if _,written:=query(s.db,"UPDATE owner_execution_journal SET state='retired',retired_seq=? WHERE reservation_id=? AND state='committed'",fmt.tprintf("%d",seq^),row[0]);!written do return false
        if !execution_change(tx,seq^,now,p,"execution.lease_ended",row[0],"retired") do return false
    }
    return true
}

// Releases enabled fleet.reserve rows whose reserved instance never launched:
// at least one retired preparation, none preparing or committed, and no grant
// ever (Mundus .13: inst_a67a... stayed a running:false member and kept the
// task placed on a dead reservation). The fleet row and the never-launched
// member are disabled and the task revision advances, so the matcher places
// the task again. The task's lifecycle configuration is NOT revoked (F4 C,
// Mundus .14): a revoked latest config fails lifecycle_path_current, so the
// re-place fleet.reserve was refused invalid_scope forever; the re-place
// writes the next configuration for its new author itself. Nothing ran, so
// there is no lease, review or checkpoint to retire. Bounded per pass.
execution_release_stale :: proc(tx:^Transaction,seq:^i64,now:i64,released:^[dynamic]Reservation_Release)->bool {
    s:=tx.store
    rows,ok:=query(s.db,`SELECT f.chain_id,f.task_id,f.instance_id,m.agent_id,m.role FROM local_fleet f
      JOIN local_assignment_history h ON h.chain_id=f.chain_id AND h.task_id=f.task_id AND h.revision=f.configuration_revision
      JOIN local_chain_member_versions m ON m.chain_id=f.chain_id AND m.instance_id=f.instance_id
        AND m.accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)
      WHERE f.enabled=1 AND m.enabled=1 AND json_extract(h.command_json,'$.method')='fleet.reserve'
        AND EXISTS(SELECT 1 FROM owner_execution_journal j WHERE j.instance_id=f.instance_id AND j.state='retired')
        AND NOT EXISTS(SELECT 1 FROM owner_execution_journal j WHERE j.instance_id=f.instance_id AND (j.state!='retired' OR j.grant_seq IS NOT NULL))
        AND NOT EXISTS(SELECT 1 FROM local_leases l WHERE l.instance_id=f.instance_id)
      ORDER BY f.chain_id,f.task_id LIMIT 20`)
    if !ok do return false
    for row in rows {
        chain,task,instance,agent:=row[0],row[1],row[2],row[3]
        // An earlier row of this pass may already have released the member.
        current,read:=query(s.db,"SELECT enabled FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
        if !read do return false
        if len(current)!=1 || current[0][0]!="1" do continue
        seq^+=1
        operation:=payload_hash(encode([3]string{chain,instance,"reservation.release"}))
        if _,written:=query(s.db,"UPDATE local_fleet SET enabled=0,configuration_revision=configuration_revision+1 WHERE chain_id=? AND task_id=? AND enabled=1",chain,task);!written do return false
        if _,written:=query(s.db,`INSERT INTO local_chain_member_versions SELECT chain_id,instance_id,?,agent_id,role,0,child_json FROM local_chain_member_versions
          WHERE chain_id=? AND instance_id=? ORDER BY accepted_seq DESC LIMIT 1`,fmt.tprintf("%d",seq^),chain,instance);!written do return false
        if _,written:=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!written do return false
        evidence:=doc(map[string]string{"chain_id"=chain,"task_id"=task,"instance_id"=instance,"agent_id"=agent})
        if !execution_change(tx,seq^,now,evidence,"execution.reservation_released",operation,"never_launched") do return false
        if released!=nil do append(released,Reservation_Release{chain,task,agent,instance})
    }
    return true
}

// A renewal action is an immutable outbox journal entry, inserted in the same
// transaction as the lease heartbeat receipt. Historical receipt replay returns
// before this helper, so it can never enqueue or extend the deadline twice.
// Local children have no execution journal and keep their ordinary lease path.
execution_renewal_enqueue :: proc(tx:^Transaction,c:json.Object,seq,version,expires,hard,now:i64,
    key:contracts.Owner_Verified_Key,sign:Signer)->bool {
    if !transaction_current(tx) || field(c,"method")!="lease.heartbeat" || sign.sign==nil do return false
    s:=tx.store
    rows,ok:=query(s.db,"SELECT prepare_json FROM owner_execution_journal WHERE lease_id=? AND chain_id=? AND task_id=? AND instance_id=? AND state='committed'",
        field(c,"lease_id"),field(c,"chain_id"),field(c,"task_id"),field(c,"instance_id"))
    if !ok || len(rows)>1 do return false
    if len(rows)==0 do return true
    p,valid:=contracts.executor_parse(rows[0][0],"prepare")
    if !valid || !contracts.executor_verify("prepare",p,key) || hard!=contracts.executor_number(p,"hard_ms") do return false
    digest,_:=contracts.executor_digest("prepare",p)
    a:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"executor_bridge_id"=field(p,"executor_bridge_id"),
        "owner_bridge_id"=s.owner,"chain_id"=field(p,"chain_id"),"reservation_id"=field(p,"reservation_id"),
        "operation_id"=contracts.owner_payload_digest(encode([3]string{field(p,"reservation_id"),"heartbeat",field(c,"operation_id")})),
        "method"="heartbeat","prepare_digest"=digest,"executor_incarnation"=field(p,"executor_incarnation"),
        "owner_incarnation"=fmt.tprintf("%d",s.incarnation),"owner_commit_seq"=fmt.tprintf("%d",seq),
        "grant_generation"=field(p,"grant_generation"),"deadline_version"=fmt.tprintf("%d",version),
        "expires_ms"=fmt.tprintf("%d",expires),"hard_ms"=fmt.tprintf("%d",hard),
        "request_expires_ms"=fmt.tprintf("%d",min(now+contracts.OWNER_REQUEST_TTL_MS,expires)),
        "key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
    signature,signed:=sign.sign(sign.ctx,"executor.action",a)
    if !signed do return false
    a["signature"]=json.String(signature)
    if !contracts.executor_verify("action",a,key) do return false
    return intent_enqueue(tx,{field(c,"chain_id"),field(c,"instance_id"),field(c,"operation_id"),seq,
        "executor.heartbeat",field(p,"executor_bridge_id"),rows[0][0],encode(a)})
}

// G3 (coordinator decision a): the executor proved the launched child is
// gone (child_absent) while its lease is live. The owner ends that lease
// (reason child_absent) and retires its journal row in one transaction, so
// the preparation loop re-places the task as a new generation: a new
// reservation, lease, launch key, token and owner fence. A live child is never
// touched (B answers child_present). Idempotent: an already ended lease or a
// claim that is no longer this row's is a no-op ("ok", replay).
execution_child_absent :: proc(s:^Store,claim:Intent_Claim,now:i64)->Result {
    now:=effective_now(s,now) // C1: monotonic clamp, never refuse on the clock
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    if code:=execution_clock(&tx,now);code!="ok" do return fail(code)
    rows,read:=query(s.db,`SELECT j.reservation_id,j.prepare_json,l.lease_id,l.chain_id,l.task_id FROM owner_execution_journal j
      JOIN local_leases l ON l.lease_id=j.lease_id WHERE j.prepare_json=? AND j.state='committed' AND l.retired_seq IS NULL`,claim.fence)
    if !read do return fail("storage_error")
    if len(rows)!=1 do return Result{code="ok",replay=true}
    row:=rows[0]
    p,valid:=contracts.executor_parse(row[1],"prepare")
    if !valid do return fail("invalid_scope")
    runtime,ok:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !ok || len(runtime)!=1 do return fail("storage_error")
    seq:=number(runtime[0][0])+1
    if _,written:=query(s.db,"UPDATE local_leases SET retired_seq=? WHERE lease_id=? AND retired_seq IS NULL",fmt.tprintf("%d",seq),row[2]);!written do return fail("storage_error")
    if !event_record(&tx,seq,now,row[3],row[4],"bridge",s.owner,"lease.expired",row[2],"","",encode(doc(map[string]string{"lease_id"=row[2],"reason"="child_absent"})),"") do return fail("storage_error")
    if _,written:=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),row[3],"lease.expired",row[4],"1",row[2]);!written do return fail("storage_error")
    seq+=1
    if _,written:=query(s.db,"UPDATE owner_execution_journal SET state='retired',retired_seq=? WHERE reservation_id=? AND state='committed'",fmt.tprintf("%d",seq),row[0]);!written do return fail("storage_error")
    if !execution_change(&tx,seq,now,p,"execution.lease_ended",row[0],"child_absent") do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body="child_absent",seq=seq}
}
