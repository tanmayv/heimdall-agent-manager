#+feature dynamic-literals
package owner_local

// P-CS CC-B: coordinator work operations on owner chains, outside the lease
// system. Each runs inside execute()'s transaction after agent admission
// (agent_authority.odin: coordinator only) and the shared execute-path gates
// (deferred workflow retirements, workflow_task_current, quarantine, reason).
//
//   lifecycle.force_submit  ready -> in_review bound to the task's last
//                           retired lease (REQ-CC-6, R2-3, R3-4).
//   task.complete --force   skips ONLY the independent-agent review; never a
//                           user-approval gate (REQ-CC-7 as replaced by R2-4).
//   task.split              N children + links + dependents, original
//                           cancelled, one transaction (REQ-CC-9, R2-8).
//   chain.policy.set        device-only chain policy (coordinator_force_done).
//
// REQ-CC-13: a coordinator never reviews, force-completes or names itself a
// reviewer of a task it worked as the worker (Hub solo_self_review parity).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"
import wf "odin_test:lib/workflow_v1"

// A language-run item, a legacy workflow stage task or an archived imported
// stage: controlled by workflow.cancel/retry, never by these operations.
coordinator_generated :: proc(s:^Store,chain,task:string) -> (bool,bool) {
    rows,ok:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=?1 UNION ALL SELECT 1 FROM local_workflow_tasks WHERE chain_id=?2 AND task_id=?1 LIMIT 1",task,chain)
    if !ok do return false,false
    return len(rows)>0 || migration_archived_task(s,chain,task),true
}

// REQ-CC-13: the agent worked this task as its worker (it is the configured
// author, held one of its leases, or authored one of its submissions).
agent_self_worked :: proc(s:^Store,chain,task:string,agent:Child) -> (bool,bool) {
    if agent.instance=="" do return false,true
    if config,_,configured:=lifecycle_config(s,chain,task);configured && field(config,"author_agent_id")==agent.agent_id do return true,true
    rows,ok:=query(s.db,`SELECT 1 FROM local_leases WHERE chain_id=?1 AND task_id=?2 AND instance_id=?3
      UNION ALL SELECT 1 FROM local_submissions WHERE chain_id=?1 AND task_id=?2 AND author_agent_id=?4 LIMIT 1`,chain,task,agent.instance,agent.agent_id)
    if !ok do return false,false
    return len(rows)>0,true
}

// coordinator_force_done: device-signed, newest version wins, default on.
force_done_enabled :: proc(s:^Store,chain:string) -> (bool,bool) {
    rows,ok:=query(s.db,"SELECT value FROM local_chain_policies WHERE chain_id=? AND policy='coordinator_force_done' ORDER BY accepted_seq DESC LIMIT 1",chain)
    if !ok do return false,false
    return len(rows)==0 || rows[0][0]=="1",true
}

// Every user-approval source of the task at this attempt (R2-4): the current
// brief, the submitted brief of the attempt, the latest role configuration and
// a workflow-language item flag.
complete_user_gate :: proc(s:^Store,chain,task,attempt:string) -> (required,approved,ok:bool) {
    required,ok=task_user_approval_required(s,chain,task)
    if !ok do return
    rows,read:=query(s.db,`SELECT 1 FROM local_submissions WHERE chain_id=?1 AND task_id=?2 AND attempt=?3 AND json_extract(requirements_json,'$.requires_user_approval')=1
      UNION ALL SELECT 1 FROM local_workflow_language_items WHERE task_id=?2 AND requires_user_approval=1 LIMIT 1`,chain,task,attempt)
    if !read do return false,false,false
    required=required || len(rows)>0
    device,dread:=query(s.db,"SELECT 1 FROM local_reviews WHERE chain_id=? AND task_id=? AND attempt=? AND principal_kind='device' AND reviewer_agent_id=principal_id AND verdict='approve' LIMIT 1",chain,task,attempt)
    if !dread do return false,false,false
    return required,len(device)>0,true
}

// The agent reviews the gate would still wait for at this attempt.
complete_skipped_gates :: proc(s:^Store,chain,task,attempt:string,config:json.Object) -> ([]string,bool) {
    out:=make([dynamic]string,context.temp_allocator)
    independent,ok:=query(s.db,"SELECT 1 FROM local_reviews WHERE chain_id=? AND task_id=? AND attempt=? AND reviewer_agent_id=? AND verdict='approve' LIMIT 1",chain,task,attempt,field(config,"reviewer_agent_id"))
    if !ok do return nil,false
    if len(independent)==0 do append(&out,"independent_review")
    owed,read:=query(s.db,`SELECT p.role FROM local_role_pairs p WHERE chain_id=?1 AND task_id=?2
      AND revision=(SELECT max(revision) FROM local_role_configs c WHERE c.chain_id=p.chain_id AND c.task_id=p.task_id)
      AND NOT EXISTS(SELECT 1 FROM local_role_reviews r WHERE r.chain_id=p.chain_id AND r.task_id=p.task_id AND r.attempt=?3
        AND r.role_revision=p.revision AND r.role=p.role AND r.agent_id=p.agent_id AND r.verdict='approve') ORDER BY p.role`,chain,task,attempt)
    if !read do return nil,false
    for row in owed do append(&out,fmt.tprintf("role:%s",row[0]))
    return out[:],true
}

// Why task.complete --force would be refused, for the caller's message and
// for complete_command itself. code "ok" means it may proceed.
complete_check :: proc(s:^Store,chain,task:string,agent:Child) -> (code,reason:string) {
    generated,checked:=coordinator_generated(s,chain,task)
    if !checked do return "storage_error",""
    if generated do return "operation_conflict","a workflow-generated task is completed by its workflow (workflow retry/cancel)"
    enabled,read:=force_done_enabled(s,chain)
    if !read do return "storage_error",""
    if !enabled do return "invalid_scope","the chain policy coordinator_force_done is off (only the user can turn it on)"
    if !control_ready(s,chain,task) do return "operation_conflict","the task is held, blocked or cancelled"
    config,_,configured:=lifecycle_config(s,chain,task)
    if !configured do return "invalid_scope","the task has no lifecycle configuration"
    self,self_read:=agent_self_worked(s,chain,task,agent)
    if !self_read do return "storage_error",""
    if self do return "invalid_scope","solo_self_review: the coordinator worked this task, so the user reviews it"
    states,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok || len(states)!=1 do return "storage_error",""
    state,attempt:=states[0][0],states[0][1]
    git:=field(config,"merge_policy")=="git"
    if state!="in_review" && !(state=="ready" && !git) do return "operation_conflict","only a task in review (or a ready task without a Git merge) can be completed"
    if git {
        heads,hread:=query(s.db,"SELECT head FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,attempt)
        if !hread do return "storage_error",""
        if len(heads)!=1 || heads[0][0]=="" do return "operation_conflict","merge_policy git needs a submitted head"
    }
    // The user's explicit rejection of the latest attempt stands: a device
    // request_changes on it (the task went back to ready, or the verdict
    // waits under a hold) is never overridden by force-done. A new
    // submission (a new attempt) follows the normal rules.
    rejected,rread:=query(s.db,"SELECT 1 FROM local_reviews WHERE chain_id=? AND task_id=? AND attempt=? AND principal_kind='device' AND verdict='request_changes' LIMIT 1",chain,task,attempt)
    if !rread do return "storage_error",""
    if len(rejected)>0 do return "invalid_scope","the user requested changes on the latest attempt; force-done never overrides the user's verdict"
    required,approved,gate_ok:=complete_user_gate(s,chain,task,attempt if state=="in_review" else "0")
    if !gate_ok do return "storage_error",""
    if required && !approved do return "invalid_scope","the task requires the user's approval (device-signed review); force-done never skips it"
    if !language_policy_ready(s,chain,task) do return "operation_conflict","the brief's assignee/reviewer policy does not match the task configuration"
    return "ok",""
}

complete_command :: proc(s:^Store,c,p:json.Object,reason:string,seq:i64,agent:Child) -> (string,json.Object) {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    // Non-force completion is task.recheck (R2-4a).
    if field(p,"force")!="1" do return "invalid_content",nil
    if code,_:=complete_check(s,chain,task,agent);code!="ok" do return code,nil
    config,_,_:=lifecycle_config(s,chain,task)
    states,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok || len(states)!=1 do return "storage_error",nil
    state,attempt:=states[0][0],states[0][1]
    head:=""
    if state=="in_review" {
        heads,read:=query(s.db,"SELECT head FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,attempt)
        if !read || len(heads)!=1 do return "storage_error",nil
        head=heads[0][0]
    }
    // Bound to the attempt and head the coordinator saw.
    if attempt!=field(p,"attempt") || head!=field(p,"head") do return "stale_revision",nil
    // Every agent review the gate would still wait for: the independent
    // review and each owed role pair (a ready task owes all of them).
    skipped,skipped_read:=complete_skipped_gates(s,chain,task,attempt if state=="in_review" else "0",config)
    if !skipped_read do return "storage_error",nil
    next:="merge_pending" if field(config,"merge_policy")=="git" else "done"
    // Any live lease (a ready task) ends; review sessions close.
    if !control_revoke(s,c,seq,"stop") do return "storage_error",nil
    if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state=? WHERE chain_id=? AND task_id=?",next,chain,task);!ok do return "storage_error",nil
    skipped_text:=strings.join(skipped,",",context.temp_allocator)
    record:=doc(map[string]string{"summary"=reason,"next_steps"=fmt.tprintf("forced by coordinator; skipped gates: %s",skipped_text if skipped_text!="" else "none")})
    if !control_record(s,c,record,seq) do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    // The event carries forced/skipped_gates/notify so the user sees it.
    return "ok",doc(map[string]string{"state"=next,"previous_state"=state,"attempt"=attempt,"forced"="1","skipped_gates"=skipped_text,"notify"="user"})
}

// ---- lifecycle.force_submit ------------------------------------------------

force_submit_command :: proc(s:^Store,c,p:json.Object,reason:string,seq:i64,source:Source_Proof,agent:Child) -> (string,json.Object) {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    generated,checked:=coordinator_generated(s,chain,task)
    if !checked do return "storage_error",nil
    if generated do return "operation_conflict",nil
    if !control_ready(s,chain,task) do return "operation_conflict",nil
    config,binding,configured:=lifecycle_config(s,chain,task)
    if !configured do return "invalid_scope",nil
    req,has_req:=lifecycle_requirements(s,chain,task)
    if !has_req || req[0]!=field(p,"requirements_revision") do return "stale_revision",nil
    states,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok || len(states)!=1 do return "storage_error",nil
    if states[0][0]!="ready" do return "operation_conflict",nil
    // R3-4: a task that never had a lease has nothing to submit.
    ever,read:=query(s.db,"SELECT 1 FROM local_leases WHERE chain_id=? AND task_id=? LIMIT 1",chain,task)
    if !read do return "storage_error",nil
    if len(ever)==0 do return "operation_conflict",nil
    // The Bridge observed the worktree head itself (as lease.submit).
    if !source.valid || source.head!=field(p,"head") || ((field(config,"merge_policy")=="git") != (source.head!="")) do return "invalid_scope",nil
    output_err:=wf.validate_task_output_contract(req[1],"")
    if output_err.code!=.None do return "invalid_content",nil
    // A live lease is revoked first (stop): its holder gets a stop notice and
    // the submission binds the lease it was working under.
    live,live_read:=query(s.db,"SELECT 1 FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NULL",chain,task)
    if !live_read do return "storage_error",nil
    revoked:=len(live)>0
    if revoked && !control_revoke(s,c,seq,"stop") do return "storage_error",nil
    last,last_read:=query(s.db,"SELECT lease_id,instance_id,launch_epoch,token_generation,run_count,configuration_revision FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NOT NULL ORDER BY retired_seq DESC,rowid DESC LIMIT 1",chain,task)
    if !last_read || len(last)!=1 do return "storage_error",nil
    lease:=last[0][0]
    // The bound lease belongs to the current configuration (lease.submit
    // parity, lifecycle_agent.odin): it was granted under the current fleet
    // revision, its holder is the configured author and never the reviewer.
    // After a reassignment the old holder's work is not submitted under the
    // new author's name.
    fleet_rev,fleet_read:=query(s.db,"SELECT configuration_revision FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
    if !fleet_read do return "storage_error",nil
    if len(fleet_rev)!=1 || fleet_rev[0][0]!=last[0][5] do return "operation_conflict",nil
    bound_author,author_parsed:=contracts.owner_request_document(binding[1]);author_obj,is_obj:=bound_author.(json.Object)
    if !author_parsed || !is_obj || field(author_obj,"instance")!=last[0][1] do return "operation_conflict",nil
    if last[0][1]==field(config,"reviewer_instance_id") do return "operation_conflict",nil
    // That lease already produced a submission: nothing new to bind.
    used,used_read:=query(s.db,"SELECT 1 FROM local_submissions WHERE lease_id=?",lease)
    if !used_read do return "storage_error",nil
    if len(used)>0 do return "operation_conflict",nil
    // R3-4: the requirements acknowledgement of that lease, or an audited
    // explicit override (the reason is mandatory on this path).
    ack,ack_read:=query(s.db,"SELECT 1 FROM requirement_ack WHERE lease_id=? AND revision=? AND acknowledged=1",lease,req[0])
    if !ack_read do return "storage_error",nil
    overridden:=len(ack)==0
    if overridden && field(p,"override_ack")!="1" do return "stale_revision",nil
    author:=field(config,"author_agent_id")
    author_child:=Child{last[0][1],last[0][2],last[0][3],number(last[0][4]),author}
    attempt:=number(states[0][1])+1
    if _,ok=query(s.db,"INSERT INTO local_submissions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",chain,task,fmt.tprintf("%d",attempt),lease,author,encode(author_child),req[0],field(config,"configuration_revision"),source.head,field(p,"summary"),req[1],agent.instance,field(c,"operation_id"));!ok do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state='in_review',attempt=? WHERE chain_id=? AND task_id=?",fmt.tprintf("%d",attempt),chain,task);!ok do return "storage_error",nil
    if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    bound:=doc(map[string]string{})
    for k,v in c do bound[k]=v
    bound["lease_id"]=json.String(lease)
    record:=doc(map[string]string{"summary"=reason,"next_steps"=("requirements acknowledgement overridden" if overridden else "")})
    if !control_record(s,bound,record,seq) do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    return "ok",doc(map[string]string{"state"="in_review","attempt"=fmt.tprintf("%d",attempt),"head"=source.head,"lease_id"=lease,
        "author_agent_id"=author,"submitted_by"=agent.instance,"override_ack"=("1" if overridden else "0"),"live_lease_revoked"=("1" if revoked else "0")})
}

// ---- task.split ------------------------------------------------------------

Split_Child :: struct {
    task_id,title,body,brief,assignee:string,
    unassigned:bool,
}

split_parse :: proc(body:string) -> (reason,mode:string,children:[]Split_Child,mapping:json.Object,ok:bool) {
    v,valid:=contracts.owner_request_document(body);o,obj:=v.(json.Object)
    if !valid || !obj do return
    reason=strings.trim_space(field(o,"reason"))
    mode=field(o,"dependents")
    if mode=="" do mode="all"
    if mode!="all" && mode!="last" && mode!="map" do return
    if mode=="map" {
        m,is_map:=o["map"].(json.Object)
        if !is_map do return
        mapping=m
    }
    list,array:=o["children"].(json.Array)
    if !array || len(list)<1 || len(list)>32 do return
    out:=make([dynamic]Split_Child,context.temp_allocator)
    for item in list {
        spec,is_obj:=item.(json.Object)
        if !is_obj do return
        child:=Split_Child{task_id=field(spec,"task_id"),title=field(spec,"title"),body=field(spec,"body"),assignee=field(spec,"assignee_instance_id")}
        if b,typed:=spec["unassigned"].(json.Boolean);typed do child.unassigned=bool(b)
        if brief,has:=spec["brief"];has && brief!=nil {
            bo,bobj:=brief.(json.Object)
            if !bobj do return
            child.brief=encode(bo)
        }
        if !contracts.owner_field_valid(child.task_id,"id") || strings.trim_space(child.title)=="" || len(child.title)>MAX_BODY || len(child.body)>MAX_BODY do return
        if child.assignee!="" && (child.unassigned || !contracts.owner_field_valid(child.assignee,"id")) do return
        for prior in out do if prior.task_id==child.task_id do return
        append(&out,child)
    }
    return reason,mode,out[:],mapping,true
}

// A child of a gated original inherits requires_user_approval unless its
// brief explicitly sets it false (cleared: the coordinator removes the gate,
// audited in the split result).
split_brief_with_approval :: proc(brief:string) -> (gated:string,cleared:bool) {
    v,ok:=contracts.owner_request_document(brief);o,obj:=v.(json.Object)
    if !ok || !obj do return brief,false
    if flag,has:=o["requires_user_approval"];has {
        if b,typed:=flag.(json.Boolean);typed && !bool(b) do return brief,true
    }
    o["requires_user_approval"]=json.Boolean(true)
    return encode(o),false
}

// Atomic split inside execute()'s transaction; any refusal rolls back the
// whole command (children, links, dependents and the cancellation).
split_command :: proc(s:^Store,c:json.Object,command_raw,payload,body:string,seq:i64,device,agent_mode:bool,observed:[]Child) -> (string,json.Object) {
    chain,task,principal,op:=field(c,"chain_id"),field(c,"task_id"),field(c,"principal_id"),field(c,"operation_id")
    reason,mode,children,mapping,parsed:=split_parse(body)
    if !parsed do return "invalid_content",nil
    if reason=="" do return "invalid_content",nil
    generated,checked:=coordinator_generated(s,chain,task)
    if !checked do return "storage_error",nil
    if generated do return "operation_conflict",nil
    if agent_mode {
        escalated,read:=control_escalated(s,chain,task)
        if !read do return "storage_error",nil
        if escalated do return "invalid_scope",nil
    }
    controls,cread:=query(s.db,"SELECT mode FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    if !cread do return "storage_error",nil
    if len(controls)==1 && controls[0][0]=="cancelled" do return "operation_conflict",nil
    states,sread:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !sread do return "storage_error",nil
    // R2-8: never while in review or merging, and not once finished.
    if len(states)==1 && states[0][0]!="ready" do return "operation_conflict",nil
    // The original's approval obligation, inherited by each child unless the
    // child brief explicitly clears it.
    original_gated,gate_read:=task_user_approval_required(s,chain,task)
    if !gate_read do return "storage_error",nil
    original_brief:=""
    if req,has:=lifecycle_requirements(s,chain,task);has do original_brief=req[1]
    config,binding,configured:=lifecycle_config(s,chain,task)
    fleet,fread:=query(s.db,"SELECT instance_id,enabled,launch_epoch,run_count,token_generation,configuration_command FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
    if !fread do return "storage_error",nil
    // A remote reservation is claimed only by its executor preparation; it is
    // never copied (the child starts unassigned).
    copy_fleet:=len(fleet)==1
    if copy_fleet {
        assigned,valid:=contracts.owner_parse(fleet[0][5],"command")
        if !valid || field(assigned,"method")=="fleet.reserve" do copy_fleet=false
    }
    roles,rread:=query(s.db,"SELECT revision,requires_user_approval,pairs_json FROM local_role_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
    if !rread do return "storage_error",nil
    priority,pread:=query(s.db,"SELECT priority FROM local_task_priority_versions WHERE chain_id=? AND task_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,task)
    if !pread do return "storage_error",nil
    publication,pubread:=query(s.db,"SELECT publish_state FROM local_task_publications WHERE chain_id=? AND task_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,task)
    if !pubread do return "storage_error",nil
    prerequisites,dread:=query(s.db,"SELECT prerequisite FROM local_dependencies WHERE chain_id=? AND task_id=? ORDER BY prerequisite",chain,task)
    if !dread do return "storage_error",nil
    stamp:=fmt.tprintf("%d",seq)
    ids:=make([dynamic]string,context.temp_allocator)
    cleared_ids:=make([dynamic]string,context.temp_allocator)
    for child,i in children {
        id:=child.task_id
        exists,eread:=query(s.db,"SELECT 1 FROM tasks WHERE task_id=?1 UNION ALL SELECT 1 FROM task_deletions WHERE task_id=?1 LIMIT 1",id)
        if !eread do return "storage_error",nil
        if len(exists)>0 do return "operation_conflict",nil
        if _,ok:=query(s.db,"INSERT INTO tasks VALUES(?,?,?,?,1)",chain,id,child.title,child.body);!ok do return "storage_error",nil
        brief:=brief_without_reason(s,child.brief if child.brief!="" else original_brief)
        if brief!="" {
            if original_gated && !device {
                gated,cleared:=split_brief_with_approval(brief)
                if cleared do append(&cleared_ids,id)
                brief=gated
            }
            if !brief_valid(brief) do return "invalid_content",nil
            if _,ok:=query(s.db,"INSERT INTO task_requirements VALUES(?,?,1,?,'',?,?)",chain,id,brief,principal,op);!ok do return "storage_error",nil
            if code:=brief_inputs_pin(s,chain,id,"1",brief);code!="ok" do return code,nil
        }
        if len(priority)==1 {
            if _,ok:=query(s.db,"INSERT INTO local_task_priority_versions VALUES(?,?,?,?)",chain,id,stamp,priority[0][0]);!ok do return "storage_error",nil
        }
        if len(publication)==1 && publication[0][0]=="draft" {
            if _,ok:=query(s.db,"INSERT INTO local_task_publications VALUES(?,?,?,'draft')",chain,id,stamp);!ok do return "storage_error",nil
        }
        for row in prerequisites {
            if _,ok:=query(s.db,"INSERT INTO local_dependencies VALUES(?,?,?)",chain,id,row[0]);!ok do return "operation_conflict",nil
        }
        if code:=split_assign(s,chain,task,id,child,command_raw,payload,principal,op,config,binding,configured,fleet[:],copy_fleet,roles[:],observed,agent_mode);code!="ok" do return code,nil
        if _,ok:=query(s.db,"INSERT INTO local_task_links VALUES(?,?,'split_from',?,?,?,?,?)",chain,id,task,fmt.tprintf("%d",i),stamp,principal,op);!ok do return "storage_error",nil
        if _,ok:=query(s.db,"INSERT INTO local_task_links VALUES(?,?,'split_into',?,?,?,?,?)",chain,task,id,fmt.tprintf("%d",i),stamp,principal,op);!ok do return "storage_error",nil
        append(&ids,id)
    }
    // R2-1/R2-8: for an agent every child keeps the user gate the original
    // had, whichever source carried it, unless its brief explicitly cleared it.
    if original_gated && !device {
        outer: for id in ids {
            for cleared in cleared_ids do if cleared==id do continue outer
            gated,read:=task_user_approval_required(s,chain,id)
            if !read do return "storage_error",nil
            if !gated do return "invalid_scope",nil
        }
    }
    if code:=split_dependents(s,chain,task,mode,mapping,ids[:]);code!="ok" do return code,nil
    // Cancel the original: a live holder is asked to checkpoint first.
    joined:=strings.join(ids[:],", ",context.temp_allocator)
    summary:=fmt.tprintf("split into %s: %s",joined,reason)
    if !control_revoke(s,c,seq,"checkpoint") do return "storage_error",nil
    if _,ok:=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    if !control_mode(s,chain,task,"cancelled","ready",summary,"") do return "storage_error",nil
    if _,ok:=query(s.db,"UPDATE lifecycle_state SET state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    if !control_record(s,c,doc(map[string]string{"summary"=summary,"destination_task_id"=ids[0]}),seq) do return "storage_error",nil
    if _,ok:=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    out:=doc(map[string]string{"children"=strings.join(ids[:],",",context.temp_allocator),"dependents"=mode,"original_state"="cancelled"})
    if len(cleared_ids)>0 {
        // Audit: the children whose inherited user gate the split cleared.
        audit:=user_approval_audit(c,true,false,device,reason,"ready")
        change:=audit["user_approval_change"].(json.Object)
        change["task_ids"]=json.String(strings.join(cleared_ids[:],",",context.temp_allocator))
        out["user_approval_change"]=change
    }
    runs,runs_read:=work_run_dependents(s,chain,task)
    if !runs_read do return "storage_error",nil
    if len(runs)>0 {
        out["workflow_run_dependents"]=json.String(strings.join(runs,",",context.temp_allocator))
        out["warning"]=json.String("workflow runs depend on the original task and stay blocked on it; edit their work dependencies to wait on the children")
    }
    return "ok",out
}

// Children copy the original's fleet binding and lifecycle (and review-role)
// configuration unless the child spec overrides the assignee or asks for an
// unassigned child. Worktree paths are the child's own.
split_assign :: proc(s:^Store,chain,original,id:string,child:Split_Child,command_raw,payload,principal,op:string,config:json.Object,binding:[]string,configured:bool,fleet:[][]string,copy_fleet:bool,roles:[][]string,observed:[]Child,agent_mode:bool) -> string {
    if child.unassigned do return "ok"
    author:Child
    has_author:=false
    if child.assignee!="" {
        for o in observed {
            if o.instance==child.assignee && o.epoch!="" && member_authorized(s,chain,o) { author=o;has_author=true;break }
        }
        if !has_author do return "invalid_scope"
        // A coordinator assigns only agents already in this chain.
        if agent_mode {
            participant,read:=agent_chain_participant(s,chain,author.instance)
            if !read do return "storage_error"
            if !participant do return "invalid_scope"
        }
    } else if copy_fleet {
        f:=fleet[0]
        agent_id:=""
        if configured do agent_id=field(config,"author_agent_id")
        author=Child{f[0],f[2],f[4],number(f[3]),agent_id}
        has_author=true
    }
    if !has_author do return "ok"
    enabled:="1"
    if child.assignee=="" do enabled=fleet[0][1]
    if _,ok:=query(s.db,"INSERT INTO local_fleet VALUES(?,?,?,1,?,?,?,?,?,?,?,?)",chain,id,author.instance,enabled,principal,op,command_raw,payload,author.epoch,fmt.tprintf("%d",author.run_count),author.token_generation);!ok do return "storage_error"
    if _,ok:=query(s.db,"INSERT INTO local_assignment_history VALUES(?,?,1,?,?,?,?,?)",chain,id,principal,op,command_raw,payload,encode(author));!ok do return "storage_error"
    if !configured do return "ok"
    next:=doc(map[string]string{})
    for k,v in config do next[k]=v
    next["configuration_revision"]=json.String("1")
    if field(config,"merge_policy")=="git" {
        next["worktree"]=json.String(fmt.tprintf("%s/.heimdall/worktrees/%s",field(config,"repository"),id))
        next["source_branch"]=json.String(fmt.tprintf("heimdall/%s",id))
    }
    author_child:=binding[1]
    if child.assignee!="" {
        if author.agent_id==field(config,"reviewer_agent_id") || author.instance==field(config,"reviewer_instance_id") do return "invalid_scope"
        next["author_agent_id"]=json.String(author.agent_id)
        author_child=encode(author)
    }
    raw:=encode(next)
    if _,valid:=contracts.owner_parse(raw,"lifecycle_config_payload");!valid do return "invalid_content"
    if _,ok:=query(s.db,"INSERT INTO lifecycle_configs VALUES(?,?,1,?,?,?,?,?,?)",chain,id,raw,command_raw,principal,op,author_child,binding[2]);!ok do return "storage_error"
    if _,ok:=query(s.db,"INSERT INTO lifecycle_state(chain_id,task_id,state) VALUES(?,?,'ready')",chain,id);!ok do return "storage_error"
    if len(roles)==1 {
        if _,ok:=query(s.db,"INSERT INTO local_role_configs VALUES(?,?,1,?,?)",chain,id,roles[0][1],roles[0][2]);!ok do return "storage_error"
        pairs,read:=query(s.db,"SELECT role,agent_id,child_json FROM local_role_pairs WHERE chain_id=? AND task_id=? AND revision=?",chain,original,roles[0][0])
        if !read do return "storage_error"
        for pair in pairs {
            if pair[1]==field(next,"author_agent_id") do return "invalid_scope"
            if _,ok:=query(s.db,"INSERT INTO local_role_pairs VALUES(?,?,1,?,?,?)",chain,id,pair[0],pair[1],pair[2]);!ok do return "storage_error"
        }
    }
    return "ok"
}

// Re-point the original's dependents to children: all (every child), last
// (the last child) or map ({dependent: [child ids]} covering every
// dependent). Generated workflow edges and cycles are refused as in cancel.
split_dependents :: proc(s:^Store,chain,original,mode:string,mapping:json.Object,children:[]string) -> string {
    rows,ok:=query(s.db,"SELECT task_id FROM local_dependencies WHERE chain_id=? AND prerequisite=? ORDER BY task_id",chain,original)
    if !ok do return "storage_error"
    if mode=="map" {
        for key in mapping {
            found:=false
            for row in rows do if row[0]==key do found=true
            if !found do return "invalid_content"
        }
    }
    for row in rows {
        dependent:=row[0]
        generated,read:=query(s.db,"SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id=?",chain,dependent)
        if !read do return "storage_error"
        if len(generated)>0 do return "operation_conflict"
        targets:=make([dynamic]string,context.temp_allocator)
        switch mode {
        case "all": for id in children do append(&targets,id)
        case "last": append(&targets,children[len(children)-1])
        case "map":
            list,array:=mapping[dependent].(json.Array)
            if !array || len(list)==0 do return "invalid_content"
            for item in list {
                id,is_text:=item.(json.String)
                if !is_text do return "invalid_content"
                member:=false
                for c in children do if c==string(id) do member=true
                if !member do return "invalid_content"
                append(&targets,string(id))
            }
        }
        if _,ok=query(s.db,"DELETE FROM local_dependencies WHERE chain_id=? AND task_id=? AND prerequisite=?",chain,dependent,original);!ok do return "storage_error"
        for target in targets {
            if dependent==target || !work_edge_acyclic(s,chain,"task",dependent,"task",target) do return "operation_conflict"
            if _,ok=query(s.db,"INSERT OR IGNORE INTO local_dependencies VALUES(?,?,?)",chain,dependent,target);!ok do return "operation_conflict"
        }
        if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,dependent);!ok do return "storage_error"
    }
    return "ok"
}

// Registry publication of each child, as task.create publishes its task.
split_registry :: proc(tx:^Transaction,c:json.Object,seq:i64,kr:^vault.Vault_Keyring,sign:Signer) -> bool {
    s:=tx.store
    chain:=field(c,"chain_id")
    if sign.sign==nil do return false
    rows,ok:=query(s.db,"SELECT l.task_id,t.title FROM local_task_links l JOIN tasks t ON t.chain_id=l.chain_id AND t.task_id=l.task_id WHERE l.chain_id=? AND l.relation='split_from' AND l.accepted_seq=? ORDER BY l.ordinal",chain,fmt.tprintf("%d",seq))
    genesis,read:=query(s.db,"SELECT genesis_digest FROM chain_genesis WHERE chain_id=?",chain)
    if !ok || !read || len(genesis)!=1 do return false
    for row in rows {
        title,sealed:=vault.seal_string(row[1],kr,context.temp_allocator)
        if !sealed do return false
        r:=doc(map[string]string{"protocol_version"="1","account_id"=s.account,"chain_id"=chain,"owner_bridge_id"=s.owner,"key_id"=s.owner_key,"genesis_digest"=genesis[0][0],"metadata_revision"=fmt.tprintf("%d",seq),"task_id"=row[0],"chain_title_cipher"="","chain_description_cipher"="","task_title_cipher"=title,"deleted"="0","signature"=strings.repeat("0",128,context.temp_allocator)})
        sig,signed:=sign.sign(sign.ctx,"registry",r)
        if !signed do return false
        r["signature"]=json.String(sig)
        if !intent_enqueue(tx,Intent_Input{chain=chain,principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind="registry",destination=row[0],fence="{}",payload=encode(r)}) do return false
    }
    return true
}

// Locked read for the owner Bridge: why task.complete --force would be
// refused right now (empty reason when it may proceed or on storage error).
complete_refusal_locked :: proc(s:^Store,chain,task:string,agent:Child) -> (code,reason:string) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return "storage_error",""
    defer transaction_rollback(&tx)
    return complete_check(s,chain,task,agent)
}

// Workflow runs (work graph) waiting on this task: task.split and task.cancel
// do not re-point them, so the result warns.
work_run_dependents :: proc(s:^Store,chain,task:string) -> ([]string,bool) {
    rows,ok:=query(s.db,`SELECT d.dependent_id FROM local_work_dependencies d WHERE d.chain_id=? AND d.dependent_kind='workflow_run'
      AND d.prerequisite_kind='task' AND d.prerequisite_id=?
      AND NOT EXISTS(SELECT 1 FROM local_work_dependency_removals r WHERE r.chain_id=d.chain_id AND r.dependency_id=d.dependency_id) ORDER BY d.dependent_id`,chain,task)
    if !ok do return nil,false
    out:=make([dynamic]string,context.temp_allocator)
    for row in rows do append(&out,row[0])
    return out[:],true
}
