#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import wf "odin_test:lib/workflow_v1"

Source_Proof :: struct { head:string, valid:bool }
// The owner-signed attestation includes the payload and exact observed child.
// Historical replay precedes every mutation fence, but never current read auth.
execute_lifecycle :: proc(s:^Store,raw,payload,cap_raw:string,child:Child,key:contracts.Owner_Verified_Key,now:i64,sign:Signer,source:Source_Proof={}) -> Result {
    context.allocator=context.temp_allocator
    gate,gate_valid:=contracts.owner_parse(raw,"lifecycle_command")
    if gate_valid && field(gate,"method")=="workflow.gate.post" do return execute_coordinator_gate(s,raw,payload,cap_raw,child,key,now,sign)
    c,valid:=contracts.owner_parse(raw,"lifecycle_command")
    if !valid do return fail("malformed")
    if !key.enrolled || key.revoked || key.kind!="bridge" || key.account_id!=s.account || key.principal_id!=s.owner || key.key_id!=s.owner_key ||
       field(c,"account_id")!=s.account || field(c,"owner_bridge_id")!=s.owner || field(c,"key_id")!=s.owner_key ||
       !lease_scope(c,child) || !contracts.owner_field_valid(child.agent_id,"id") { return fail("invalid_scope") }
    if !contracts.owner_verify_signature("lifecycle_command",c,"signature",key) do return fail("bad_signature")
    if field(c,"payload_digest")!=contracts.owner_payload_digest(payload) || field(c,"capability_digest")!=contracts.owner_payload_digest(cap_raw) do return fail("digest_mismatch")
    p,parsed:=contracts.owner_parse(payload,contracts.owner_payload_kind(field(c,"method")))
    if !parsed do return fail("malformed")
    for name in ([2]string{"summary","next_steps"}) {
        if len(field(p,name))>MAX_BODY || len(encode(field(p,name)))>MAX_ENCODED_FIELD do return fail("invalid_content")
    }
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    chain,task,op,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"operation_id"),field(c,"method")
    config,binding,configured:=lifecycle_config(s,chain,task)
    if !configured do return fail("invalid_scope")
    role_method:=method=="review.role.open" || method=="review.role.post"
    reviewer:=role_method || method=="review.open" || method=="review.post" || method=="review.checkpoint"
    if reviewer {
        if child.agent_id==field(config,"author_agent_id") do return fail("invalid_scope")
        if role_method {
            if !role_child_authorized(s,chain,task,child,field(p,"role")) do return fail("invalid_scope")
        } else if method=="review.checkpoint" {
            if encode(child)!=binding[2] && !role_child_authorized(s,chain,task,child,"") do return fail("invalid_scope")
        } else if child.agent_id!=field(config,"reviewer_agent_id") || encode(child)!=binding[2] do return fail("invalid_scope")
    } else {
        if child.agent_id!=field(config,"author_agent_id") || encode(child)!=binding[1] do return fail("invalid_scope")
        fleet,ok:=query(s.db,"SELECT enabled,instance_id,launch_epoch,run_count,token_generation FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
        if !ok || len(fleet)!=1 || fleet[0][0]!="1" || fleet[0][1]!=child.instance || fleet[0][2]!=child.epoch || number(fleet[0][3])!=child.run_count || fleet[0][4]!=child.token_generation do return fail("invalid_scope")
    }
    digest,_:=contracts.owner_digest("lifecycle_command",c)
    receipts,ok:=query(s.db,"SELECT method,input_digest,result_json,commit_seq,chain_id,task_id FROM command_receipts WHERE principal_id=? AND operation_id=?",child.instance,op)
    if !ok do return fail("storage_error")
    if len(receipts)==1 {
        r:=receipts[0]
        if r[0]!=method || r[1]!=digest || r[4]!=chain || r[5]!=task do return fail("operation_conflict")
        if !transaction_commit(&tx) do return fail("storage_error")
        return Result{code="ok",body=r[2],seq=number(r[3]),replay=true}
    }
    tomb,read:=query(s.db,"SELECT input_digest FROM operation_tombstones WHERE principal_id=? AND operation_id=?",child.instance,op)
    if !read do return fail("storage_error")
    if len(tomb)>0 {
        if tomb[0][0]!=digest do return fail("operation_conflict")
        return fail("retired")
    }
    if !workflow_task_current(s,chain,task) do return fail("stale_revision")
    if !dependency_ready(s,chain,task) do return fail("operation_conflict")
    held_checkpoint:=control_checkpoint_authorized(s,c,child,cap_raw,now)
    if !control_ready(s,chain,task) && !held_checkpoint do return fail("operation_conflict")
    if now<0 || now>0x7fffffffffffffff-LEASE_HARD_MS || number(field(c,"request_expires_ms"))<=now || number(field(c,"request_expires_ms"))-now>contracts.OWNER_REQUEST_TTL_MS do return fail("expired")
    state,looked:=query(s.db,"SELECT commit_seq,clock_high_ms,recovery_state FROM runtime_database WHERE singleton=1")
    if !looked || len(state)!=1 do return fail("storage_error")
    if now<number(state[0][1]) { _=mark_clock_uncertain(&tx);return fail("clock_uncertain") }
    if state[0][2]!="ready" do return fail("clock_uncertain")
    tasks,found:=query(s.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
    if !found || len(tasks)!=1 do return fail("storage_error")
    if tasks[0][0]!=field(c,"expected_revision") do return fail("stale_revision")
    req,has_req:=lifecycle_requirements(s,chain,task)
    if !has_req || req[0]!=field(p,"requirements_revision") do return fail("stale_revision")
    quota,checked:=query(s.db,"SELECT (SELECT count(*) FROM command_receipts)+(SELECT count(*) FROM operation_tombstones),(SELECT count(*) FROM local_changes)")
    if !checked || number(quota[0][0])>=MAX_RECORDS || number(quota[0][1])>=1000000 do return fail("retention_capacity")
    seq:=number(state[0][0])+1
    lease:=field(c,"lease_id")
    result:=""
    if !reviewer {
        cap,cap_ok:=contracts.owner_parse(cap_raw,"capability")
        if !cap_ok || !contracts.owner_verify_signature("capability",cap,"signature",key) || !strings.contains(fmt.tprintf(",%s,",field(cap,"allowed_methods")),fmt.tprintf(",%s,",method)) do return fail("invalid_scope")
        leases,lease_ok:=query(s.db,"SELECT capability_json,expires_ms,hard_ms,configuration_revision FROM local_leases WHERE lease_id=? AND chain_id=? AND task_id=? AND instance_id=? AND (retired_seq IS NULL OR ?='1')",lease,chain,task,child.instance,("1" if held_checkpoint else "0"))
        if !lease_ok || len(leases)!=1 || leases[0][0]!=cap_raw || !lease_scope(cap,child) || leases[0][3]!=field(c,"configuration_revision") do return fail("invalid_scope")
        fleet,ok:=query(s.db,"SELECT configuration_revision FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
        if !ok || len(fleet)!=1 || fleet[0][0]!=leases[0][3] do return fail("invalid_scope")
        if number(leases[0][1])<=now || number(leases[0][2])<=now do return fail("expired")
        switch method {
        case "requirements.present":
            if _,ok=query(s.db,"INSERT OR IGNORE INTO requirement_ack VALUES(?,?,1,0)",lease,req[0]);!ok do return fail("storage_error")
            projection,ready:=context_materialize(s,chain)
            if !ready do return fail("storage_error")
            ack,ack_ok:=query(s.db,"SELECT acknowledged FROM requirement_ack WHERE lease_id=? AND revision=?",lease,req[0])
            if !ack_ok || len(ack)!=1 do return fail("storage_error")
            provenance:=doc(map[string]string{"algorithm"=field(projection,"algorithm"),"version"=field(projection,"version"),"source_seq"=field(projection,"source_seq"),"source_digest"=field(projection,"source_digest"),"source_count"=field(projection,"source_count"),"freshness"="snapshot","fetch_method"="context.read"})
            result=encode(doc(map[string]string{"requirements_revision"=req[0],"acknowledged"=ack[0][0],"brief"=req[1],"revision"=tasks[0][0],"chain_summary"=field(projection,"body"),"context_provenance"=encode(provenance)}))
        case "requirements.ack":
            rows,ok:=query(s.db,"UPDATE requirement_ack SET acknowledged=1 WHERE lease_id=? AND revision=? AND presented=1 RETURNING revision",lease,req[0])
            if !ok do return fail("storage_error")
            if len(rows)!=1 do return fail("stale_revision")
            result=encode(doc(map[string]string{"requirements_revision"=req[0],"acknowledged"="1","revision"=tasks[0][0]}))
        case "lease.handoff", "lease.block", "lease.switch":
            c["principal_id"]=json.String(child.instance)
            result,valid=control_agent(&tx,c,p,child,seq,now,sign)
            if !valid do return fail(result)
        case "lease.submit":
            ack,ok:=query(s.db,"SELECT revision FROM requirement_ack WHERE lease_id=? AND revision=? AND acknowledged=1",lease,req[0])
            if !ok do return fail("storage_error")
            if len(ack)!=1 do return fail("stale_revision")
            if !source.valid || source.head!=field(p,"head") || ((field(config,"merge_policy")=="git") != (source.head!="")) do return fail("invalid_scope")
            states,state_ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
            if !state_ok || len(states)!=1 do return fail("storage_error")
            if states[0][0]!="ready" do return fail("operation_conflict")
            output:=field(p,"output")
            if len(output)>MAX_BODY || len(encode(output))>MAX_ENCODED_FIELD do return fail("invalid_content")
            if output!="" {
                v,valid_output:=contracts.owner_request_document(output)
                if _,obj:=v.(json.Object);!valid_output || !obj do return fail("invalid_content")
            }
            if err:=wf.validate_task_output_contract(req[1],output);err.code!=.None do return fail("invalid_content")
            attempt:=number(states[0][1])+1
            if _,ok=query(s.db,"INSERT INTO local_submissions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",chain,task,fmt.tprintf("%d",attempt),lease,child.agent_id,encode(child),req[0],field(config,"configuration_revision"),source.head,field(p,"summary"),req[1],child.instance,op);!ok do return fail("storage_error")
            if output!="" {
                if _,ok=query(s.db,"INSERT INTO local_workflow_outputs VALUES(?,?,?,?)",chain,task,fmt.tprintf("%d",attempt),output);!ok do return fail("storage_error")
            }
            if _,ok=query(s.db,"UPDATE local_leases SET retired_seq=? WHERE lease_id=?",fmt.tprintf("%d",seq),lease);!ok do return fail("storage_error")
            if _,ok=query(s.db,"UPDATE lifecycle_state SET state='in_review',attempt=? WHERE chain_id=? AND task_id=?",fmt.tprintf("%d",attempt),chain,task);!ok do return fail("storage_error")
            if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return fail("storage_error")
            result=encode(doc(map[string]string{"state"="in_review","attempt"=fmt.tprintf("%d",attempt),"requirements_revision"=req[0],"head"=source.head,"revision"=fmt.tprintf("%d",number(tasks[0][0])+1)}))
        }
    } else {
        if field(c,"configuration_revision")!=field(config,"configuration_revision") do return fail("stale_revision")
        submitted,ok:=query(s.db,"SELECT lease_id,head,requirements_revision,summary,requirements_json FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,field(p,"attempt"))
        if !ok || len(submitted)!=1 do return fail("stale_revision")
        states,state_ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !state_ok || len(states)!=1 || states[0][0]!="in_review" || states[0][1]!=field(p,"attempt") || submitted[0][0]!=lease || submitted[0][1]!=field(p,"head") || submitted[0][2]!=req[0] do return fail("stale_revision")
        if method=="review.open" || method=="review.role.open" {
            if cap_raw!="" do return fail("invalid_scope")
            cap,signed:=lease_capability(s,c,now+LEASE_TTL_MS,now+LEASE_TTL_MS,sign,("review.role.post,review.checkpoint" if role_method else "review.post,review.checkpoint"))
            if !signed do return fail("storage_error")
            if _,ok=query(s.db,"INSERT INTO local_review_sessions VALUES(?,?,?,?,?,?) ON CONFLICT(chain_id,task_id,attempt,child) DO UPDATE SET child=excluded.child,capability_json=excluded.capability_json,expires_ms=excluded.expires_ms",chain,task,field(p,"attempt"),encode(child),cap,fmt.tprintf("%d",now+LEASE_TTL_MS));!ok do return fail("storage_error")
            result=encode(doc(map[string]string{"capability"=cap,"summary"=submitted[0][3],"brief"=submitted[0][4],"revision"=tasks[0][0]}))
        } else {
            rcap,cap_valid:=contracts.owner_parse(cap_raw,"capability")
            if !cap_valid || !contracts.owner_verify_signature("capability",rcap,"signature",key) || !strings.contains(fmt.tprintf(",%s,",field(rcap,"allowed_methods")),fmt.tprintf(",%s,",method)) do return fail("invalid_scope")
            sessions,read:=query(s.db,"SELECT child,capability_json,expires_ms FROM local_review_sessions WHERE chain_id=? AND task_id=? AND attempt=? AND child=?",chain,task,field(p,"attempt"),encode(child))
            if held_checkpoint {
                sessions,read=query(s.db,"SELECT child_json,capability_json,expires_ms FROM local_checkpoints WHERE chain_id=? AND task_id=? AND lease_id=? AND child_json=?",chain,task,lease,encode(child))
            }
            if !read || len(sessions)!=1 || sessions[0][0]!=encode(child) || sessions[0][1]!=cap_raw do return fail("invalid_scope")
            if number(sessions[0][2])<=now do return fail("expired")
            c["principal_id"]=json.String(child.instance)
            if method=="review.checkpoint" {
                if !control_record(s,c,p,seq) do return fail("storage_error")
                if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=? AND lease_id=? AND child_json=?",chain,task,lease,encode(child));!ok do return fail("storage_error")
                if _,ok=query(s.db,"DELETE FROM local_review_sessions WHERE chain_id=? AND task_id=? AND attempt=? AND child=?",chain,task,field(p,"attempt"),encode(child));!ok do return fail("storage_error")
                if !control_notice(s,c,child,"stop") do return fail("storage_error")
                if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return fail("storage_error")
                result=encode(doc(map[string]string{"state"="in_review","checkpoint"="1","revision"=fmt.tprintf("%d",number(tasks[0][0])+1)}))
            } else {
                if code:=lifecycle_review(s,c,p,child.agent_id,false);code!="ok" do return fail(code)
                result=encode(doc(map[string]string{"verdict"=field(p,"verdict"),"revision"=fmt.tprintf("%d",number(tasks[0][0])+1)}))
            }
        }
    }
    if result=="" do return fail("malformed")
    if _,ok=query(s.db,"INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq,created_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?)",child.instance,op,chain,task,method,digest,key.key_id,field(c,"request_expires_ms"),result,fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if !reviewer {
        if _,ok=query(s.db,"INSERT INTO lease_receipt_pins VALUES(?,?,?)",child.instance,op,lease);!ok do return fail("storage_error")
        if method=="lease.switch" {
            if _,ok=query(s.db,"INSERT INTO lease_receipt_pins VALUES(?,?,?)",child.instance,op,field(p,"destination_lease_id"));!ok do return fail("storage_error")
            if _,ok=query(s.db,"INSERT OR IGNORE INTO lease_receipt_pins SELECT principal_id,operation_id,? FROM local_fleet WHERE chain_id=? AND task_id=?",field(p,"destination_lease_id"),field(p,"destination_chain_id"),field(p,"destination_task_id"));!ok do return fail("storage_error")
        }
    }
    c["principal_id"]=json.String(child.instance)
    if !control_intents(&tx,c,seq) do return fail("storage_error")
    if !workflow_refresh(s) do return fail("storage_error")
    if !source_lifecycle(&tx,c,p,seq,now) do return fail("storage_error")
    if (method=="review.post" || method=="review.role.post") && !lifecycle_merge_intent(&tx,c,p,seq) do return fail("storage_error")
    if !event_record(&tx,seq,now,chain,task,"agent",child.instance,method,op,raw,payload,encode(child),result) do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),chain,method,task,req[0],op);!ok do return fail("storage_error")
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=? WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=result,seq=seq}
}
