#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

budget_input :: proc(s:^Store,chain,task:string)->(Budget_Input,bool) {
    input:=Budget_Input{max_attempts=5}
    if req,found:=lifecycle_requirements(s,chain,task);found {
        value,err:=json.parse_string(req[1],.JSON,true,context.temp_allocator)
        brief,obj:=value.(json.Object)
        if err!=nil || !obj do return input,false
        if value,present:=brief["budget"];present {
            budget,obj:=value.(json.Object)
            if !obj do return input,false
            if value,present:=budget["max_attempts"];present {
                n,integer:=value.(json.Integer)
                if !integer || n<=0 do return input,false
                input.max_attempts=i64(n)
            }
        }
    }
    return input,true
}

budget_local_event :: proc(v:^Budget_State,pending:^bool,kind:string,c,p,content:json.Object,input:Budget_Input,destination:bool) {
    if destination {
        budget_event(v,"lease_granted",encode(doc(map[string]string{"lease_id"=field(p,"destination_lease_id"),"instance_id"=field(c,"instance_id")})),input)
        return
    }
    switch kind {
    case "lease.claim": budget_event(v,"lease_granted",encode(c),input)
    case "lease.handoff","lease.switch":budget_event(v,"handoff","{}",input)
    case "lease.block":budget_event(v,"blocked","{}",input)
    case "lease.expired":budget_event(v,"lease_expired",encode(content),input)
    case "dependency.edit":
        if field(content,"dependency_retired")!="" do budget_event(v,"lease_expired",`{"reason":"dep_added"}`,input)
    case "lease.submit":budget_event(v,"submitted","{}",input)
    case "task.cancel":budget_event(v,"cancelled","{}",input)
    case "task.reopen":budget_event(v,"reopened","{}",input)
    case "task.resolve":budget_event(v,"answered","{}",input)
    case "task.hold":budget_event(v,"held","{}",input)
    case "task.release":
        budget_event(v,"hold_released","{}",input)
        if pending^ { budget_event(v,"changes_requested","{}",input);pending^=false }
    case "fleet.edit","fleet.reserve","lifecycle.configure","review.roles":
        if v.live do budget_event(v,"lease_expired",`{"reason":"replaced"}`,input)
        if v.in_review do budget_event(v,"requirements_rework","{}",input)
        pending^=false
    case "requirements.edit":
        budget_event(v,"requirements_rework","{}",input);pending^=false
    case "review.post","review.role.post":
        if field(p,"verdict")=="request_changes" && v.in_review {
            if v.held { pending^=true } else { budget_event(v,"changes_requested","{}",input) }
        }
    }
}

budget_view :: proc(s:^Store,chain,task:string)->(Budget_State,contracts.Owner_Budget_State,bool) {
    v:Budget_State
    input,input_ok:=budget_input(s,chain,task)
    document:=contracts.Owner_Budget_State{max_attempts=fmt.tprintf("%d",input.max_attempts),requirements_revision="0",configuration_revision="0",execution="standalone"}
    if !input_ok do return v,document,false
    checkpoint,checkpoint_ok:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !checkpoint_ok || len(checkpoint)!=1 do return v,document,false
    document.local_cutoff=checkpoint[0][0]
    if req,found:=lifecycle_requirements(s,chain,task);found do document.requirements_revision=req[0]
    if config,_,found:=lifecycle_config(s,chain,task);found do document.configuration_revision=field(config,"configuration_revision")
    execution,execution_ok:=budget_execution(s,chain,task)
    if !execution_ok do return v,document,false
    document.execution=execution
    baselines,ok:=query(s.db,"SELECT source_revision,native_cutoff,local_cutoff,execution,activation_json FROM native_budget_baselines WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return v,document,false
    after:="0"
    if len(baselines)==1 {
        b:=baselines[0];document.source_revision=b[0]
        if b[3]!=execution { document.reason="history_incomplete" } else {
            var_valid:bool
            source_input:=input
            activation,activation_valid:=contracts.owner_parse(b[4],"budget_activation_payload")
            if !activation_valid do return v,document,false
            source_input.gate=field(activation,"source_gate")=="1";source_input.no_review=field(activation,"source_no_review")=="1"
            v,var_valid=budget_source(s,chain,task,b[0],b[1],source_input)
            if !var_valid do document.reason="history_incomplete"
        }
        after=b[2]
    } else {
        archived,read:=query(s.db,"SELECT 1 FROM native_history_records WHERE chain_id=? AND task_id=? LIMIT 1",chain,task)
        if !read do return v,document,false
        if len(archived)>0 do document.reason="activation_required"
    }
    local,complete:=attempt_view(s,chain,task)
    if !complete do return v,document,false
    if local.incomplete do document.reason="history_incomplete"
    pending:=false
    for {
        rows,read:=query(s.db,`WITH selected AS (
          SELECT seq,chain_id,task_id,kind,completeness,CASE WHEN completeness='full' THEN evidence_json ELSE '{}' END evidence
          FROM local_events WHERE seq>?3 AND ((chain_id=?1 AND task_id=?2 AND kind IN(
            'lease.claim','lease.handoff','lease.switch','lease.block','lease.expired','lease.submit',
            'task.cancel','task.reopen','task.resolve','task.hold','task.release','fleet.edit','fleet.reserve','lifecycle.configure',
            'review.roles','requirements.edit','review.post','review.role.post','dependency.edit')) OR kind='lease.switch'
            OR EXISTS(SELECT 1 FROM local_metadata_retirements r WHERE r.seq=local_events.seq AND r.chain_id=?1 AND r.task_id=?2) OR EXISTS(SELECT 1 FROM local_task_retirements r WHERE r.seq=local_events.seq AND r.chain_id=?1 AND r.task_id=?2))),
          decoded AS (SELECT *,NULLIF(json_extract(evidence,'$.command'),'') AS command,
            NULLIF(json_extract(evidence,'$.payload'),'') AS payload,
            NULLIF(json_extract(evidence,'$.content'),'') AS content FROM selected)
          SELECT seq,kind,completeness,chain_id,task_id,
            COALESCE(json_extract(command,'$.lease_id'),''),COALESCE(json_extract(command,'$.instance_id'),''),
            COALESCE(json_extract(payload,'$.verdict'),''),COALESCE(json_extract(payload,'$.destination_lease_id'),''),
            COALESCE(json_extract(content,'$.reason'),''),
            COALESCE((SELECT reason FROM local_task_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2),''),
            COALESCE((SELECT lease_id FROM local_dependency_retirements d WHERE d.seq=decoded.seq AND d.chain_id=?1 AND d.task_id=?2),''),
            COALESCE((SELECT cause FROM local_metadata_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2),'')
          FROM decoded WHERE chain_id=?1 AND task_id=?2 OR
            (kind='lease.switch' AND json_extract(payload,'$.destination_chain_id')=?1
              AND json_extract(payload,'$.destination_task_id')=?2)
            OR EXISTS(SELECT 1 FROM local_metadata_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2) OR EXISTS(SELECT 1 FROM local_task_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2)
          ORDER BY seq LIMIT 128`,chain,task,after)
        if !read do return v,document,false
        for row in rows {
            after=row[0]
            if row[2]!="full" { document.reason="history_incomplete";continue }
            c:=doc(map[string]string{"lease_id"=row[5],"instance_id"=row[6]})
            p:=doc(map[string]string{"verdict"=row[7],"destination_lease_id"=row[8]})
            content:=doc(map[string]string{"reason"=row[9],"dependency_retired"=row[11]})
            destination:=row[3]!=chain || row[4]!=task
            if !destination || row[1]=="lease.switch" do budget_local_event(&v,&pending,row[1],c,p,content,input,destination)
            if row[12]!="" do budget_local_event(&v,&pending,"fleet.edit",c,p,content,input,false)
            if row[10]!="" {
                if v.live do budget_event(&v,"lease_expired",`{"reason":"chain_closed"}`,input)
                budget_event(&v,"cancelled","{}",input)
            }
        }
        if len(rows)<128 do break
    }
    document.attempt_no=fmt.tprintf("%d",v.attempt_no);document.counting_attempts=fmt.tprintf("%d",v.counting_attempts);document.last_release=v.last_release
    if document.reason=="" && (v.exhausted || (!v.live && !v.in_review && !v.done && !v.cancelled && !budget_allows(v,input.max_attempts))) do document.reason="budget_exhausted"
    if document.reason=="" && v.oscillating do document.reason="oscillation"
    if document.reason=="" && document.source_revision!="" {
        if v.done || v.cancelled { document.reason="native_terminal" } else if v.blocked_on_json!="" || v.oscillating { document.reason="native_blocked" }
    }
    return v,document,true
}

budget_admit :: proc(s:^Store,chain,task:string)->string {
    v,state,ok:=budget_view(s,chain,task)
    if !ok do return "storage_error"
    if state.reason=="history_incomplete" || state.reason=="activation_required" do return "recovery_required"
    if v.attempt_no==0x7fffffffffffffff && v.last_release!="handoff" do return "recovery_required"
    if state.reason=="budget_exhausted" do return "budget_exhausted"
    if state.reason=="native_blocked" || state.reason=="oscillation" do return "operation_conflict"
    if state.source_revision!="" && (v.done || v.cancelled) do return "operation_conflict"
    return "ok"
}

// Append evidence alongside the accepted cause event, in its transaction.
// Failure rolls back the cause/receipt/authority together. No replay appends.
budget_record :: proc(s:^Store,chain,task:string,seq:i64)->bool {
    _,state,ok:=budget_view(s,chain,task)
    if !ok do return false
    state.local_cutoff=fmt.tprintf("%d",seq)
    _,ok=query(s.db,"INSERT INTO local_budget_evidence VALUES(?,?,?,?)",chain,task,fmt.tprintf("%d",seq),encode(state))
    if !ok do return false
    return budget_control_reconcile(s,chain,task,state.reason)
}

budget_control_reconcile :: proc(s:^Store,chain,task,reason:string)->bool {
    controls,ok:=query(s.db,"SELECT mode,resume_state,reason,waiting_on FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return false
    owners,read:=query(s.db,"SELECT reason,prior_json FROM budget_control_owners WHERE chain_id=? AND task_id=?",chain,task)
    if !read do return false
    required:=reason=="budget_exhausted" || reason=="native_blocked" || reason=="oscillation"
    if len(controls)==1 && controls[0][0]=="cancelled" do required=false
    if required {
        if len(owners)==0 {
            if _,ok=query(s.db,"INSERT INTO budget_control_owners VALUES(?,?,?,?)",chain,task,reason,encode(controls));!ok do return false
        } else if _,ok=query(s.db,"UPDATE budget_control_owners SET reason=? WHERE chain_id=? AND task_id=?",reason,chain,task);!ok do return false
        if len(controls)==1 && controls[0][0]=="held" {
            _,ok=query(s.db,"UPDATE local_controls SET resume_state='blocked' WHERE chain_id=? AND task_id=?",chain,task)
            return ok
        }
        return control_mode(s,chain,task,"blocked","ready",reason,"human")
    }
    if len(owners)==0 do return true
    prior:[dynamic][]string
    if json.unmarshal_string(owners[0][1],&prior,.JSON,context.temp_allocator)!=nil do return false
    if len(prior)>1 || (len(prior)==1 && len(prior[0])!=4) do return false
    if len(controls)==1 && controls[0][0]=="held" {
        resume,waiting:="ready",""
        if len(prior)==1 { resume=prior[0][0];waiting=prior[0][3];if resume=="held" do resume=prior[0][1] }
        if _,ok=query(s.db,"UPDATE local_controls SET resume_state=?,waiting_on=? WHERE chain_id=? AND task_id=?",resume,waiting,chain,task);!ok do return false
    } else if len(controls)==1 && controls[0][0]=="blocked" && controls[0][2]==owners[0][0] {
        if len(prior)==0 {
            if _,ok=query(s.db,"DELETE FROM local_controls WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
        } else if !control_mode(s,chain,task,prior[0][0],prior[0][1],prior[0][2],prior[0][3]) do return false
    }
    _,ok=query(s.db,"DELETE FROM budget_control_owners WHERE chain_id=? AND task_id=?",chain,task)
    return ok
}
