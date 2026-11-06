#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:time"
import contracts "odin_test:contracts"

Overlap_Step :: struct {
    seq,ts,kind,lease,holder,reason,actor:string,
    attempt,counting:i64,
}
overlap_relevant :: proc(kind:string)->bool {
    switch kind {
    case "lease_granted","handoff","blocked","lease_expired","submitted","held","hold_released","cancelled","reopened","answered","requirements_rework","changes_requested","approved","merge_conflict","carried_forward": return true
    }
    return false
}

overlap_approval_settled :: proc(s:^Store,chain,task,seq,cutoff,attempt:string)->bool {
    generated,generated_ok:=query(s.db,"SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id=?",chain,task)
    if !generated_ok do return false
    if len(generated)==0 {
        submitted,read:=query(s.db,`SELECT r.requirements_json,c.config_json FROM local_submissions r JOIN lifecycle_configs c
          ON c.chain_id=r.chain_id AND c.task_id=r.task_id AND c.revision=r.configuration_revision
          WHERE r.chain_id=? AND r.task_id=? AND r.attempt=?`,chain,task,attempt)
        if !read || len(submitted)!=1 do return false
        config,parsed:=contracts.owner_parse(submitted[0][1],"lifecycle_config_payload")
        if !parsed do return false
        reviews,review_ok:=query(s.db,`SELECT r.reviewer_agent_id,r.principal_id,r.verdict FROM local_reviews r JOIN local_events e
          ON e.chain_id=r.chain_id AND e.task_id=r.task_id AND e.actor_id=r.principal_id AND e.operation_id=r.operation_id
          WHERE r.chain_id=? AND r.task_id=? AND r.attempt=? AND e.seq<=?`,chain,task,attempt,seq)
        if !review_ok do return false
        independent,user:=false,false
        for row in reviews {
            if row[2]=="request_changes" do return false
            if row[2]=="approve" && row[0]==field(config,"reviewer_agent_id") do independent=true
            if row[2]=="approve" && row[0]==row[1] && row[0]!=field(config,"reviewer_agent_id") do user=true
        }
        required_user:=budget_bool(submitted[0][0],"requires_user_approval")
        roles,roles_ok:=query(s.db,`SELECT json_extract(json_extract(json_extract(evidence_json,'$.content'),'$.body'),'$.configuration_revision')
          FROM local_events WHERE chain_id=? AND task_id=? AND seq<=? AND kind='review.roles' AND completeness='full' ORDER BY seq DESC LIMIT 1`,chain,task,seq)
        if !roles_ok do return false
        if len(roles)==1 {
            owed,owed_ok:=query(s.db,`SELECT 1 FROM local_role_pairs p WHERE p.chain_id=?1 AND p.task_id=?2 AND p.revision=?3
              AND NOT EXISTS(SELECT 1 FROM local_role_reviews r JOIN local_events e ON e.chain_id=r.chain_id AND e.task_id=r.task_id
                AND e.actor_id=r.principal_id AND e.operation_id=r.operation_id WHERE r.chain_id=p.chain_id AND r.task_id=p.task_id
                AND r.attempt=?4 AND r.role_revision=p.revision AND r.role=p.role AND r.agent_id=p.agent_id AND r.verdict='approve' AND e.seq<=?5)`,chain,task,roles[0][0],attempt,seq)
            flags,flags_ok:=query(s.db,"SELECT requires_user_approval FROM local_role_configs WHERE chain_id=? AND task_id=? AND revision=?",chain,task,roles[0][0])
            rejected,rejected_ok:=query(s.db,`SELECT 1 FROM local_role_reviews r JOIN local_events e ON e.chain_id=r.chain_id AND e.task_id=r.task_id
              AND e.actor_id=r.principal_id AND e.operation_id=r.operation_id WHERE r.chain_id=? AND r.task_id=? AND r.role_revision=? AND r.attempt=? AND r.verdict='request_changes' AND e.seq<=?`,chain,task,roles[0][0],attempt,seq)
            if !owed_ok || !flags_ok || !rejected_ok || len(owed)>0 || len(rejected)>0 || len(flags)!=1 do return false
            required_user=required_user || flags[0][0]=="1"
        }
        return independent && (!required_user || user)
    }
    rows,ok:=query(s.db,`SELECT 1 FROM lifecycle_state l WHERE l.chain_id=?1 AND l.task_id=?2
      AND l.state IN('done','merge_pending','merge_blocked') AND CAST(?3 AS INTEGER)=(SELECT max(e.seq) FROM local_events e
        WHERE e.chain_id=?1 AND e.task_id=?2 AND e.seq<=?4 AND e.completeness='full'
          AND e.kind IN('review.post','review.role.post')
          AND json_extract(json_extract(e.evidence_json,'$.payload'),'$.verdict')='approve'
          AND json_extract(json_extract(e.evidence_json,'$.payload'),'$.attempt')=CAST(l.attempt AS TEXT))`,chain,task,seq,cutoff)
    return ok && len(rows)==1
}

// Compare the complete budget-bearing local prefix with a contiguous suffix of
// original source events. Audit-only events can sit between its transitions.
// Every grant/end retains its exact lease, actor/holder and event timestamp;
// logical counters differ only by the source prefix preceding the overlap.
overlap_local_steps :: proc(s:^Store,chain,task,cutoff:string,input:Budget_Input)->([]Overlap_Step,bool) {
    steps:=make([dynamic]Overlap_Step,context.temp_allocator)
    v:Budget_State;pending:=false;after:="0";submission:=i64(0)
    for {
        rows,ok:=query(s.db,`WITH selected AS (SELECT seq,kind,ts_ms,actor_id,completeness,
          CASE WHEN completeness='full' THEN evidence_json ELSE '{}' END AS e,chain_id,task_id
          FROM local_events WHERE seq>?3 AND seq<=?4 AND ((chain_id=?1 AND task_id=?2) OR kind='lease.switch')),
          decoded AS (SELECT *,NULLIF(json_extract(e,'$.command'),'') c,NULLIF(json_extract(e,'$.payload'),'') p,NULLIF(json_extract(e,'$.content'),'') b FROM selected)
          SELECT seq,kind,COALESCE(ts_ms,''),actor_id,completeness,chain_id,task_id,
            COALESCE(json_extract(c,'$.lease_id'),''),COALESCE(json_extract(c,'$.instance_id'),''),
            COALESCE(json_extract(p,'$.verdict'),''),COALESCE(json_extract(p,'$.destination_lease_id'),''),COALESCE(json_extract(b,'$.reason'),''),
            COALESCE((SELECT lease_id FROM local_dependency_retirements d WHERE d.seq=decoded.seq AND d.chain_id=?1 AND d.task_id=?2),'')
          FROM decoded WHERE chain_id=?1 AND task_id=?2 OR (kind='lease.switch' AND json_extract(p,'$.destination_chain_id')=?1 AND json_extract(p,'$.destination_task_id')=?2)
          ORDER BY seq LIMIT 128`,chain,task,after,cutoff)
        if !ok do return nil,false
        for row in rows {
            after=row[0]
            kind:=row[1]
            // These are archived or administrative observations, never grants.
            if kind=="task.create" || kind=="task.comment" || kind=="native.history.import" || kind=="requirements.present" || kind=="requirements.ack" || kind=="lease.heartbeat" || kind=="review.open" || kind=="review.role.open" || kind=="review.checkpoint" do continue
            if row[4]!="full" do return nil,false
            c:=doc(map[string]string{"lease_id"=row[7],"instance_id"=row[8]})
            p:=doc(map[string]string{"verdict"=row[9],"destination_lease_id"=row[10]})
            content:=doc(map[string]string{"reason"=row[11],"dependency_retired"=row[12]})
            before:=v;was_pending:=pending
            destination:=row[5]!=chain || row[6]!=task
            budget_local_event(&v,&pending,kind,c,p,content,input,destination)
            if kind=="lease.submit" do submission+=1
            native,reason:="",""
            switch kind {
            case "lease.claim":native="lease_granted"
            case "lease.switch":native=("lease_granted" if destination else "handoff")
            case "lease.handoff":native="handoff"
            case "lease.block":native="blocked"
            case "lease.expired":native="lease_expired";reason=row[11]
            case "lease.submit":native="submitted"
            case "task.hold":native="held"
            case "task.release":native="hold_released"
            case "task.cancel":native="cancelled"
            case "task.reopen":native="reopened"
            case "task.resolve":native="answered"
            case "dependency.edit":if row[12]!="" {native="lease_expired";reason="dep_added"}
            case "fleet.edit","lifecycle.configure","review.roles":
                if before.live {native="lease_expired";reason="replaced"} else if before.in_review {native="requirements_rework"}
            case "requirements.edit":if before.in_review do native="requirements_rework"
            case "review.post","review.role.post":
                if row[9]=="request_changes" && before.in_review && !before.held do native="changes_requested"
                // A terminal current gate and its exact final review event
                // prove settlement; partial approvals remain native audit only.
                if row[9]=="approve" && before.in_review && !before.held && overlap_approval_settled(s,chain,task,row[0],cutoff,fmt.tprintf("%d",submission)) {
                    native="approved";budget_event(&v,"approved","{}",input)
                }
            }
            if native=="" do continue
            lease:=before.work_lease_id;holder:=row[8]
            if native=="lease_granted" {lease=(row[10] if destination else row[7])}
            append(&steps,Overlap_Step{row[0],row[2],native,lease,holder,reason,row[3],v.attempt_no,v.counting_attempts})
            if kind=="task.release" && was_pending {
                append(&steps,Overlap_Step{row[0],row[2],"changes_requested",lease,holder,"",row[3],v.attempt_no,v.counting_attempts})
            } else if kind=="task.release" && before.in_review && overlap_approval_settled(s,chain,task,row[0],cutoff,fmt.tprintf("%d",submission)) {
                budget_event(&v,"approved","{}",input)
                append(&steps,Overlap_Step{row[0],row[2],"approved",lease,holder,"",row[3],v.attempt_no,v.counting_attempts})
            }
        }
        if len(rows)<128 do break
    }
    return steps[:],true
}

overlap_timestamp :: proc(raw,ms:string)->bool {
    if len(raw)<20 do return false
    end:=19;fraction,digits:=i64(0),0
    if raw[end]=='.' {
        end+=1
        for end<len(raw) && raw[end]>='0' && raw[end]<='9' {
            digits+=1
            if digits>9 || (digits>3 && raw[end]!='0') do return false
            if digits<=3 do fraction=fraction*10+i64(raw[end]-'0')
            end+=1
        }
        if digits==0 do return false
    }
    zone:=raw[end:]
    if zone!="Z" && zone!="z" {
        if len(zone)!=6 || (zone[0]!='+' && zone[0]!='-') || zone[3]!=':' do return false
        for i in ([4]int{1,2,4,5}) { if zone[i]<'0' || zone[i]>'9' do return false }
        if (zone[1]-'0')*10+zone[2]-'0'>23 || (zone[4]-'0')*10+zone[5]-'0'>59 do return false
    }
    // The pinned core parser accepts only hundredths. Parse its whole-second
    // calendar/offset form and retain the original fractional precision here.
    whole:=fmt.tprintf("%s%s",raw[:19],zone)
    t,n:=time.rfc3339_to_time_utc(whole)
    if n==0 || n!=len(whole) do return false
    scale:=i64(1000)
    if digits>0 {
        for i:=digits;i<3;i+=1 do fraction*=10
        scale=(100 if digits==1 else (10 if digits==2 else 1))
    }
    value:=time.to_unix_nanoseconds(t)/1000000+fraction
    return value==number(ms)/scale*scale
}
overlap_provenance :: proc(raw,name:string)->string {
    value,err:=json.parse_string(raw,.JSON,true,context.temp_allocator);o,obj:=value.(json.Object)
    if err!=nil || !obj do return ""
    if text,ok:=o[name].(json.String);ok do return string(text)
    if n,ok:=o[name].(json.Integer);ok do return fmt.tprintf("%d",n)
    return ""
}

budget_reconcile_overlap :: proc(s:^Store,chain,task,source,cutoff,local_cutoff:string,input:Budget_Input)->bool {
    projection,ok:=attempt_view(s,chain,task)
    if !ok || projection.incomplete || projection.live || projection.held do return false
    if projection.grants==0 do return true
    steps,local_ok:=overlap_local_steps(s,chain,task,local_cutoff,input)
    if !local_ok || len(steps)==0 || steps[0].kind!="lease_granted" do return false
    v:Budget_State;last:="0";started:=false;index:=0
    offset,count_offset:=i64(0),i64(0)
    mapped:=make(map[i64]i64,context.temp_allocator)
    matches:=make([dynamic][4]string,context.temp_allocator)
    for {
        rows,read:=query(s.db,"SELECT record_json FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=? AND record_kind='event' AND CAST(record_key AS INTEGER)>? ORDER BY CAST(record_key AS INTEGER) LIMIT 128",chain,task,source,last)
        if !read do return false
        for row in rows {
            e,valid:=native_content_parse(row[0],"native_history_event")
            if !valid || field(e,"owner_user_id")!=s.account do return false
            last=field(e,"event_id");kind,payload:=field(e,"kind"),field(e,"payload_json")
            before:=v;budget_event(&v,kind,payload,input)
            if !overlap_relevant(kind) || budget_string(payload,"kind")=="review" do continue
            lease:=budget_string(payload,"lease_id")
            if kind=="lease_granted" && lease==steps[0].lease {
                if started do return false
                started=true;offset=v.attempt_no-steps[0].attempt;count_offset=v.counting_attempts-steps[0].counting
            }
            if !started do continue
            if index>=len(steps) do return false
            step:=steps[index]
            if step.kind!=kind || step.ts!=field(e,"ts_ms") || v.attempt_no!=step.attempt+offset || v.counting_attempts!=step.counting+count_offset do return false
            if kind=="lease_granted" {
                if lease!=step.lease || budget_string(payload,"instance_id")!=step.holder do return false
                if budget_string(payload,"bridge_id")!=s.owner do return false
                if budget_string(payload,"attempt_no")!="" && overlap_provenance(payload,"attempt_no")!=fmt.tprintf("%d",v.attempt_no) do return false
                if prior,exists:=mapped[step.attempt];exists && prior!=v.attempt_no do return false
                mapped[step.attempt]=v.attempt_no
            }
            if kind=="handoff" || kind=="blocked" || kind=="submitted" || kind=="lease_expired" {
                if lease!=step.lease || before.work_lease_id!=step.lease do return false
                if kind=="lease_expired" && budget_string(payload,"reason")!=step.reason do return false
                if kind!="lease_expired" && field(e,"actor_id")!=step.actor do return false
            }
            append(&matches,[4]string{step.seq,last,fmt.tprintf("%d",step.attempt),fmt.tprintf("%d",v.attempt_no)})
            index+=1
        }
        if len(rows)<128 do break
    }
    if !started || index!=len(steps) || last!=cutoff || offset<0 || count_offset<0 do return false
    // Compare each original attempt's outcome/bit/holder/time and signed source
    // requirements/config provenance with the immutable local lease records.
    for local_no,native_no in mapped {
        _,local,_,local_valid:=attempt_scan(s,chain,task,local_no)
        if !local_valid || local.completeness!="full" do return false
        rows,read:=query(s.db,"SELECT record_json FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=? AND record_kind='attempt' AND record_key=?",chain,task,source,fmt.tprintf("%d",native_no))
        if !read || len(rows)!=1 do return false
        record,valid:=native_content_parse(rows[0][0],"native_history_attempt")
        if !valid || field(record,"owner_user_id")!=s.account || field(record,"holder_instance_id")!=local.holder_instance_id || field(record,"outcome")!=local.outcome || field(record,"counts_toward_budget")!=local.counts_toward_budget do return false
        if !overlap_timestamp(field(record,"started_at"),local.started_ms) || !overlap_timestamp(field(record,"ended_at"),local.ended_ms) do return false
        leases,lease_ok:=query(s.db,"SELECT requirements_revision,configuration_revision FROM local_leases WHERE lease_id=?",local.work_lease_id)
        if !lease_ok || len(leases)!=1 || overlap_provenance(field(record,"provenance_json"),"requirements_revision")!=leases[0][0] || overlap_provenance(field(record,"provenance_json"),"configuration_revision")!=leases[0][1] do return false
        execution,execution_ok:=budget_execution(s,chain,task)
        run:=overlap_provenance(field(record,"provenance_json"),"run_id")
        if !execution_ok || (execution!="standalone" && fmt.tprintf("%s:%s",run,overlap_provenance(field(record,"provenance_json"),"execution"))!=execution) || (execution=="standalone" && run!="") do return false
        head:=overlap_provenance(field(record,"provenance_json"),"head")
        if head!="" {
            heads,head_ok:=query(s.db,"SELECT head FROM local_submissions WHERE lease_id=? UNION SELECT json_extract(config_json,'$.base_head') FROM lifecycle_configs WHERE chain_id=? AND task_id=? AND revision=?",local.work_lease_id,chain,task,leases[0][1])
            found:=false
            for row in heads { if row[0]==head do found=true }
            if !head_ok || !found do return false
        }
    }
    for row in matches {
        if _,inserted:=query(s.db,"INSERT INTO native_budget_overlap VALUES(?,?,?,?,?,?)",chain,task,row[0],row[1],row[2],row[3]);!inserted do return false
    }
    return true
}
