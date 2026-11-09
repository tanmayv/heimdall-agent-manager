#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

role_configuration :: proc(s:^Store,chain,task:string)->([]string,bool) {
    rows,ok:=query(s.db,"SELECT revision,requires_user_approval FROM local_role_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
    if !ok || len(rows)!=1 do return nil,false
    return rows[0],true
}
// The user or the verified chain coordinator may add or remove the role
// gate; a change is audited in the returned extra.
role_configure :: proc(s:^Store,c:json.Object,body:string,children:[]Child,seq:i64,device:=false,agent:=false,self:Child={})->(string,json.Object) {
    p,valid:=contracts.owner_parse(body,"review_roles")
    if !valid do return "malformed",nil
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    config,_,configured:=lifecycle_config(s,chain,task)
    if !configured do return "invalid_scope",nil
    prior:i64
    prior_user:=false
    if previous,found:=role_configuration(s,chain,task);found { prior=number(previous[0]);prior_user=previous[1]=="1" }
    if number(field(p,"configuration_revision"))!=prior+1 do return "stale_revision",nil
    state,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok || len(state)!=1 do return "storage_error",nil
    if state[0][0]!="ready" && state[0][0]!="in_review" do return "operation_conflict",nil
    v,parsed:=contracts.owner_request_document(field(p,"pairs"));pairs,array:=v.(json.Array)
    if !parsed || !array || len(pairs)<1 || len(pairs)>16 do return "invalid_content",nil
    if _,ok=query(s.db,"INSERT INTO local_role_configs VALUES(?,?,?,?,?)",chain,task,field(p,"configuration_revision"),field(p,"requires_user_approval"),field(p,"pairs"));!ok do return "storage_error",nil
    for pair in pairs {
        o,obj:=pair.(json.Object)
        if !obj || !contracts.owner_document_valid("review_pair",o) || field(o,"agent_id")==field(config,"author_agent_id") do return "invalid_scope",nil
        // A coordinator configures roles for participants of this chain
        // (like lifecycle.configure); it enrolls new ones itself first
        // (chain.member.set / `task-chain fleet set`).
        if agent {
            // REQ-CC-13: the coordinator never names itself a role reviewer.
            if field(o,"instance_id")==self.instance || field(o,"agent_id")==self.agent_id do return "invalid_scope",nil
            participant,read:=agent_chain_participant(s,chain,field(o,"instance_id"))
            if !read do return "storage_error",nil
            if !participant do return "invalid_scope",nil
        }
        found:=false
        for child in children {
            if member_authorized(s,chain,child) && child.instance==field(o,"instance_id") && child.agent_id==field(o,"agent_id") && child.epoch!="" {
                found=true
                if _,ok=query(s.db,"INSERT INTO local_role_pairs VALUES(?,?,?,?,?,?)",chain,task,field(p,"configuration_revision"),field(o,"role"),child.agent_id,encode(child));!ok do return "operation_conflict",nil
                break
            }
        }
        if !found do return "invalid_scope",nil
    }
    if !control_revoke(s,c,seq,"checkpoint") do return "storage_error",nil
    if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE local_controls SET resume_state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    next_user:=field(p,"requires_user_approval")=="1"
    if prior_user==next_user do return "ok",nil
    return "ok",user_approval_audit(c,prior_user,next_user,device,"","ready")
}
role_child_authorized :: proc(s:^Store,chain,task:string,child:Child,role:string)->bool {
    rows,ok:=query(s.db,"SELECT 1 FROM local_role_pairs p WHERE chain_id=? AND task_id=? AND agent_id=? AND child_json=? AND (?='' OR role=?) AND revision=(SELECT max(revision) FROM local_role_configs c WHERE c.chain_id=p.chain_id AND c.task_id=p.task_id)",chain,task,child.agent_id,encode(child),role,role)
    return ok && len(rows)>0
}
role_record :: proc(s:^Store,c,p:json.Object,agent:string)->string {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    config,_,valid:=lifecycle_config(s,chain,task)
    rc,has_roles:=role_configuration(s,chain,task)
    if !valid || !has_roles || agent==field(config,"author_agent_id") do return "invalid_scope"
    pair,ok:=query(s.db,"SELECT 1 FROM local_role_pairs WHERE chain_id=? AND task_id=? AND revision=? AND role=? AND agent_id=?",chain,task,rc[0],field(p,"role"),agent)
    if !ok do return "storage_error"
    if len(pair)!=1 do return "invalid_scope"
    _,ok=query(s.db,"INSERT INTO local_role_reviews VALUES(?,?,?,?,?,?,?,?,?,?)",chain,task,field(p,"attempt"),rc[0],field(p,"role"),agent,field(c,"principal_id"),field(c,"operation_id"),field(p,"verdict"),field(p,"summary"))
    if !ok do return "operation_conflict"
    return "ok"
}
// brief_cleared: the brief's user gate was just cleared on this submitted
// attempt (requirements.edit), so the submission's snapshot flag no longer
// applies. Role and workflow-stage user requirements still do.
role_gate :: proc(s:^Store,chain,task,attempt:string,brief_cleared:=false)->(string,bool) {
    // Native hold defers gate settlement, not the recording of a live verdict.
    if control_held(s,chain,task) do return "in_review",true
    config,_,valid:=lifecycle_config(s,chain,task)
    if !valid do return "",false
    reviews,ok:=query(s.db,"SELECT reviewer_agent_id,principal_id,verdict,principal_kind FROM local_reviews WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,attempt)
    if !ok do return "",false
    independent,user:=false,false
    for row in reviews {
        if row[2]=="request_changes" do return "ready",true
        if row[0]==field(config,"reviewer_agent_id") do independent=true
        // Only a device-signed verdict is the user (R2-1). An agent row, even a
        // coordinator's review.human on the user's behalf, never is.
        if row[3]=="device" && row[0]==row[1] && row[0]!=field(config,"reviewer_agent_id") do user=true
    }
    role_configs,roles_read:=query(s.db,"SELECT revision,requires_user_approval FROM local_role_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
    if !roles_read do return "",false
    if len(role_configs)==1 {
        rc:=role_configs[0]
        changes,read:=query(s.db,"SELECT 1 FROM local_role_reviews WHERE chain_id=? AND task_id=? AND attempt=? AND role_revision=? AND verdict='request_changes'",chain,task,attempt,rc[0])
        if !read do return "",false
        if len(changes)>0 do return "ready",true
        owed,owed_read:=query(s.db,"SELECT 1 FROM local_role_pairs p WHERE chain_id=? AND task_id=? AND revision=? AND NOT EXISTS(SELECT 1 FROM local_role_reviews r WHERE r.chain_id=p.chain_id AND r.task_id=p.task_id AND r.attempt=? AND r.role_revision=p.revision AND r.role=p.role AND r.agent_id=p.agent_id AND r.verdict='approve') LIMIT 1",chain,task,rc[0],attempt)
        if !owed_read do return "",false
        if len(owed)>0 || (rc[1]=="1" && !user) do return "in_review",true
    }
    // A human gate belongs to the immutable submitted attempt, including
    // ordinary/static producers. Role configuration or stage metadata may add
    // a requirement, but cannot remove an explicit submitted human gate; only
    // a requirements edit clearing the brief's gate does (brief_cleared).
    submitted_gate,submitted_read:=query(s.db,`SELECT 1 FROM local_submissions
      WHERE chain_id=? AND task_id=? AND attempt=? AND json_extract(requirements_json,'$.requires_user_approval')=1`,chain,task,attempt)
    stage_gate,stage_read:=query(s.db,"SELECT 1 FROM local_workflow_language_items WHERE task_id=? AND requires_user_approval=1 LIMIT 1",task)
    if !submitted_read || !stage_read do return "",false
    if ((len(submitted_gate)>0 && !brief_cleared) || len(stage_gate)>0) && !user do return "in_review",true
    if !language_policy_ready(s,chain,task) do return "in_review",true
    if !independent do return "in_review",true
    return ("merge_pending" if field(config,"merge_policy")=="git" else "done"),true
}

// ---- user approval (R2-1) ---------------------------------------------------
// The user or the verified chain coordinator may add or remove
// requires_user_approval through every source that carries it:
// requirements.edit (brief), review.roles (role config), task.split (child
// briefs). Workers and reviewers never hold those verbs (agent_authority).
// While a gate is on, only a device-signed review satisfies it (role_gate).

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
// Any mutable user-approval source of the task (brief or latest role config).
task_user_approval_required :: proc(s:^Store,chain,task:string) -> (required:bool,ok:bool) {
    brief,read:=requirements_user_approval(s,chain,task)
    if !read do return false,false
    if brief do return true,true
    rows,roles_ok:=query(s.db,"SELECT requires_user_approval FROM local_role_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
    if !roles_ok do return false,false
    return len(rows)==1 && rows[0][0]=="1",true
}
