#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

execution_bootstrap_fixture :: proc(t:^testing.T)->(^Execution_Test,Intent_Claim) {
    x:=execution_test_fixture(t);f:=x.owner
    lifecycle_edit(t,f,"1","2")
    x.lease=lease_request(f,lease_child(),"lease.claim","claim","lease","","3")
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    testing.expect_value(t,execution_test_commit(x).code,"ok")
    claims,ok:=intent_claim_due(&f.store,1200)
    testing.expect(t,ok)
    for claim in claims do if claim.kind=="executor.activate" do return x,claim
    testing.fail_now(t,"activation claim missing")
}
@(test)
owner_bootstrap_keeps_original_signed_snapshot_and_existing_capability :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,claim:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    first:=execution_bootstrap(&f.store,claim,"# Worker","", "[]",f.owner,1200,sign)
    if !testing.expect_value(t,first.code,"ok") do return
    value,_:=contracts.owner_content_document(first.body);bundle,_:=value.(json.Object)
    b,valid:=contracts.executor_parse(field(bundle,"bootstrap"),"bootstrap");testing.expect(t,valid)
    testing.expect(t,contracts.executor_verify("bootstrap",b,f.owner))
    body,content:=contracts.executor_parse(field(bundle,"body"),"bootstrap_content");testing.expect(t,content)
    testing.expect(t,strings.contains(field(body,"task_md"),"Existing lease capability"))
    caps,_:=query(f.store.db,"SELECT capability_json FROM local_leases")
    testing.expect(t,strings.contains(field(body,"task_md"),caps[0][0]))
    again:=execution_bootstrap(&f.store,claim,"changed instructions","changed memory","[]",f.owner,1300,sign)
    testing.expect(t,again.code=="ok" && again.replay && again.body==first.body)
    testing.expect(t,!exec(f.store.db,"UPDATE owner_execution_bootstraps SET body='changed'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM owner_execution_bootstraps"))
    changed:=claim;changed.payload="{}"
    testing.expect_value(t,execution_bootstrap(&f.store,changed,"Worker","","[]",f.owner,1300,sign).code,"owner_fence_not_current")
    testing.expect_value(t,execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,3000,sign).code,"owner_fence_not_current")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,1300,sign).code,"owner_fence_not_current")
    rows,ok:=query(f.store.db,"SELECT document,body FROM owner_execution_bootstraps")
    testing.expect(t,ok && len(rows)==1 && rows[0][0]==field(bundle,"bootstrap") && rows[0][1]==field(bundle,"body"))
}
@(test)
owner_bootstrap_storage_fault_rolls_back_content_and_does_not_regrant :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,claim:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    before,_:=query(f.store.db,"SELECT commit_seq,(SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts) FROM runtime_database")
    testing.expect(t,exec(f.store.db,"CREATE TABLE bootstrap_parent(id INTEGER PRIMARY KEY); CREATE TABLE bootstrap_probe(id INTEGER REFERENCES bootstrap_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER bootstrap_fail AFTER INSERT ON owner_execution_bootstraps BEGIN INSERT INTO bootstrap_probe VALUES(1); END;"))
    testing.expect_value(t,execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,1200,sign).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM owner_execution_bootstraps),(SELECT count(*) FROM bootstrap_probe)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER bootstrap_fail"))
    testing.expect_value(t,execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,1200,sign).code,"ok")
    after,_:=query(f.store.db,"SELECT commit_seq,(SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts) FROM runtime_database")
    testing.expect_value(t,encode(after),encode(before))
}
@(test)
owner_bootstrap_v26_upgrade_collision_rolls_back_original_activation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,claim:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    before,_:=query(f.store.db,"SELECT database_id,commit_seq,(SELECT activation_json FROM owner_execution_journal) FROM runtime_database")
    close(&f.store)
    db:DB;testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    sql:=string(MIGRATION_026)
    prefix:=sql[:strings.index(sql,"CREATE TABLE owner_execution_journal")]
    testing.expect(t,exec(db,strings.concatenate({"PRAGMA foreign_keys=OFF; DROP TABLE owner_execution_bootstraps;",prefix,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=26; CREATE VIEW owner_execution_bootstraps AS SELECT 1;"},context.temp_allocator)))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id,commit_seq,(SELECT activation_json FROM owner_execution_journal) FROM runtime_database")
    testing.expect(t,rows[0][0]=="26" && rows[0][1]=="26" && rows[0][2]==before[0][0] && rows[0][3]==before[0][1] && rows[0][4]==before[0][2])
    testing.expect(t,exec(db,"DROP VIEW owner_execution_bootstraps"));testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id,commit_seq,(SELECT activation_json FROM owner_execution_journal) FROM runtime_database")
    testing.expect(t,rows[0][0]=="35" && rows[0][1]=="35" && rows[0][2]==before[0][0] && rows[0][3]==before[0][1] && rows[0][4]==before[0][2])
}
