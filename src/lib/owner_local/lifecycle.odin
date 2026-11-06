#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// Child agent identity is observed from the launch record, never caller JSON.
Lifecycle_Proof :: struct { author,reviewer:Child, paths_valid:bool }
lifecycle_config :: proc(s:^Store,chain,task:string) -> (json.Object,[]string,bool) {
    rows,ok:=query(s.db,"SELECT config_json,author_child,reviewer_child,revision FROM lifecycle_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
    if !ok || len(rows)!=1 do return nil,nil,false
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
    if !ok || !obj || len(o)!=2 do return false
    goal,is_string:=o["goal"].(json.String)
    acceptance,is_array:=o["acceptance"].(json.Array)
    if !is_string || strings.trim_space(string(goal))=="" || !is_array || len(acceptance)==0 || len(acceptance)>100 do return false
    for a in acceptance { text,valid:=a.(json.String);if !valid || strings.trim_space(string(text))=="" do return false }
    return true
}
lifecycle_human :: proc(s:^Store,c,p:json.Object,body,raw,payload:string,proof:Lifecycle_Proof) -> string {
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    switch method {
    case "lifecycle.configure":
        if !proof.paths_valid || proof.author.agent_id!=field(p,"author_agent_id") ||
           proof.reviewer.agent_id!=field(p,"reviewer_agent_id") || proof.author.agent_id==proof.reviewer.agent_id ||
           proof.reviewer.instance!=field(p,"reviewer_instance_id") || proof.author.instance==proof.reviewer.instance ||
           proof.author.epoch=="" || proof.reviewer.epoch=="" { return "invalid_scope" }
        previous,read:=query(s.db,"SELECT revision FROM lifecycle_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
        if !read do return "storage_error"
        if len(previous)>0 && number(previous[0][0])>=number(field(p,"configuration_revision")) do return "stale_revision"
        states,looked:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !looked do return "storage_error"
        if len(states)>0 && states[0][0]!="ready" && states[0][0]!="in_review" do return "operation_conflict"
        fleet,found:=query(s.db,"SELECT instance_id,launch_epoch,run_count,token_generation,enabled FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
        if !found || len(fleet)!=1 || fleet[0][0]!=proof.author.instance || fleet[0][1]!=proof.author.epoch ||
           number(fleet[0][2])!=proof.author.run_count || fleet[0][3]!=proof.author.token_generation || fleet[0][4]!="1" {return "invalid_scope"}
        if _,ok:=query(s.db,"INSERT INTO lifecycle_configs VALUES(?,?,?,?,?,?,?,?,?)",chain,task,field(p,"configuration_revision"),payload,raw,field(c,"principal_id"),field(c,"operation_id"),encode(proof.author),encode(proof.reviewer));!ok do return "storage_error"
        if _,ok:=query(s.db,"INSERT OR IGNORE INTO lifecycle_state(chain_id,task_id,state) VALUES(?,?,'ready')",chain,task);!ok do return "storage_error"
        if _,ok:=query(s.db,"UPDATE lifecycle_state SET state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    case "requirements.edit":
        if !brief_valid(body) do return "invalid_content"
        prior:i64
        if r,ok:=lifecycle_requirements(s,chain,task);ok do prior=number(r[0])
        if number(field(p,"requirements_revision"))!=prior+1 do return "stale_revision"
        state,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !ok do return "storage_error"
        if len(state)==1 && (state[0][0]=="merge_pending" || state[0][0]=="merge_blocked" || state[0][0]=="done") do return "operation_conflict"
        if _,ok=query(s.db,"INSERT INTO task_requirements VALUES(?,?,?,?,?,?,?)",chain,task,field(p,"requirements_revision"),body,field(p,"body_cipher"),field(c,"principal_id"),field(c,"operation_id"));!ok do return "storage_error"
        if _,ok=query(s.db,"UPDATE lifecycle_state SET state='ready' WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    case "review.post":
        return lifecycle_review(s,c,p,"",true)
    }
    _,ok:=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return "storage_error"
    return "ok"
}

// Verdicts always bind the immutable submission. Device approval is recorded
// separately and never satisfies the required independent agent pair.
lifecycle_review :: proc(s:^Store,c,p:json.Object,agent:string,human:bool) -> string {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    if !control_ready(s,chain,task) do return "operation_conflict"
    config,_,configured:=lifecycle_config(s,chain,task)
    req,has_req:=lifecycle_requirements(s,chain,task)
    state,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
    if !configured || !has_req || !ok || len(state)!=1 do return "invalid_scope"
    if state[0][0]!="in_review" || state[0][1]!=field(p,"attempt") || req[0]!=field(p,"requirements_revision") do return "stale_revision"
    submitted,read:=query(s.db,"SELECT head,requirements_revision,author_agent_id,configuration_revision FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,field(p,"attempt"))
    if !read || len(submitted)!=1 do return "storage_error"
    if submitted[0][0]!=field(p,"head") || submitted[0][1]!=req[0] || submitted[0][3]!=field(config,"configuration_revision") do return "stale_revision"
    if !human && (agent!=field(config,"reviewer_agent_id") || agent==submitted[0][2]) do return "invalid_scope"
    reviewer:=agent
    if human do reviewer=field(c,"principal_id")
    if _,ok=query(s.db,"INSERT INTO local_reviews VALUES(?,?,?,?,?,?,?,?,?,?)",chain,task,field(p,"attempt"),reviewer,field(c,"principal_id"),field(c,"operation_id"),req[0],field(p,"head"),field(p,"verdict"),field(p,"summary"));!ok do return "operation_conflict"
    next:="in_review"
    if field(p,"verdict")=="request_changes" { next="ready" } else if !human {
        next="done"
        if field(config,"merge_policy")=="git" do next="merge_pending"
    }
    if _,ok=query(s.db,"UPDATE lifecycle_state SET state=? WHERE chain_id=? AND task_id=?",next,chain,task);!ok do return "storage_error"
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
