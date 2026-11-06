#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

LEASE_TTL_MS :: i64(15*60*1000)
LEASE_HARD_MS :: i64(60*60*1000)

// These facts come from the local Bridge's current token+child validation,
// never from JSON or a Hub assertion. The signed command binds the same facts.
Child :: struct {
    instance,epoch,token_generation:string,
    run_count:i64,
    agent_id:string,
}
lease_scope :: proc(c:json.Object,child:Child) -> bool {
    return field(c,"instance_id")==child.instance && field(c,"launch_epoch")==child.epoch &&
        field(c,"token_generation")==child.token_generation && number(field(c,"run_count"))==child.run_count
}
lease_capability :: proc(s:^Store,c:json.Object,expires,hard:i64,sign:Signer,methods:string="") -> (string,bool) {
    req:="1"
    if r,ok:=lifecycle_requirements(s,field(c,"chain_id"),field(c,"task_id"));ok do req=r[0]
    allowed:=methods
    if allowed=="" {
        allowed="lease.claim,lease.heartbeat"
        if _,_,ok:=lifecycle_config(s,field(c,"chain_id"),field(c,"task_id"));ok do allowed="lease.claim,lease.heartbeat,requirements.present,requirements.ack,lease.submit,lease.handoff,lease.block,lease.switch"
    }
    cap:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"owner_bridge_id"=s.owner,
        "chain_id"=field(c,"chain_id"),"task_id"=field(c,"task_id"),"lease_id"=field(c,"lease_id"),
        "instance_id"=field(c,"instance_id"),"launch_epoch"=field(c,"launch_epoch"),
        "run_count"=field(c,"run_count"),"token_generation"=field(c,"token_generation"),
        "configuration_revision"=field(c,"configuration_revision"),"requirements_revision"=req,
        "expires_ms"=fmt.tprintf("%d",expires),"hard_ms"=fmt.tprintf("%d",hard),
        "allowed_methods"=allowed,"key_id"=s.owner_key,
        "signature"=strings.repeat("0",128,context.temp_allocator)})
    if sign.sign==nil do return "",false
    sig,ok:=sign.sign(sign.ctx,"capability",cap)
    if !ok do return "",false
    cap["signature"]=json.String(sig)
    return encode(cap),true
}

// Current authenticated read scope is checked before receipts. Capabilities are
// not bearer authority: every invocation needs the actual local child proof.
execute_lease :: proc(s:^Store,raw,cap_raw:string,child:Child,key:contracts.Owner_Verified_Key,now:i64,sign:Signer) -> Result {
    context.allocator=context.temp_allocator
    c,valid:=contracts.owner_parse(raw,"lease_command")
    if !valid do return fail("malformed")
    if now<0 || !key.enrolled || key.revoked || key.kind!="bridge" || key.account_id!=s.account || key.principal_id!=s.owner || key.key_id!=s.owner_key ||
       field(c,"account_id")!=s.account || field(c,"owner_bridge_id")!=s.owner || field(c,"key_id")!=s.owner_key ||
       !lease_scope(c,child) { return fail("invalid_scope") }
    if !contracts.owner_verify_signature("lease_command",c,"signature",key) do return fail("bad_signature")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    chain,task,instance,op,method:=field(c,"chain_id"),field(c,"task_id"),child.instance,field(c,"operation_id"),field(c,"method")
    fleet,found:=query(s.db,"SELECT instance_id,configuration_revision,enabled,launch_epoch,run_count,token_generation FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
    if !found do return fail("storage_error")
    current:=len(fleet)==1 && fleet[0][0]==instance && fleet[0][2]=="1" && fleet[0][3]==child.epoch && number(fleet[0][4])==child.run_count && fleet[0][5]==child.token_generation
    if !current do return fail("invalid_scope")
    digest,_:=contracts.owner_digest("lease_command",c)
    receipts,ok:=query(s.db,"SELECT method,input_digest,result_json,commit_seq,chain_id,task_id FROM command_receipts WHERE principal_id=? AND operation_id=?",instance,op)
    if !ok do return fail("storage_error")
    if len(receipts)==1 {
        r:=receipts[0]
        if r[0]!=method || r[1]!=digest || r[4]!=chain || r[5]!=task do return fail("operation_conflict")
        if !transaction_commit(&tx) do return fail("storage_error")
        return Result{code="ok",body=r[2],seq=number(r[3]),replay=true}
    }
    retired,retired_ok:=query(s.db,"SELECT input_digest FROM operation_tombstones WHERE principal_id=? AND operation_id=?",instance,op)
    if !retired_ok do return fail("storage_error")
    if len(retired)>0 {
        if retired[0][0]!=digest do return fail("operation_conflict")
        return fail("retired")
    }
    if !workflow_task_current(s,chain,task) do return fail("stale_revision")
    if !current || !control_ready(s,chain,task) do return fail("invalid_scope")
    if fleet[0][1]!=field(c,"configuration_revision") do return fail("invalid_scope")
    state,state_ok:=query(s.db,"SELECT commit_seq,clock_high_ms,recovery_state FROM runtime_database WHERE singleton=1")
    if !state_ok || len(state)!=1 do return fail("storage_error")
    if now<0 || now>0x7fffffffffffffff-LEASE_HARD_MS do return fail("expired")
    request_end:=number(field(c,"request_expires_ms"))
    if request_end<=now || request_end-now>contracts.OWNER_REQUEST_TTL_MS do return fail("expired")
    if now<number(state[0][1]) {
        if !mark_clock_uncertain(&tx) do return fail("storage_error")
        return fail("clock_uncertain")
    }
    if state[0][2]!="ready" do return fail("clock_uncertain")
    tasks,task_ok:=query(s.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
    if !task_ok do return fail("storage_error")
    if len(tasks)!=1 do return fail("invalid_scope")
    if tasks[0][0]!=field(c,"expected_revision") do return fail("stale_revision")
    quota,quota_ok:=query(s.db,"SELECT (SELECT count(*) FROM command_receipts)+(SELECT count(*) FROM operation_tombstones),(SELECT count(*) FROM local_changes)")
    if !quota_ok || number(quota[0][0])>=MAX_RECORDS || number(quota[0][1])>=1000000 do return fail("retention_capacity")
    seq:=number(state[0][0])+1
    lease:=field(c,"lease_id")
    expires,hard:=now+LEASE_TTL_MS,now+LEASE_HARD_MS
    version:=i64(1)
    if method=="lease.claim" {
        if !dependency_ready(s,chain,task) || !language_claim_ready(s,chain,task) do return fail("operation_conflict")
        if config,binding,configured:=lifecycle_config(s,chain,task);configured {
            if child.agent_id!=field(config,"author_agent_id") || encode(child)!=binding[1] do return fail("invalid_scope")
            states,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
            if !ok || len(states)!=1 || states[0][0]!="ready" do return fail("operation_conflict")
        }
        if cap_raw!="" || field(c,"capability_digest")!=contracts.owner_payload_digest("") do return fail("digest_mismatch")
        // Expiry is a separate durable decision. Never silently replace a live
        // row or reuse an old lease identity, including after restart.
        existing,checked:=query(s.db,"SELECT lease_id FROM local_leases WHERE lease_id=? OR (retired_seq IS NULL AND (instance_id=? OR task_id=?))",lease,instance,task)
        if !checked do return fail("storage_error")
        if len(existing)>0 do return fail("operation_conflict")
    } else {
        cap,parsed:=contracts.owner_parse(cap_raw,"capability")
        if !parsed || field(c,"capability_digest")!=contracts.owner_payload_digest(cap_raw) do return fail("digest_mismatch")
        if !contracts.owner_verify_signature("capability",cap,"signature",key) do return fail("bad_signature")
        rows,read:=query(s.db,"SELECT capability_json,expires_ms,hard_ms,deadline_version FROM local_leases WHERE lease_id=? AND chain_id=? AND task_id=? AND instance_id=? AND retired_seq IS NULL",lease,chain,task,instance)
        if !read do return fail("storage_error")
        if len(rows)!=1 || rows[0][0]!=cap_raw || !lease_scope(cap,child) ||
            field(cap,"configuration_revision")!=fleet[0][1] { return fail("invalid_scope") }
        if number(rows[0][1])<=now || number(rows[0][2])<=now do return fail("expired")
        hard=number(rows[0][2]);version=number(rows[0][3])+1
        expires=min(expires,hard)
    }
    cap,signed:=lease_capability(s,c,expires,hard,sign)
    if !signed do return fail("storage_error")
    work_attempt:=""
    if method=="lease.claim" {
        initial_req:="1"
        if req,has_req:=lifecycle_requirements(s,chain,task);has_req do initial_req=req[0]
        if _,ok=query(s.db,`INSERT INTO local_leases VALUES(?,?,?,?,?,?,?,?,?,?,?,1,?,NULL)`,
          lease,chain,task,instance,child.epoch,fmt.tprintf("%d",child.run_count),child.token_generation,field(c,"configuration_revision"),initial_req,fmt.tprintf("%d",expires),fmt.tprintf("%d",hard),cap);!ok do return fail("storage_error")
        recorded:bool
        work_attempt,recorded=work_attempt_record(s,chain,task,lease)
        if !recorded do return fail("storage_error")
    } else {
        if _,ok=query(s.db,"UPDATE local_leases SET expires_ms=?,deadline_version=?,capability_json=? WHERE lease_id=?",fmt.tprintf("%d",expires),fmt.tprintf("%d",version),cap,lease);!ok do return fail("storage_error")
    }
    result:=encode(map[string]string{"work_attempt"=work_attempt,"lease_id"=lease,"capability"=cap,"deadline_version"=fmt.tprintf("%d",version),"revision"=tasks[0][0]})
    if _,ok=query(s.db,`INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq,created_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?)`,instance,op,chain,task,method,digest,s.owner_key,field(c,"request_expires_ms"),result,fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO lease_receipt_pins VALUES(?,?,?)",instance,op,lease);!ok do return fail("storage_error")
    if _,ok=query(s.db,"INSERT OR IGNORE INTO lease_receipt_pins SELECT principal_id,operation_id,? FROM local_fleet WHERE chain_id=? AND task_id=?",lease,chain,task);!ok do return fail("storage_error")
    if !event_record(&tx,seq,now,chain,task,"agent",instance,method,op,raw,"",encode(child),result) do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),chain,method,task,tasks[0][0],op);!ok do return fail("storage_error")
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=? WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=result,seq=seq}
}

// Periodic local maintenance, also before claim. Deadlines never extend across
// process death. No task state or lease material is sent to the Hub.
expire_leases :: proc(s:^Store,now:i64) -> bool {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    state,ok:=query(s.db,"SELECT commit_seq,clock_high_ms,recovery_state FROM runtime_database WHERE singleton=1")
    if !ok || len(state)!=1 do return false
    if now<number(state[0][1]) {
        _=mark_clock_uncertain(&tx)
        return false
    }
    if state[0][2]!="ready" do return false
    rows,read:=query(s.db,"SELECT lease_id,chain_id,task_id FROM local_leases WHERE retired_seq IS NULL AND expires_ms<=? ORDER BY expires_ms LIMIT 100",fmt.tprintf("%d",now))
    if !read do return false
    seq:=number(state[0][0])
    for row in rows {
        seq+=1
        if _,ok=query(s.db,"UPDATE local_leases SET retired_seq=? WHERE lease_id=? AND retired_seq IS NULL",fmt.tprintf("%d",seq),row[0]);!ok do return false
        if !event_record(&tx,seq,now,row[1],row[2],"bridge",s.owner,"lease.expired",row[0],"","",encode(doc(map[string]string{"lease_id"=row[0]})),"") do return false
        if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),row[1],"lease.expired",row[2],"1",row[0]);!ok do return false
    }
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=? WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return false
    return transaction_commit(&tx)
}
