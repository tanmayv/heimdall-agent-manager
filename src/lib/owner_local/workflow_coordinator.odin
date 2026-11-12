#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

coordinator_configure :: proc(s:^Store,c,p:json.Object,child:Child,now:i64,sign:Signer)->string {
    if !member_authorized(s,field(c,"chain_id"),child) || child.instance!=field(p,"instance_id") || child.agent_id!=field(p,"agent_id") || child.epoch=="" || child.run_count<1 || !contracts.owner_field_valid(child.token_generation,"hash") do return "invalid_scope"
    chain:=field(c,"chain_id")
    rows,ok:=query(s.db,"SELECT COALESCE(max(revision),0) FROM local_workflow_coordinators WHERE chain_id=?",chain)
    if !ok || len(rows)!=1 do return "storage_error"
    if number(field(p,"configuration_revision"))!=number(rows[0][0])+1 do return "stale_revision"
    cap:=doc(map[string]string{
        "protocol_version"="1","account_id"=s.account,"owner_bridge_id"=s.owner,"chain_id"=chain,
        "instance_id"=child.instance,"launch_epoch"=child.epoch,"run_count"=fmt.tprintf("%d",child.run_count),
        "token_generation"=child.token_generation,"configuration_revision"=field(p,"configuration_revision"),
        "expires_ms"=fmt.tprintf("%d",now+LEASE_TTL_MS),"allowed_methods"="workflow.gate.post",
        "key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
    if sign.sign==nil do return "storage_error"
    sig,signed:=sign.sign(sign.ctx,"coordinator_capability",cap)
    if !signed do return "storage_error"
    cap["signature"]=json.String(sig)
    if _,ok=query(s.db,"INSERT INTO local_workflow_coordinators VALUES(?,?,?,?,?,?,?)",chain,field(p,"configuration_revision"),child.agent_id,encode(child),encode(cap),field(c,"principal_id"),field(c,"operation_id"));!ok do return "storage_error"
    return "ok"
}

// Bridge attestation proves the current child. The device-configured durable
// agent and exact launch binding are current read authorization, checked before
// historical receipts. Current task/generation/time fences follow receipts.
execute_coordinator_gate :: proc(s:^Store,raw,payload,cap_raw:string,child:Child,key:contracts.Owner_Verified_Key,now:i64,sign:Signer)->Result {
    now:=effective_now(s,now) // C1: monotonic clamp, never refuse on the clock
    c,valid:=contracts.owner_parse(raw,"lifecycle_command")
    p,pvalid:=contracts.owner_parse(payload,"workflow_gate")
    cap,capvalid:=contracts.owner_parse(cap_raw,"coordinator_capability")
    if !valid || !pvalid || !capvalid do return fail("malformed")
    if !key.enrolled || key.revoked || key.kind!="bridge" || key.account_id!=s.account || key.principal_id!=s.owner || key.key_id!=s.owner_key || !lease_scope(c,child) || field(c,"account_id")!=s.account || field(c,"owner_bridge_id")!=s.owner || field(c,"key_id")!=s.owner_key do return fail("invalid_scope")
    if !contracts.owner_verify_signature("lifecycle_command",c,"signature",key) || !contracts.owner_verify_signature("coordinator_capability",cap,"signature",key) do return fail("bad_signature")
    if field(c,"payload_digest")!=payload_hash(payload) || field(c,"capability_digest")!=payload_hash(cap_raw) do return fail("digest_mismatch")
    if len(field(p,"summary"))>MAX_BODY || len(encode(field(p,"summary")))>MAX_ENCODED_FIELD do return fail("invalid_content")
    chain,task,op:=field(c,"chain_id"),field(c,"task_id"),field(c,"operation_id")
    if field(cap,"account_id")!=s.account || field(cap,"owner_bridge_id")!=s.owner || field(cap,"key_id")!=s.owner_key || field(cap,"chain_id")!=chain || !lease_scope(cap,child) || field(cap,"configuration_revision")!=field(c,"configuration_revision") do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    if !member_authorized(s,chain,child) do return fail("invalid_scope")
    revoked,revoked_read:=query(s.db,"SELECT 1 FROM local_coordinator_revocations WHERE chain_id=? AND revision=?",chain,field(c,"configuration_revision"))
    if !revoked_read do return fail("storage_error")
    if len(revoked)>0 do return fail("invalid_scope")
    binding,ok:=query(s.db,"SELECT revision,agent_id,child_json,capability_json FROM local_workflow_coordinators WHERE chain_id=? ORDER BY revision DESC LIMIT 1",chain)
    if !ok do return fail("storage_error")
    if len(binding)!=1 || binding[0][0]!=field(c,"configuration_revision") || binding[0][1]!=child.agent_id || binding[0][2]!=encode(child) || binding[0][3]!=cap_raw do return fail("invalid_scope")
    digest,_:=contracts.owner_digest("lifecycle_command",c)
    prior,read:=query(s.db,"SELECT method,input_digest,result_json,commit_seq,chain_id,task_id FROM command_receipts WHERE principal_id=? AND operation_id=?",child.instance,op)
    if !read do return fail("storage_error")
    if len(prior)==1 {
        row:=prior[0]
        if row[0]!="workflow.gate.post" || row[1]!=digest || row[4]!=chain || row[5]!=task do return fail("operation_conflict")
        if !transaction_commit(&tx) do return fail("storage_error")
        return Result{code="ok",body=row[2],seq=number(row[3]),replay=true}
    }
    tomb,tread:=query(s.db,"SELECT input_digest FROM operation_tombstones WHERE principal_id=? AND operation_id=?",child.instance,op)
    if !tread do return fail("storage_error")
    if len(tomb)>0 {
        if tomb[0][0]!=digest do return fail("operation_conflict")
        return fail("retired")
    }
    if now<0 || now>0x7fffffffffffffff-LEASE_HARD_MS || number(field(c,"request_expires_ms"))<=now || number(field(c,"request_expires_ms"))-now>contracts.OWNER_REQUEST_TTL_MS || number(field(cap,"expires_ms"))<=now do return fail("expired")
    runtime,rread:=query(s.db,"SELECT commit_seq,clock_high_ms,recovery_state FROM runtime_database")
    if !rread || len(runtime)!=1 do return fail("storage_error")
    if now<number(runtime[0][1]) { _=mark_clock_uncertain(&tx);return fail("clock_uncertain") }
    if runtime[0][2]!="ready" do return fail("clock_uncertain")
    current,cread:=query(s.db,"SELECT t.revision,q.brief_json,i.requires_user_approval FROM local_workflow_tasks w JOIN local_workflow_language_items i USING(task_id) JOIN tasks t ON t.chain_id=w.chain_id AND t.task_id=w.task_id JOIN task_requirements q ON q.chain_id=t.chain_id AND q.task_id=t.task_id WHERE w.chain_id=? AND w.run_id=? AND w.execution=? AND i.stage_key=? AND w.task_id=? AND i.kind='gate' ORDER BY q.revision DESC LIMIT 1",chain,field(p,"run_id"),field(p,"execution"),field(p,"stage_key"),task)
    if !cread do return fail("storage_error")
    if len(current)!=1 do return fail("invalid_scope")
    if current[0][0]!=field(c,"expected_revision") do return fail("stale_revision")
    v,parsed:=contracts.owner_request_document(current[0][1]);brief,obj:=v.(json.Object)
    if !parsed || !obj do return fail("storage_error")
    if field(brief,"approver")!="user_or_coordinator" || current[0][2]=="1" do return fail("invalid_scope")
    quota,qread:=query(s.db,"SELECT (SELECT count(*) FROM command_receipts)+(SELECT count(*) FROM operation_tombstones),(SELECT count(*) FROM local_changes)")
    if !qread || len(quota)!=1 do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS || number(quota[0][1])>=1000000 do return fail("retention_capacity")
    seq:=number(runtime[0][0])+1
    command:=doc(map[string]string{"chain_id"=chain,"method"="workflow.gate","principal_id"=child.instance,"operation_id"=op})
    handled,code:=language_command(s,command,payload,seq)
    if !handled || code!="ok" do return fail(code)
    result:=encode(doc(map[string]string{"run_id"=field(p,"run_id"),"execution"=field(p,"execution"),"stage_key"=field(p,"stage_key"),"verdict"=field(p,"verdict")}))
    if _,ok=query(s.db,"INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq,created_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?)",child.instance,op,chain,task,"workflow.gate.post",digest,key.key_id,field(c,"request_expires_ms"),result,fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if !control_intents(&tx,command,seq) || !workflow_refresh(s) do return fail("storage_error")
    if !event_record(&tx,seq,now,chain,task,"agent",child.instance,"workflow.gate.post",op,raw,payload,encode(child),result) do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),chain,"workflow.gate.post",task,field(c,"configuration_revision"),op);!ok do return fail("storage_error")
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=max(clock_high_ms,CAST(? AS INTEGER)) WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=result,seq=seq}
}
