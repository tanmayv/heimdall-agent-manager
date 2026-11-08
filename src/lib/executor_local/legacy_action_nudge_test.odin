package executor_local

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
executor_legacy_nudge_exact_child_identity_replay_and_rollback :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    draft,config,resources:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,draft,resources))
    testing.expect(t,local_begin_dispatch(&f.store,launch,1100,resources))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,true}))
    action:=legacy_action_draft_running(t,f)
    o:=Legacy_Action_Nudge{action=action,entry_index=0,entry_digest=contracts.owner_payload_digest("nudge entry"),launch_id=launch.id,child_pid=42,run_count=number(field(config,"run_count"))}
    testing.expect(t,exec(f.store.db,"CREATE TABLE nudge_parent(id INTEGER PRIMARY KEY); CREATE TABLE nudge_fault(id INTEGER REFERENCES nudge_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER nudge_commit AFTER INSERT ON executor_legacy_action_nudges BEGIN INSERT INTO nudge_fault VALUES(1); END;"))
    before,_:=legacy_journal_snapshot(&f.store)
    testing.expect_value(t,legacy_action_observe_nudge(&f.store,o).code,"storage_error")
    after,_:=legacy_journal_snapshot(&f.store)
    testing.expect(t,before.sequence==after.sequence)
    rows,read:=query(f.store.db,"SELECT count(*) FROM executor_legacy_action_nudges")
    testing.expect(t,read && rows[0][0]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER nudge_commit"))
    first:=legacy_action_observe_nudge(&f.store,o);testing.expect_value(t,first.code,"ok")
    testing.expect(t,legacy_action_observe_nudge(&f.store,o).replay)
    changed:=o;changed.child_pid+=1
    testing.expect_value(t,legacy_action_observe_nudge(&f.store,changed).code,"observation_conflict")
    changed=o;changed.launch_id="retargeted_child"
    testing.expect_value(t,legacy_action_observe_nudge(&f.store,changed).code,"observation_conflict")
    changed=o;changed.entry_digest=contracts.owner_payload_digest("swapped")
    testing.expect_value(t,legacy_action_observe_nudge(&f.store,changed).code,"observation_conflict")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_action_nudges SET launch_key='retargeted'"))
    testing.expect(t,!exec(f.store.db,"INSERT OR REPLACE INTO executor_legacy_action_nudges SELECT * FROM executor_legacy_action_nudges"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_action_nudges"))
    rows,read=query(f.store.db,"SELECT launch_key,configuration_digest,instance_id,directory_key FROM executor_legacy_action_nudges")
    testing.expect(t,read && rows[0][0]==launch.launch_key && rows[0][1]==contracts.owner_payload_digest(encode(config)) &&
        rows[0][2]==launch.instance && rows[0][3]==field(config,"directory_key"))
    testing.expect_value(t,legacy_action_transition(&f.store,action,"running","returned").code,"ok")
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    testing.expect(t,legacy_action_observe_nudge(&f.store,o).replay,"retained presence is read-only history, not a new physical query")
    next:=legacy_action_draft_running(t,f);changed=o;changed.action=next
    testing.expect_value(t,legacy_action_observe_nudge(&f.store,changed).code,"invalid_scope")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    before,_=legacy_journal_snapshot(&f.store)
    testing.expect(t,legacy_action_observe_nudge(&f.store,o).replay)
    after,_=legacy_journal_snapshot(&f.store)
    testing.expect(t,before.sequence==after.sequence && after.prior_coverage_unknown)
}

@(test)
executor_legacy_nudge_v13_upgrade_collision_and_commit_failure_preserve_history :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    action:=legacy_action_draft_running(t,f)
    testing.expect_value(t,reserve(f,document("prepare"),&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_action_nudges; DROP TABLE IF EXISTS executor_legacy_action_effects; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v14_fixture;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=16","schema_version=13",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,13,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v14_fixture; DROP TABLE runtime_v14_fixture;"))
    for line in strings.split_lines(schema) do if strings.has_prefix(line,"CREATE TRIGGER native_journal_executor_runtime_") do testing.expect(t,exec(f.store.db,line))
    testing.expect(t,exec(f.store.db,"CREATE VIEW executor_legacy_action_nudges AS SELECT 1"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_legacy_actions WHERE action_id=?),(SELECT material FROM executor_local_drafts) FROM executor_runtime",fmt.tprintf("%d",action.id))
    testing.expect(t,read && rows[0][0]=="13" && rows[0][1]=="1" && rows[0][2]=="running" && rows[0][3]==d.material)
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_legacy_action_nudges; CREATE TABLE nudge_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE nudge_upgrade_fault(id INTEGER REFERENCES nudge_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER nudge_upgrade_commit AFTER UPDATE ON executor_reservations WHEN NEW.state='released' BEGIN INSERT INTO nudge_upgrade_fault VALUES(1); END;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM sqlite_master WHERE name='executor_legacy_action_nudges') FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="13" && rows[0][1]=="1" && rows[0][2]=="prepared" && rows[0][3]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER nudge_upgrade_commit"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_legacy_actions),(SELECT material FROM executor_local_drafts) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="16" && rows[0][1]=="2" && rows[0][2]=="running" && rows[0][3]==d.material)
    refs,refs_read:=query(f.store.db,"SELECT name FROM sqlite_master WHERE sql LIKE '%executor_runtime_v13%'")
    testing.expect(t,refs_read && len(refs)==0)
}
