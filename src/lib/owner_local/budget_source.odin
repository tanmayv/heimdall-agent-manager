#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

// Digest exact archived bytes in (record_kind,record_key) binary order. The
// initial domain includes scope; each link includes its typed immutable key.
// Counts are signed too, so a partially imported snapshot cannot activate.
budget_snapshot :: proc(s:^Store,chain,task,source:string)->(string,[3]i64,bool) {
    digest:=contracts.owner_payload_digest(encode([4]string{"native.budget.snapshot.v1",chain,task,source}))
    counts:[3]i64
    after_kind,after_key:="",""
    for {
        rows,ok:=query(s.db,`SELECT record_kind,record_key,record_json,completeness FROM native_history_records
          WHERE chain_id=? AND task_id=? AND source_revision=? AND (record_kind,record_key)>(?,?)
          ORDER BY record_kind,record_key LIMIT 128`,chain,task,source,after_kind,after_key)
        if !ok do return "",counts,false
        for row in rows {
            if row[3]!="full" do return "",counts,false
            digest=contracts.owner_payload_digest(encode([4]string{digest,row[0],row[1],row[2]}))
            switch row[0] { case "attempt":counts[0]+=1;case "event":counts[1]+=1;case "facet":counts[2]+=1 }
            after_kind=row[0];after_key=row[1]
        }
        if len(rows)<128 do break
    }
    return digest,counts,true
}

// Source events, rather than lease-row counts or arbitrary imported outcomes,
// determine admission. The owner signs the complete prefix/cutoff manifest.
// Validate row accounting against that prefix, allowing an explicit migrated
// seed to stand without fabricating the absent pre-v2 attempt rows.
budget_source :: proc(s:^Store,chain,task,source,cutoff:string,input:Budget_Input)->(Budget_State,bool) {
    v:Budget_State
    expected_counts:=make(map[i64]bool,context.temp_allocator)
    expected_outcomes:=make(map[i64]string,context.temp_allocator)
    seed,last:=i64(0),i64(0)
    first:=true
    for {
        rows,ok:=query(s.db,`SELECT record_json FROM native_history_records WHERE chain_id=? AND task_id=?
          AND source_revision=? AND record_kind='event' AND CAST(record_key AS INTEGER)>? ORDER BY CAST(record_key AS INTEGER) LIMIT 128`,chain,task,source,fmt.tprintf("%d",last))
        if !ok do return v,false
        for row in rows {
            event,valid:=native_content_parse(row[0],"native_history_event")
            if !valid do return v,false
            id:=number(field(event,"event_id"));kind,payload:=field(event,"kind"),field(event,"payload_json")
            if id<=last || id>number(cutoff) do return v,false
            if first {
                if kind!="created" && kind!="migrated" do return v,false
                first=false
            } else if kind=="created" || kind=="migrated" { return v,false }
            p,parse_err:=json.parse_string(payload,.JSON,true,context.temp_allocator);o,obj:=p.(json.Object)
            if parse_err!=nil || !obj do return v,false
            if kind=="migrated" {
                value,present:=o["attempt_no"];n,integer:=value.(json.Integer)
                if !present || !integer || n<0 do return v,false
                switch budget_string(payload,"state") {
                case "backlog","ready","in_progress","in_review","done","cancelled":
                case:return v,false
                }
            }
            before:=v
            if kind=="lease_granted" && budget_string(payload,"kind")!="review" && !v.done && !v.cancelled && v.last_release!="handoff" && v.attempt_no==0x7fffffffffffffff do return v,false
            budget_event(&v,kind,payload,input)
            if kind=="migrated" do seed=v.attempt_no
            if kind=="lease_granted" && budget_string(payload,"kind")!="review" && !before.done && !before.cancelled {
                if before.live || budget_string(payload,"lease_id")=="" do return v,false
                if v.attempt_no>seed { expected_counts[v.attempt_no]=v.current_counted;expected_outcomes[v.attempt_no]="" }
            }
            if before.live && !v.live && v.attempt_no>seed {
                outcome:=v.last_release
                if kind=="blocked" && budget_bool(payload,"dispatch_failed") {
                    // Native dispatch.odin:77-85 closes with this outcome and
                    // refunds only a fresh (not handoff-continuation) attempt.
                    outcome="dispatch_failed"
                    if !budget_bool(payload,"continuation") do expected_counts[v.attempt_no]=false
                }
                if kind=="lease_expired" || kind=="cancelled" {
                    reason:=budget_string(payload,"reason")
                    if kind=="cancelled" do reason="cancelled"
                    if reason=="" do return v,false
                    outcome=fmt.tprintf("expired:%s",reason)
                }
                expected_outcomes[v.attempt_no]=outcome
            }
            last=id
        }
        if len(rows)<128 do break
    }
    if first || last!=number(cutoff) do return v,false
    // One original row per post-seed logical attempt, with the exact native
    // counting bit and final outcome; handoff updates that row, never adds one.
    seen:=i64(0);after:="0"
    for {
        rows,ok:=query(s.db,`SELECT record_json FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=?
          AND record_kind='attempt' AND CAST(record_key AS INTEGER)>? ORDER BY CAST(record_key AS INTEGER) LIMIT 128`,chain,task,source,after)
        if !ok do return v,false
        for row in rows {
            record,valid:=native_content_parse(row[0],"native_history_attempt")
            if !valid do return v,false
            n:=number(field(record,"attempt_no"));after=field(record,"attempt_no")
            // Pre-seed rows are not justified by the declared migrated prefix.
            // Archive them freely, but do not activate unverifiable overlap.
            counted,found:=expected_counts[n]
            if n<=seed || !found || (field(record,"counts_toward_budget")=="1")!=counted || field(record,"outcome")!=expected_outcomes[n] do return v,false
            seen+=1
        }
        if len(rows)<128 do break
    }
    return v,seen==i64(len(expected_counts))
}

budget_execution :: proc(s:^Store,chain,task:string)->(string,bool) {
    rows,ok:=query(s.db,"SELECT run_id,execution FROM local_workflow_tasks WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return "",false
    if len(rows)==0 do return "standalone",true
    if len(rows)!=1 do return "",false
    return fmt.tprintf("%s:%s",rows[0][0],rows[0][1]),true
}

budget_activate :: proc(s:^Store,c,p:json.Object,seq:i64)->string {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    prior,ok:=query(s.db,"SELECT 1 FROM native_budget_baselines WHERE chain_id=? AND task_id=?",chain,task)
    if !ok do return "storage_error"
    if len(prior)>0 do return "operation_conflict"
    state,state_ok:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !state_ok || len(state)!=1 do return "storage_error"
    if field(p,"local_cutoff")!=state[0][0] do return "stale_revision"
    req,has_req:=lifecycle_requirements(s,chain,task)
    config,_,configured:=lifecycle_config(s,chain,task)
    execution,execution_ok:=budget_execution(s,chain,task)
    if !has_req || !configured || !execution_ok || req[0]!=field(p,"requirements_revision") || field(config,"configuration_revision")!=field(p,"configuration_revision") || execution!=field(p,"execution") do return "stale_revision"
    // Without an unambiguous shared identity boundary, combining independently
    // executed local history would double count or erase real work. Fail closed.
    local,read:=query(s.db,`SELECT 1 FROM local_leases WHERE chain_id=? AND task_id=?
      UNION ALL SELECT 1 FROM local_submissions WHERE chain_id=? AND task_id=? LIMIT 1`,chain,task,chain,task)
    if !read do return "storage_error"
    if len(local)>0 do return "recovery_required"
    projection,projected:=attempt_view(s,chain,task)
    if !projected do return "storage_error"
    if projection.incomplete || projection.grants!=0 do return "recovery_required"
    digest,counts,valid:=budget_snapshot(s,chain,task,field(p,"source_revision"))
    if !valid || digest!=field(p,"snapshot_digest") || counts[0]!=number(field(p,"attempt_count")) || counts[1]!=number(field(p,"event_count")) || counts[2]!=number(field(p,"facet_count")) do return "recovery_required"
    input,input_ok:=budget_input(s,chain,task)
    if !input_ok do return "storage_error"
    input.gate=field(p,"source_gate")=="1";input.no_review=field(p,"source_no_review")=="1"
    v,valid_source:=budget_source(s,chain,task,field(p,"source_revision"),field(p,"native_cutoff"),input)
    if !valid_source || v.live || v.in_review || v.held do return "recovery_required"
    _,inserted:=query(s.db,`INSERT INTO native_budget_baselines VALUES(?,?,?,?,?,?,?,?,?,?,?)`,chain,task,field(p,"source_revision"),digest,field(p,"native_cutoff"),field(p,"local_cutoff"),req[0],field(config,"configuration_revision"),execution,encode(p),fmt.tprintf("%d",seq))
    return ("ok" if inserted else "storage_error")
}
