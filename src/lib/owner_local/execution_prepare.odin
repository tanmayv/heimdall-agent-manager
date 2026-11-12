#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// Initiation uses accepted remote enrollment only. A stable identity for this
// exact assignment/task revision prevents a new reservation after an ambiguous
// outcome or owner restart. A changed task still passes ordinary admission.
execution_prepare_assignment :: proc(s:^Store,chain,task:string,key:contracts.Owner_Verified_Key,now:i64,sign:Signer)->Result {
    now:=store_now(s,now) // C1: decide and stamp with max(caller clock, store clock)
    if !execution_owner_key(s,key) || sign.sign==nil do return fail("invalid_scope")
    rows,ok:=query(s.db,`SELECT h.payload_json,t.revision FROM local_fleet f
      JOIN local_assignment_history h ON h.chain_id=f.chain_id AND h.task_id=f.task_id AND h.revision=f.configuration_revision
      JOIN tasks t ON t.chain_id=f.chain_id AND t.task_id=f.task_id
      WHERE f.chain_id=? AND f.task_id=? AND f.enabled=1 AND json_extract(h.command_json,'$.method')='fleet.reserve'`,chain,task)
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    c,valid:=remote_assignment_configuration(rows[0][0])
    if !valid || field(c,"executor_bridge_id")==s.owner do return fail("invalid_scope")
    // G3: one reservation (and lease) per generation. A live row of this
    // assignment is adopted (a repeated call replays it, never conflicts);
    // once the task's earlier rows retired with their leases, the next
    // generation is a new reservation. Generation 0 keeps the original id.
    live,live_read:=query(s.db,"SELECT prepare_seq,state FROM owner_execution_journal WHERE chain_id=? AND task_id=? AND instance_id=? AND state!='retired'",chain,task,field(c,"instance_id"))
    if !live_read do return fail("storage_error")
    if len(live)==1 do return Result{code="ok",body=live[0][1],seq=number(live[0][0]),replay=true}
    // R1 FIX B: a new work generation only for a claimable task. A submitted
    // (in_review), held or done task owes no work; preparing one anyway made
    // the executor refuse each generation with resource_conflict.
    if !execution_work_claimable(s,chain,task) do return fail("invalid_scope")
    retired,retired_read:=query(s.db,"SELECT count(*) FROM owner_execution_journal WHERE chain_id=? AND task_id=? AND state='retired'",chain,task)
    if !retired_read || len(retired)!=1 do return fail("storage_error")
    reservation:=payload_hash(encode([7]string{s.account,s.owner,chain,task,field(c,"instance_id"),field(c,"configuration_revision"),rows[0][1]}))
    if generation:=retired[0][0];generation!="0" {
        // Only a reservation id that already retired moves on: the first
        // prepare after a retire is the next generation of the same lease slot.
        saved_retired,saved_read:=query(s.db,"SELECT 1 FROM owner_execution_journal WHERE reservation_id=?",reservation)
        if !saved_read do return fail("storage_error")
        if len(saved_retired)>0 do reservation=payload_hash(encode([8]string{s.account,s.owner,chain,task,field(c,"instance_id"),field(c,"configuration_revision"),rows[0][1],generation}))
    }
    saved,read:=query(s.db,"SELECT prepare_seq,state FROM owner_execution_journal WHERE reservation_id=?",reservation)
    if !read do return fail("storage_error")
    if len(saved)==1 do return Result{code="ok",body=saved[0][1],seq=number(saved[0][0]),replay=true}
    if now<0 || now>0x7fffffffffffffff-LEASE_HARD_MS do return fail("expired")
    _,hard,deadline_ok:=lease_deadlines(s,chain,task,now)
    if !deadline_ok || hard<=now do return fail("invalid_scope")
    until:=min(now+contracts.EXECUTOR_PREPARE_TTL_MS,hard)
    lease:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"owner_bridge_id"=s.owner,
        "chain_id"=chain,"task_id"=task,"lease_id"=payload_hash(encode([2]string{reservation,"lease"})),
        "operation_id"=payload_hash(encode([2]string{reservation,"claim"})),"method"="lease.claim",
        "expected_revision"=rows[0][1],"request_expires_ms"=fmt.tprintf("%d",until),
        "capability_digest"=payload_hash(""),"key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
    for name in ([5]string{"instance_id","launch_epoch","run_count","token_generation","configuration_revision"}) do lease[name]=c[name]
    signature,signed:=sign.sign(sign.ctx,"lease_command",lease)
    if !signed do return fail("storage_error")
    lease["signature"]=json.String(signature)
    p:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"owner_bridge_id"=s.owner,
        "chain_id"=chain,"task_id"=task,"lease_id"=field(lease,"lease_id"),"reservation_id"=reservation,
        "operation_id"=payload_hash(encode([2]string{reservation,"prepare"})),
        "grant_generation"=rows[0][1],"owner_incarnation"=fmt.tprintf("%d",s.incarnation),"purpose"="work",
        "prepare_until_ms"=fmt.tprintf("%d",until),"hard_ms"=fmt.tprintf("%d",hard),
        "request_expires_ms"=fmt.tprintf("%d",until),"key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
    for name in ([11]string{"executor_bridge_id","instance_id","launch_epoch","run_count","token_generation","configuration_revision",
        "executor_incarnation","policy_revision","slot_id","provider_profile","directory_key"}) { p[name]=c[name] }
    signature,signed=sign.sign(sign.ctx,"executor.prepare",p)
    if !signed do return fail("storage_error")
    p["signature"]=json.String(signature)
    return execution_prepare_start(s,encode(p),encode(lease),key,now)
}

// Whether a refused execution_prepare_assignment only skipped a task that owes
// no work (FIX B1), which the preparation loop does not report as a refusal.
execution_prepare_skipped :: proc(s:^Store,chain,task,code:string)->bool {
    return code=="invalid_scope" && !execution_work_claimable(s,chain,task)
}

// Whether the task can take a new work lease: lifecycle ready (or not yet
// started) and dispatch controls ready (not held, blocked or cancelled).
execution_work_claimable :: proc(s:^Store,chain,task:string)->bool {
    rows,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok || len(rows)>0 && rows[0][0]!="ready" do return false
    return control_ready(s,chain,task)
}

// Before every external prepare/query, require the original owner incarnation,
// current assignment, revision and readiness. This check grants no lease.
execution_preparation_current :: proc(s:^Store,reservation:string,now:i64)->bool {
    now:=store_now(s,now) // C1: the store's single clock source
    rows,ok:=query(s.db,"SELECT prepare_json,lease_command,state FROM owner_execution_journal WHERE reservation_id=?",reservation)
    if !ok || len(rows)!=1 || rows[0][2]!="preparing" do return false
    p,valid:=contracts.executor_parse(rows[0][0],"prepare");c,c_ok:=contracts.owner_parse(rows[0][1],"lease_command")
    if !valid || !c_ok || contracts.executor_number(p,"owner_incarnation")!=s.incarnation ||
       now<0 || contracts.executor_number(p,"prepare_until_ms")<=now {return false}
    if _,current:=execution_assignment(s,p,c);!current do return false
    chain,task:=field(p,"chain_id"),field(p,"task_id")
    revisions,read:=query(s.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
    return read && len(revisions)==1 && revisions[0][0]==field(c,"expected_revision") &&
        workflow_task_current(s,chain,task) && work_task_published(s,chain,task) &&
        control_active(s,chain,task) && control_ready(s,chain,task) &&
        dependency_ready(s,chain,task) && language_claim_ready(s,chain,task)
}

// Persist the original prepare evidence and a fixed signed query before query
// I/O. Never substitute a fresh reservation or extend the original deadline.
execution_query_start :: proc(s:^Store,reservation,receipt_raw:string,owner_key,executor_key:contracts.Owner_Verified_Key,
    now:i64,sign:Signer)->Result {
    now:=store_now(s,now) // C1: the store's single clock source
    if !execution_owner_key(s,owner_key) do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    if !execution_preparation_current(s,reservation,now) do return fail("invalid_scope")
    rows,ok:=query(s.db,"SELECT prepare_json,prepare_seq FROM owner_execution_journal WHERE reservation_id=?",reservation)
    if !ok || len(rows)!=1 do return fail("storage_error")
    p,valid:=contracts.executor_parse(rows[0][0],"prepare")
    r,r_ok:=contracts.executor_parse(receipt_raw,"receipt")
    if !valid || !r_ok || !remote_assignment_key_matches(s,p,executor_key) ||
       !contracts.executor_receipt_matches(r,p,"prepare",executor_key,now,false) { return fail("invalid_scope") }
    prior,read:=query(s.db,"SELECT query_json FROM owner_execution_queries WHERE reservation_id=?",reservation)
    if !read do return fail("storage_error")
    if len(prior)==1 do return Result{code="ok",body=prior[0][0],replay=true}
    if sign.sign==nil do return fail("storage_error")
    digest,_:=contracts.executor_digest("prepare",p)
    q:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"owner_bridge_id"=s.owner,
        "operation_id"=payload_hash(encode([2]string{reservation,"query"})),"method"="query",
        "prepare_digest"=digest,"owner_commit_seq"=rows[0][1],"deadline_version"="1",
        "expires_ms"=field(p,"prepare_until_ms"),"key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
    for name in ([8]string{"executor_bridge_id","chain_id","reservation_id","executor_incarnation",
        "owner_incarnation","grant_generation","hard_ms","request_expires_ms"}) { q[name]=p[name] }
    signature,signed:=sign.sign(sign.ctx,"executor.action",q)
    if !signed do return fail("storage_error")
    q["signature"]=json.String(signature)
    raw:=encode(q)
    if !contracts.executor_verify("action",q,owner_key) do return fail("storage_error")
    if _,written:=query(s.db,"INSERT INTO owner_execution_queries VALUES(?,?,?)",reservation,receipt_raw,raw);!written do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=raw}
}
