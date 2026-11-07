#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// This snapshot is derived from the authoritative committed grant. No remote
// request or process may supply its capability, task requirements or launch key.
// The exact first signed bootstrap is retained before network I/O.
execution_bootstrap :: proc(s:^Store,claim:Intent_Claim,agents_md,memory_md,skills_json:string,
    owner_key:contracts.Owner_Verified_Key,now:i64,sign:Signer)->Result {
    context.allocator=context.temp_allocator
    if !execution_owner_key(s,owner_key) || sign.sign==nil do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    current,_,_,_:=execution_activation_fence_locked(s,claim,now)
    if !current do return fail("owner_fence_not_current")
    p,parsed:=contracts.executor_parse(claim.fence,"prepare")
    a,activated:=contracts.executor_parse(claim.payload,"action")
    if !parsed || !activated do return fail("invalid_scope")
    id:=field(p,"reservation_id")
    prior,read:=query(s.db,"SELECT document,body FROM owner_execution_bootstraps WHERE reservation_id=?",id)
    if !read do return fail("storage_error")
    if len(prior)>0 {
        // Caller changes cannot replace the first snapshot or extend its TTL.
        return Result{code="ok",body=encode(struct{bootstrap,body:string}{prior[0][0],prior[0][1]}),replay=true}
    }
    rows,ok:=query(s.db,`SELECT j.receipt_json,l.capability_json,t.title,t.revision,
        h.payload_json FROM owner_execution_journal j
        JOIN local_leases l ON l.lease_id=j.lease_id
        JOIN tasks t ON t.chain_id=j.chain_id AND t.task_id=j.task_id
        JOIN local_assignment_history h ON h.chain_id=j.chain_id AND h.task_id=j.task_id AND h.revision=l.configuration_revision
        WHERE j.reservation_id=?`,id)
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    row:=rows[0]
    receipt,r_ok:=contracts.executor_parse(row[0],"receipt")
    snapshot,s_ok:=contracts.owner_parse(row[4],"remote_assignment_snapshot")
    reservation,c_ok:=contracts.owner_parse(field(snapshot,"reservation"),"remote_reservation")
    config:=field(reservation,"configuration")
    if !r_ok || !s_ok || !c_ok do return fail("invalid_scope")
    req,req_ok:=lifecycle_requirements(s,claim.chain,field(p,"task_id"))
    if !req_ok do return fail("invalid_content")
    projection,projected:=context_materialize(s,claim.chain)
    if !projected do return fail("storage_error")
    // Complete requirements and the existing capability are never compacted.
    task:=fmt.tprintf("# Owner-local task %s: %s\n\nChain: %s\nLease: %s\nInstance: %s\nConfiguration revision: %s\nTask revision: %s\nRequirements revision: %s\n\n## Current requirements\n\x60\x60\x60json\n%s\n\x60\x60\x60\n\n## Existing lease capability (local secret)\n\x60\x60\x60json\n%s\n\x60\x60\x60\n\n## Chain context\n%s\n\nUse ./bin/ham-ctl task-chain owner-local lease --request-file <input.json>. This bootstrap does not present or acknowledge requirements. Call requirements.present, then requirements.ack using the exact revision and existing capability. Never request a replacement lease.claim. The owner alone authorizes task changes.\n",
        field(p,"task_id"),row[2],claim.chain,field(p,"lease_id"),field(p,"instance_id"),field(p,"configuration_revision"),row[3],req[0],req[1],row[1],field(projection,"body"))
    body:=encode(struct{agents_md,memory_md,task_md,skills_json:string}{agents_md,memory_md,task,skills_json})
    if _,valid:=contracts.executor_parse(body,"bootstrap_content");!valid do return fail("bootstrap_too_large_or_invalid")
    b:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("bootstrap") {
        value:=field(p,f.name)
        if value=="" do value=field(a,f.name)
        b[f.name]=json.String(value)
    }
    pd,_:=contracts.executor_digest("prepare",p);ad,_:=contracts.executor_digest("action",a)
    for pair in ([8][2]string{{"prepare_digest",pd},{"action_digest",ad},{"configuration_digest",contracts.owner_payload_digest(config)},
        {"body_digest",contracts.owner_payload_digest(body)},{"launch_key",field(receipt,"launch_key")},
        {"issued_ms",fmt.tprintf("%d",now)},{"request_expires_ms",fmt.tprintf("%d",min(now+contracts.EXECUTOR_FENCE_TTL_MS,contracts.executor_number(a,"request_expires_ms"),contracts.executor_number(a,"expires_ms")))},
        {"signature",strings.repeat("0",128,context.temp_allocator)}}) {b[pair[0]]=json.String(pair[1])}
    signature,signed:=sign.sign(sign.ctx,"executor.bootstrap",b)
    if !signed do return fail("signer_unavailable")
    b["signature"]=json.String(signature)
    if !contracts.executor_bootstrap_matches(b,p,a,config,body,field(receipt,"launch_key"),owner_key,now) do return fail("invalid_scope")
    raw:=encode(b);digest,_:=contracts.executor_digest("bootstrap",b)
    if _,written:=query(s.db,"INSERT INTO owner_execution_bootstraps VALUES(?,?,?,?,?)",id,raw,body,digest,contracts.owner_payload_digest(body));!written do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=encode(struct{bootstrap,body:string}{raw,body})}
}
