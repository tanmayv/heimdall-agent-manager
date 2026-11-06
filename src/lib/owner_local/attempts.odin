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
    live,in_review,incomplete,held,pending_changes:bool,
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
    v.pending_changes=false
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
        // A requested checkpoint is an ordinary handoff continuation.
        // Reviewer checkpoints never reach this work-attempt branch.
        if v.attempt_no==0 { v.incomplete=true;return }
        attempt_release(v,"handoff")
    case "lease.block": attempt_release(v,"blocked")
    case "lease.expired": attempt_release(v,"expired")
    case "dependency.edit":
        if field(p,"dependency_retired")!="" do attempt_release(v,"dep_added")
    case "lease.submit":
        attempt_release(v,"submitted");v.in_review=true
    case "task.reopen":
        attempt_release(v,"reopened");v.in_review=false
    case "fleet.edit","lifecycle.configure","review.roles":
        if v.live || v.in_review {
            attempt_release(v,"replaced");v.in_review=false
        }
    case "task.cancel":
        v.live=false;v.in_review=false;v.held=false;v.pending_changes=false
    case "task.hold":
        v.held=true
        // Pre-fix hold evidence revoked authority immediately. Keep that
        // historical gap explicit even after a later checkpoint or release.
        if v.live && field(p,"hold_semantics")!=contracts.OWNER_HOLD_SEMANTICS do v.incomplete=true
    case "task.release":
        v.held=false
        if v.pending_changes {
            attempt_release(v,"changes_requested");v.in_review=false
            v.pending_changes=false
        }
    case "requirements.edit":
        // Editing a live brief does not retire the work lease. Replacing a
        // submitted brief does invalidate its review, without spending budget.
        if v.in_review { attempt_release(v,"replaced");v.in_review=false }
    case "review.post","review.role.post":
        if field(p,"verdict")=="request_changes" {
            if v.held { v.pending_changes=true } else {
                attempt_release(v,"changes_requested");v.in_review=false
            }
        }
    }
}

// This projection deliberately reports incomplete historical evidence. V13
// legacy_tag rows do not contain enough data to reconstruct native outcomes.
// An older unrepresented workflow retirement remains explicitly incomplete;
// V14 records task-specific retirement evidence without repairing old events.
// Callers must not use this for budget enforcement or native migration export.
attempt_view :: proc(s:^Store,chain,task:string) -> (Attempt_View,bool) {
    v,_,_,ok:=attempt_scan(s,chain,task)
    return v,ok
}

// The immutable accepted event stream is the canonical source. Keep only one
// selected native record in memory while scanning bounded pages. In particular,
// a handoff continuation changes holder/end/outcome, never original start time
// or counting status (native lease.odin:177-190).
attempt_scan :: proc(s:^Store,chain,task:string,selected:i64=0,target_lease:string="") -> (Attempt_View,contracts.Owner_Native_Attempt,string,bool) {
    v:Attempt_View
    record:contracts.Owner_Native_Attempt
    record_incomplete:=false
    mapped:=""
    after:="0"
    for {
        // Project only structural fields from trusted accepted evidence. Never
        // copy every historical summary/body into a runtime observation. Keyset
        // pages bound each database result even for long handoff histories.
        rows,ok:=query(s.db,`WITH candidates AS (
          SELECT seq,chain_id,task_id,kind,completeness,ts_ms,
            CASE WHEN completeness='full' THEN evidence_json ELSE '{}' END AS evidence
          FROM local_events WHERE seq>?3 AND ((chain_id=?1 AND task_id=?2
            AND kind IN('lease.claim','lease.handoff','lease.switch','lease.block',
              'lease.expired','lease.submit','task.reopen','fleet.edit','lifecycle.configure',
              'review.roles','task.hold','task.release','task.cancel','requirements.edit','review.post','review.role.post','dependency.edit'))
            OR kind='lease.switch' OR EXISTS(SELECT 1 FROM local_metadata_retirements r WHERE r.seq=local_events.seq AND r.chain_id=?1 AND r.task_id=?2) OR (chain_id=?1 AND EXISTS(SELECT 1 FROM local_task_retirements r WHERE r.seq=local_events.seq AND r.chain_id=?1 AND r.task_id=?2)))),
          decoded AS (SELECT *,NULLIF(json_extract(evidence,'$.command'),'') AS command,
            NULLIF(json_extract(evidence,'$.payload'),'') AS payload,
            NULLIF(json_extract(evidence,'$.content'),'') AS content FROM candidates)
          SELECT seq,chain_id,task_id,kind,completeness,
            COALESCE(json_extract(command,'$.lease_id'),''),
            COALESCE(json_extract(payload,'$.verdict'),''),
            COALESCE(json_extract(payload,'$.destination_lease_id'),''),
            COALESCE(json_extract(content,'$.hold_semantics'),''),
            COALESCE(ts_ms,''),COALESCE(json_extract(command,'$.instance_id'),''),
            COALESCE(json_extract(content,'$.reason'),''),
            COALESCE((SELECT lease_id FROM local_task_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2),''),
            COALESCE((SELECT reason FROM local_task_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2),''),
            COALESCE((SELECT lease_id FROM local_dependency_retirements d WHERE d.seq=decoded.seq AND d.chain_id=?1 AND d.task_id=?2),''),
            COALESCE((SELECT lease_id FROM local_metadata_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2),''),
            COALESCE((SELECT cause FROM local_metadata_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2),'')
          FROM decoded WHERE (chain_id=?1 AND task_id=?2) OR EXISTS(SELECT 1 FROM local_metadata_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2) OR EXISTS(SELECT 1 FROM local_task_retirements r WHERE r.seq=decoded.seq AND r.chain_id=?1 AND r.task_id=?2) OR
            (kind='lease.switch' AND json_extract(payload,'$.destination_chain_id')=?1
              AND json_extract(payload,'$.destination_task_id')=?2)
          ORDER BY seq LIMIT 128`,chain,task,after)
        if !ok do return v,record,mapped,false
        for row in rows {
            after=row[0]
            if row[4]!="full" { v.incomplete=true;continue }
            c:=doc(map[string]string{"lease_id"=row[5]})
            p:=doc(map[string]string{"verdict"=row[6],"destination_lease_id"=row[7],"hold_semantics"=row[8],"dependency_retired"=row[14]})
            previous:=v
            destination:=row[1]!=chain || row[2]!=task
            if !destination || row[3]=="lease.switch" do attempt_event(&v,row[3],c,p,destination)
            if v.grants>previous.grants {
                if v.work_lease_id==target_lease do mapped=fmt.tprintf("%d",v.attempt_no)
                if selected==0 || selected==v.attempt_no {
                    if v.attempt_no!=previous.attempt_no {
                        record_incomplete=false
                        record=contracts.Owner_Native_Attempt{
                            account_id=s.account,chain_id=chain,task_id=task,
                            attempt_no=fmt.tprintf("%d",v.attempt_no),started_ms=row[9],
                            counts_toward_budget=("1" if v.counting_attempts>previous.counting_attempts else "0"),
                        }
                    }
                    record.holder_instance_id=row[10];record.work_lease_id=v.work_lease_id
                    record.ended_ms="";record.outcome=""
                }
            } else if previous.live && !v.live && record.attempt_no==fmt.tprintf("%d",previous.attempt_no) {
                record.ended_ms=row[9]
                record.outcome=v.last_release
                // Native close_attempt stores expiry reasons verbatim with
                // their prefix (lease.odin:407), separate from fold releases.
                switch row[3] {
                case "task.cancel": record.outcome="expired:cancelled"
                case "dependency.edit": record.outcome="expired:dep_added"
                case "fleet.edit","lifecycle.configure","review.roles": record.outcome="expired:replaced"
                case "lease.expired":
                    if row[11]=="ttl" || row[11]=="hard_cap" {
                        record.outcome=fmt.tprintf("expired:%s",row[11])
                    } else {
                        // Older evidence retained no reason. Do not fabricate
                        // the reason from a deadline observed much later.
                        record_incomplete=true
                    }
                }
            }
            if row[16]!="" {
                if v.live && row[15]!=v.work_lease_id { v.incomplete=true } else {
                    was_live:=v.live
                    attempt_event(&v,"fleet.edit",c,p,false)
                    if was_live && record.attempt_no==fmt.tprintf("%d",v.attempt_no) {
                        record.ended_ms=row[9];record.outcome="expired:replaced"
                    }
                }
            }
            if row[13]!="" {
                // The parent command may concern a different task. Apply its
                // task-scoped native expiry then cancellation after the parent.
                if v.live {
                    if row[12]!=v.work_lease_id { v.incomplete=true } else {
                        if record.attempt_no==fmt.tprintf("%d",v.attempt_no) {
                            record.ended_ms=row[9];record.outcome="expired:chain_closed"
                        }
                        attempt_release(&v,"expired")
                    }
                } else if row[12]!="" { v.incomplete=true }
                v.in_review=false;v.held=false;v.pending_changes=false
            }
        }
        if len(rows)<128 do break
    }
    // Count is a completeness cross-check only, never the native attempt count.
    leases,read:=query(s.db,"SELECT count(*),COALESCE(MAX(CASE WHEN retired_seq IS NULL THEN lease_id END),'') FROM local_leases WHERE chain_id=? AND task_id=?",chain,task)
    if !read || len(leases)!=1 do return v,record,mapped,false
    if number(leases[0][0])!=v.grants || (v.live && leases[0][1]!=v.work_lease_id) || (!v.live && leases[0][1]!="") do v.incomplete=true
    record.completeness=("incomplete" if v.incomplete || record_incomplete else "full")
    return v,record,mapped,true
}

attempt_document :: proc(v:Attempt_View) -> contracts.Owner_Attempt_State {
    return {fmt.tprintf("%d",v.attempt_no),fmt.tprintf("%d",v.counting_attempts),v.last_release,v.work_lease_id,("incomplete" if v.incomplete else "full")}
}
