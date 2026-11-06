#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

deferred_retirement_test :: proc(t:^testing.T,legacy:bool) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    spec:=`{"schema":"workflow.v1","stages":[
      {"key":"source","brief":{"goal":"Source","output":{"schema":"inline","required":["items"]}}},
      {"key":"merging","brief":{"goal":"Merge","acceptance":["done"]}},
      {"key":"gate","kind":"gate","approver":"user"},
      {"key":"expand","depends_on":["source","gate"],"for_each":"source.outputs[0].items","brief":{"goal":"Expand","acceptance":["done"]}}]}`
    testing.expect_value(t,language_test_define(f,"deferred",spec).code,"ok")
    testing.expect_value(t,language_test_run(f,"deferred","deferred",`{}`).code,"ok")
    source:=language_tasks(f,"deferred","1","source")[0][0]
    output:=strings.concatenate({`{"items":[`,strings.repeat("{},",256,context.temp_allocator),`{}]}`},context.temp_allocator)
    language_finish(t,f,source,output)
    task:=language_tasks(f,"deferred","1","merging")[0][0]
    human_gate_bind(t,f,task,true)
    claimed:=lease_invoke(f,workflow_lease_raw(f,task,"merging_lease","merging_claim"),"",lease_child())
    if !testing.expect_value(t,claimed.code,"ok") do return
    cap:=result_cap(claimed)
    for method in ([2]string{"requirements.present","requirements.ack"}) {
        testing.expect_value(t,language_child_call(f,task,"merging_lease",lease_child(),method,fmt.tprintf("merge_%s",method),`{"requirements_revision":"1"}`,cap).code,"ok")
    }
    head:=strings.repeat("a",40,context.temp_allocator)
    payload:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Submitted before workflow failure"}))
    raw:=language_child_raw(f,task,"merging_lease",lease_child(),"lease.submit","merge_submit",payload,cap)
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{head,true}).code,"ok")
    verdict:=lifecycle_verdict(head)
    opened:=language_child_call(f,task,"merging_lease",lifecycle_reviewer(),"review.open","merge_open",verdict,"")
    testing.expect_value(t,opened.code,"ok")
    testing.expect_value(t,language_child_call(f,task,"merging_lease",lifecycle_reviewer(),"review.post","merge_approved",verdict,result_cap(opened)).code,"ok")
    claims,read:=intent_claim_due(&f.store,1000)
    testing.expect(t,read)
    merge:Intent_Claim
    for claim in claims { if claim.kind=="merge" do merge=claim }
    if !testing.expect(t,merge.id!="") do return
    testing.expect(t,merge_prepare(&f.store,merge,head))
    testing.expect_value(t,advanced_call(f,"workflow.gate","fail_expansion",`{"run_id":"deferred","execution":"1","stage_key":"gate","verdict":"approve","summary":"Go"}`,"",nil,1500).code,"ok")
    rows,_:=query(f.store.db,"SELECT d.intent_id,d.cause,e.operation_id,(SELECT count(*) FROM deferred_workflow_dispositions),(SELECT state FROM lifecycle_state WHERE task_id=?) FROM deferred_workflow_retirements d JOIN local_events e ON e.seq=d.requested_seq",task)
    if !testing.expect_value(t,len(rows),1) do return
    testing.expect(t,rows[0][0]==merge.id && rows[0][1]=="workflow.failed" && rows[0][2]=="fail_expansion" && rows[0][3]=="0" && rows[0][4]=="merge_pending")
    testing.expect_value(t,merge_prepared(&f.store,merge),head)
    testing.expect(t,merge_claim_current(&f.store,merge))
    testing.expect_value(t,advanced_call(f,"task.cancel","unsafe_cancel","Stop",task,nil,1500).code,"operation_conflict")
    testing.expect(t,merge_claim_current(&f.store,merge))
    testing.expect(t,intent_result(&f.store,merge,false,"transport failed",1600))
    testing.expect_value(t,advanced_call(f,"workflow.retry","unsafe_retry",`{"run_id":"deferred","execution":"1"}`,"",nil,1600).code,"operation_conflict")
    close(&f.store)
    if legacy {
        // Reconstruct genuine V14: there was no deferred table or event member.
        // This fixture-only edit removes V15 evidence rather than pretending
        // its known original request provenance existed in the older runtime.
        db:DB
        testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
        testing.expect(t,exec(db,`DROP TABLE IF EXISTS local_chain_defaults_versions; DROP TABLE IF EXISTS local_chain_summary_versions; DROP TRIGGER IF EXISTS native_history_origin; DROP TABLE IF EXISTS local_fleet_policy_sources; DROP TABLE IF EXISTS native_fleet_policies; DROP TABLE IF EXISTS native_fleet_snapshots; DROP TABLE IF EXISTS local_task_priority_versions; DROP TABLE IF EXISTS native_fact_chain; DROP TABLE IF EXISTS native_fact_task; DROP TABLE IF EXISTS native_fact_comment; DROP TABLE IF EXISTS native_fact_summary; DROP TABLE IF EXISTS native_fact_snapshots; DROP TABLE IF EXISTS native_metadata_members; DROP TABLE IF EXISTS native_metadata_directories; DROP TABLE IF EXISTS native_metadata_snapshots; DROP TABLE IF EXISTS native_metadata_origins; DROP VIEW IF EXISTS local_fleet_policy_current; DROP TABLE IF EXISTS local_fleet_policy_models; DROP TABLE IF EXISTS local_fleet_policy_roles; DROP TABLE IF EXISTS local_fleet_policy_versions; DROP TABLE IF EXISTS native_budget_overlap; DROP TABLE IF EXISTS budget_control_owners; DROP TABLE IF EXISTS local_dependency_retirements; DROP TABLE IF EXISTS local_budget_evidence; DROP TABLE IF EXISTS native_budget_baselines; DROP TRIGGER deferred_prepared_merge_no_invalidation;
          DROP TABLE deferred_workflow_dispositions; DROP TABLE deferred_workflow_retirements; DROP TABLE native_history_records;
          DROP TRIGGER local_events_no_update;
          UPDATE local_events SET evidence_json=json_remove(evidence_json,'$.deferred_retirements') WHERE json_type(evidence_json,'$.deferred_retirements') IS NOT NULL;
          CREATE TRIGGER local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;`))
        prefix:=string(MIGRATION_014);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_task_retirements")]
        if !testing.expect(t,exec(db,prefix)) do return
        testing.expect(t,exec(db,"UPDATE schema_migrations SET version=14"))
        testing.expect_value(t,sqlite3_close(db),0)
    }
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT COALESCE(requested_seq,''),cause,source_completeness FROM deferred_workflow_retirements")
    if !testing.expect_value(t,len(rows),1) do return
    if legacy { testing.expect(t,rows[0][0]=="" && rows[0][1]=="unknown" && rows[0][2]=="incomplete") }
    else { testing.expect(t,rows[0][0]!="" && rows[0][1]=="workflow.failed" && rows[0][2]=="full") }
    testing.expect_value(t,advanced_call(f,"task.cancel","restart_unsafe_cancel","Stop",task,nil,3000).code,"operation_conflict")
    testing.expect(t,!intent_result(&f.store,merge,true,head,3000))
    claims,read=intent_claim_due(&f.store,3000);testing.expect(t,read)
    fresh:Intent_Claim
    for claim in claims { if claim.kind=="merge" do fresh=claim }
    testing.expect(t,fresh.id==merge.id && fresh.digest==merge.digest && fresh.fence==merge.fence)
    testing.expect_value(t,merge_prepared(&f.store,fresh),head)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER settlement_fail BEFORE INSERT ON local_events WHEN NEW.kind='merge.merged' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect(t,!intent_result(&f.store,fresh,true,head,3000))
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM deferred_workflow_dispositions),(SELECT state FROM runtime_intents WHERE intent_id=?)",fresh.id)
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="claimed")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER settlement_fail"))
    testing.expect(t,intent_result(&f.store,fresh,true,head,3000))
    testing.expect(t,!intent_result(&f.store,fresh,true,head,3000))
    rows,_=query(f.store.db,"SELECT r.disposition,r.head,e.kind,e.actor_kind,e.ts_ms FROM deferred_workflow_dispositions r JOIN local_events e ON e.seq=r.settled_seq")
    testing.expect(t,len(rows)==1 && rows[0][0]=="preserved_terminal" && rows[0][1]==head && rows[0][2]=="merge.merged" && rows[0][3]=="bridge" && rows[0][4]=="3000")
    _,attempt,_,ok:=attempt_scan(&f.store,"chain",task,1)
    testing.expect(t,ok && attempt.outcome=="submitted" && attempt.ended_ms=="1000")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM deferred_workflow_retirements),(SELECT count(*) FROM deferred_workflow_dispositions),(SELECT count(*) FROM local_task_retirements WHERE task_id=?)",task)
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="1" && rows[0][2]=="0")
    testing.expect_value(t,advanced_call(f,"workflow.retry","safe_retry",`{"run_id":"deferred","execution":"1"}`,"",nil,3000).code,"ok")
}

@(test)
workflow_deferred_prepared_cas_failure_restart_and_exact_terminal_disposition :: proc(t:^testing.T) {
    deferred_retirement_test(t,false)
}
@(test)
workflow_legacy_prepared_cas_upgrade_preserves_unknown_request_and_exact_settlement :: proc(t:^testing.T) {
    deferred_retirement_test(t,true)
}
