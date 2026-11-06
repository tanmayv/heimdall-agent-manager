#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

// Native attempt numbers differ from both immutable V7 lease ordinals and V4
// submission keys. Derive them from retained accepted events, never row counts.
// See taskv2/fold.odin:138-149,377-403. Handoff continues an attempt; structural
// replacement starts a new, non-counting attempt on the next grant.
Attempt_View :: struct {
    attempt_no,counting_attempts,grants:i64,
    last_release,work_lease_id:string,
    live,in_review,incomplete:bool,
}

attempt_grant :: proc(v:^Attempt_View,lease:string) {
    if v.live || lease=="" { v.incomplete=true;return }
    if v.last_release!="handoff" {
        v.attempt_no+=1
        switch v.last_release {
        case "replaced","dep_added","reopened","user_stopped","released_noncounting":
        case: v.counting_attempts+=1
        }
    }
    v.grants+=1
    v.last_release=""
    v.work_lease_id=lease
    v.live=true;v.in_review=false
}

attempt_release :: proc(v:^Attempt_View,release:string) {
    v.live=false
    v.last_release=release
}

// Only accepted events enter this fold. Receipt replay and rolled-back commands
// therefore cannot consume attempts. Ignore observations and review checkpoints.
attempt_event :: proc(v:^Attempt_View,kind:string,c,p:json.Object,destination:=false) {
    if kind=="lease.switch" && destination {
        attempt_grant(v,field(p,"destination_lease_id"))
        return
    }
    switch kind {
    case "lease.claim": attempt_grant(v,field(c,"lease_id"))
    case "lease.handoff","lease.switch":
        // A held-work checkpoint can follow the owner's retirement decision.
        // It still represents a native handoff continuation, unlike a reviewer
        // checkpoint, which has its own method and never reaches this branch.
        if v.attempt_no==0 { v.incomplete=true;return }
        attempt_release(v,"handoff")
    case "lease.block": attempt_release(v,"blocked")
    case "lease.expired": attempt_release(v,"expired")
    case "lease.submit":
        attempt_release(v,"submitted");v.in_review=true
    case "task.reopen":
        attempt_release(v,"reopened");v.in_review=false
    case "fleet.edit","lifecycle.configure","review.roles":
        if v.live || v.in_review {
            attempt_release(v,"replaced");v.in_review=false
        }
    case "task.cancel":
        v.live=false;v.in_review=false
    case "task.hold":
        // Native hold retains its work lease until checkpoint or TTL expiry
        // (taskv2/verbs_m2.odin:622-625). The current local hold retires it
        // immediately. Do not invent a structural native release for that gap.
        if v.live do v.incomplete=true
    case "requirements.edit":
        // Editing a live brief does not retire the work lease. Replacing a
        // submitted brief does invalidate its review, without spending budget.
        if v.in_review { attempt_release(v,"replaced");v.in_review=false }
    case "review.post","review.role.post":
        if field(p,"verdict")=="request_changes" {
            attempt_release(v,"changes_requested");v.in_review=false
        }
    }
}

// This projection deliberately reports incomplete historical evidence. V13
// legacy_tag rows do not contain enough data to reconstruct native outcomes.
// An unrepresented retirement (for example a workflow-wide retry) is likewise
// explicit until its task-specific native mapping is implemented. Callers must
// not use such a projection for budget enforcement or native migration export.
attempt_view :: proc(s:^Store,chain,task:string) -> (Attempt_View,bool) {
    v:Attempt_View
    after:="0"
    for {
        // Project only structural fields from trusted accepted evidence. Never
        // copy every historical summary/body into a runtime observation. Keyset
        // pages bound each database result even for long handoff histories.
        rows,ok:=query(s.db,`WITH candidates AS (
          SELECT seq,chain_id,task_id,kind,completeness,
            CASE WHEN completeness='full' THEN evidence_json ELSE '{}' END AS evidence
          FROM local_events WHERE seq>?3 AND ((chain_id=?1 AND task_id=?2
            AND kind IN('lease.claim','lease.handoff','lease.switch','lease.block',
              'lease.expired','lease.submit','task.reopen','fleet.edit','lifecycle.configure',
              'review.roles','task.hold','task.cancel','requirements.edit','review.post','review.role.post'))
            OR kind='lease.switch')),
          decoded AS (SELECT *,NULLIF(json_extract(evidence,'$.command'),'') AS command,
            NULLIF(json_extract(evidence,'$.payload'),'') AS payload FROM candidates)
          SELECT seq,chain_id,task_id,kind,completeness,
            COALESCE(json_extract(command,'$.lease_id'),''),
            COALESCE(json_extract(payload,'$.verdict'),''),
            COALESCE(json_extract(payload,'$.destination_lease_id'),'')
          FROM decoded WHERE (chain_id=?1 AND task_id=?2) OR
            (kind='lease.switch' AND json_extract(payload,'$.destination_chain_id')=?1
              AND json_extract(payload,'$.destination_task_id')=?2)
          ORDER BY seq LIMIT 128`,chain,task,after)
        if !ok do return v,false
        for row in rows {
            after=row[0]
            if row[4]!="full" { v.incomplete=true;continue }
            c:=doc(map[string]string{"lease_id"=row[5]})
            p:=doc(map[string]string{"verdict"=row[6],"destination_lease_id"=row[7]})
            attempt_event(&v,row[3],c,p,row[1]!=chain || row[2]!=task)
        }
        if len(rows)<128 do break
    }
    // Count is a completeness cross-check only, never the native attempt count.
    leases,read:=query(s.db,"SELECT count(*),COALESCE(MAX(CASE WHEN retired_seq IS NULL THEN lease_id END),'') FROM local_leases WHERE chain_id=? AND task_id=?",chain,task)
    if !read || len(leases)!=1 do return v,false
    if number(leases[0][0])!=v.grants || (v.live && leases[0][1]!=v.work_lease_id) || (!v.live && leases[0][1]!="") do v.incomplete=true
    return v,true
}

attempt_document :: proc(v:Attempt_View) -> contracts.Owner_Attempt_State {
    return {fmt.tprintf("%d",v.attempt_no),fmt.tprintf("%d",v.counting_attempts),v.last_release,v.work_lease_id,("incomplete" if v.incomplete else "full")}
}
