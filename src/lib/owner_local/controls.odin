#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

control_ready :: proc(s:^Store,chain,task:string) -> bool {
    rows,ok:=query(s.db,"SELECT mode FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    return ok && (len(rows)==0 || rows[0][0]=="ready")
}
// Existing holders keep authority under a hold. New dispatch still requires
// control_ready; blocked/cancelled authority is never admitted by this helper.
control_active :: proc(s:^Store,chain,task:string) -> bool {
    rows,ok:=query(s.db,"SELECT mode FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    return ok && (len(rows)==0 || rows[0][0]=="ready" || rows[0][0]=="held")
}
control_held :: proc(s:^Store,chain,task:string) -> bool {
    rows,ok:=query(s.db,"SELECT mode FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    return ok && len(rows)==1 && rows[0][0]=="held"
}
control_notice :: proc(s:^Store,c:json.Object,child:Child,kind:string) -> bool {
    _,ok:=query(s.db,"INSERT OR IGNORE INTO control_notices VALUES(?,?,?,?,?,?)",field(c,"chain_id"),field(c,"task_id"),field(c,"principal_id"),field(c,"operation_id"),encode(child),kind)
    return ok
}
control_notify :: proc(s:^Store,c:json.Object,kind:string) -> bool {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    rows,ok:=query(s.db,"SELECT instance_id,launch_epoch,token_generation,run_count FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NULL",chain,task)
    if !ok do return false
    agent:=""
    if config,_,found:=lifecycle_config(s,chain,task);found do agent=field(config,"author_agent_id")
    for row in rows {
        if !control_notice(s,c,Child{row[0],row[1],row[2],number(row[3]),agent},kind) do return false
    }
    sessions,read:=query(s.db,"SELECT child FROM local_review_sessions WHERE chain_id=? AND task_id=? UNION SELECT child_json FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task,chain,task)
    if !read do return false
    for row in sessions {
        child:Child
        if json.unmarshal_string(row[0],&child,.JSON,context.temp_allocator)!=nil do return false
        if !control_notice(s,c,child,kind) do return false
    }
    return true
}
// Evidence remains immutable. Revocation changes only current authority and
// writes exact-child notices in the same caller transaction.
control_revoke :: proc(s:^Store,c:json.Object,seq:i64,kind:string,notify:=true,retire:=true) -> bool {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    if notify && !control_notify(s,c,kind) do return false
    ok:=true
    if retire { if _,ok=query(s.db,"UPDATE local_leases SET retired_seq=? WHERE chain_id=? AND task_id=? AND retired_seq IS NULL",fmt.tprintf("%d",seq),chain,task);!ok do return false }
    if _,ok=query(s.db,"DELETE FROM local_review_sessions WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
    // Do not mutate or delete the old intent/result. It may already have
    // performed Git CAS; prepared/result evidence remains available for repair.
    _,ok=query(s.db,"INSERT OR IGNORE INTO intent_invalidations SELECT intent_id,?,? FROM runtime_intents WHERE chain_id=? AND kind='merge' AND json_extract(exact_fence_json,'$.task_id')=? AND state!='settled'",field(c,"principal_id"),field(c,"operation_id"),chain,task)
    return ok
}
control_record :: proc(s:^Store,c,p:json.Object,seq:i64) -> bool {
    _,ok:=query(s.db,"INSERT INTO local_handoffs VALUES(?,?,?,?,?,?,?,?,?,?,?)",
      field(c,"chain_id"),field(c,"task_id"),field(c,"principal_id"),field(c,"operation_id"),
      field(c,"method"),field(c,"lease_id"),field(p,"summary"),field(p,"next_steps"),field(p,"waiting_on"),field(p,"destination_task_id"),fmt.tprintf("%d",seq))
    return ok
}
control_mode :: proc(s:^Store,chain,task,mode,resume,reason,waiting:string) -> bool {
    _,ok:=query(s.db,"INSERT INTO local_controls VALUES(?,?,?,?,?,?) ON CONFLICT(chain_id,task_id) DO UPDATE SET mode=excluded.mode,resume_state=excluded.resume_state,reason=excluded.reason,waiting_on=excluded.waiting_on",chain,task,mode,resume,reason,waiting)
    return ok
}
// The budget overlay saves independent controls for later recovery. Accepted
// hold/release commands must advance that saved state in the same transaction,
// otherwise recovery can restore a hold the operator has already released.
control_budget_hold :: proc(s:^Store,chain,task,method,body:string) -> bool {
    rows,ok:=query(s.db,"SELECT prior_json FROM budget_control_owners WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return false
    if len(rows)==0 do return true
    prior:[dynamic][]string
    if json.unmarshal_string(rows[0][0],&prior,.JSON,context.temp_allocator)!=nil do return false
    if len(prior)>1 || (len(prior)==1 && len(prior[0])!=4) do return false
    mode,resume,reason,waiting:="ready","ready",body,""
    if len(prior)==1 { mode=prior[0][0];resume=prior[0][1];reason=prior[0][2];waiting=prior[0][3] }
    if method=="task.hold" {
        if mode!="held" { resume=mode;mode="held";reason=body }
    } else if mode=="held" {
        mode="ready";reason=body
        if resume=="blocked" {
            mode="blocked"
            blocks,found:=query(s.db,"SELECT summary FROM local_handoffs WHERE chain_id=? AND task_id=? AND kind='lease.block' ORDER BY seq DESC LIMIT 1",chain,task)
            if !found || len(blocks)!=1 do return false
            reason=blocks[0][0]
        } else { waiting="" }
        resume="ready"
    }
    _,ok=query(s.db,"UPDATE budget_control_owners SET prior_json=? WHERE chain_id=? AND task_id=?",encode([1][4]string{{mode,resume,reason,waiting}}),chain,task)
    return ok
}
control_human :: proc(s:^Store,c,p:json.Object,body:string,seq:i64) -> string {
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    state:="ready"
    states,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return "storage_error"
    if len(states)==1 do state=states[0][0]
    controls,read:=query(s.db,"SELECT mode,resume_state,reason,waiting_on FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    if !read do return "storage_error"
    mode,resume,reason,waiting:="ready","ready",body,""
    if len(controls)==1 { mode=controls[0][0];resume=controls[0][1];waiting=controls[0][3] }
    next:=state
    switch method {
    case "task.hold":
        if (mode!="ready" && mode!="blocked") || state=="done" || state=="merge_pending" || state=="merge_blocked" do return "operation_conflict"
        resume=mode;mode="held"
        // A hold asks for a checkpoint; it neither retires capabilities nor
        // invalidates review/merge evidence. TTL and exact-child fences remain.
        if !control_notify(s,c,"checkpoint") do return "storage_error"
    case "task.release":
        if mode!="held" do return "operation_conflict"
        mode="ready"
        // Pre-fix holds stored lifecycle state in resume_state; always retain
        // the current lifecycle state. A native block is a separate overlay.
        if resume=="blocked" do mode="blocked"
        owned,owned_ok:=query(s.db,"SELECT reason FROM budget_control_owners WHERE chain_id=? AND task_id=?",chain,task)
        if !owned_ok do return "storage_error"
        if mode=="blocked" && len(owned)==1 {
            reason=owned[0][0]
        } else if mode=="blocked" {
            blocks,found:=query(s.db,"SELECT summary FROM local_handoffs WHERE chain_id=? AND task_id=? AND kind='lease.block' ORDER BY seq DESC LIMIT 1",chain,task)
            if !found || len(blocks)!=1 do return "storage_error"
            reason=blocks[0][0]
        }
    case "task.cancel":
        if mode=="cancelled" || state=="done" do return "operation_conflict"
        source_view,source_state,source_ok:=budget_view(s,chain,task)
        if !source_ok do return "storage_error"
        if source_state.source_revision!="" && source_view.done do return "operation_conflict"
        mode="cancelled";next="ready";waiting=""
        if !control_revoke(s,c,seq,"stop") do return "storage_error"
    case "task.reopen":
        if !work_unconsumed(s,chain,"task",task) do return "operation_conflict"
        generated,checked:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=?",task)
        if !checked do return "storage_error"
        if len(generated)>0 do return "operation_conflict"
        consumed,read_consumed:=query(s.db,"SELECT 1 FROM local_workflow_output_triggers WHERE chain_id=? AND source_task=? AND consumed=1 LIMIT 1",chain,task)
        if !read_consumed do return "storage_error"
        if len(consumed)>0 do return "operation_conflict"
        if mode!="cancelled" && state!="done" && state!="merge_blocked" {
            source_view,source_state,source_ok:=budget_view(s,chain,task)
            if !source_ok do return "storage_error"
            if source_state.source_revision=="" || (!source_view.done && !source_view.cancelled) do return "operation_conflict"
        }
        mode="ready";next="ready";waiting=""
        if !control_revoke(s,c,seq,"checkpoint") do return "storage_error"
    case "task.resolve":
        if mode!="blocked" do return "operation_conflict"
        mode="ready";next="ready";waiting=""
    case "merge.retry":
        if mode!="ready" || state!="merge_blocked" do return "operation_conflict"
        config,_,found:=lifecycle_config(s,chain,task)
        req,has_req:=lifecycle_requirements(s,chain,task)
        submitted,got:=query(s.db,"SELECT attempt,head,configuration_revision FROM local_submissions WHERE chain_id=? AND task_id=? ORDER BY attempt DESC LIMIT 1",chain,task)
        if !found || !has_req || !got || len(submitted)!=1 || submitted[0][0]!=field(p,"attempt") || submitted[0][1]!=field(p,"head") ||
           req[0]!=field(p,"requirements_revision") || field(config,"configuration_revision")!=field(p,"configuration_revision") || submitted[0][2]!=field(p,"configuration_revision") { return "stale_revision" }
        pending,read:=query(s.db,"SELECT intent_id FROM runtime_intents WHERE chain_id=? AND kind='merge' AND json_extract(exact_fence_json,'$.task_id')=? AND json_extract(exact_fence_json,'$.attempt')=? AND state='pending' AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=runtime_intents.intent_id)",chain,task,field(p,"attempt"))
        if !read do return "storage_error"
        if len(pending)!=1 do return "operation_conflict"
        // Preserve the original intent identity, prepared head and retry floor.
        // A signed retry acknowledges repair; it never rebinds Git input.
        next="merge_pending"
    case: return "malformed"
    }
    if method=="task.hold" || method=="task.release" {
        if !control_budget_hold(s,chain,task,method,body) do return "storage_error"
    }
    if method!="task.hold" {
        if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    }
    if method=="task.resolve" || method=="task.cancel" || method=="task.reopen" {
        if _,ok=query(s.db,"DELETE FROM budget_control_owners WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    }
    if !control_mode(s,chain,task,mode,resume,reason,waiting) do return "storage_error"
    if method=="task.release" && next=="in_review" {
        gate,valid:=role_gate(s,chain,task,states[0][1])
        if !valid do return "storage_error"
        next=gate
        if next!="in_review" {
            if _,ok=query(s.db,"DELETE FROM local_review_sessions WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
        }
    }
    event:=doc(map[string]string{"summary"=body})
    if !control_record(s,c,event,seq) do return "storage_error"
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state=? WHERE chain_id=? AND task_id=?",next,chain,task);!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    return "ok"
}
control_intents :: proc(tx:^Transaction,c:json.Object,seq:i64) -> bool {
    rows,ok:=query(tx.store.db,"SELECT child_json,kind,task_id FROM control_notices WHERE principal_id=? AND operation_id=?",field(c,"principal_id"),field(c,"operation_id"))
    if !ok do return false
    for row in rows {
        if !intent_enqueue(tx,Intent_Input{chain=field(c,"chain_id"),principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind=row[1],destination=payload_hash(row[0]),fence=row[0],payload=encode(doc(map[string]string{"task_id"=row[2],"method"=field(c,"method")}))}) do return false
    }
    return true
}

control_agent :: proc(tx:^Transaction,c,p:json.Object,child:Child,seq,now:i64,sign:Signer) -> (string,bool) {
    s:=tx.store
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    if !control_record(s,c,p,seq) do return "storage_error",false
    if _,ok:=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=? AND lease_id=? AND child_json=?",chain,task,field(c,"lease_id"),encode(child));!ok do return "storage_error",false
    if _,ok:=query(s.db,"UPDATE local_leases SET retired_seq=? WHERE lease_id=? AND retired_seq IS NULL",fmt.tprintf("%d",seq),field(c,"lease_id"));!ok do return "storage_error",false
    if method=="lease.block" {
        if control_held(s,chain,task) {
            if _,ok:=query(s.db,"UPDATE local_controls SET resume_state='blocked',waiting_on=? WHERE chain_id=? AND task_id=?",field(p,"waiting_on"),chain,task);!ok do return "storage_error",false
        } else if !control_mode(s,chain,task,"blocked","ready",field(p,"summary"),field(p,"waiting_on")) do return "storage_error",false
    }
    if _,ok:=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",false
    if method!="lease.switch" {
        if !control_notice(s,c,child,"stop") do return "storage_error",false
        return encode(doc(map[string]string{"state"=("blocked" if method=="lease.block" else ("ready" if control_ready(s,chain,task) else "held")) ,"revision"=fmt.tprintf("%d",number(field(c,"expected_revision"))+1)})),true
    }
    dest_chain,dest:=field(p,"destination_chain_id"),field(p,"destination_task_id")
    if dest==task do return "invalid_scope",false
    // Only this Store's immutable owner can issue the destination capability.
    config,binding,configured:=lifecycle_config(s,dest_chain,dest)
    req,has_req:=lifecycle_requirements(s,dest_chain,dest)
    if !configured || !has_req || encode(child)!=binding[1] || child.agent_id!=field(config,"author_agent_id") do return "invalid_scope",false
    if !dependency_ready(s,dest_chain,dest) do return "operation_conflict",false
    if code:=budget_admit(s,dest_chain,dest);code!="ok" do return code,false
    if !control_ready(s,dest_chain,dest) do return "operation_conflict",false
    if req[0]!=field(p,"destination_requirements_revision") do return "stale_revision",false
    states,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",dest_chain,dest)
    if !ok || len(states)!=1 || states[0][0]!="ready" do return "operation_conflict",false
    tasks,read:=query(s.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id=?",dest_chain,dest)
    if !read || len(tasks)!=1 do return "invalid_scope",false
    if tasks[0][0]!=field(p,"destination_revision") do return "stale_revision",false
    fleet,found:=query(s.db,"SELECT configuration_revision,instance_id,launch_epoch,run_count,token_generation,enabled FROM local_fleet WHERE chain_id=? AND task_id=?",dest_chain,dest)
    if !found || len(fleet)!=1 || fleet[0][0]!=field(p,"destination_configuration_revision") || fleet[0][1]!=child.instance || fleet[0][2]!=child.epoch ||
       number(fleet[0][3])!=child.run_count || fleet[0][4]!=child.token_generation || fleet[0][5]!="1" { return "invalid_scope",false }
    duplicate,checked:=query(s.db,"SELECT lease_id FROM local_leases WHERE lease_id=? OR (retired_seq IS NULL AND (task_id=? OR instance_id=?))",field(p,"destination_lease_id"),dest,child.instance)
    if !checked do return "storage_error",false
    if len(duplicate)>0 do return "operation_conflict",false
    target:=doc(map[string]string{})
    for key,value in c do target[key]=value
    target["chain_id"]=json.String(dest_chain);target["task_id"]=json.String(dest);target["lease_id"]=p["destination_lease_id"]
    target["configuration_revision"]=p["destination_configuration_revision"]
    expires,hard,deadline_ok:=lease_deadlines(s,dest_chain,dest,now)
    if !deadline_ok do return "invalid_content",false
    cap,signed:=lease_capability(s,target,expires,hard,sign)
    if !signed do return "storage_error",false
    if _,ok=query(s.db,"INSERT INTO local_leases VALUES(?,?,?,?,?,?,?,?,?,?,?,1,?,NULL)",field(p,"destination_lease_id"),dest_chain,dest,child.instance,child.epoch,fmt.tprintf("%d",child.run_count),child.token_generation,field(p,"destination_configuration_revision"),req[0],fmt.tprintf("%d",expires),fmt.tprintf("%d",hard),cap);!ok do return "storage_error",false
    attempt,recorded:=work_attempt_record(s,dest_chain,dest,field(p,"destination_lease_id"))
    if !recorded do return "storage_error",false
    // Deliberately no stop/checkpoint notice for the child now holding dest.
    return encode(doc(map[string]string{"work_attempt"=attempt,"state"="ready","revision"=fmt.tprintf("%d",number(field(c,"expected_revision"))+1),"destination_chain_id"=dest_chain,"destination_task_id"=dest,"destination_revision"=tasks[0][0],"lease_id"=field(p,"destination_lease_id"),"capability"=cap})),true
}

work_attempt_record :: proc(s:^Store,chain,task,lease:string) -> (string,bool) {
    rows,ok:=query(s.db,"INSERT INTO local_work_attempts SELECT ?,?,COALESCE(MAX(attempt),0)+1,? FROM local_work_attempts WHERE chain_id=? AND task_id=? RETURNING attempt",chain,task,lease,chain,task)
    if !ok || len(rows)!=1 do return "",false
    return rows[0][0],true
}

// Compatibility only: pre-fix runtimes retired holds and saved one narrowly
// scoped checkpoint. Never resurrect those leases or mint new such bindings.
control_checkpoint_authorized :: proc(s:^Store,c:json.Object,child:Child,cap:string,now:i64) -> bool {
    method:=field(c,"method")
    if method!="lease.handoff" && method!="review.checkpoint" do return false
    rows,ok:=query(s.db,"SELECT 1 FROM local_checkpoints p JOIN local_controls m ON m.chain_id=p.chain_id AND m.task_id=p.task_id WHERE p.chain_id=? AND p.task_id=? AND p.lease_id=? AND p.child_json=? AND p.capability_json=? AND p.expires_ms>? AND m.mode='held'",field(c,"chain_id"),field(c,"task_id"),field(c,"lease_id"),encode(child),cap,fmt.tprintf("%d",now))
    return ok && len(rows)==1
}
