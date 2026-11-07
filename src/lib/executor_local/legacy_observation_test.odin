package executor_local

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// Reconstruct the pre-V11 effective schema in historical upgrade fixtures.
legacy_remove_v11_journal_fixture :: proc(t:^testing.T,s:^Store) {
    rows,read:=query(s.db,"SELECT name FROM sqlite_master WHERE type='trigger' AND name GLOB 'native_journal_*'")
    testing.expect(t,read)
    for row in rows do testing.expect(t,exec(s.db,strings.concatenate({"DROP TRIGGER ",row[0]},context.temp_allocator)))
    testing.expect(t,exec(s.db,"DROP TABLE IF EXISTS executor_native_journal"))
    testing.expect(t,exec(s.db,"DROP TABLE IF EXISTS executor_legacy_observations"))
}

legacy_draft_observation :: proc(d:Local_Draft)->Legacy_Draft_Observation {
    return {parent_command_id="parent",parent_digest=contracts.owner_payload_digest("original parent"),
        entry_digest=contracts.owner_payload_digest("original entry"),chain="chain",instance="instance",
        task="task",lease="lease",native_request_digest=contracts.owner_payload_digest("native command"),draft_id=d.id,entry_index=0}
}

@(test)
executor_legacy_observation_retains_later_packet_associations_without_rewriting_draft :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    c,_:=contracts.executor_parse(d.configuration,"local_configuration")
    o:=legacy_draft_observation(d);o.instance=field(c,"instance_id")
    first:=legacy_observe_draft(&f.store,o)
    testing.expect_value(t,first.code,"ok")
    testing.expect(t,!first.replay)
    testing.expect(t,legacy_observe_draft(&f.store,o).replay)
    changed:=o;changed.parent_digest=contracts.owner_payload_digest("substituted parent")
    testing.expect_value(t,legacy_observe_draft(&f.store,changed).code,"observation_conflict")
    changed=o;changed.entry_digest=contracts.owner_payload_digest("swapped entry")
    testing.expect_value(t,legacy_observe_draft(&f.store,changed).code,"observation_conflict")
    changed=o;changed.instance="other"
    testing.expect_value(t,legacy_observe_draft(&f.store,changed).code,"observation_conflict")
    later:=o;later.parent_command_id="later_parent";later.parent_digest=contracts.owner_payload_digest("later parent")
    testing.expect_value(t,legacy_observe_draft(&f.store,later).code,"ok")
    rows,read:=query(f.store.db,"SELECT count(*) FROM executor_legacy_observations")
    testing.expect(t,read && rows[0][0]=="2")
    retained,found:=local_draft_native(&f.store,d.id)
    testing.expect(t,found && retained.material==d.material && retained.state=="pending","observation grants no consent or execution")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_legacy_observations SET task_id='relabel'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_legacy_observations"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,legacy_observe_draft(&f.store,o).replay)
    testing.expect(t,legacy_observe_draft(&f.store,later).replay)
    later.parent_command_id="after_restart"
    testing.expect_value(t,legacy_observe_draft(&f.store,later).code,"ok")
    rows,read=query(f.store.db,"SELECT observed_incarnation FROM executor_legacy_observations WHERE parent_command_id='after_restart'")
    testing.expect(t,read && rows[0][0]=="2")
}

@(test)
executor_legacy_observation_failure_is_atomic_and_cannot_invent_native_draft :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    c,_:=contracts.executor_parse(d.configuration,"local_configuration")
    o:=legacy_draft_observation(d);o.instance=field(c,"instance_id")
    changed:=o;changed.instance="other"
    testing.expect_value(t,legacy_observe_draft(&f.store,changed).code,"invalid_scope")
    changed=o;changed.draft_id=contracts.owner_payload_digest("missing")
    testing.expect_value(t,legacy_observe_draft(&f.store,changed).code,"draft_not_found")
    before,before_read:=legacy_journal_snapshot(&f.store)
    testing.expect(t,before_read)
    testing.expect(t,exec(f.store.db,"CREATE TABLE observation_parent(id INTEGER PRIMARY KEY); CREATE TABLE observation_fault(id INTEGER REFERENCES observation_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER observation_commit AFTER INSERT ON executor_legacy_observations BEGIN INSERT INTO observation_fault VALUES(1); END;"))
    testing.expect_value(t,legacy_observe_draft(&f.store,o).code,"storage_error")
    rows,read:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_legacy_observations),(SELECT count(*) FROM observation_fault)")
    testing.expect(t,read && rows[0][0]=="0" && rows[0][1]=="0")
    after,after_read:=legacy_journal_snapshot(&f.store)
    testing.expect(t,after_read && after.sequence==before.sequence,"failed observation COMMIT rolls back its journal increment too")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER observation_commit"))
    testing.expect_value(t,legacy_observe_draft(&f.store,o).code,"ok")
}

@(test)
executor_legacy_observation_v10_upgrade_collision_retains_native_material :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,_:=draft_inputs(t,f)
    testing.expect_value(t,reserve(f,document("prepare"),&f.owner1).code,"ok")
    // Effective historical header and absence of V11 tables/triggers.
    legacy_remove_v11_journal_fixture(t,&f.store)
    testing.expect(t,exec(f.store.db,"PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v11_fixture;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=11","schema_version=10",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,10,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v11_fixture; DROP TABLE runtime_v11_fixture; CREATE VIEW executor_legacy_observations AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT material FROM executor_local_drafts) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="10" && rows[0][1]=="1" && rows[0][2]==d.material)
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_legacy_observations; CREATE TABLE observation_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE observation_upgrade_fault(id INTEGER REFERENCES observation_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER observation_upgrade_commit AFTER UPDATE ON executor_reservations WHEN NEW.state='released' BEGIN INSERT INTO observation_upgrade_fault VALUES(1); END;"));close(&f.store)
    testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM sqlite_master WHERE name='executor_native_journal') FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="10" && rows[0][1]=="1" && rows[0][2]=="prepared" && rows[0][3]=="0","failed COMMIT preserves exact pre-upgrade state")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER observation_upgrade_commit"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,read=query(f.store.db,"SELECT schema_version,incarnation,(SELECT material FROM executor_local_drafts) FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="11" && rows[0][1]=="2" && rows[0][2]==d.material)
    refs,read_refs:=query(f.store.db,"SELECT name FROM sqlite_master WHERE sql LIKE '%executor_runtime_v10%'")
    testing.expect(t,read_refs && len(refs)==0)
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier()).code,"ok")
}

@(test)
executor_native_journal_detects_draft_changes_restart_and_atomic_barrier_cas :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    before,read:=legacy_journal_snapshot(&f.store)
    testing.expect(t,read && before.prior_coverage_unknown && before.coverage_version==1)
    d,_,_:=draft_inputs(t,f)
    after,read_after:=legacy_journal_snapshot(&f.store)
    testing.expect(t,read_after && after.sequence>before.sequence)
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier(),snapshot=&before).code,"stale_observation")
    _,installed:=legacy_barrier_status(&f.store,"chain");testing.expect(t,!installed)
    c,_:=contracts.executor_parse(d.configuration,"local_configuration")
    o:=legacy_draft_observation(d);o.instance=field(c,"instance_id")
    testing.expect_value(t,legacy_observe_draft(&f.store,o).code,"ok")
    observed,observed_read:=legacy_journal_snapshot(&f.store)
    testing.expect(t,observed_read && observed.sequence>after.sequence)
    testing.expect(t,legacy_observe_draft(&f.store,o).replay)
    same,same_read:=legacy_journal_snapshot(&f.store)
    testing.expect(t,same_read && same.sequence==observed.sequence,"exact evidence replay does not change CAS")
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier(),snapshot=&after).code,"stale_observation")
    testing.expect_value(t,legacy_barrier_install(&f.store,legacy_test_barrier(),snapshot=&observed).code,"ok")
    testing.expect(t,legacy_barrier_install(&f.store,legacy_test_barrier(),snapshot=&before).replay,"historical exact barrier receipt is read-only")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    restarted,restart_read:=legacy_journal_snapshot(&f.store)
    testing.expect(t,restart_read && restarted.incarnation>observed.incarnation && restarted.sequence>observed.sequence && restarted.prior_coverage_unknown)
    other:=legacy_test_barrier();other.chain="other";other.migration="other_migration"
    testing.expect_value(t,legacy_barrier_install(&f.store,other,snapshot=&observed).code,"stale_observation")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_native_journal SET sequence=0"))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_native_journal SET prior_coverage_unknown=0,sequence=sequence+1"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_native_journal"))
    testing.expect(t,!exec(f.store.db,"INSERT OR REPLACE INTO executor_native_journal VALUES(1,0,1,1)"))
}
