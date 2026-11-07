#+feature dynamic-literals
package owner_local

import "core:fmt"
import "core:strings"
import "core:testing"

V23_TEST_DROP :: "DROP TABLE IF EXISTS owner_execution_stop_steps;" + #load("migration_025_test_drop.sql",string) + "DROP TABLE IF EXISTS owner_execution_bootstraps; DROP TABLE IF EXISTS owner_execution_queries; DROP TABLE IF EXISTS owner_execution_journal;" + #load("migration_023_test_drop.sql",string)
V10_TEST_DROP :: V23_TEST_DROP + "DROP TABLE IF EXISTS local_metadata_retirements; DROP TABLE IF EXISTS local_brief_inputs; DROP TABLE IF EXISTS local_coordinator_revocations; DROP TABLE IF EXISTS local_config_revocations; DROP TABLE IF EXISTS local_chain_directory_versions; DROP TABLE IF EXISTS local_chain_member_versions; DROP TABLE IF EXISTS local_member_chains; DROP TABLE IF EXISTS local_chain_defaults_versions; DROP TABLE IF EXISTS local_chain_summary_versions; DROP TRIGGER IF EXISTS native_history_origin; DROP TABLE IF EXISTS local_fleet_policy_sources; DROP TABLE IF EXISTS native_fleet_policies; DROP TABLE IF EXISTS native_fleet_snapshots; DROP TABLE IF EXISTS local_task_priority_versions; DROP TABLE IF EXISTS native_fact_chain; DROP TABLE IF EXISTS native_fact_task; DROP TABLE IF EXISTS native_fact_comment; DROP TABLE IF EXISTS native_fact_summary; DROP TABLE IF EXISTS native_fact_snapshots; DROP TABLE IF EXISTS native_metadata_members; DROP TABLE IF EXISTS native_metadata_directories; DROP TABLE IF EXISTS native_metadata_snapshots; DROP TABLE IF EXISTS native_metadata_origins; DROP VIEW IF EXISTS local_fleet_policy_current; DROP TABLE IF EXISTS local_fleet_policy_models; DROP TABLE IF EXISTS local_fleet_policy_roles; DROP TABLE IF EXISTS local_fleet_policy_versions; DROP TABLE IF EXISTS native_budget_overlap; DROP TABLE IF EXISTS budget_control_owners; DROP TABLE IF EXISTS local_dependency_retirements; DROP TABLE IF EXISTS local_budget_evidence; DROP TABLE IF EXISTS native_budget_baselines; DROP TRIGGER IF EXISTS deferred_prepared_merge_no_invalidation; DROP TABLE IF EXISTS deferred_workflow_dispositions; DROP TABLE IF EXISTS deferred_workflow_retirements; DROP TABLE IF EXISTS native_history_records; DROP TABLE IF EXISTS local_task_retirements; DROP TABLE IF EXISTS local_events; DROP TABLE IF EXISTS local_workflow_trigger_failures; DROP TABLE IF EXISTS local_workflow_coordinators; DROP TABLE IF EXISTS local_workflow_registry_envelopes; DROP TABLE IF EXISTS local_workflow_output_triggers; DROP TABLE IF EXISTS local_workflow_outputs; DROP TABLE IF EXISTS local_workflow_language_items; DROP TABLE IF EXISTS local_workflow_stage_expansions; DROP TABLE IF EXISTS local_workflow_language_executions; DROP TABLE IF EXISTS local_workflow_language_runs;"
V9_TEST_DROP :: "DROP TABLE IF EXISTS local_chain_context;" + V10_TEST_DROP + string(#load("migration_009_test_drop.sql"))
SEARCH_TEST_DROP :: V9_TEST_DROP + "DROP TABLE IF EXISTS local_grant_audit; DROP TABLE IF EXISTS local_grant_policy;" + `DROP INDEX IF EXISTS local_review_holder; DROP TRIGGER IF EXISTS search_local_handoffs_insert; DROP TABLE IF EXISTS local_checkpoints; DROP TABLE IF EXISTS local_work_attempts; DROP TABLE IF EXISTS local_assignment_history; DROP TABLE IF EXISTS intent_invalidations; DROP TABLE IF EXISTS control_notices; DROP TABLE IF EXISTS local_handoffs; DROP TABLE IF EXISTS local_controls; DROP TRIGGER IF EXISTS search_insert; DROP TRIGGER IF EXISTS search_delete; DROP TRIGGER IF EXISTS search_update; DROP TRIGGER IF EXISTS search_task_chains_insert; DROP TRIGGER IF EXISTS search_task_chains_update; DROP TRIGGER IF EXISTS search_task_chains_delete; DROP TRIGGER IF EXISTS search_tasks_insert; DROP TRIGGER IF EXISTS search_tasks_update; DROP TRIGGER IF EXISTS search_tasks_delete; DROP TRIGGER IF EXISTS search_task_comments_insert; DROP TRIGGER IF EXISTS search_task_comments_update; DROP TRIGGER IF EXISTS search_task_comments_delete; DROP TRIGGER IF EXISTS search_task_requirements_insert; DROP TRIGGER IF EXISTS search_task_requirements_update; DROP TRIGGER IF EXISTS search_task_requirements_delete; DROP TRIGGER IF EXISTS search_local_submissions_insert; DROP TRIGGER IF EXISTS search_local_submissions_update; DROP TRIGGER IF EXISTS search_local_submissions_delete; DROP TABLE IF EXISTS search_fts; DROP TABLE IF EXISTS search_docs; DROP TABLE IF EXISTS task_deletions;  DROP TRIGGER IF EXISTS task_no_resurrection; DROP TRIGGER IF EXISTS receipt_scope; CREATE TRIGGER receipt_scope BEFORE INSERT ON command_receipts
WHEN NOT EXISTS(SELECT 1 FROM task_chains WHERE chain_id=NEW.chain_id)
 OR (NEW.task_id!='' AND NOT EXISTS(SELECT 1 FROM tasks WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id))
 OR EXISTS(SELECT 1 FROM operation_tombstones WHERE principal_id=NEW.principal_id AND operation_id=NEW.operation_id)
BEGIN SELECT RAISE(ABORT,'receipt scope or retired operation'); END;
`

@(test)
additive_migration_preserves_v1_and_rolls_back_partial_ddl :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    close(&f.store)
    // Replace the empty V2 fixture with the exact V1 schema and representative
    // committed content, replay evidence and already-published outbox records.
    legacy:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&legacy),0)
    testing.expect(t,exec(legacy,`PRAGMA foreign_keys=OFF;`+SEARCH_TEST_DROP+`
      DROP TABLE local_merge_preparations; DROP TABLE local_reviews; DROP TABLE local_review_sessions; DROP TABLE local_submissions; DROP TABLE requirement_ack; DROP TABLE task_requirements; DROP TABLE lifecycle_state; DROP TABLE lifecycle_configs; DROP TABLE lease_receipt_pins; DROP TABLE local_leases; DROP TABLE local_fleet; DROP TABLE runtime_intents; DROP TABLE local_changes; DROP TABLE command_receipts;
      DROP TABLE operation_tombstones; DROP TABLE task_comments; DROP TABLE tasks;
      DROP TABLE local_grants; DROP TRIGGER genesis_immutable_delete; DROP TABLE chain_genesis;
      DROP TABLE task_chains; DROP TABLE runtime_database; DROP TABLE schema_migrations;`))
    testing.expect(t,exec(legacy,string(SCHEMA)))
    testing.expect(t,exec(legacy,`INSERT INTO runtime_database(singleton,account_id,owner_bridge_id,owner_key_id,incarnation,commit_seq) VALUES(1,'account','bridge','bridge_key',7,1);
      INSERT INTO task_chains VALUES('chain','device','device','old title','old description',1);
      INSERT INTO command_receipts VALUES('device','old_op','chain','','chain.create','digest','device',2000,'historical result',1);
      INSERT INTO runtime_intents VALUES('old_op','chain',1,'signed old payload',1);`))
    testing.expect_value(t,sqlite3_close(legacy),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,ok:=query(f.store.db,`SELECT (SELECT version FROM schema_migrations),incarnation,commit_seq,
      (SELECT title FROM task_chains),(SELECT result_json FROM command_receipts),
      (SELECT payload_json FROM runtime_intents),(SELECT state FROM runtime_intents),database_id FROM runtime_database`)
    if testing.expect(t,ok && len(rows)==1) {
        expected:=[7]string{"32","8","1","old title","historical result","signed old payload","settled"}
        for value,i in expected do testing.expect_value(t,rows[0][i],value)
        testing.expect_value(t,len(rows[0][7]),32)
    }
    count,retained:=compact_receipts(&f.store,RECEIPT_RETENTION_MS+1999)
    testing.expect(t,retained && count==0,"legacy receipt age is conservatively anchored to request expiry")
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"),"repeat migration is a no-op")
    close(&f.store)
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&legacy),0)
    testing.expect(t,exec(legacy,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=99"))
    testing.expect_value(t,sqlite3_close(legacy),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"),"unknown future schema fails closed")

    broken:=fixture(t);defer destroy(broken)
    close(&broken.store)
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(broken.path,context.temp_allocator),&legacy),0)
    // Force a V1 migration failure after several ALTERs. The transaction must
    // undo both DDL and the migration marker; subsequent repair can retry.
    testing.expect(t,exec(legacy,`PRAGMA foreign_keys=OFF;`+SEARCH_TEST_DROP+` DROP TABLE local_merge_preparations; DROP TABLE local_reviews; DROP TABLE local_review_sessions; DROP TABLE local_submissions; DROP TABLE requirement_ack; DROP TABLE task_requirements; DROP TABLE lifecycle_state; DROP TABLE lifecycle_configs; DROP TABLE lease_receipt_pins; DROP TABLE local_leases; DROP TABLE local_fleet; DROP TABLE runtime_intents; DROP TABLE local_changes;
      DROP TABLE command_receipts; DROP TABLE task_comments; DROP TABLE tasks; DROP TABLE local_grants;
      DROP TRIGGER genesis_immutable_delete; DROP TABLE chain_genesis; DROP TABLE task_chains;
      DROP TABLE runtime_database; DROP TABLE schema_migrations;`))
    testing.expect(t,exec(legacy,string(SCHEMA)))
    testing.expect(t,exec(legacy,"INSERT INTO runtime_database(singleton,account_id,owner_bridge_id,owner_key_id) VALUES(1,'account','bridge','bridge_key')"))
    testing.expect_value(t,sqlite3_close(legacy),0)
    testing.expect(t,!open(&broken.store,broken.path,"wrong_account","bridge","bridge_key"))
    testing.expect(t,!open(&broken.store,broken.path,"account","bridge","bridge_key"),"conflicting tombstone table aborts migration")
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(broken.path,context.temp_allocator),&legacy),0)
    columns,_:=query(legacy,"PRAGMA table_info(runtime_database)")
    testing.expect(t,len(columns)==9,"all added columns rolled back")
    markers,_:=query(legacy,"SELECT name FROM sqlite_master WHERE name='schema_migrations'")
    testing.expect(t,len(markers)==0,"migration marker also rolled back")
    testing.expect(t,exec(legacy,"DROP TRIGGER tombstone_no_delete; DROP TABLE operation_tombstones"))
    testing.expect_value(t,sqlite3_close(legacy),0)
    testing.expect(t,open(&broken.store,broken.path,"account","bridge","bridge_key"),"repair then retry succeeds")
}

@(test)
identity_revision_scope_and_incarnation_guards :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    for sql in ([8]string{
      "UPDATE runtime_database SET account_id='other'", "UPDATE runtime_database SET owner_bridge_id='other'",
      "UPDATE runtime_database SET database_id='other'", "UPDATE runtime_database SET commit_seq=0",
      "UPDATE task_chains SET title='unversioned'", "UPDATE tasks SET revision=revision+2",
      "UPDATE tasks SET chain_id='other',revision=revision+1", "UPDATE local_grants SET can_mutate=0",
    }) { testing.expectf(t,!exec(f.store.db,sql),"guard rejects %s",sql) }
    testing.expect(t,!exec(f.store.db,`INSERT INTO task_comments(chain_id,task_id,operation_id,principal_id,body,seq) VALUES('another_chain','task','cross','device','wrong',3)`),"composite task scope")
    testing.expect(t,!exec(f.store.db,`INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq)
       VALUES('device','cross','wrong','task','task.comment','x','device',1000,'x',3)`),"receipt same-chain scope")
    testing.expect(t,!exec(f.store.db,"DELETE FROM command_receipts"),"deduplication evidence cannot disappear")
    f.store.incarnation+=1
    tx:Transaction
    testing.expect(t,!transaction_begin(&f.store,&tx),"stale in-memory writer incarnation")
    f.store.incarnation-=1
    testing.expect(t,transaction_begin(&f.store,&tx))
    transaction_rollback(&tx)
}

@(test)
verified_directory_pins_and_historical_replay_are_independent :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"historical")}))
    c:=command(f,"task.comment","historical","task",p,"1")
    original:=invoke(f,c,p)
    testing.expect_value(t,original.code,"ok")
    testing.expect(t,observe_directory(&f.store,2,"new_head"))
    testing.expect(t,!observe_directory(&f.store,1,"head"),"old directory cannot undo observed revocation")
    testing.expect(t,!observe_directory(&f.store,2,"fork_head"),"same-version equivocation")
    before,_:=query(f.store.db,"SELECT total_changes()")
    replay:=execute(&f.store,c,p,f.genesis,f.creator,f.owner,2,"new_head",3000,&f.kr,Signer{&f.owner_priv,test_sign})
    after,_:=query(f.store.db,"SELECT total_changes()")
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==original.body)
    testing.expect(t,after[0][0]==before[0][0],"replay writes no rows")
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",3000,&f.kr,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
    wrong:=f.owner;wrong.account_id="another_account"
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,wrong,2,"new_head",3000,&f.kr,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
}

@(test)
nested_candidate_rollback_drops_state_receipt_change_and_intent :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    outer,child:Transaction
    testing.expect(t,transaction_begin(&f.store,&outer))
    another:Transaction
    testing.expect(t,!transaction_begin(&f.store,&another),"nested begin fails instead of deadlocking; use savepoint")
    testing.expect(t,transaction_savepoint(&outer,&child))
    testing.expect(t,!transaction_savepoint(&child,&outer),"active ancestor handle cannot be overwritten")
    testing.expect(t,exec(f.store.db,`INSERT INTO task_comments(chain_id,task_id,operation_id,principal_id,body,seq) VALUES('chain','task','candidate','device','candidate',3);
      INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq)
       VALUES('device','candidate','chain','task','task.comment','x','device',2000,'result',3);
      INSERT INTO local_changes VALUES(3,'chain','task.comment','task',2,'candidate');`))
    testing.expect(t,intent_enqueue(&child,Intent_Input{"chain","device","candidate",3,"test","target","{}","effect"}))
    transaction_rollback(&child)
    testing.expect(t,!transaction_commit(&child),"closed candidate cannot commit")
    testing.expect(t,transaction_commit(&outer))
    rows,_:=query(f.store.db,`SELECT (SELECT count(*) FROM task_comments),
      (SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_changes),(SELECT count(*) FROM runtime_intents)`)
    expected:=[4]string{"0","2","2","2"}
    for value,i in expected do testing.expect_value(t,rows[0][i],value)
    // A released candidate is still subject to rollback of its outer parent.
    testing.expect(t,transaction_begin(&f.store,&outer))
    testing.expect(t,transaction_savepoint(&outer,&child))
    testing.expect(t,exec(f.store.db,"UPDATE tasks SET revision=revision+1 WHERE task_id='task'"))
    testing.expect(t,transaction_commit(&child))
    transaction_rollback(&outer)
    rows,_=query(f.store.db,"SELECT revision FROM tasks")
    testing.expect_value(t,rows[0][0],"1")
}

@(test)
real_commit_failure_and_sqlite_full_never_report_success :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect(t,exec(f.store.db,`CREATE TABLE failure_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE failure_child(id INTEGER REFERENCES failure_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER fail_commit AFTER INSERT ON command_receipts BEGIN INSERT INTO failure_child VALUES(99); END;`))
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"commit failure")}))
    c:=command(f,"task.comment","commit_failure","task",p,"1")
    testing.expect(t,invoke(f,c,p).code=="storage_error","deferred foreign key fails at COMMIT")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM task_comments),(SELECT count(*) FROM command_receipts),commit_seq FROM runtime_database")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="2" && rows[0][2]=="2","failed COMMIT rolled back everything")
    testing.expect_value(t,len(search_hits(search_for(f,"failure"))),0)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_commit"))
    testing.expect(t,invoke(f,c,p).code=="ok","next transaction remains usable")
    testing.expect_value(t,len(search_hits(search_for(f,"failure"))),1)
    testing.expect(t,exec(f.store.db,"CREATE TABLE failure_pages(body BLOB)"))
    pages,_:=query(f.store.db,"PRAGMA page_count")
    testing.expect(t,exec(f.store.db,fmt.tprintf("PRAGMA max_page_count=%d",number(pages[0][0])+4)))
    testing.expect(t,exec(f.store.db,`CREATE TRIGGER disk_full AFTER INSERT ON command_receipts
      BEGIN INSERT INTO failure_pages VALUES(zeroblob(8388608)); END;`))
    c=command(f,"task.comment","disk_full","task",p,"2")
    testing.expect(t,invoke(f,c,p).code=="storage_error","real SQLITE_FULL during mutation")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM task_comments),(SELECT count(*) FROM command_receipts),commit_seq FROM runtime_database")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="3" && rows[0][2]=="3","disk full left no phantom comment or receipt")
    testing.expect_value(t,len(search_hits(search_for(f,"failure"))),1)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER disk_full; PRAGMA max_page_count=1073741823"))
    testing.expect_value(t,invoke(f,c,p).code,"ok")
    pages,_=query(f.store.db,"PRAGMA page_count")
    testing.expect(t,exec(f.store.db,fmt.tprintf("PRAGMA max_page_count=%d",number(pages[0][0])+4)))
    testing.expect(t,exec(f.store.db,`CREATE TRIGGER first_write_full BEFORE INSERT ON task_comments
      BEGIN INSERT INTO failure_pages VALUES(zeroblob(8388608)); END;`))
    c=command(f,"task.comment","first_write_full","task",p,"3")
    testing.expect(t,invoke(f,c,p).code=="storage_error","first-write disk failure is not an operation conflict")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER first_write_full; PRAGMA max_page_count=1073741823"))
    testing.expect_value(t,invoke(f,c,p).code,"ok")
}

@(test)
outbox_enqueue_failure_and_claim_commit_failure_are_atomic :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fail_intent BEFORE INSERT ON runtime_intents BEGIN SELECT RAISE(ABORT,'intent storage failure'); END"))
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"new task"),"body_cipher"=cipher(f,"new body")}))
    c:=command(f,"task.create","new_task","new_task",p,"2")
    testing.expect_value(t,invoke(f,c,p).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM tasks),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_changes),(SELECT count(*) FROM runtime_intents),commit_seq FROM runtime_database")
    expected:=[5]string{"1","2","2","2","2"}
    for value,i in expected do testing.expect_value(t,rows[0][i],value)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_intent"))
    testing.expect_value(t,invoke(f,c,p).code,"ok")
    testing.expect(t,exec(f.store.db,`CREATE TABLE claim_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE claim_child(id INTEGER REFERENCES claim_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER fail_claim AFTER UPDATE OF state ON runtime_intents WHEN NEW.state='claimed'
       BEGIN INSERT INTO claim_child VALUES(99); END;`))
    claims,ok:=intent_claim_due(&f.store,1000)
    testing.expect(t,!ok && len(claims)==0,"failed claim COMMIT returns no executable work")
    rows,_=query(f.store.db,"SELECT state,attempts FROM runtime_intents")
    for row in rows do testing.expect(t,row[0]=="pending" && row[1]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_claim"))
    claims,ok=intent_claim_due(&f.store,1000)
    testing.expect(t,ok && len(claims)==3)
}

@(test)
outbox_claim_retry_restart_and_obsolete_results :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    claims,ok:=intent_claim_due(&f.store,1000)
    if !testing.expect(t,ok && len(claims)==2) do return
    first:=claims[0];second:=claims[1]
    more,more_ok:=intent_claim_due(&f.store,1000)
    testing.expect(t,more_ok && len(more)==0,"one in-flight claimant per effect")
    testing.expect(t,intent_result(&f.store,first,false,"unknown outcome",1000))
    early,early_ok:=intent_claim_due(&f.store,1999)
    testing.expect(t,early_ok && len(early)==0,"durable retry floor")
    retried,retry_ok:=intent_claim_due(&f.store,2000)
    if !testing.expect(t,retry_ok && len(retried)==1) do return
    retry:=retried[0]
    testing.expect(t,retry.id==first.id && retry.payload==first.payload && retry.digest==first.digest && retry.attempt==2)
    testing.expect(t,!intent_result(&f.store,first,true,"stale response",2000))
    testing.expect(t,intent_result(&f.store,retry,true,"published",2000))
    testing.expect(t,!intent_result(&f.store,retry,true,"duplicate callback",2000))
    old_incarnation:=f.store.incarnation
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,f.store.incarnation==old_incarnation+1)
    testing.expect(t,!intent_result(&f.store,second,true,"old process result",2000))
    recovered,recovered_ok:=intent_claim_due(&f.store,2000)
    if !testing.expect(t,recovered_ok && len(recovered)==1) do return
    testing.expect(t,recovered[0].id==second.id && recovered[0].payload==second.payload && recovered[0].attempt==2)
    testing.expect(t,intent_result(&f.store,recovered[0],true,"published after reconciliation",2000))
    rows,_:=query(f.store.db,"SELECT count(*) FROM runtime_intents WHERE state='settled'")
    testing.expect_value(t,rows[0][0],"2")
}

@(test)
retained_delivery_results_recover_write_and_commit_failures_without_reopen :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    for commit_failure in ([2]bool{false,true}) {
        f:=fixture(t);defer destroy(f);seed(t,f)
        q:Intent_Completions
        defer intent_completions_destroy(&q)
        incarnation:=f.store.incarnation
        claims,ok:=intent_claim_due(&f.store,1000,1)
        if !testing.expect(t,ok && len(claims)==1) do continue
        first:=claims[0]
        // Simulate an HTTP503 outcome; the queue must own its strings beyond
        // the request that performed the I/O, including a failed result COMMIT.
        testing.expect(t,intent_completion_keep(&q,first,false,"503",1000))
        if commit_failure {
            testing.expect(t,exec(f.store.db,`CREATE TABLE result_parent(id INTEGER PRIMARY KEY);
              CREATE TABLE result_child(id INTEGER REFERENCES result_parent(id) DEFERRABLE INITIALLY DEFERRED);
              CREATE TRIGGER fail_result AFTER UPDATE OF state ON runtime_intents WHEN OLD.state='claimed' AND NEW.state='pending'
              BEGIN INSERT INTO result_child VALUES(99); END;`))
        } else {
            testing.expect(t,exec(f.store.db,`CREATE TRIGGER fail_result BEFORE UPDATE OF state ON runtime_intents
              WHEN OLD.state='claimed' AND NEW.state='pending' BEGIN SELECT RAISE(ABORT,'temporary storage error'); END;`))
        }
        testing.expect(t,!intent_completions_flush(&f.store,&q))
        testing.expect_value(t,q.count,1)
        current,read:=intent_claim_current(&f.store,first)
        testing.expect(t,read && current,"failed result persistence retains the same claimed row")
        testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_result"))
        testing.expect(t,intent_completions_flush(&f.store,&q),"storage recovers without Store.open")
        testing.expect_value(t,q.count,0)
        claims,ok=intent_claim_due(&f.store,2000)
        testing.expect(t,ok && len(claims)==2)
        deliveries:=0
        for claim in claims {
            // Eventual successful publication uses the same effect ID/digest.
            if claim.id==first.id {
                deliveries+=1
                testing.expect(t,claim.attempt==2 && claim.digest==first.digest && claim.payload==first.payload)
            }
            testing.expect(t,intent_completion_keep(&q,claim,true,"200",2000))
        }
        testing.expect(t,intent_completions_flush(&f.store,&q))
        testing.expect_value(t,deliveries,1)
        testing.expect_value(t,f.store.incarnation,incarnation)
        rows,_:=query(f.store.db,"SELECT count(*) FROM runtime_intents WHERE state='settled'")
        testing.expect_value(t,rows[0][0],"2")
        testing.expect_value(t,q.count,0)
    }
}

@(test)
retained_success_results_and_stale_completions_do_not_redeliver :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    q:Intent_Completions;defer intent_completions_destroy(&q)
    claims,ok:=intent_claim_due(&f.store,1000,1)
    if !testing.expect(t,ok && len(claims)==1) do return
    claim:=claims[0]
    testing.expect(t,intent_completion_keep(&q,claim,true,"200",1000))
    testing.expect(t,exec(f.store.db,`CREATE TRIGGER fail_settle BEFORE UPDATE OF state ON runtime_intents
      WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'temporary storage error'); END;`))
    testing.expect(t,!intent_completions_flush(&f.store,&q))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_settle"))
    testing.expect(t,intent_completions_flush(&f.store,&q))
    current,read:=intent_claim_current(&f.store,claim)
    testing.expect(t,read && !current)
    // A delayed duplicate completion is safely discarded after checking the
    // durable claim, rather than overwriting an immutable successful result.
    testing.expect(t,intent_completion_keep(&q,claim,false,"stale503",1000))
    testing.expect(t,intent_completions_flush(&f.store,&q))
    rows,_:=query(f.store.db,"SELECT state,result_json FROM runtime_intents WHERE intent_id=?",claim.id)
    testing.expect(t,rows[0][0]=="settled" && rows[0][1]=="200")
    more,more_ok:=intent_claim_due(&f.store,1000000)
    testing.expect(t,more_ok && len(more)==1 && more[0].id!=claim.id,"settled effect never redelivers")
}

@(test)
tombstones_expired_misses_and_read_revocation :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"retained result")}))
    c:=command(f,"task.comment","old_comment","task",p,"1")
    result:=invoke(f,c,p)
    testing.expect_value(t,result.code,"ok")
    // Receipt retention exceeds the original bounded grant. Renew explicitly;
    // this test isolates receipt/tombstone behavior from authorization expiry.
    renewal:=encode(doc(map[string]string{"principal_id"="device","key_id"="device","expires_ms"=fmt.tprintf("%d",2001+GRANT_MAX_TTL_MS),"can_read"="1","can_mutate"="1"}))
    renewal_command:=command(f,"grant.set","renew_before_retention","",renewal,"3",4000)
    testing.expect_value(t,execute(&f.store,renewal_command,renewal,f.genesis,f.creator,f.owner,1,"head",2001,&f.kr,Signer{&f.owner_priv,test_sign},grant_proof=Grant_Proof{target=f.creator}).code,"ok")
    late:=RECEIPT_RETENTION_MS+2000
    n,ok:=compact_receipts(&f.store,late)
    testing.expect(t,ok && n==1,"pending registry effects pin their full receipts")
    testing.expect_value(t,invoke(f,c,p,late).code,"retired")
    changed:=command(f,"task.comment","old_comment","task",p,"0",late+1000)
    testing.expect_value(t,invoke(f,changed,p,late).code,"operation_conflict")
    miss:=command(f,"task.comment","expired_miss","task",p,"2")
    testing.expect_value(t,invoke(f,miss,p,late).code,"expired")
    testing.expect(t,exec(f.store.db,"UPDATE local_grants SET can_read=0,revision=revision+1"))
    testing.expect(t,invoke(f,c,p,late).code=="invalid_scope","even tombstone identity is read-authorized")
    testing.expect(t,exec(f.store.db,"UPDATE local_grants SET can_read=1,revision=revision+1"))
    claims,claimed:=intent_claim_due(&f.store,late)
    testing.expect(t,claimed && len(claims)==2)
    for claim in claims do testing.expect(t,intent_result(&f.store,claim,true,"done",late))
    n,ok=compact_receipts(&f.store,late)
    testing.expect(t,ok && n==2)
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM command_receipts),(SELECT count(*) FROM operation_tombstones),(SELECT count(*) FROM task_comments)")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="3" && rows[0][2]=="1")
}

@(test)
backward_clock_latches_until_generation_checked_reconciliation :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"timed mutation")}))
    c:=command(f,"task.comment","clock","task",p,"1")
    testing.expect_value(t,invoke(f,c,p,999).code,"clock_uncertain")
    testing.expect(t,invoke(f,c,p,1001).code=="clock_uncertain","catching up alone cannot clear uncertainty")
    testing.expect(t,!reconcile_clock(&f.store,f.store.incarnation,1,999))
    testing.expect(t,!reconcile_clock(&f.store,f.store.incarnation,2,1001))
    testing.expect(t,reconcile_clock(&f.store,f.store.incarnation,1,1001))
    testing.expect(t,!reconcile_clock(&f.store,f.store.incarnation,1,1001),"generation CAS")
    first:=invoke(f,c,p,1001)
    testing.expect_value(t,first.code,"ok")
    // Replay is independent of the mutation clock and never creates effects.
    replay:=invoke(f,c,p,999)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
}

@(test)
retention_quota_counts_tombstones_and_keeps_historical_replay :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect(t,exec(f.store.db,`WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<99998)
      INSERT INTO operation_tombstones SELECT 'device','retired_'||i,'chain','','chain.read','digest','device',2000,1 FROM n`))
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"at capacity")}))
    testing.expect_value(t,invoke(f,command(f,"task.comment","capacity","task",p,"1"),p).code,"retention_capacity")
    rows,_:=query(f.store.db,"SELECT count(*) FROM task_comments")
    testing.expect_value(t,rows[0][0],"0")
    // The existing create result remains available despite full retention.
    p=encode(doc(map[string]string{"operation_id"="task"}))
    testing.expect_value(t,invoke(f,command(f,"receipt.read","receipt_at_capacity","",p,"0"),p).code,"ok")
}

@(test)
v2_runtime_identity_upgrade_is_atomic_and_preserves_clocks_and_intents :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    close(&f.store)
    legacy:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&legacy),0)
    testing.expect(t,exec(legacy,`PRAGMA foreign_keys=OFF;`+SEARCH_TEST_DROP+`
      DROP TABLE local_merge_preparations; DROP TABLE local_reviews; DROP TABLE local_review_sessions; DROP TABLE local_submissions; DROP TABLE requirement_ack; DROP TABLE task_requirements; DROP TABLE lifecycle_state; DROP TABLE lifecycle_configs; DROP TABLE lease_receipt_pins; DROP TABLE local_leases; DROP TABLE local_fleet;
      DROP TABLE runtime_intents; DROP TABLE local_changes; DROP TABLE command_receipts;
      DROP TABLE operation_tombstones; DROP TABLE task_comments; DROP TABLE tasks;
      DROP TABLE local_grants; DROP TRIGGER genesis_immutable_delete; DROP TABLE chain_genesis;
      DROP TABLE task_chains; DROP TABLE runtime_database; DROP TABLE schema_migrations;`))
    testing.expect(t,exec(legacy,string(SCHEMA)))
    testing.expect(t,exec(legacy,string(MIGRATION_002)))
    testing.expect(t,exec(legacy,INTENT_IDENTITY_TRIGGER))
    testing.expect(t,exec(legacy,`CREATE TABLE schema_migrations(singleton INTEGER PRIMARY KEY,version INTEGER NOT NULL);
      INSERT INTO schema_migrations VALUES(1,2);
      INSERT INTO runtime_database(singleton,account_id,owner_bridge_id,owner_key_id,incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id)
       VALUES(1,'account','bridge','bridge_key',7,5,4000,2,'head','stable_database');
      INSERT INTO task_chains VALUES('chain','device','device','preserved title','preserved description',1);
      INSERT INTO tasks VALUES('chain','task','preserved task','preserved body',1);
      INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq)
       VALUES('device','old_operation','chain','','chain.create','digest','device',2000,'original receipt',5);
      INSERT INTO runtime_intents(intent_id,chain_id,commit_seq,payload_json,principal_id,operation_id,state,attempts,claim_incarnation)
       VALUES('old_intent','chain',5,'original signed intent','device','old_operation','claimed',1,7);
      CREATE VIEW local_fleet AS SELECT 1;`))
    testing.expect_value(t,sqlite3_close(legacy),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"),"collision rolls back runtime table rebuild too")
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&legacy),0)
    rows,ok:=query(legacy,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id,incarnation,commit_seq,clock_high_ms,directory_version,directory_hash FROM runtime_database")
    testing.expect(t,ok && len(rows)==1 && rows[0][0]=="2" && rows[0][1]=="2" && rows[0][2]=="stable_database")
    testing.expect(t,exec(legacy,"DROP VIEW local_fleet"))
    testing.expect_value(t,sqlite3_close(legacy),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,ok=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id,incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,(SELECT body FROM tasks),(SELECT payload_json FROM runtime_intents),(SELECT state FROM runtime_intents),(SELECT attempts FROM runtime_intents),(SELECT claim_incarnation FROM runtime_intents) FROM runtime_database")
    expected:=[13]string{"32","32","stable_database","8","5","4000","2","head","preserved body","original signed intent","pending","1","0"}
    if testing.expect(t,ok && len(rows)==1) do for value,i in expected do testing.expect_value(t,rows[0][i],value)
    testing.expect(t,!exec(f.store.db,"UPDATE runtime_database SET account_id='other'"),"rebuilt identity guard remains active")
    testing.expect(t,!exec(f.store.db,"UPDATE runtime_database SET commit_seq=0"),"rebuilt monotonic guard remains active")
}

@(test)
v3_lifecycle_migration_preserves_live_fences_and_rolls_back_collision :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    raw:=lease_request(f,child,"lease.claim","claim","lease","")
    first:=lease_invoke(f,raw,"",child)
    if !testing.expect_value(t,first.code,"ok") do return
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,`PRAGMA foreign_keys=OFF;`+SEARCH_TEST_DROP+`
      DROP TABLE local_merge_preparations; DROP TABLE local_reviews; DROP TABLE local_review_sessions;
      DROP TABLE local_submissions; DROP TABLE requirement_ack; DROP TABLE task_requirements;
      DROP TABLE lifecycle_state; DROP TABLE lifecycle_configs;`))
    text:=string(MIGRATION_004)
    prefix:=text[:strings.index(text,"CREATE TABLE lifecycle_configs")]
    v3,_:=strings.replace_all(prefix,"DEFAULT 4 CHECK(schema_version=4)","DEFAULT 3 CHECK(schema_version=3)",context.temp_allocator)
    v3,_=strings.replace_all(v3,"database_id,4,","database_id,3,",context.temp_allocator)
    testing.expect(t,exec(db,v3))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=3; CREATE VIEW lifecycle_configs AS SELECT 1;"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"),"collision rolls back all migration4 DDL and header changes")
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,ok:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL) FROM runtime_database")
    testing.expect(t,ok && rows[0][0]=="3" && rows[0][1]=="3" && rows[0][2]=="1")
    testing.expect(t,exec(db,"DROP VIEW lifecycle_configs"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    replay:=lease_invoke(f,raw,"",child,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body,"migration preserves exact signed capability and historical receipt")
    rows,ok=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,ok && rows[0][0]=="32" && rows[0][1]=="32")
}
