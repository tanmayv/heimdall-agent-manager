#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:slice"
import contracts "odin_test:contracts"

// ---- review gate -------------------------------------------------------------
// A task's review gate is its reviewers and a user-approval flag, nothing else:
// the configured independent reviewer (lifecycle.configure) plus every agent
// id named in the current brief's reviewers must approve the submitted
// attempt, and when the brief (or the submitted brief, or a workflow stage)
// requires it, so must the user (a device-signed review). Each reviewer opens
// its own review session (review.open, local_review_sessions keyed by child)
// and posts one verdict (local_reviews keyed by reviewer agent id).

// The agent ids named in a brief's reviewers (in order, without duplicates).
brief_reviewers :: proc(brief:string) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    v,ok:=contracts.owner_request_document(brief);o,obj:=v.(json.Object)
    if !ok || !obj do return out[:]
    list,_:=o["reviewers"].(json.Array)
    for item in list {
        id,text:=item.(json.String)
        if text && string(id)!="" && !slice.contains(out[:],string(id)) do append(&out,string(id))
    }
    return out[:]
}

// Every agent whose approval the gate requires: the configured reviewer first,
// then the current brief's reviewers.
task_reviewers :: proc(s:^Store,chain,task:string,config:json.Object) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    if primary:=field(config,"reviewer_agent_id");primary!="" do append(&out,primary)
    if req,has:=lifecycle_requirements(s,chain,task);has {
        for id in brief_reviewers(req[1]) do if !slice.contains(out[:],id) do append(&out,id)
    }
    return out[:]
}

// A launched child of an agent the current brief names as a reviewer. It is
// never the task's author nor the chain's coordinator, and it must be a member
// of this chain (member_authorized: an instance bound to another chain is
// foreign). The Bridge observes child.agent_id from the launch record.
brief_reviewer_authorized :: proc(s:^Store,chain,task:string,child:Child) -> bool {
    if child.epoch=="" || !member_authorized(s,chain,child) || agent_coordinator(s,chain,child) do return false
    config,_,configured:=lifecycle_config(s,chain,task)
    if !configured || child.agent_id==field(config,"author_agent_id") do return false
    req,has:=lifecycle_requirements(s,chain,task)
    return has && slice.contains(brief_reviewers(req[1]),child.agent_id)
}

// The configured reviewer's bound child or a brief reviewer's child.
task_reviewer_authorized :: proc(s:^Store,chain,task:string,child:Child) -> bool {
    config,binding,configured:=lifecycle_config(s,chain,task)
    if !configured || child.agent_id==field(config,"author_agent_id") do return false
    if s.relayed_from!="" do return relayed_reviewer_authorized(s,chain,task,child,config)
    if encode(child)==binding[2] && child.agent_id==field(config,"reviewer_agent_id") do return true
    return brief_reviewer_authorized(s,chain,task,child)
}

// A reviewer running on another Bridge of this account (user decision
// 2026-11-11): the owner Bridge admitted the relay (same-account, approved,
// unrevoked Bridge key; owner.remote_agent_admit) and the relaying Bridge
// proved its own live child, so the agent is trusted by its durable id. It
// must be one of the task's reviewers, never its author nor a coordinator of
// the chain. No exact process binding is required here.
relayed_reviewer_authorized :: proc(s:^Store,chain,task:string,child:Child,config:json.Object) -> bool {
    if child.epoch=="" || child.agent_id==field(config,"author_agent_id") || !slice.contains(task_reviewers(s,chain,task,config),child.agent_id) do return false
    coordinators,ok:=chain_coordinator_agents(s,chain)
    return ok && !slice.contains(coordinators,child.agent_id)
}

// The reviewers whose approval of this attempt is still owed (in order).
review_owed :: proc(s:^Store,chain,task,attempt:string,config:json.Object) -> ([]string,bool) {
    out:=make([dynamic]string,context.temp_allocator)
    for agent in task_reviewers(s,chain,task,config) {
        rows,ok:=query(s.db,"SELECT 1 FROM local_reviews WHERE chain_id=? AND task_id=? AND attempt=? AND reviewer_agent_id=? AND principal_kind='agent' AND verdict='approve' LIMIT 1",chain,task,attempt,agent)
        if !ok do return nil,false
        if len(rows)==0 do append(&out,agent)
    }
    return out[:],true
}

// ---- review dispatch ---------------------------------------------------------
// A task entering in_review (lease.submit, force submit, release, recheck) owes
// each reviewer in review_owed a review lease: the Bridge wakes a live member
// instance of that agent, or starts/launches one (owner_agent_routing.odin),
// and the reviewer's `lease next` returns the pending review (review_pending).

// The agents of the chain's enabled coordinator members (never reviewers).
chain_coordinator_agents :: proc(s:^Store,chain:string) -> ([]string,bool) {
    rows,ok:=query(s.db,`SELECT DISTINCT agent_id FROM local_chain_member_versions m WHERE chain_id=? AND enabled=1 AND role='coordinator'
      AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)`,chain)
    if !ok do return nil,false
    out:=make([]string,len(rows),context.temp_allocator)
    for r,i in rows do out[i]=r[0]
    return out,true
}

// A brief naming the task's author (its configured author or the brief's own
// assignee) or a chain coordinator among its reviewers can never settle
// (brief_reviewer_authorized refuses both), so every brief source refuses it:
// requirements.edit, task.split, proposals/publication and workflow runs.
// task is "" for a brief not bound to a configured task yet.
brief_reviewers_admissible :: proc(s:^Store,chain,task,brief:string) -> string {
    reviewers:=brief_reviewers(brief)
    if len(reviewers)==0 do return "ok"
    excluded:=make([dynamic]string,context.temp_allocator)
    if task!="" {
        if config,_,configured:=lifecycle_config(s,chain,task);configured do append(&excluded,field(config,"author_agent_id"))
    }
    if v,ok:=contracts.owner_request_document(brief);ok {
        if o,obj:=v.(json.Object);obj && field(o,"assignee")!="" do append(&excluded,field(o,"assignee"))
    }
    coordinators,read:=chain_coordinator_agents(s,chain)
    if !read do return "storage_error"
    for id in reviewers do if slice.contains(excluded[:],id) || slice.contains(coordinators,id) do return "invalid_scope"
    return "ok"
}

// One owed reviewer of a task in review and the chain's enabled member
// instances of that agent (the configured reviewer's bound instance first).
Review_Target :: struct { agent_id:string, instances:[]string }

// The reviewers a task in review (not held) still owes a verdict, in gate
// order; empty for any other state. Read-only.
review_targets :: proc(s:^Store,chain,task:string) -> ([]Review_Target,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,false
    defer transaction_rollback(&tx)
    out:=make([dynamic]Review_Target,context.temp_allocator)
    states,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return nil,false
    if len(states)!=1 || states[0][0]!="in_review" || !control_ready(s,chain,task) do return out[:],true
    config,_,configured:=lifecycle_config(s,chain,task)
    if !configured do return out[:],true
    owed,owed_ok:=review_owed(s,chain,task,states[0][1],config)
    if !owed_ok do return nil,false
    for agent in owed {
        instances:=make([dynamic]string,context.temp_allocator)
        if agent==field(config,"reviewer_agent_id") && field(config,"reviewer_instance_id")!="" do append(&instances,field(config,"reviewer_instance_id"))
        rows,read:=query(s.db,`SELECT instance_id FROM local_chain_member_versions m WHERE chain_id=? AND agent_id=? AND enabled=1 AND role!='coordinator'
          AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id) ORDER BY accepted_seq DESC`,chain,agent)
        if !read do return nil,false
        for r in rows do if !slice.contains(instances[:],r[0]) do append(&instances,r[0])
        append(&out,Review_Target{agent,instances[:]})
    }
    return out[:],true
}

// The review lease `lease next` hands this child: the first task in review
// (not held) whose gate still owes the child's agent a verdict and that the
// child may review (task_reviewer_authorized). Read-only.
review_pending :: proc(s:^Store,child:Child,only_chain:="") -> (chain,task:string,found,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return "","",false,false
    defer transaction_rollback(&tx)
    // only_chain scopes the search to one chain (a relayed `lease next` names it).
    rows,read:=query(s.db,"SELECT chain_id,task_id,attempt FROM lifecycle_state WHERE state='in_review' AND (?1='' OR chain_id=?1) ORDER BY chain_id,task_id LIMIT 500",only_chain)
    if !read do return "","",false,false
    for row in rows {
        if !control_ready(s,row[0],row[1]) || !task_reviewer_authorized(s,row[0],row[1],child) do continue
        config,_,configured:=lifecycle_config(s,row[0],row[1])
        if !configured do continue
        owed,owed_ok:=review_owed(s,row[0],row[1],row[2],config)
        if !owed_ok do return "","",false,false
        if slice.contains(owed,child.agent_id) do return row[0],row[1],true,true
    }
    return "","",false,true
}

// brief_cleared: the brief's user gate was just cleared on this submitted
// attempt (requirements.edit), so the submission's snapshot flag no longer
// applies. A workflow-stage user requirement still does.
review_gate :: proc(s:^Store,chain,task,attempt:string,brief_cleared:=false)->(string,bool) {
    // Native hold defers gate settlement, not the recording of a live verdict.
    if control_held(s,chain,task) do return "in_review",true
    config,_,valid:=lifecycle_config(s,chain,task)
    if !valid do return "",false
    reviews,ok:=query(s.db,"SELECT reviewer_agent_id,principal_id,verdict,principal_kind FROM local_reviews WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,attempt)
    if !ok do return "",false
    user:=false
    for row in reviews {
        if row[2]=="request_changes" do return "ready",true
        // Only a device-signed verdict is the user (R2-1). An agent row, even a
        // coordinator's review.human on the user's behalf, never is.
        if row[3]=="device" && row[0]==row[1] && row[0]!=field(config,"reviewer_agent_id") do user=true
    }
    // A human gate belongs to the immutable submitted attempt, including
    // ordinary/static producers; the current brief or stage metadata may add
    // a requirement, and only a requirements edit clearing the brief's gate
    // removes the submitted one (brief_cleared).
    submitted_gate,submitted_read:=query(s.db,`SELECT 1 FROM local_submissions
      WHERE chain_id=? AND task_id=? AND attempt=? AND json_extract(requirements_json,'$.requires_user_approval')=1`,chain,task,attempt)
    stage_gate,stage_read:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=? AND requires_user_approval=1 LIMIT 1",task)
    current_gate,current_read:=requirements_user_approval(s,chain,task)
    if !submitted_read || !stage_read || !current_read do return "",false
    if ((len(submitted_gate)>0 && !brief_cleared) || len(stage_gate)>0 || current_gate) && !user do return "in_review",true
    if !language_policy_ready(s,chain,task) do return "in_review",true
    owed,owed_read:=review_owed(s,chain,task,attempt,config)
    if !owed_read do return "",false
    if len(owed)>0 do return "in_review",true
    return ("merge_pending" if field(config,"merge_policy")=="git" else "done"),true
}

// ---- user approval (R2-1) ---------------------------------------------------
// The user or the verified chain coordinator may add or remove
// requires_user_approval through every source that carries it:
// requirements.edit (brief) and task.split (child briefs). Workers and
// reviewers never hold those verbs (agent_authority). While a gate is on, only
// a device-signed review satisfies it (review_gate).

// The audit of a requires_user_approval change, recorded in the command's
// result (receipt and local event): actor, old -> new value and reason.
user_approval_audit :: proc(c:json.Object,old,new,device:bool,reason,state:string) -> json.Object {
    out:=doc(map[string]string{"state"=state})
    out["user_approval_change"]=json.Object{
        "field"=json.String("requires_user_approval"),"old"=json.Boolean(old),"new"=json.Boolean(new),
        "actor_kind"=json.String("device" if device else "agent"),"actor_id"=json.String(field(c,"principal_id")),
        "operation_id"=json.String(field(c,"operation_id")),"reason"=json.String(reason)}
    return out
}

// The reason a requirements revision carries (Hub requirements_reason parity).
brief_requirements_reason :: proc(s:^Store,brief:string) -> string {
    rows,ok:=query(s.db,"SELECT CASE WHEN json_valid(?1) AND json_type(?1,'$.requirements_reason')='text' THEN trim(json_extract(?1,'$.requirements_reason')) ELSE '' END",brief)
    return rows[0][0] if ok && len(rows)==1 else ""
}

// The brief without its requirements_reason (a revision note the Bridge adds
// to requirements.edit; never inherited by another task).
brief_without_reason :: proc(s:^Store,brief:string) -> string {
    rows,ok:=query(s.db,"SELECT CASE WHEN json_valid(?1) AND json_type(?1,'$.requirements_reason') IS NOT NULL THEN json_remove(?1,'$.requirements_reason') ELSE ?1 END",brief)
    return rows[0][0] if ok && len(rows)==1 else brief
}

// The two briefs differ only in the gate flag and the revision reason.
brief_gate_only_change :: proc(prior,next:string) -> bool {
    strip :: proc(raw:string) -> (string,bool) {
        v,ok:=contracts.owner_request_document(raw);o,obj:=v.(json.Object)
        if !ok || !obj do return "",false
        delete_key(&o,"requires_user_approval");delete_key(&o,"requirements_reason")
        b,e:=json.marshal(o,{sort_maps_by_key=true},context.temp_allocator)
        return string(b),e==nil
    }
    a,a_ok:=strip(prior);b,b_ok:=strip(next)
    return a_ok && b_ok && a==b
}

// The brief's own flag, read exactly as the gate reads submissions.
brief_user_approval :: proc(s:^Store,brief:string) -> bool {
    rows,ok:=query(s.db,"SELECT json_valid(?1) AND json_extract(?1,'$.requires_user_approval')=1",brief)
    return ok && len(rows)==1 && rows[0][0]=="1"
}
requirements_user_approval :: proc(s:^Store,chain,task:string) -> (required:bool,ok:bool) {
    req,has:=lifecycle_requirements(s,chain,task)
    if !has do return false,true
    return brief_user_approval(s,req[1]),true
}
// The task's mutable user-approval source: its current brief.
task_user_approval_required :: proc(s:^Store,chain,task:string) -> (required:bool,ok:bool) {
    return requirements_user_approval(s,chain,task)
}
