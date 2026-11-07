package executor_local

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

legacy_action_test_input :: proc()->Legacy_Action_Input {
    return {kind="wake_agent",packet_digest=contracts.owner_payload_digest("exact idless unscoped packet")}
}

@(test)
executor_legacy_action_occurrences_keep_unknown_claims_and_crash_ambiguity :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    input:=legacy_action_test_input()
    before_receive,before_read:=legacy_journal_snapshot(&f.store);testing.expect(t,before_read)
    first,r:=legacy_action_receive(&f.store,input);testing.expect_value(t,r.code,"ok")
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier(),snapshot=&before_receive).code,"stale_observation")
    relabeled:=first;relabeled.scope[0]=0
    testing.expect_value(t,legacy_action_transition(&f.store,relabeled,"received","prepared").code,"invalid_scope")
    second,r2:=legacy_action_receive(&f.store,input);testing.expect_value(t,r2.code,"ok")
    testing.expect(t,second.id>first.id,"a repeated packet is a separate observation, not an invocation receipt")
    rows,read:=query(f.store.db,"SELECT command_id,chain_claim,packet_digest,state FROM executor_legacy_actions ORDER BY action_id")
    testing.expect(t,read && len(rows)==2 && rows[0][0]=="" && rows[0][1]=="" && rows[0][2]==input.packet_digest && rows[0][3]=="received")
    testing.expect_value(t,legacy_action_transition(&f.store,first,"prepared","running").code,"action_conflict")
    testing.expect_value(t,legacy_action_transition(&f.store,first,"received","prepared").code,"ok")
    testing.expect_value(t,legacy_action_transition(&f.store,first,"prepared","running").code,"ok")
    testing.expect_value(t,legacy_action_transition(&f.store,first,"running","returned").code,"ok")
    testing.expect(t,legacy_action_transition(&f.store,first,"running","returned").replay)
    testing.expect_value(t,legacy_action_transition(&f.store,second,"received","discarded").code,"ok")
    testing.expect_value(t,legacy_action_transition(&f.store,second,"prepared","discarded").code,"action_conflict")
    third,_:=legacy_action_receive(&f.store,input)
    testing.expect_value(t,legacy_action_transition(&f.store,third,"received","prepared").code,"ok")
    testing.expect_value(t,legacy_action_transition(&f.store,third,"prepared","running").code,"ok")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_actions SET packet_digest=printf('%064d',0)"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_actions"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    before,ok:=legacy_journal_snapshot(&f.store);testing.expect(t,ok && before.prior_coverage_unknown)
    testing.expect(t,legacy_action_transition(&f.store,first,"running","returned").replay)
    after,ok2:=legacy_journal_snapshot(&f.store);testing.expect(t,ok2 && after.sequence==before.sequence)
    testing.expect_value(t,legacy_action_transition(&f.store,third,"running","returned").code,"stale_incarnation")
    rows,read=query(f.store.db,"SELECT state FROM executor_legacy_actions WHERE action_id=?",fmt.tprintf("%d",third.id))
    testing.expect(t,read && rows[0][0]=="running","restart cannot infer handler completion or child absence")
}

@(test)
executor_legacy_action_commit_failures_roll_back_evidence_and_sequence :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    input:=legacy_action_test_input()
    before,ok:=legacy_journal_snapshot(&f.store);testing.expect(t,ok)
    testing.expect(t,exec(f.store.db,"CREATE TABLE action_parent(id INTEGER PRIMARY KEY); CREATE TABLE action_fault(id INTEGER REFERENCES action_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER action_receive_commit AFTER INSERT ON executor_legacy_actions BEGIN INSERT INTO action_fault VALUES(1); END;"))
    _,r:=legacy_action_receive(&f.store,input);testing.expect_value(t,r.code,"storage_error")
    after,ok2:=legacy_journal_snapshot(&f.store);testing.expect(t,ok2 && before.sequence==after.sequence)
    rows,read:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_legacy_actions),(SELECT count(*) FROM action_fault)")
    testing.expect(t,read && rows[0][0]=="0" && rows[0][1]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER action_receive_commit"))
    action,created:=legacy_action_receive(&f.store,input);testing.expect_value(t,created.code,"ok")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER action_transition_commit AFTER UPDATE ON executor_legacy_actions BEGIN INSERT INTO action_fault VALUES(1); END;"))
    before,ok=legacy_journal_snapshot(&f.store);testing.expect(t,ok)
    testing.expect_value(t,legacy_action_transition(&f.store,action,"received","prepared").code,"storage_error")
    after,ok2=legacy_journal_snapshot(&f.store);testing.expect(t,ok2 && before.sequence==after.sequence)
    rows,read=query(f.store.db,"SELECT state,previous_state FROM executor_legacy_actions")
    testing.expect(t,read && rows[0][0]=="received" && rows[0][1]=="")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER action_transition_commit"))
    testing.expect_value(t,legacy_action_transition(&f.store,action,"received","prepared").code,"ok")
}

@(test)
executor_legacy_action_v11_upgrade_collision_and_commit_rollback :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    testing.expect_value(t,reserve(f,document("prepare"),&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_actions; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v12_fixture;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=12","schema_version=11",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,11,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v12_fixture; DROP TABLE runtime_v12_fixture;"))
    for line in strings.split_lines(schema) do if strings.has_prefix(line,"CREATE TRIGGER native_journal_executor_runtime_") do testing.expect(t,exec(f.store.db,line))
    testing.expect(t,exec(f.store.db,"CREATE VIEW executor_legacy_actions AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT material FROM executor_local_drafts) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="11" && rows[0][1]=="1" && rows[0][2]==d.material)
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_legacy_actions; CREATE TABLE action_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE action_upgrade_fault(id INTEGER REFERENCES action_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER action_upgrade_commit AFTER UPDATE ON executor_reservations WHEN NEW.state='released' BEGIN INSERT INTO action_upgrade_fault VALUES(1); END;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM sqlite_master WHERE name='executor_legacy_actions') FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="11" && rows[0][1]=="1" && rows[0][2]=="prepared" && rows[0][3]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER action_upgrade_commit"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT material FROM executor_local_drafts) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="12" && rows[0][1]=="2" && rows[0][2]==d.material)
    refs,refs_read:=query(f.store.db,"SELECT name FROM sqlite_master WHERE sql LIKE '%executor_runtime_v11%'")
    testing.expect(t,refs_read && len(refs)==0)
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier()).code,"ok")
}
