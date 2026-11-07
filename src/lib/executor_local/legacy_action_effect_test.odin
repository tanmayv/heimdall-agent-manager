package executor_local

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

legacy_effect_test_running :: proc(t:^testing.T,s:^Store,kind,packet:string)->Legacy_Action {
    a,result:=legacy_action_receive(s,{kind=kind,packet_digest=contracts.owner_payload_digest(packet)})
    testing.expect_value(t,result.code,"ok")
    testing.expect_value(t,legacy_action_transition(s,a,"received","prepared").code,"ok")
    testing.expect_value(t,legacy_action_transition(s,a,"prepared","running").code,"ok")
    return a
}

@(test)
executor_legacy_effects_preserve_exact_stop_merge_targets_and_replay :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    consent,config,resources:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,consent,config))
    testing.expect(t,local_begin_dispatch(&f.store,launch,f.owner2.public,1100,resources))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,true}))
    stop:=legacy_effect_test_running(t,&f.store,"stop_agent","stop packet")
    entry:=contracts.owner_payload_digest("stop packet")
    target:=Legacy_Stop_Evidence{launch.instance,launch.id,launch.launch_key,contracts.owner_payload_digest(encode(config)),field(config,"directory_key"),number(field(config,"run_count")),42}
    testing.expect(t,exec(f.store.db,"CREATE TABLE effect_parent(id INTEGER PRIMARY KEY); CREATE TABLE effect_fault(id INTEGER REFERENCES effect_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER effect_commit AFTER INSERT ON executor_legacy_action_effects BEGIN INSERT INTO effect_fault VALUES(1); END;"))
    before,_:=legacy_journal_snapshot(&f.store)
    testing.expect_value(t,legacy_action_observe_stop(&f.store,stop,-1,entry,target).code,"storage_error")
    after,_:=legacy_journal_snapshot(&f.store)
    testing.expect(t,before.sequence==after.sequence)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER effect_commit"))
    first:=legacy_action_observe_stop(&f.store,stop,-1,entry,target)
    testing.expect_value(t,first.code,"ok")
    testing.expect(t,legacy_action_observe_stop(&f.store,stop,-1,entry,target).replay)
    changed:=target;changed.child_pid+=1
    testing.expect_value(t,legacy_action_observe_stop(&f.store,stop,-1,entry,changed).code,"observation_conflict")
    testing.expect_value(t,legacy_action_observe_stop(&f.store,stop,-1,contracts.owner_payload_digest("other entry"),target).code,"observation_conflict")
    testing.expect_value(t,legacy_action_transition(&f.store,stop,"running","returned").code,"ok")
    merge:=legacy_effect_test_running(t,&f.store,"taskv2_merge_worktree","merge packet")
    merge_entry:=contracts.owner_payload_digest("merge packet")
    m:=Legacy_Merge_Evidence{"task",contracts.owner_payload_digest("repo"),contracts.owner_payload_digest("workdir"),"heimdall/task",strings.repeat("a",40),strings.repeat("b",40)}
    testing.expect_value(t,legacy_action_observe_merge(&f.store,merge,merge_entry,m).code,"ok")
    different:=m;different.repository_head=strings.repeat("c",40)
    testing.expect_value(t,legacy_action_observe_merge(&f.store,merge,merge_entry,different).code,"observation_conflict")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_action_effects SET evidence='{}'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_action_effects"))
    testing.expect(t,!exec(f.store.db,"INSERT OR REPLACE INTO executor_legacy_action_effects SELECT * FROM executor_legacy_action_effects"))
    rows,read:=query(f.store.db,"SELECT effect_kind,evidence_digest FROM executor_legacy_action_effects ORDER BY action_id")
    testing.expect(t,read && len(rows)==2 && rows[0][0]=="stop" && rows[0][1]==contracts.owner_payload_digest(encode(target)) && rows[1][0]=="merge")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    before,_=legacy_journal_snapshot(&f.store)
    testing.expect(t,legacy_action_observe_stop(&f.store,stop,-1,entry,target).replay)
    testing.expect(t,legacy_action_observe_merge(&f.store,merge,merge_entry,m).replay)
    after,_=legacy_journal_snapshot(&f.store)
    testing.expect(t,before.sequence==after.sequence && after.prior_coverage_unknown)
    fresh:=legacy_effect_test_running(t,&f.store,"taskv2_merge_worktree","fresh merge")
    fresh.incarnation=merge.incarnation
    testing.expect_value(t,legacy_action_observe_merge(&f.store,fresh,contracts.owner_payload_digest("fresh merge"),m).code,"invalid_scope")
}

@(test)
executor_legacy_effect_v14_upgrade_rolls_back_collision_and_commit_failure :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    action:=legacy_effect_test_running(t,&f.store,"taskv2_merge_worktree","retained")
    testing.expect_value(t,reserve(f,document("prepare"),&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_action_effects; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v15_fixture;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=15","schema_version=14",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,14,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v15_fixture; DROP TABLE runtime_v15_fixture;"))
    for line in strings.split_lines(schema) do if strings.has_prefix(line,"CREATE TRIGGER native_journal_executor_runtime_") do testing.expect(t,exec(f.store.db,line))
    testing.expect(t,exec(f.store.db,"CREATE VIEW executor_legacy_action_effects AS SELECT 1"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_legacy_actions WHERE action_id=?),(SELECT material FROM executor_local_drafts) FROM executor_runtime",fmt.tprintf("%d",action.id))
    testing.expect(t,read && rows[0][0]=="14" && rows[0][1]=="1" && rows[0][2]=="running" && rows[0][3]==d.material)
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_legacy_action_effects; CREATE TABLE effect_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE effect_upgrade_fault(id INTEGER REFERENCES effect_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER effect_upgrade_commit AFTER UPDATE ON executor_reservations WHEN NEW.state='released' BEGIN INSERT INTO effect_upgrade_fault VALUES(1); END;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM sqlite_master WHERE name='executor_legacy_action_effects') FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="14" && rows[0][1]=="1" && rows[0][2]=="prepared" && rows[0][3]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER effect_upgrade_commit"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_legacy_actions),(SELECT material FROM executor_local_drafts) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="15" && rows[0][1]=="2" && rows[0][2]=="running" && rows[0][3]==d.material)
    refs,refs_read:=query(f.store.db,"SELECT name FROM sqlite_master WHERE sql LIKE '%executor_runtime_v14%'")
    testing.expect(t,refs_read && len(refs)==0)
}
