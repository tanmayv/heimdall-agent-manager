#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

control_ready :: proc(s:^Store,chain,task:string) -> bool {
    rows,ok:=query(s.db,"SELECT mode FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    return ok && (len(rows)==0 || rows[0][0]=="ready")
}
control_notice :: proc(s:^Store,c:json.Object,child:Child,kind:string) -> bool {
    _,ok:=query(s.db,"INSERT OR IGNORE INTO control_notices VALUES(?,?,?,?,?,?)",field(c,"chain_id"),field(c,"task_id"),field(c,"principal_id"),field(c,"operation_id"),encode(child),kind)
    return ok
}
// Evidence remains immutable. Revocation changes only current authority and
// writes exact-child notices in the same caller transaction.
control_revoke :: proc(s:^Store,c:json.Object,seq:i64,kind:string,notify:=true,retire:=true) -> bool {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    rows,ok:=query(s.db,"SELECT instance_id,launch_epoch,token_generation,run_count FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NULL",chain,task)
    if !ok do return false
    agent:=""
    if config,_,found:=lifecycle_config(s,chain,task);found do agent=field(config,"author_agent_id")
    if notify {
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
    }
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
control_human :: proc(s:^Store,c,p:json.Object,body:string,seq:i64) -> string {
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    state:="ready"
    states,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return "storage_error"
    if len(states)==1 do state=states[0][0]
    controls,read:=query(s.db,"SELECT mode,resume_state FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    if !read do return "storage_error"
    mode,resume:="ready",state
    if len(controls)==1 { mode=controls[0][0];resume=controls[0][1] }
    next:=state
    switch method {
    case "task.hold":
        if mode!="ready" || state=="done" || state=="merge_pending" || state=="merge_blocked" do return "operation_conflict"
        mode="held";resume=state
        if !control_hold_checkpoints(s,chain,task) do return "storage_error"
        if !control_revoke(s,c,seq,"checkpoint") do return "storage_error"
    case "task.release":
        if mode!="held" do return "operation_conflict"
        mode="ready";next=resume
    case "task.cancel":
        if mode=="cancelled" || state=="done" do return "operation_conflict"
        mode="cancelled";next="ready"
        if !control_revoke(s,c,seq,"stop") do return "storage_error"
    case "task.reopen":
        generated,checked:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=?",task)
        if !checked do return "storage_error"
        if len(generated)>0 do return "operation_conflict"
        if mode!="cancelled" && state!="done" && state!="merge_blocked" do return "operation_conflict"
        mode="ready";next="ready"
        if !control_revoke(s,c,seq,"checkpoint") do return "storage_error"
    case "task.resolve":
        if mode!="blocked" do return "operation_conflict"
        mode="ready";next="ready"
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
    if method!="task.hold" {
        if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    }
    if !control_mode(s,chain,task,mode,resume,body,"") do return "storage_error"
    event:=doc(map[string]string{"summary"=body})
    if !control_record(s,c,event,seq) do return "storage_error"
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state=? WHERE chain_id=? AND task_id=?",next,chain,task);!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    return "ok"
}
control_intents :: proc(tx:^Transaction,c:json.Object,seq:i64) -> bool {
    rows,ok:=query(tx.store.db,"SELECT child_json,kind FROM control_notices WHERE principal_id=? AND operation_id=?",field(c,"principal_id"),field(c,"operation_id"))
    if !ok do return false
    for row in rows {
        if !intent_enqueue(tx,Intent_Input{chain=field(c,"chain_id"),principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind=row[1],destination=payload_hash(row[0]),fence=row[0],payload=encode(doc(map[string]string{"task_id"=field(c,"task_id"),"method"=field(c,"method")}))}) do return false
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
        if !control_mode(s,chain,task,"blocked","ready",field(p,"summary"),field(p,"waiting_on")) do return "storage_error",false
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
    cap,signed:=lease_capability(s,target,now+LEASE_TTL_MS,now+LEASE_HARD_MS,sign)
    if !signed do return "storage_error",false
    if _,ok=query(s.db,"INSERT INTO local_leases VALUES(?,?,?,?,?,?,?,?,?,?,?,1,?,NULL)",field(p,"destination_lease_id"),dest_chain,dest,child.instance,child.epoch,fmt.tprintf("%d",child.run_count),child.token_generation,field(p,"destination_configuration_revision"),req[0],fmt.tprintf("%d",now+LEASE_TTL_MS),fmt.tprintf("%d",now+LEASE_HARD_MS),cap);!ok do return "storage_error",false
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

// A hold retires execution/review authority but retains one narrowly scoped
// exact-child checkpoint. It can save handoff prose, never submit or vote.
control_hold_checkpoints :: proc(s:^Store,chain,task:string) -> bool {
    if _,ok:=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
    config,_,configured:=lifecycle_config(s,chain,task)
    if !configured do return true
    rows,ok:=query(s.db,"SELECT lease_id,instance_id,launch_epoch,token_generation,run_count,capability_json,expires_ms FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NULL",chain,task)
    if !ok do return false
    for row in rows {
        child:=Child{row[1],row[2],row[3],number(row[4]),field(config,"author_agent_id")}
        if _,ok=query(s.db,"INSERT INTO local_checkpoints VALUES(?,?,?,?,?,?)",chain,task,row[0],encode(child),row[5],row[6]);!ok do return false
    }
    _,ok=query(s.db,"INSERT INTO local_checkpoints SELECT r.chain_id,r.task_id,a.lease_id,r.child,r.capability_json,r.expires_ms FROM local_review_sessions r JOIN local_submissions a ON a.chain_id=r.chain_id AND a.task_id=r.task_id AND a.attempt=r.attempt WHERE r.chain_id=? AND r.task_id=?",chain,task)
    return ok
}
control_checkpoint_authorized :: proc(s:^Store,c:json.Object,child:Child,cap:string,now:i64) -> bool {
    method:=field(c,"method")
    if method!="lease.handoff" && method!="review.checkpoint" do return false
    rows,ok:=query(s.db,"SELECT 1 FROM local_checkpoints p JOIN local_controls m ON m.chain_id=p.chain_id AND m.task_id=p.task_id WHERE p.chain_id=? AND p.task_id=? AND p.lease_id=? AND p.child_json=? AND p.capability_json=? AND p.expires_ms>? AND m.mode='held'",field(c,"chain_id"),field(c,"task_id"),field(c,"lease_id"),encode(child),cap,fmt.tprintf("%d",now))
    return ok && len(rows)==1
}
