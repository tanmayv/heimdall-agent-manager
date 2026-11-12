#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

control_ready :: proc(s:^Store,chain,task:string) -> bool {
    if migration_quarantined(s,chain) do return false
    rows,ok:=query(s.db,"SELECT mode FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    return ok && (len(rows)==0 || rows[0][0]=="ready")
}
// Existing holders keep authority under a hold. New dispatch still requires
// control_ready; blocked/cancelled authority is never admitted by this helper.
control_active :: proc(s:^Store,chain,task:string) -> bool {
    if migration_quarantined(s,chain) do return false
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
    rows,ok:=query(s.db,"SELECT l.instance_id,l.launch_epoch,l.token_generation,l.run_count,COALESCE((SELECT j.child_json FROM owner_execution_journal j WHERE j.lease_id=l.lease_id AND j.state='committed'),'') FROM local_leases l WHERE l.chain_id=? AND l.task_id=? AND l.retired_seq IS NULL",chain,task)
    if !ok do return false
    agent:=""
    if config,_,found:=lifecycle_config(s,chain,task);found do agent=field(config,"author_agent_id")
    for row in rows {
        child:=Child{row[0],row[1],row[2],number(row[3]),agent}
        if row[4]!="" {
            // Remote grants retain the complete original Child, including its
            // author identity; a local lifecycle configuration may not exist.
            if json.unmarshal_string(row[4],&child,.JSON,context.temp_allocator)!=nil ||
               child.instance!=row[0] || child.epoch!=row[1] || child.token_generation!=row[2] ||
               child.run_count!=number(row[3]) || child.agent_id=="" {return false}
        }
        if !control_notice(s,c,child,kind) do return false
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
// A human escalation (task.escalate, R3-3) is the current block: only the
// user's device may clear it; agents cannot resolve, cancel or hold it.
control_escalated :: proc(s:^Store,chain,task:string) -> (bool,bool) {
    controls,ok:=query(s.db,"SELECT mode,resume_state FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return false,false
    if len(controls)!=1 || !(controls[0][0]=="blocked" || (controls[0][0]=="held" && controls[0][1]=="blocked")) do return false,true
    last,read:=query(s.db,"SELECT kind FROM local_handoffs WHERE chain_id=? AND task_id=? AND kind IN('lease.block','task.escalate') ORDER BY seq DESC LIMIT 1",chain,task)
    if !read do return false,false
    return len(last)==1 && last[0][0]=="task.escalate",true
}
// Tasks of a LANGUAGE workflow run are controlled through workflow.cancel /
// workflow.retry. Legacy-run stage tasks stay cancellable: nothing else can
// stop them (workflow.cancel handles pending and language runs only).
control_workflow_generated :: proc(s:^Store,chain,task:string) -> (bool,bool) {
    rows,ok:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=? LIMIT 1",task)
    if !ok do return false,false
    return len(rows)>0 && !migration_archived_task(s,chain,task),true
}
// reopen_refusal_cause names why task.reopen answered operation_conflict
// (T1: reopen errors must name their cause). Read-only, mirrors the checks of
// control_human's task.reopen branch in order; "" when no cause is found.
reopen_refusal_cause :: proc(s:^Store,chain,task:string) -> string {
    if status,ok:=query(s.db,"SELECT status FROM local_work_chains WHERE chain_id=?",chain);ok && len(status)==1 && status[0][0]!="active" {
        return fmt.tprintf("chain not active (status %s)",status[0][0])
    }
    if migration_archived_task(s,chain,task) do return "an archived workflow stage imported from the Hub cannot be reopened"
    consumers,ok:=query(s.db,"SELECT DISTINCT dependent_kind,dependent_id FROM local_work_inputs WHERE chain_id=? AND prerequisite_kind='task' AND prerequisite_id=? ORDER BY dependent_kind,dependent_id",chain,task)
    if !ok do return ""
    if len(consumers)>0 {
        names:=make([dynamic]string,context.temp_allocator)
        for row in consumers do append(&names,fmt.tprintf("%s %s",row[0],row[1]))
        return fmt.tprintf("consumed by a started dependent (%s); create replacement work instead",strings.join(names[:],", ",context.temp_allocator))
    }
    if generated,read:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=?",task);read && len(generated)>0 {
        return "a generated workflow task: retry or cancel the workflow run instead"
    }
    if triggered,read:=query(s.db,"SELECT 1 FROM local_workflow_output_triggers WHERE chain_id=? AND source_task=? AND consumed=1 LIMIT 1",chain,task);read && len(triggered)>0 {
        return "consumed by a started workflow run (its output trigger fired); create replacement work instead"
    }
    state,mode:="ready","ready"
    if rows,read:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task);read && len(rows)==1 do state=rows[0][0]
    if rows,read:=query(s.db,"SELECT mode FROM local_controls WHERE chain_id=? AND task_id=?",chain,task);read && len(rows)==1 do mode=rows[0][0]
    if mode!="cancelled" && state!="done" && state!="merge_blocked" {
        return fmt.tprintf("not cancelled, done or merge-blocked (state %s, control %s)",state,mode)
    }
    return ""
}
// task.cancel dependents handling (R2-2), inside the cancel transaction:
// keep leaves dependents waiting (reported as a warning), drop removes their
// edge to the cancelled task, repoint:<task> moves the edge to another task
// with dependency.edit's generated-edge and cycle checks.
control_cancel_dependents :: proc(s:^Store,c,p:json.Object) -> (string,[]string) {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    rows,ok:=query(s.db,"SELECT task_id FROM local_dependencies WHERE chain_id=? AND prerequisite=? ORDER BY task_id",chain,task)
    if !ok do return "storage_error",nil
    dependents:=make([dynamic]string,context.temp_allocator)
    for row in rows do append(&dependents,row[0])
    mode:=field(p,"dependents")
    if mode=="" || mode=="keep" do return "ok",dependents[:]
    target:=""
    if mode!="drop" {
        target=mode[len("repoint:"):]
        if target==task do return "invalid_scope",nil
        exists,read:=query(s.db,"SELECT 1 FROM tasks WHERE chain_id=? AND task_id=?",chain,target)
        if !read do return "storage_error",nil
        if len(exists)!=1 do return "invalid_scope",nil
    }
    for d in dependents {
        // Generated private graph edges remain controlled by their workflow plan.
        generated,read:=query(s.db,"SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id IN(?,?)",chain,d,target)
        if !read do return "storage_error",nil
        if len(generated)>0 do return "operation_conflict",nil
        if _,ok=query(s.db,"DELETE FROM local_dependencies WHERE chain_id=? AND task_id=? AND prerequisite=?",chain,d,task);!ok do return "storage_error",nil
        if target!="" {
            if d==target || !work_edge_acyclic(s,chain,"task",d,"task",target) do return "operation_conflict",nil
            if _,ok=query(s.db,"INSERT OR IGNORE INTO local_dependencies VALUES(?,?,?)",chain,d,target);!ok do return "storage_error",nil
        }
        if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,d);!ok do return "storage_error",nil
    }
    return "ok",dependents[:]
}
// Device controls and their coordinator forms (agent=true). Returns the extra
// result fields for the caller's receipt; code "unchanged" (task.recheck)
// means nothing changed and nothing must be recorded.
control_human :: proc(s:^Store,c,p:json.Object,body:string,seq:i64,agent:=false) -> (string,json.Object) {
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    state:="ready"
    states,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return "storage_error",nil
    if len(states)==1 do state=states[0][0]
    controls,read:=query(s.db,"SELECT mode,resume_state,reason,waiting_on FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    if !read do return "storage_error",nil
    mode,resume,reason,waiting:="ready","ready",body,""
    if len(controls)==1 { mode=controls[0][0];resume=controls[0][1];waiting=controls[0][3] }
    escalated,escalation_read:=control_escalated(s,chain,task)
    if !escalation_read do return "storage_error",nil
    if agent && escalated && (method=="task.resolve" || method=="task.cancel" || method=="task.hold") do return "invalid_scope",nil
    next:=state
    // revoke and recheck leave the control overlay as it is.
    overlay:=method!="lease.revoke" && method!="task.recheck"
    extra:json.Object
    event:=doc(map[string]string{"summary"=body})
    switch method {
    case "task.hold":
        if (mode!="ready" && mode!="blocked") || state=="done" || state=="merge_pending" || state=="merge_blocked" do return "operation_conflict",nil
        resume=mode;mode="held"
        // A hold asks for a checkpoint; it neither retires capabilities nor
        // invalidates review/merge evidence. TTL and exact-child fences remain.
        if !control_notify(s,c,"checkpoint") do return "storage_error",nil
    case "task.release":
        if mode!="held" do return "operation_conflict",nil
        mode="ready"
        // Pre-fix holds stored lifecycle state in resume_state; always retain
        // the current lifecycle state. A native block is a separate overlay.
        if resume=="blocked" do mode="blocked"
        if mode=="blocked" {
            blocks,found:=query(s.db,"SELECT summary FROM local_handoffs WHERE chain_id=? AND task_id=? AND kind IN('lease.block','task.escalate') ORDER BY seq DESC LIMIT 1",chain,task)
            if !found || len(blocks)!=1 do return "storage_error",nil
            reason=blocks[0][0]
        }
    case "task.cancel":
        if mode=="cancelled" || state=="done" do return "operation_conflict",nil
        generated,checked:=control_workflow_generated(s,chain,task)
        if !checked do return "storage_error",nil
        if generated do return "operation_conflict",nil
        code,dependents:=control_cancel_dependents(s,c,p)
        if code!="ok" do return code,nil
        if len(dependents)>0 {
            choice:=field(p,"dependents")
            if choice=="" do choice="keep"
            extra=doc(map[string]string{"dependents"=choice,"dependent_task_ids"=strings.join(dependents,",",context.temp_allocator)})
            if choice=="keep" do extra["warning"]=json.String("dependent tasks stay blocked on this cancelled task; drop or repoint their dependency to unblock them")
        }
        runs,runs_read:=work_run_dependents(s,chain,task)
        if !runs_read do return "storage_error",nil
        if len(runs)>0 {
            if extra==nil do extra=doc(map[string]string{})
            extra["workflow_run_dependents"]=json.String(strings.join(runs,",",context.temp_allocator))
            note:="workflow runs depend on this task and stay blocked on it; edit their work dependencies"
            if prior,has:=extra["warning"].(json.String);has do note=fmt.tprintf("%s; %s",string(prior),note)
            extra["warning"]=json.String(note)
        }
        mode="cancelled";next="ready";waiting=""
        if !control_revoke(s,c,seq,"stop") do return "storage_error",nil
    case "task.reopen":
        // Imported workflow stage tasks are archival; reopening them would
        // turn a stage of an archived run into an ordinary ticket.
        if migration_archived_task(s,chain,task) do return "operation_conflict",nil
        if !work_unconsumed(s,chain,"task",task) do return "operation_conflict",nil
        generated,checked:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=?",task)
        if !checked do return "storage_error",nil
        if len(generated)>0 do return "operation_conflict",nil
        consumed,read_consumed:=query(s.db,"SELECT 1 FROM local_workflow_output_triggers WHERE chain_id=? AND source_task=? AND consumed=1 LIMIT 1",chain,task)
        if !read_consumed do return "storage_error",nil
        if len(consumed)>0 do return "operation_conflict",nil
        if mode!="cancelled" && state!="done" && state!="merge_blocked" do return "operation_conflict",nil
        mode="ready";next="ready";waiting=""
        if !control_revoke(s,c,seq,"checkpoint") do return "storage_error",nil
    case "task.resolve":
        if mode!="blocked" do return "operation_conflict",nil
        mode="ready";next="ready";waiting=""
    case "task.escalate":
        // Coordinator-initiated blocked-on-human (R2-5, R3-3). A held task is
        // released first so an escalation is never hidden under a hold.
        if (mode!="ready" && mode!="blocked") || state!="ready" do return "operation_conflict",nil
        mode="blocked";resume="ready";waiting="human"
        event["waiting_on"]=json.String("human")
        // The task leaves dispatch; a live holder is asked to checkpoint.
        if !control_revoke(s,c,seq,"checkpoint") do return "storage_error",nil
    case "lease.revoke":
        // End the current work lease without cancelling (REQ-CC-5). The task
        // keeps its attempts and history and returns to dispatch.
        if mode=="cancelled" do return "operation_conflict",nil
        live,found:=query(s.db,"SELECT 1 FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NULL",chain,task)
        if !found do return "storage_error",nil
        if len(live)==0 do return "operation_conflict",nil
        if !control_revoke(s,c,seq,field(p,"mode")) do return "storage_error",nil
        if field(p,"disable_fleet")=="1" {
            // Reassignment (R3-2): the same child must not reclaim the task
            // before fleet.edit names its replacement.
            // Same shape as operational retirement: the revision advances so
            // the replacement fleet.edit is a strictly newer configuration.
            if _,ok=query(s.db,"UPDATE local_fleet SET enabled=0,configuration_revision=configuration_revision+1 WHERE chain_id=? AND task_id=? AND enabled=1",chain,task);!ok do return "storage_error",nil
        }
        extra=doc(map[string]string{"mode"=field(p,"mode"),"fleet_disabled"=field(p,"disable_fleet")})
    case "task.recheck":
        // Re-run the review gate on verdicts already posted (Hub recheck.odin
        // parity): it never approves and records nothing when nothing changes.
        if mode!="ready" || state!="in_review" || len(states)!=1 do return "unchanged",doc(map[string]string{"state"=state,"mode"=mode})
        gate,valid:=review_gate(s,chain,task,states[0][1])
        if !valid do return "storage_error",nil
        if gate==state do return "unchanged",doc(map[string]string{"state"=state,"mode"=mode})
        next=gate
        if _,ok=query(s.db,"DELETE FROM local_review_sessions WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
        extra=doc(map[string]string{"previous_state"=state,"state"=next})
    case "merge.retry":
        if mode!="ready" || state!="merge_blocked" do return "operation_conflict",nil
        config,_,found:=lifecycle_config(s,chain,task)
        req,has_req:=lifecycle_requirements(s,chain,task)
        submitted,got:=query(s.db,"SELECT attempt,head,configuration_revision FROM local_submissions WHERE chain_id=? AND task_id=? ORDER BY attempt DESC LIMIT 1",chain,task)
        if !found || !has_req || !got || len(submitted)!=1 || submitted[0][0]!=field(p,"attempt") || submitted[0][1]!=field(p,"head") ||
           req[0]!=field(p,"requirements_revision") || field(config,"configuration_revision")!=field(p,"configuration_revision") || submitted[0][2]!=field(p,"configuration_revision") { return "stale_revision",nil }
        pending,read:=query(s.db,"SELECT intent_id FROM runtime_intents WHERE chain_id=? AND kind='merge' AND json_extract(exact_fence_json,'$.task_id')=? AND json_extract(exact_fence_json,'$.attempt')=? AND state='pending' AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=runtime_intents.intent_id)",chain,task,field(p,"attempt"))
        if !read do return "storage_error",nil
        if len(pending)!=1 do return "operation_conflict",nil
        // Preserve the original intent identity, prepared head and retry floor.
        // A signed retry acknowledges repair; it never rebinds Git input.
        next="merge_pending"
    case: return "malformed",nil
    }
    if method!="task.hold" && method!="task.recheck" {
        if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    }
    if overlay && !control_mode(s,chain,task,mode,resume,reason,waiting) do return "storage_error",nil
    if method=="task.release" && next=="in_review" {
        gate,valid:=review_gate(s,chain,task,states[0][1])
        if !valid do return "storage_error",nil
        next=gate
        if next!="in_review" {
            if _,ok=query(s.db,"DELETE FROM local_review_sessions WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
        }
    }
    if !control_record(s,c,event,seq) do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state=? WHERE chain_id=? AND task_id=?",next,chain,task);!ok do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    return "ok",extra
}
control_intents :: proc(tx:^Transaction,c:json.Object,seq:i64) -> bool {
    rows,ok:=query(tx.store.db,"SELECT child_json,kind,task_id FROM control_notices WHERE principal_id=? AND operation_id=?",field(c,"principal_id"),field(c,"operation_id"))
    if !ok do return false
    for row in rows {
        if row[1]=="stop" {
            handled,ok:=execution_stop_intent(tx,c,row[0],seq,row[2])
            if !ok do return false
            if handled do continue
        }
        if row[1]=="checkpoint" {
            handled,ok:=execution_notification_intent(tx,c,row[0],seq)
            if !ok do return false
            if handled do continue
        }
        if !intent_enqueue(tx,Intent_Input{chain=field(c,"chain_id"),principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind=row[1],destination=payload_hash(row[0]),fence=row[0],payload=encode(doc(map[string]string{"task_id"=row[2],"method"=field(c,"method")}))}) do return false
    }
    return true
}

control_agent :: proc(tx:^Transaction,c,p:json.Object,child:Child,seq,now:i64,sign:Signer) -> (string,bool) {
    s:=tx.store
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    // Switching starts new destination work, so it has the same publication
    // admission as claim. Check before recording or retiring the source.
    if method=="lease.switch" && !work_task_published(s,field(p,"destination_chain_id"),field(p,"destination_task_id")) do return "operation_conflict",false
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
    now:=store_now(s,now) // C1: the store's single clock source
    method:=field(c,"method")
    if method!="lease.handoff" && method!="review.checkpoint" do return false
    // A quarantined (unactivated migration import) chain grants no authority,
    // including this compatibility checkpoint path for held tasks.
    if migration_quarantined(s,field(c,"chain_id")) do return false
    rows,ok:=query(s.db,"SELECT 1 FROM local_checkpoints p JOIN local_controls m ON m.chain_id=p.chain_id AND m.task_id=p.task_id WHERE p.chain_id=? AND p.task_id=? AND p.lease_id=? AND p.child_json=? AND p.capability_json=? AND p.expires_ms>? AND m.mode='held'",field(c,"chain_id"),field(c,"task_id"),field(c,"lease_id"),encode(child),cap,fmt.tprintf("%d",now))
    return ok && len(rows)==1
}
