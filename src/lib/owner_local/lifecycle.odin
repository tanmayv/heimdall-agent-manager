#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import contracts "odin_test:contracts"
import wf "odin_test:lib/workflow_v1"

// Child agent identity is observed from the launch record, never caller JSON.
Lifecycle_Proof :: struct { author,reviewer:Child, paths_valid:bool }
lifecycle_config :: proc(s:^Store,chain,task:string) -> (json.Object,[]string,bool) {
    rows,ok:=query(s.db,"SELECT config_json,author_child,reviewer_child,revision FROM lifecycle_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
    if !ok || len(rows)!=1 do return nil,nil,false
    revoked,read:=query(s.db,"SELECT 1 FROM local_config_revocations WHERE chain_id=? AND task_id=? AND revision=?",chain,task,rows[0][3])
    if !read || len(revoked)>0 do return nil,nil,false
    c,valid:=contracts.owner_parse(rows[0][0],"lifecycle_config_payload")
    return c,rows[0],valid
}
lifecycle_requirements :: proc(s:^Store,chain,task:string) -> ([]string,bool) {
    rows,ok:=query(s.db,"SELECT revision,brief_json FROM task_requirements WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
    if !ok || len(rows)!=1 do return nil,false
    return rows[0],true
}
brief_valid :: proc(raw:string) -> bool {
    v,ok:=contracts.owner_request_document(raw);o,obj:=v.(json.Object)
    if !ok || !obj || !wf.brief_bounded(raw) do return false
    goal,is_string:=o["goal"].(json.String)
    acceptance,is_array:=o["acceptance"].(json.Array)
    if !is_string || strings.trim_space(string(goal))=="" || !is_array || len(acceptance)==0 || len(acceptance)>100 do return false
    for a in acceptance { text,valid:=a.(json.String);if !valid || strings.trim_space(string(text))=="" do return false }
    return true
}
// device: the command was signed by a device key for itself (the user). The
// user or the verified chain coordinator (agent_authority admits
// requirements.edit for the coordinator only) may add or remove
// requires_user_approval; a change is audited in the returned extra.
lifecycle_human :: proc(s:^Store,c,p:json.Object,body,raw,payload:string,proof:Lifecycle_Proof,device:bool) -> (string,json.Object) {
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    extra:json.Object
    switch method {
    case "lifecycle.configure":
        // The lifecycle payload carries no requires_user_approval and a new
        // configuration never touches the brief, so it
        // never changes a user gate (lifecycle_configure_keeps_user_gate).
        if !directory_config_authorized(s,chain,p) || !member_authorized(s,chain,proof.author) || !member_authorized(s,chain,proof.reviewer) || !proof.paths_valid || proof.author.agent_id!=field(p,"author_agent_id") ||
           proof.reviewer.agent_id!=field(p,"reviewer_agent_id") || proof.author.agent_id==proof.reviewer.agent_id ||
           proof.reviewer.instance!=field(p,"reviewer_instance_id") || proof.author.instance==proof.reviewer.instance ||
           proof.author.epoch=="" || proof.reviewer.epoch=="" { return "invalid_scope",nil }
        previous,read:=query(s.db,"SELECT revision FROM lifecycle_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
        if !read do return "storage_error",nil
        if len(previous)>0 && number(previous[0][0])>=number(field(p,"configuration_revision")) do return "stale_revision",nil
        states,looked:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !looked do return "storage_error",nil
        if len(states)>0 && states[0][0]!="ready" && states[0][0]!="in_review" do return "operation_conflict",nil
        // The new author never reviews its own task (brief_reviewers_admissible).
        if req,has:=lifecycle_requirements(s,chain,task);has && slice.contains(brief_reviewers(req[1]),proof.author.agent_id) do return "invalid_scope",nil
        fleet,found:=query(s.db,"SELECT instance_id,launch_epoch,run_count,token_generation,enabled FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
        if !found || len(fleet)!=1 || fleet[0][0]!=proof.author.instance || fleet[0][1]!=proof.author.epoch ||
           number(fleet[0][2])!=proof.author.run_count || fleet[0][3]!=proof.author.token_generation || fleet[0][4]!="1" {return "invalid_scope",nil}
        if _,ok:=query(s.db,"INSERT INTO lifecycle_configs VALUES(?,?,?,?,?,?,?,?,?)",chain,task,field(p,"configuration_revision"),payload,raw,field(c,"principal_id"),field(c,"operation_id"),encode(proof.author),encode(proof.reviewer));!ok do return "storage_error",nil
        if _,ok:=query(s.db,"INSERT OR IGNORE INTO lifecycle_state(chain_id,task_id,state) VALUES(?,?,'ready')",chain,task);!ok do return "storage_error",nil
        if _,ok:=query(s.db,"UPDATE lifecycle_state SET state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
    case "requirements.edit":
        // requirements_reason is this revision's audit note, not brief content.
        if !brief_valid(brief_without_reason(s,body)) do return "invalid_content",nil
        if code:=brief_reviewers_admissible(s,chain,task,body);code!="ok" do return code,nil
        prior:i64
        prior_brief:=""
        if r,ok:=lifecycle_requirements(s,chain,task);ok { prior=number(r[0]);prior_brief=r[1] }
        if number(field(p,"requirements_revision"))!=prior+1 do return "stale_revision",nil
        state,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !ok do return "storage_error",nil
        if len(state)==1 && (state[0][0]=="merge_pending" || state[0][0]=="merge_blocked" || state[0][0]=="done") do return "operation_conflict",nil
        prior_user,next_user:=brief_user_approval(s,prior_brief),brief_user_approval(s,body)
        reason:=brief_requirements_reason(s,body)
        // An agent (the coordinator) clearing the gate must say why (audit).
        if prior_user && !next_user && !device && reason=="" do return "invalid_content",nil
        if _,ok=query(s.db,"INSERT INTO task_requirements VALUES(?,?,?,?,?,?,?)",chain,task,field(p,"requirements_revision"),body,field(p,"body_cipher"),field(c,"principal_id"),field(c,"operation_id"));!ok do return "storage_error",nil
        if code:=brief_inputs_pin(s,chain,task,field(p,"requirements_revision"),body);code!="ok" do return code,nil
        next_state:="ready"
        // Clearing only the gate of a submitted attempt re-evaluates its review
        // gate without the brief's user requirement: an attempt already holding
        // every other required approval advances. Otherwise, as for any
        // requirements edit, the task returns to ready for a fresh submission.
        if prior_user && !next_user && len(state)==1 && state[0][0]=="in_review" && brief_gate_only_change(prior_brief,body) {
            gate,gate_ok:=review_gate(s,chain,task,state[0][1],true)
            if !gate_ok do return "storage_error",nil
            if gate!="in_review" do next_state=gate
        }
        if next_state!="ready" {
            if _,ok=query(s.db,"DELETE FROM local_review_sessions WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error",nil
        }
        if _,ok=query(s.db,"UPDATE lifecycle_state SET state=? WHERE chain_id=? AND task_id=?",next_state,chain,task);!ok do return "storage_error",nil
        if prior_user!=next_user do extra=user_approval_audit(c,prior_user,next_user,device,reason,next_state)
    case "review.post":
        return lifecycle_review(s,c,p,"",true,device),nil
    }
    _,ok:=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return "storage_error",nil
    return "ok",extra
}

// Verdicts always bind the immutable submission. Device approval is recorded
// separately and never satisfies the required independent agent pair.
// human: review.post outside a review session (a device verdict, or an agent's
// review.human on the user's behalf). Only device=true rows are the user.
lifecycle_review :: proc(s:^Store,c,p:json.Object,agent:string,human:bool,device:=false) -> string {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    if !control_active(s,chain,task) do return "operation_conflict"
    config,_,configured:=lifecycle_config(s,chain,task)
    req,has_req:=lifecycle_requirements(s,chain,task)
    state,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !configured || !has_req || !ok || len(state)!=1 do return "invalid_scope"
    if state[0][0]!="in_review" || state[0][1]!=field(p,"attempt") || req[0]!=field(p,"requirements_revision") do return "stale_revision"
    submitted,read:=query(s.db,"SELECT head,requirements_revision,author_agent_id,configuration_revision FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,field(p,"attempt"))
    if !read || len(submitted)!=1 do return "storage_error"
    if submitted[0][0]!=field(p,"head") || submitted[0][1]!=req[0] || submitted[0][3]!=field(config,"configuration_revision") do return "stale_revision"
    // An agent verdict comes from one of the task's reviewers (the configured
    // reviewer or a brief reviewer), never from the attempt's author.
    if !human && (agent==submitted[0][2] || !slice.contains(task_reviewers(s,chain,task,config),agent)) do return "invalid_scope"
    reviewer:=agent
    if human do reviewer=field(c,"principal_id")
    kind:="device" if human && device else "agent"
    if _,ok=query(s.db,`INSERT INTO local_reviews(chain_id,task_id,attempt,reviewer_agent_id,principal_id,operation_id,requirements_revision,head,verdict,summary,principal_kind)
      VALUES(?,?,?,?,?,?,?,?,?,?,?)`,chain,task,field(p,"attempt"),reviewer,field(c,"principal_id"),field(c,"operation_id"),req[0],field(p,"head"),field(p,"verdict"),field(p,"summary"),kind);!ok do return "operation_conflict"
    next,gate_ok:=review_gate(s,chain,task,field(p,"attempt"))
    if !gate_ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state=? WHERE chain_id=? AND task_id=?",next,chain,task);!ok do return "storage_error"
    if next!="in_review" {
        if _,ok=query(s.db,"DELETE FROM local_review_sessions WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    }
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    return "ok"
}
lifecycle_merge_intent :: proc(tx:^Transaction,c,p:json.Object,seq:i64) -> bool {
    s:=tx.store
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    state,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return false
    if len(state)!=1 || state[0][0]!="merge_pending" do return true
    config,_,valid:=lifecycle_config(s,chain,task)
    if !valid do return false
    fence:=encode(doc(map[string]string{"task_id"=task,"attempt"=field(p,"attempt"),"requirements_revision"=field(p,"requirements_revision"),"head"=field(p,"head"),"configuration_revision"=field(config,"configuration_revision")}))
    return intent_enqueue(tx,Intent_Input{chain=chain,principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind="merge",fence=fence,payload=encode(config)})
}

merge_claim_current :: proc(s:^Store,claim:Intent_Claim) -> bool {
    rows,ok:=query(s.db,"SELECT exact_fence_json FROM runtime_intents WHERE intent_id=? AND state='claimed' AND claim_incarnation=? AND attempts=? AND payload_digest=? AND NOT EXISTS(SELECT 1 FROM intent_invalidations WHERE intent_id=runtime_intents.intent_id)",claim.id,fmt.tprintf("%d",claim.incarnation),fmt.tprintf("%d",claim.attempt),claim.digest)
    if !ok || len(rows)!=1 || rows[0][0]!=claim.fence do return false
    v,valid:=contracts.owner_request_document(claim.fence);f,obj:=v.(json.Object)
    if !valid || !obj do return false
    config,_,configured:=lifecycle_config(s,claim.chain,field(f,"task_id"))
    req,has_req:=lifecycle_requirements(s,claim.chain,field(f,"task_id"))
    states,read:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",claim.chain,field(f,"task_id"))
    return configured && has_req && read && len(states)==1 && (states[0][0]=="merge_pending" || states[0][0]=="merge_blocked") &&
        states[0][1]==field(f,"attempt") && req[0]==field(f,"requirements_revision") && field(config,"configuration_revision")==field(f,"configuration_revision")
}
merge_prepared :: proc(s:^Store,claim:Intent_Claim) -> string {
    rows,ok:=query(s.db,"SELECT head FROM local_merge_preparations WHERE intent_id=? AND payload_digest=?",claim.id,claim.digest)
    if !ok || len(rows)!=1 do return ""
    return rows[0][0]
}
merge_prepare :: proc(s:^Store,claim:Intent_Claim,head:string) -> bool {
    if head=="" || !contracts.owner_field_valid(head,"optional_commit") do return false
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    if !merge_claim_current(s,claim) do return false
    existing:=merge_prepared(s,claim)
    if existing!="" {
        if existing!=head do return false
    } else {
        if _,ok:=query(s.db,"INSERT INTO local_merge_preparations VALUES(?,?,?)",claim.id,claim.digest,head);!ok do return false
    }
    return transaction_commit(&tx)
}


// A revoked lifecycle cannot fall back to the generic lease-only protocol after
// fleet re-enrollment. Only a fresh explicit lifecycle configuration restores it.
lifecycle_path_current :: proc(s:^Store,chain,task:string) -> bool {
    rows,ok:=query(s.db,"SELECT 1 FROM local_config_revocations r WHERE chain_id=? AND task_id=? AND revision=(SELECT max(revision) FROM lifecycle_configs c WHERE c.chain_id=r.chain_id AND c.task_id=r.task_id)",chain,task)
    return ok && len(rows)==0
}
