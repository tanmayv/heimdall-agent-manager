#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

retirement_record_test :: proc(t:^testing.T,f:^Fixture,task:string)->contracts.Owner_Native_Attempt {
    v,r,_,ok:=attempt_scan(&f.store,"chain",task,1)
    testing.expect(t,ok && !v.incomplete && !v.live && !v.in_review && !v.held)
    testing.expect_value(t,v.attempt_no,1)
    testing.expect_value(t,v.counting_attempts,1)
    testing.expect_value(t,r.outcome,"expired:chain_closed")
    testing.expect_value(t,r.completeness,"full")
    testing.expect_value(t,r.started_ms,"1000")
    _,parsed:=contracts.owner_parse(encode(r),"native_attempt")
    testing.expect(t,parsed,"retired native records must satisfy the public wire contract")
    return r
}

@(test)
workflow_retirement_static_retry_is_atomic_replay_safe_and_restart_exact :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"workflow.define","define",workflow_test_definition()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
    task:=workflow_task_id("chain","run","1","first")
    workflow_bind(t,f,task)
    claim:=workflow_lease_raw(f,task,"wf_lease","claim_workflow")
    testing.expect_value(t,lease_invoke(f,claim,"",lease_child()).code,"ok")
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,`{"run_id":"run","execution":"1"}`)}))
    rev,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    raw:=command(f,"workflow.retry","retry","",payload,rev[0][0],3000)
    snapshot:="SELECT (SELECT json_group_array(evidence_json) FROM local_events),(SELECT json_group_array(capability_json) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_workflow_tasks)"
    before,_:=query(f.store.db,snapshot)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER retire_event_fail BEFORE INSERT ON local_events WHEN NEW.kind='workflow.retry' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,invoke(f,raw,payload,1200).code,"storage_error")
    after,_:=query(f.store.db,snapshot)
    testing.expect_value(t,encode(after),encode(before))
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_task_retirements")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,`DROP TRIGGER retire_event_fail;
      CREATE TABLE retire_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE retire_ref(id INTEGER REFERENCES retire_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER retire_commit_fail AFTER INSERT ON local_task_retirements BEGIN INSERT INTO retire_ref VALUES(1); END;`))
    testing.expect_value(t,invoke(f,raw,payload,1200).code,"storage_error")
    after,_=query(f.store.db,snapshot)
    testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER retire_commit_fail"))
    result:=invoke(f,raw,payload,1200)
    testing.expect_value(t,result.code,"ok")
    record:=retirement_record_test(t,f,task)
    testing.expect_value(t,record.ended_ms,"1200")
    testing.expect_value(t,record.work_lease_id,"wf_lease")
    replay:=invoke(f,raw,payload,1250)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==result.body)
    ok:bool
    rows,ok=query(f.store.db,"SELECT r.lease_id,r.reason,r.cause,e.actor_kind,e.actor_id,e.ts_ms,e.evidence_json FROM local_task_retirements r JOIN local_events e USING(seq) WHERE r.task_id=?",task)
    if testing.expect(t,ok && len(rows)==1) {
        testing.expect(t,rows[0][0]=="wf_lease" && rows[0][1]=="chain_closed" && rows[0][2]=="workflow.retry" && rows[0][3]=="device" && rows[0][4]=="device" && rows[0][5]=="1200")
        value,_:=contracts.owner_request_document(rows[0][6]);e,_:=value.(json.Object)
        testing.expect_value(t,field(e,"command"),raw)
        testing.expect(t,strings.contains(field(e,"task_retirements"),task))
    }
    testing.expect(t,!exec(f.store.db,"UPDATE local_task_retirements SET reason='chain_closed'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_task_retirements"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,encode(retirement_record_test(t,f,task)),encode(record))
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}

@(test)
workflow_retirement_language_cancel_and_gate_rejection_preserve_native_outcome :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for method in ([2]string{"workflow.cancel","workflow.gate"}) {
        f:=fixture(t)
        seed(t,f)
        spec:=`{"schema":"workflow.v1","stages":[{"key":"work","brief":{"goal":"Work","acceptance":["done"]}},{"key":"gate","kind":"gate","approver":"user"}]}`
        testing.expect_value(t,language_test_define(f,"retire",spec).code,"ok")
        testing.expect_value(t,language_test_run(f,"retire","retire",`{}`).code,"ok")
        task:=language_tasks(f,"retire","1","work")[0][0]
        workflow_bind(t,f,task)
        testing.expect_value(t,lease_invoke(f,workflow_lease_raw(f,task,"wf_lease","wf_claim"),"",lease_child()).code,"ok")
        body:=`{"run_id":"retire","execution":"1","reason":"Stop"}`
        if method=="workflow.gate" do body=`{"run_id":"retire","execution":"1","stage_key":"gate","verdict":"request_changes","summary":"Stop"}`
        testing.expect_value(t,advanced_call(f,method,"stop",body,"",nil,1300).code,"ok")
        record:=retirement_record_test(t,f,task)
        testing.expect_value(t,record.ended_ms,"1300")
        rows,_:=query(f.store.db,"SELECT cause FROM local_task_retirements WHERE task_id=?",task)
        testing.expect_value(t,rows[0][0],method)
        testing.expect_value(t,advanced_call(f,"workflow.retry","retry",`{"run_id":"retire","execution":"1"}`,"",nil,1400).code,"ok")
        testing.expect_value(t,encode(retirement_record_test(t,f,task)),encode(record))
        rows,_=query(f.store.db,"SELECT count(*) FROM local_task_retirements WHERE task_id=?",task)
        testing.expect_value(t,rows[0][0],"1")
        destroy(f)
    }
}

@(test)
workflow_retirement_implicit_expansion_failure_uses_current_event :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    spec:=`{"schema":"workflow.v1","stages":[
      {"key":"source","brief":{"goal":"Source","output":{"schema":"inline","required":["items"]}}},
      {"key":"work","brief":{"goal":"Work","acceptance":["done"]}},
      {"key":"gate","kind":"gate","approver":"user"},
      {"key":"expand","depends_on":["source","gate"],"for_each":"source.outputs[0].items","brief":{"goal":"Expand","acceptance":["done"]}}]}`
    testing.expect_value(t,language_test_define(f,"implicit",spec).code,"ok")
    testing.expect_value(t,language_test_run(f,"implicit","implicit",`{}`).code,"ok")
    source:=language_tasks(f,"implicit","1","source")[0][0]
    // Native output fan-out fails above 256 items. A non-array output instead
    // has native empty-fan-out semantics and would not exercise failure.
    output:=strings.concatenate({`{"items":[`,strings.repeat("{},",256,context.temp_allocator),`{}]}`},context.temp_allocator)
    language_finish(t,f,source,output)
    task:=language_tasks(f,"implicit","1","work")[0][0]
    workflow_bind(t,f,task)
    testing.expect_value(t,lease_invoke(f,workflow_lease_raw(f,task,"implicit_lease","implicit_claim"),"",lease_child()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.gate","approve_gate",`{"run_id":"implicit","execution":"1","stage_key":"gate","verdict":"approve","summary":"Go"}`,"",nil,1500).code,"ok")
    record:=retirement_record_test(t,f,task)
    testing.expect_value(t,record.ended_ms,"1500")
    rows,ok:=query(f.store.db,"SELECT r.cause,e.operation_id,e.kind,e.ts_ms FROM local_task_retirements r JOIN local_events e USING(seq) WHERE r.task_id=?",task)
    testing.expect(t,ok && len(rows)==1 && rows[0][0]=="workflow.failed" && rows[0][1]=="approve_gate" && rows[0][2]=="workflow.gate" && rows[0][3]=="1500")
    _,source_record,_,read:=attempt_scan(&f.store,"chain",source,1)
    testing.expect(t,read && source_record.outcome=="submitted" && source_record.ended_ms=="1000")
    rows,_=query(f.store.db,"SELECT count(*) FROM local_task_retirements WHERE task_id=?",source)
    testing.expect_value(t,rows[0][0],"0")
}

@(test)
workflow_retirement_v13_upgrade_collision_commit_rollback_and_exact_preservation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    keep:="SELECT (SELECT json_group_array(json_array(seq,ts_ms,actor_kind,actor_id,kind,operation_id,evidence_json,completeness)) FROM local_events),(SELECT json_group_array(json_array(principal_id,operation_id,input_digest,result_json)) FROM command_receipts),(SELECT json_group_array(json_array(chain_id,task_id,revision,brief_json,cipher)) FROM task_requirements),(SELECT capability_json FROM local_leases WHERE retired_seq IS NULL LIMIT 1)"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_013);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_events")]
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS native_metadata_members; DROP TABLE IF EXISTS native_metadata_directories; DROP TABLE IF EXISTS native_metadata_snapshots; DROP TABLE IF EXISTS native_metadata_origins; DROP VIEW IF EXISTS local_fleet_policy_current; DROP TABLE IF EXISTS local_fleet_policy_models; DROP TABLE IF EXISTS local_fleet_policy_roles; DROP TABLE IF EXISTS local_fleet_policy_versions; DROP TABLE IF EXISTS native_budget_overlap; DROP TABLE IF EXISTS budget_control_owners; DROP TABLE IF EXISTS local_dependency_retirements; DROP TABLE IF EXISTS local_budget_evidence; DROP TABLE IF EXISTS native_budget_baselines; DROP TRIGGER IF EXISTS deferred_prepared_merge_no_invalidation; DROP TABLE IF EXISTS deferred_workflow_dispositions; DROP TABLE IF EXISTS deferred_workflow_retirements; DROP TABLE IF EXISTS native_history_records; DROP TABLE local_task_retirements"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=13; CREATE VIEW local_task_retirements AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="13" && rows[0][1]=="13")
    testing.expect(t,exec(db,`DROP VIEW local_task_retirements;
      CREATE TABLE migration_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE migration_ref(id INTEGER REFERENCES migration_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER retire_migration_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=14 BEGIN INSERT INTO migration_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_task_retirements') FROM runtime_database")
    testing.expect(t,rows[0][0]=="13" && rows[0][1]=="13" && rows[0][2]=="0")
    after,_:=query(db,keep)
    testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER retire_migration_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_=query(f.store.db,keep)
    testing.expect_value(t,encode(after),encode(before))
    rows,_=query(f.store.db,"SELECT count(*) FROM local_task_retirements")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","after_v14",`{"requirements_revision":"1"}`,cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
