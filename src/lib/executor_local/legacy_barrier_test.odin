package executor_local

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:strings"
import "core:os"
import "core:testing"

legacy_test_barrier :: proc()->Legacy_Barrier {return {"chain","migration",strings.repeat("a",64,context.temp_allocator),1}}
legacy_test_digest :: proc()->string {return strings.repeat("b",64,context.temp_allocator)}

@(test)
executor_legacy_barrier_blocks_late_commands_but_retains_exact_prior_invocation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    b:=legacy_test_barrier();digest:=legacy_test_digest()
    c,r:=legacy_command_admit(&f.store,"chain","before",digest)
    testing.expect_value(t,r.code,"admitted")
    testing.expect_value(t,legacy_barrier_install(&f.store,b).code,"ok")
    testing.expect(t,legacy_barrier_install(&f.store,b).replay)
    _,r=legacy_command_admit(&f.store,"chain","late",digest);testing.expect_value(t,r.code,"legacy_fenced")
    _,r=legacy_command_admit(&f.store,"chain","before",digest);testing.expect(t,r.code=="running" && r.replay)
    _,r=legacy_command_admit(&f.store,"different","before",digest);testing.expect_value(t,r.code,"command_conflict")
    _,r=legacy_command_admit(&f.store,"chain","before",strings.repeat("c",64,context.temp_allocator));testing.expect_value(t,r.code,"command_conflict")
    status,ok:=legacy_barrier_status(&f.store,"chain")
    testing.expect(t,ok && status.running==1 && status.returned==0)
    changed:=c;changed.input_digest=strings.repeat("c",64,context.temp_allocator)
    testing.expect(t,!legacy_command_returned(&f.store,changed))
    testing.expect(t,legacy_command_returned(&f.store,c))
    testing.expect(t,legacy_command_returned(&f.store,c))
    status,ok=legacy_barrier_status(&f.store,"chain")
    testing.expect(t,ok && status.running==0 && status.returned==1)
    _,r=legacy_command_admit(&f.store,"chain","before",digest);testing.expect(t,r.code=="returned" && r.replay)
    _,r=legacy_command_admit(&f.store,"unrelated","new",digest);testing.expect_value(t,r.code,"admitted")
    changed_barrier:=b;changed_barrier.source_generation=2
    testing.expect_value(t,legacy_barrier_install(&f.store,changed_barrier).code,"barrier_conflict")
    changed_barrier=b;changed_barrier.selection_digest=strings.repeat("c",64,context.temp_allocator)
    testing.expect_value(t,legacy_barrier_install(&f.store,changed_barrier).code,"barrier_conflict")
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_barriers"))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_barriers SET source_generation=2"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_commands"))
}

@(test)
executor_legacy_barrier_restart_retains_ambiguous_dispatch_and_never_reissues :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    c,r:=legacy_command_admit(&f.store,"chain","ambiguous",legacy_test_digest())
    testing.expect_value(t,r.code,"admitted")
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier()).code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,!legacy_command_returned(&f.store,c),"old process cannot finish after restart")
    status,ok:=legacy_barrier_status(&f.store,"chain")
    testing.expect(t,ok && status.running==1 && status.installed_incarnation==1)
    _,r=legacy_command_admit(&f.store,"chain","ambiguous",legacy_test_digest())
    testing.expect(t,r.replay && r.code=="running")
    _,r=legacy_command_admit(&f.store,"chain","new",legacy_test_digest());testing.expect_value(t,r.code,"legacy_fenced")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_commands SET state='returned'"))
}

@(test)
executor_legacy_barrier_storage_failure_and_direct_sql_backstops :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    testing.expect(t,exec(f.store.db,`CREATE TRIGGER reject_legacy_barrier BEFORE INSERT ON executor_legacy_barriers BEGIN SELECT RAISE(ABORT,'injected'); END;`))
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier()).code,"storage_error")
    _,ok:=legacy_barrier_status(&f.store,"chain");testing.expect(t,!ok)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER reject_legacy_barrier"))
    testing.expect(t,exec(f.store.db,`CREATE TRIGGER reject_legacy_command BEFORE INSERT ON executor_legacy_commands BEGIN SELECT RAISE(ABORT,'injected'); END;`))
    _,r:=legacy_command_admit(&f.store,"chain","failed",legacy_test_digest());testing.expect_value(t,r.code,"storage_error")
    rows,read:=query(f.store.db,"SELECT count(*) FROM executor_legacy_commands");testing.expect(t,read && rows[0][0]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER reject_legacy_command"))
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier()).code,"ok")
    _,written:=query(f.store.db,"INSERT INTO executor_legacy_commands VALUES('bypass','chain',?,1,'running')",legacy_test_digest())
    testing.expect(t,!written,"direct insert is fenced")
    s:=legacy_test_barrier();s.source_generation= -1
    testing.expect_value(t,legacy_barrier_install(&f.store,s).code,"invalid_scope")
}

@(test)
executor_legacy_barrier_admission_and_install_race_is_serialized :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for i in 0..<8 {
        f:=fixture(t)
        start:sync.Barrier;sync.barrier_init(&start,3)
        Job :: struct {f:^Fixture,start:^sync.Barrier,install:bool,code:string}
        jobs:=[2]Job{{f,&start,true,""},{f,&start,false,""}}
        workers:[2]^thread.Thread
        for j in 0..<2 {
            workers[j]=thread.create_and_start_with_data(&jobs[j],proc(data:rawptr) {
                context.allocator=context.temp_allocator
                job:=(^Job)(data);sync.barrier_wait(job.start)
                result:Result
                if job.install {result=legacy_barrier_install(&job.f.store,legacy_test_barrier())}
                else {_,result=legacy_command_admit(&job.f.store,"chain","raced",legacy_test_digest())}
                job.code=strings.clone(result.code,runtime.default_allocator())
            })
        }
        sync.barrier_wait(&start)
        for worker in workers {thread.join(worker);thread.destroy(worker)}
        testing.expect_value(t,jobs[0].code,"ok")
        status,ok:=legacy_barrier_status(&f.store,"chain")
        testing.expect(t,ok)
        if jobs[1].code=="admitted" {testing.expect_value(t,status.running,i64(1))}
        else {testing.expect_value(t,jobs[1].code,"legacy_fenced");testing.expect_value(t,status.running,i64(0))}
        for job in jobs do delete(job.code,runtime.default_allocator())
        destroy(f)
    }
}

@(test)
executor_legacy_barrier_and_command_commit_failures_grant_no_dispatch :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    testing.expect(t,exec(f.store.db,"CREATE TABLE legacy_commit_parent(id INTEGER PRIMARY KEY); CREATE TABLE legacy_commit_fault(id INTEGER REFERENCES legacy_commit_parent(id) DEFERRABLE INITIALLY DEFERRED);"))
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER legacy_commit_barrier AFTER INSERT ON executor_legacy_barriers BEGIN INSERT INTO legacy_commit_fault VALUES(1); END;"))
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier()).code,"storage_error")
    _,found:=legacy_barrier_status(&f.store,"chain");testing.expect(t,!found)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER legacy_commit_barrier; CREATE TRIGGER legacy_commit_command AFTER INSERT ON executor_legacy_commands BEGIN INSERT INTO legacy_commit_fault VALUES(1); END;"))
    _,result:=legacy_command_admit(&f.store,"chain","failed",legacy_test_digest())
    testing.expect_value(t,result.code,"storage_error")
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_legacy_commands),(SELECT count(*) FROM legacy_commit_fault)")
    testing.expect(t,ok && rows[0][0]=="0" && rows[0][1]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER legacy_commit_command"))
    command,admitted:=legacy_command_admit(&f.store,"chain","failed",legacy_test_digest())
    testing.expect_value(t,admitted.code,"admitted")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER legacy_commit_return AFTER UPDATE ON executor_legacy_commands BEGIN INSERT INTO legacy_commit_fault VALUES(1); END;"))
    testing.expect(t,!legacy_command_returned(&f.store,command))
    rows,ok=query(f.store.db,"SELECT state FROM executor_legacy_commands WHERE command_id='failed'")
    testing.expect(t,ok && rows[0][0]=="running")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER legacy_commit_return"))
    testing.expect(t,legacy_command_returned(&f.store,command))
}

// Reconstruct the genuine effective v8 schema without v9 tables/triggers. A
// retained exact prepared reservation survives collision, failed commit and retry.
@(test)
executor_legacy_v8_migration_collision_and_commit_failure_are_atomic :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    original,_:=query(f.store.db,"SELECT document,launch_key FROM executor_reservations")
    legacy_remove_v11_journal_fixture(t,&f.store)
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_commands; DROP TABLE executor_legacy_resources; DROP TABLE executor_legacy_barriers; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v9_fixture;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=11","schema_version=8",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,8,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v9_fixture; DROP TABLE runtime_v9_fixture; CREATE VIEW executor_legacy_commands AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,ok:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT count(*) FROM sqlite_master WHERE name='executor_legacy_barriers'),(SELECT document FROM executor_reservations),(SELECT launch_key FROM executor_reservations) FROM executor_runtime")
    testing.expect(t,ok && rows[0][0]=="8" && rows[0][1]=="1" && rows[0][2]=="0" && rows[0][3]==original[0][0] && rows[0][4]==original[0][1])
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_legacy_commands; CREATE TABLE legacy_migration_parent(id INTEGER PRIMARY KEY); CREATE TABLE legacy_migration_fault(id INTEGER REFERENCES legacy_migration_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER legacy_migration_commit AFTER UPDATE ON executor_reservations WHEN NEW.state='released' BEGIN INSERT INTO legacy_migration_fault VALUES(1); END;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,ok=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM sqlite_master WHERE name='executor_legacy_barriers') FROM executor_runtime")
    testing.expect(t,ok && rows[0][0]=="8" && rows[0][1]=="1" && rows[0][2]=="prepared" && rows[0][3]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER legacy_migration_commit"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,ok=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT launch_key FROM executor_reservations) FROM executor_runtime")
    testing.expect(t,ok && rows[0][0]=="11" && rows[0][1]=="2" && rows[0][2]=="released" && rows[0][3]==original[0][1])
    // Rebuilt retained triggers bind the new runtime, not the dropped alias.
    refs,read:=query(f.store.db,"SELECT name FROM sqlite_master WHERE sql LIKE '%executor_runtime_v8%'")
    testing.expect(t,read && len(refs)==0)
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier()).code,"ok")
}

@(test)
executor_legacy_resource_fences_bind_targets_across_claimed_chain_and_exact_replay :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    b:=legacy_test_barrier()
    targets:=[3]Legacy_Resource{{"instance","instance"},{"task","task"},{"workdir_hash",legacy_test_digest()}}
    testing.expect_value(t,legacy_barrier_install(&f.store,b,targets[:]).code,"ok")
    reversed:=[3]Legacy_Resource{targets[2],targets[0],targets[1]}
    testing.expect(t,legacy_barrier_install(&f.store,b,reversed[:]).replay,"resource inventory order is not identity")
    testing.expect_value(t,legacy_barrier_install(&f.store,b).code,"barrier_conflict")
    changed:=targets;changed[0].id="different"
    testing.expect_value(t,legacy_barrier_install(&f.store,b,changed[:]).code,"barrier_conflict")
    for target in targets {
        _,result:=legacy_command_admit(&f.store,"claimed_other_chain",target.id,legacy_test_digest(),[]Legacy_Resource{target})
        testing.expect_value(t,result.code,"legacy_fenced")
    }
    _,result:=legacy_command_admit(&f.store,"unrelated_chain","unrelated",legacy_test_digest(),[]Legacy_Resource{{"instance","unrelated"}})
    testing.expect_value(t,result.code,"admitted")
    duplicate:=[2]Legacy_Resource{targets[0],targets[0]}
    b.chain="next"
    testing.expect_value(t,legacy_barrier_install(&f.store,b,duplicate[:]).code,"invalid_scope")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_resources SET resource_id='changed'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_resources"))
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER reject_legacy_resource BEFORE INSERT ON executor_legacy_resources BEGIN SELECT RAISE(ABORT,'injected'); END;"))
    testing.expect_value(t,legacy_barrier_install(&f.store,b,targets[:]).code,"storage_error")
    _,found:=legacy_barrier_status(&f.store,"next");testing.expect(t,!found,"barrier and complete inventory commit together")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER reject_legacy_resource"))
    testing.expect_value(t,legacy_barrier_install(&f.store,b,targets[:]).code,"ok")
}

@(test)
executor_legacy_zero_generation_preserves_unknown_execution :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    _,r:=legacy_command_admit(&f.store,"chain","preupgrade_unknown",legacy_test_digest())
    testing.expect_value(t,r.code,"admitted")
    b:=legacy_test_barrier();b.source_generation=0
    targets:=[]Legacy_Resource{{"instance","unknown_instance"}}
    testing.expect_value(t,legacy_barrier_install(&f.store,b,targets).code,"ok")
    testing.expect(t,legacy_barrier_install(&f.store,b,targets).replay)
    status,found:=legacy_barrier_status(&f.store,"chain")
    testing.expect(t,found && status.barrier.source_generation==0 && status.running==1,"generation zero does not imply empty history or drain")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    status,found=legacy_barrier_status(&f.store,"chain")
    testing.expect(t,found && status.barrier.source_generation==0 && status.running==1)
    _,r=legacy_command_admit(&f.store,"alias","late",legacy_test_digest(),targets)
    testing.expect_value(t,r.code,"legacy_fenced")
}

@(test)
executor_legacy_v9_zero_migration_retains_barriers_and_rolls_back :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    close(&f.store)
    for suffix in ([3]string{"","-wal","-shm"}) do _=os.remove(strings.concatenate({f.path,suffix},context.temp_allocator))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    current_schema:=string(#load("schema.sql"))
    schema,_:=strings.replace_all(current_schema[:strings.index(current_schema,"-- Native observation only.")],"schema_version=11","schema_version=9",context.temp_allocator)
    historical,_:=strings.replace_all(schema,"source_generation>=0","source_generation>0",context.temp_allocator)
    testing.expect(t,exec(f.store.db,historical))
    testing.expect(t,exec(f.store.db,"PRAGMA foreign_keys=ON; INSERT INTO executor_runtime VALUES(1,9,'account','executor','operator',1,0,'ready',0,0);"))
    f.store.account=strings.clone("account");f.store.executor=strings.clone("executor");f.store.operator_key=strings.clone("operator");f.store.incarnation=1
    policy(t,f)
    testing.expect_value(t,reserve(f,document("prepare"),&f.owner1).code,"ok")
    _,ok:=query(f.store.db,"INSERT INTO executor_legacy_commands VALUES('uncertain','chain',?,1,'running')",legacy_test_digest());testing.expect(t,ok)
    _,ok=query(f.store.db,"INSERT INTO executor_legacy_barriers VALUES('chain','migration',?,1,1)",legacy_test_barrier().selection_digest);testing.expect(t,ok)
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_legacy_resources VALUES('instance','retained_instance','chain'); CREATE VIEW executor_legacy_resources_v9 AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT count(*) FROM executor_legacy_resources),(SELECT state FROM executor_legacy_commands) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="9" && rows[0][1]=="1" && rows[0][2]=="1" && rows[0][3]=="running")
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_legacy_resources_v9; CREATE TABLE zero_parent(id INTEGER PRIMARY KEY); CREATE TABLE zero_fault(id INTEGER REFERENCES zero_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER zero_commit AFTER UPDATE ON executor_reservations WHEN NEW.state='released' BEGIN INSERT INTO zero_fault VALUES(1); END;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM executor_legacy_resources) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="9" && rows[0][1]=="1" && rows[0][2]=="prepared" && rows[0][3]=="1","failed COMMIT restores header, exact reservation and barrier inventory")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER zero_commit"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    status,found:=legacy_barrier_status(&f.store,"chain")
    testing.expect(t,found && status.running==1 && status.installed_incarnation==1)
    rows,read=query(f.store.db,"SELECT schema_version,(SELECT count(*) FROM executor_legacy_resources) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="11" && rows[0][1]=="1")
    refs,refs_ok:=query(f.store.db,"SELECT name FROM sqlite_master WHERE sql LIKE '%executor_runtime_v9%' OR sql LIKE '%executor_legacy_barriers_v9%'")
    testing.expect(t,refs_ok && len(refs)==0)
    b:=legacy_test_barrier();b.chain="zero_chain";b.migration="zero_migration";b.source_generation=0
    testing.expect_value(t,legacy_barrier_install(&f.store,b).code,"ok")
}
