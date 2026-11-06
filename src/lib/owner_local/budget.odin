package owner_local

import "core:encoding/json"
import jsonx "odin_test:lib/jsonx"

// Mirrors the budget-relevant transitions in taskv2/fold.odin. In particular,
// migration is an explicit seed, handoff keeps current_counted, and an expiry
// marked noncounting affects the NEXT grant rather than refunding this one.
// The archival caller validates prefix completeness separately from this fold.
Budget_State :: struct {
    attempt_no,counting_attempts,review_leases,review_rounds:i64,
    last_release,work_lease_id,holder_instance_id,blocked_on_json:string,
    live,in_review,done,cancelled,held,exhausted,current_counted,oscillating:bool,
}
Budget_Input :: struct { max_attempts:i64, gate,no_review:bool }

budget_counts :: proc(release:string)->bool {
    switch release {
    case "replaced","dep_added","reopened","user_stopped","released_noncounting": return false
    }
    return true
}
budget_allows :: proc(v:Budget_State,maximum:i64)->bool {
    limit:=maximum
    if limit<=0 do limit=5
    return v.last_release=="handoff" || !budget_counts(v.last_release) || v.counting_attempts<limit
}
budget_exhaust :: proc(v:^Budget_State,limit:i64) {
    if v.counting_attempts>=limit && !v.done && !v.cancelled do v.exhausted=true
}
budget_bool :: proc(raw,name:string)->bool { return jsonx.extract_bool(raw,name,false,true) }
budget_string :: proc(raw,name:string)->string { return jsonx.extract_string(raw,name,"",true,context.temp_allocator) }

budget_event :: proc(v:^Budget_State,kind,payload:string,input:Budget_Input) {
    limit:=input.max_attempts
    if limit<=0 do limit=5
    switch kind {
    case "migrated":
        v.attempt_no=i64(jsonx.extract_int(payload,"attempt_no",0,true))
        v.counting_attempts=v.attempt_no;v.current_counted=v.attempt_no>0
        state:=budget_string(payload,"state")
        v.live=state=="in_progress";v.in_review=state=="in_review"
        v.done=state=="done";v.cancelled=state=="cancelled"
        v.blocked_on_json=""
        value,err:=json.parse_string(payload,.JSON,true,context.temp_allocator)
        if o,ok:=value.(json.Object);err==nil && ok {
            if block,found:=o["blocked_on"];found do v.blocked_on_json=encode(block)
        }
    case "lease_granted":
        if budget_string(payload,"kind")=="review" { v.review_leases+=1;return }
        if v.done || v.cancelled do return
        v.live=true;v.in_review=false
        v.work_lease_id=budget_string(payload,"lease_id");v.holder_instance_id=budget_string(payload,"instance_id")
        if v.last_release!="handoff" {
            v.attempt_no+=1;v.current_counted=budget_counts(v.last_release)
            if v.current_counted do v.counting_attempts+=1
        }
        v.last_release=""
    case "submitted":
        v.live=false;v.last_release="submitted"
        if !input.gate && !budget_bool(payload,"gate") && input.no_review { v.done=true;v.in_review=false } else { v.in_review=true }
    case "blocked":
        dispatch,infrastructure:=budget_bool(payload,"dispatch_failed"),budget_bool(payload,"infrastructure")
        continuation:=(dispatch && budget_bool(payload,"continuation")) || (infrastructure && v.last_release=="handoff")
        if dispatch && budget_string(payload,"kind")=="review" {
            if v.review_leases>0 do v.review_leases-=1
        } else {
            v.live=false
            if dispatch && !budget_bool(payload,"continuation") && v.current_counted { v.counting_attempts-=1;v.current_counted=false }
        }
        v.last_release=("handoff" if continuation else "blocked")
        value,err:=json.parse_string(payload,.JSON,true,context.temp_allocator)
        v.blocked_on_json="{}"
        if o,ok:=value.(json.Object);err==nil && ok {
            if block,found:=o["waiting_on"];found do v.blocked_on_json=encode(block)
        }
        if !dispatch && !infrastructure do budget_exhaust(v,limit)
    case "handoff":
        if budget_string(payload,"kind")=="review" { if v.review_leases>0 do v.review_leases-=1;return }
        v.live=false;v.last_release="handoff"
    case "lease_expired":
        if budget_string(payload,"kind")=="review" { if v.review_leases>0 do v.review_leases-=1;return }
        v.live=false
        reason:=budget_string(payload,"reason")
        switch reason {
        case "replaced","dep_added","user_stopped": v.last_release=reason
        case:
            counting,found:=jsonx.extract_bool_literal(payload,"counting",true)
            if found && !counting { v.last_release="released_noncounting";return }
            v.last_release="expired";budget_exhaust(v,limit)
        }
    case "requirements_rework":
        if v.in_review { v.in_review=false;v.last_release="replaced" }
    case "changes_requested":
        if !v.in_review do return
        v.in_review=false
        if input.gate { v.cancelled=true;return }
        v.review_rounds+=1;v.last_release="changes_requested"
        if v.review_rounds>=3 do v.oscillating=true
        budget_exhaust(v,limit)
    case "approved":
        if v.in_review { v.in_review=false;v.done=true }
    case "carried_forward": v.in_review=false;v.live=false;v.cancelled=false;v.done=true
    case "cancelled": v.cancelled=true;v.live=false;v.in_review=false
    case "held": v.held=true
    case "hold_released": v.held=false
    case "reopened":
        v.done=false;v.cancelled=false;v.in_review=false;v.live=false
        v.blocked_on_json="";v.exhausted=false;v.oscillating=false;v.review_rounds=0;v.last_release="reopened"
    case "merge_conflict":
        if v.done { v.done=false;v.last_release="reopened";v.blocked_on_json="{}" }
    case "answered":
        // Native infrastructure answers preserve review-round accounting.
        block_kind:=budget_string(v.blocked_on_json,"kind")
        infrastructure:=block_kind=="agent_not_running" || block_kind=="dispatch"
        v.blocked_on_json="";v.exhausted=false;v.oscillating=false
        if !infrastructure do v.review_rounds=0
    }
}
