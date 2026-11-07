package executor_local

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

legacy_action_draft_running :: proc(t:^testing.T,f:^Fixture)->Legacy_Action {
    action,r:=legacy_action_receive(&f.store,Legacy_Action_Input{kind="wake_agent",packet_digest=contracts.owner_payload_digest("parent")})
    testing.expect_value(t,r.code,"ok")
    testing.expect_value(t,legacy_action_transition(&f.store,action,"received","prepared").code,"ok")
    testing.expect_value(t,legacy_action_transition(&f.store,action,"prepared","running").code,"ok")
    return action
}

@(test)
executor_legacy_action_draft_binds_selected_native_material_and_retains_exact_replay :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    action:=legacy_action_draft_running(t,f)
    o:=Legacy_Action_Draft{action=action,entry_index=0,entry_digest=contracts.owner_payload_digest("entry"),
        native_request_digest=contracts.owner_payload_digest("transformed proposal"),draft_id=d.id}
    first:=legacy_action_observe_draft(&f.store,o);testing.expect_value(t,first.code,"ok")
    testing.expect(t,legacy_action_observe_draft(&f.store,o).replay)
    changed:=o;changed.entry_digest=contracts.owner_payload_digest("swapped entry")
    testing.expect_value(t,legacy_action_observe_draft(&f.store,changed).code,"observation_conflict")
    changed=o;changed.action.incarnation+=1
    testing.expect_value(t,legacy_action_observe_draft(&f.store,changed).code,"observation_conflict")
    changed=o;changed.entry_index= -1
    testing.expect_value(t,legacy_action_observe_draft(&f.store,changed).code,"invalid_scope")
    changed.entry_digest=contracts.owner_payload_digest("parent")
    testing.expect_value(t,legacy_action_observe_draft(&f.store,changed).code,"ok")
    rows,read:=query(f.store.db,"SELECT configuration_digest,material_digest,instance_id,directory_id,directory_key FROM executor_legacy_action_drafts WHERE association_id=?",first.body)
    config,_:=contracts.executor_parse(d.configuration,"local_configuration")
    testing.expect(t,read && rows[0][0]==contracts.owner_payload_digest(d.configuration) && rows[0][1]==contracts.owner_payload_digest(d.material) &&
        rows[0][2]==field(config,"instance_id") && rows[0][3]==field(config,"directory_id") && rows[0][4]==field(config,"directory_key"))
    testing.expect(t,!exec(f.store.db,"INSERT OR REPLACE INTO executor_legacy_action_drafts SELECT * FROM executor_legacy_action_drafts LIMIT 1"))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_action_drafts SET instance_id='substituted'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_action_drafts"))
    testing.expect_value(t,legacy_action_transition(&f.store,action,"running","returned").code,"ok")
    testing.expect(t,legacy_action_observe_draft(&f.store,o).replay)
    changed=o;changed.native_request_digest=contracts.owner_payload_digest("new proposal after return")
    testing.expect_value(t,legacy_action_observe_draft(&f.store,changed).code,"invalid_scope")
    retained,found:=local_draft_native(&f.store,d.id)
    testing.expect(t,found && retained.material==d.material && retained.state=="pending" && retained.launch_id=="","association grants no consent or child")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    before,_:=legacy_journal_snapshot(&f.store)
    testing.expect(t,legacy_action_observe_draft(&f.store,o).replay)
    after,_:=legacy_journal_snapshot(&f.store)
    testing.expect(t,before.sequence==after.sequence && after.prior_coverage_unknown)
}

@(test)
executor_legacy_action_draft_failure_rolls_back_identity_and_journal :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    action:=legacy_action_draft_running(t,f)
    o:=Legacy_Action_Draft{action=action,entry_index= -1,entry_digest=contracts.owner_payload_digest("parent"),
        native_request_digest=contracts.owner_payload_digest("native"),draft_id=d.id}
    before,_:=legacy_journal_snapshot(&f.store)
    testing.expect(t,exec(f.store.db,"CREATE TABLE draft_action_parent(id INTEGER PRIMARY KEY); CREATE TABLE draft_action_fault(id INTEGER REFERENCES draft_action_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER draft_action_commit AFTER INSERT ON executor_legacy_action_drafts BEGIN INSERT INTO draft_action_fault VALUES(1); END;"))
    testing.expect_value(t,legacy_action_observe_draft(&f.store,o).code,"storage_error")
    after,_:=legacy_journal_snapshot(&f.store)
    rows,read:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_legacy_action_drafts),(SELECT count(*) FROM draft_action_fault)")
    testing.expect(t,read && rows[0][0]=="0" && rows[0][1]=="0" && before.sequence==after.sequence)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER draft_action_commit"))
    testing.expect_value(t,legacy_action_observe_draft(&f.store,o).code,"ok")
}

@(test)
executor_legacy_action_draft_v12_upgrade_preserves_running_occurrences_on_failure :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    action:=legacy_action_draft_running(t,f)
    testing.expect_value(t,reserve(f,document("prepare"),&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_action_drafts; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v13_fixture;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=13","schema_version=12",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,12,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v13_fixture; DROP TABLE runtime_v13_fixture;"))
    for line in strings.split_lines(schema) do if strings.has_prefix(line,"CREATE TRIGGER native_journal_executor_runtime_") do testing.expect(t,exec(f.store.db,line))
    testing.expect(t,exec(f.store.db,"CREATE VIEW executor_legacy_action_drafts AS SELECT 1"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_legacy_actions WHERE action_id=?),(SELECT material FROM executor_local_drafts) FROM executor_runtime",fmt.tprintf("%d",action.id))
    testing.expect(t,read && rows[0][0]=="12" && rows[0][1]=="1" && rows[0][2]=="running" && rows[0][3]==d.material)
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_legacy_action_drafts; CREATE TABLE draft_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE draft_upgrade_fault(id INTEGER REFERENCES draft_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER draft_upgrade_commit AFTER UPDATE ON executor_reservations WHEN NEW.state='released' BEGIN INSERT INTO draft_upgrade_fault VALUES(1); END;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM sqlite_master WHERE name='executor_legacy_action_drafts') FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="12" && rows[0][1]=="1" && rows[0][2]=="prepared" && rows[0][3]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER draft_upgrade_commit"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_legacy_actions),(SELECT material FROM executor_local_drafts) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="13" && rows[0][1]=="2" && rows[0][2]=="running" && rows[0][3]==d.material)
    refs,refs_read:=query(f.store.db,"SELECT name FROM sqlite_master WHERE sql LIKE '%executor_runtime_v12%'")
    testing.expect(t,refs_read && len(refs)==0)
    testing.expect_value(t,legacy_action_transition(&f.store,action,"running","returned").code,"stale_incarnation")
}
