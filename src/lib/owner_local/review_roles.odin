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
role_configure :: proc(s:^Store,c:json.Object,body:string,children:[]Child,seq:i64,device:=false,agent:=false)->string {
    p,valid:=contracts.owner_parse(body,"review_roles")
    if !valid do return "malformed"
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    config,_,configured:=lifecycle_config(s,chain,task)
    if !configured do return "invalid_scope"
    prior:i64
    prior_user:=false
    if previous,found:=role_configuration(s,chain,task);found { prior=number(previous[0]);prior_user=previous[1]=="1" }
    if number(field(p,"configuration_revision"))!=prior+1 do return "stale_revision"
    if !approval_ratchet_allows(prior_user,field(p,"requires_user_approval")=="1",device) do return "invalid_scope"
    state,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok || len(state)!=1 do return "storage_error"
    if state[0][0]!="ready" && state[0][0]!="in_review" do return "operation_conflict"
    v,parsed:=contracts.owner_request_document(field(p,"pairs"));pairs,array:=v.(json.Array)
    if !parsed || !array || len(pairs)<1 || len(pairs)>16 do return "invalid_content"
    if _,ok=query(s.db,"INSERT INTO local_role_configs VALUES(?,?,?,?,?)",chain,task,field(p,"configuration_revision"),field(p,"requires_user_approval"),field(p,"pairs"));!ok do return "storage_error"
    for pair in pairs {
        o,obj:=pair.(json.Object)
        if !obj || !contracts.owner_document_valid("review_pair",o) || field(o,"agent_id")==field(config,"author_agent_id") do return "invalid_scope"
        // A coordinator configures roles only for participants already in
        // this chain (like lifecycle.configure); new members are human-only.
        if agent {
            participant,read:=agent_chain_participant(s,chain,field(o,"instance_id"))
            if !read do return "storage_error"
            if !participant do return "invalid_scope"
        }
        found:=false
        for child in children {
            if member_authorized(s,chain,child) && child.instance==field(o,"instance_id") && child.agent_id==field(o,"agent_id") && child.epoch!="" {
                found=true
                if _,ok=query(s.db,"INSERT INTO local_role_pairs VALUES(?,?,?,?,?,?)",chain,task,field(p,"configuration_revision"),field(o,"role"),child.agent_id,encode(child));!ok do return "operation_conflict"
                break
            }
        }
        if !found do return "invalid_scope"
    }
    if !control_revoke(s,c,seq,"checkpoint") do return "storage_error"
    if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE local_controls SET resume_state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    return "ok"
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
role_gate :: proc(s:^Store,chain,task,attempt:string)->(string,bool) {
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
    // a requirement, but cannot remove an explicit submitted human gate.
    required,required_read:=query(s.db,`SELECT 1 FROM local_submissions
      WHERE chain_id=? AND task_id=? AND attempt=? AND json_extract(requirements_json,'$.requires_user_approval')=1
      UNION ALL SELECT 1 FROM local_workflow_language_items WHERE task_id=? AND requires_user_approval=1 LIMIT 1`,chain,task,attempt,task)
    if !required_read do return "",false
    if len(required)>0 && !user do return "in_review",true
    if !language_policy_ready(s,chain,task) do return "in_review",true
    if !independent do return "in_review",true
    return ("merge_pending" if field(config,"merge_policy")=="git" else "done"),true
}

// ---- user-approval ratchet (R2-1) -----------------------------------------
// An agent principal may add requires_user_approval but never remove it; a
// device (the user) may do either. Every path that can change a user-approval
// source applies this: requirements.edit (brief), review.roles (role config).
// lifecycle.configure carries no flag. A future task split must call
// task_user_approval_required on the parent and keep the flag on each child
// unless the split is device-signed.
approval_ratchet_allows :: proc(prior,next,device:bool) -> bool { return device || !prior || next }

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
