#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// Callers also exercise the policy-governed reservation path, so a signed
// policy is installed; the native draft itself never consults it.
draft_inputs :: proc(t:^testing.T,f:^Fixture)->(Local_Draft,json.Object,Local_Resources) {
    policy(t,f)
    return local_inputs(t,f)
}
@(test)
executor_draft_retains_native_random_material_across_retry_and_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,r:=draft_inputs(t,f)
    testing.expect(t,d.state=="pending" && d.principal=="" && d.launch_id=="")
    // A retry of the same generation keeps the original random material.
    changed,code:=stage_local_draft(&f.store,contracts.owner_payload_digest("native-generation"),d.configuration,"{\"token\":\"replacement-secret\"}")
    testing.expect_value(t,code,"ok");testing.expect_value(t,changed.material,d.material)
    found,ok:=local_draft_source(&f.store,contracts.owner_payload_digest("native-generation"))
    testing.expect(t,ok && found.id==d.id)
    testing.expect_value(t,local_admit(f,d,r).code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    retained,loaded:=local_draft_native(&f.store,d.id)
    testing.expect(t,loaded && retained.material==d.material && retained.state=="authorized" && retained.launch_id!="")
    testing.expect(t,strings.contains(retained.material,"native-secret"))
}
@(test)
executor_draft_material_and_configuration_are_immutable :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,c,_:=draft_inputs(t,f)
    bad:=document("local_configuration");set(bad,"executor_bridge_id","other")
    _,code:=stage_local_draft(&f.store,contracts.owner_payload_digest("other-source"),encode(bad),"{}")
    testing.expect_value(t,code,"malformed")
    // A legacy slot/directory configuration is not a native configuration.
    legacy:=document("local_configuration");set(legacy,"slot_id","slot1")
    _,code=stage_local_draft(&f.store,contracts.owner_payload_digest("legacy-source"),encode(legacy),"{}")
    testing.expect_value(t,code,"malformed")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_local_drafts SET material='{}'"))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_local_drafts SET configuration='{}'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_local_drafts"))
    _=d;_=c
}
@(test)
executor_draft_v7_migration_collision_retains_exact_live_local_child :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,r:=draft_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,d,r))
    testing.expect(t,local_begin_dispatch(&f.store,launch,1100,r))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,true}))
    legacy_remove_v11_journal_fixture(t,&f.store)
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_local_draft_receipts; DROP TABLE executor_local_drafts; DROP TABLE IF EXISTS executor_legacy_action_effects; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v8_fixture;"))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_commands; DROP TABLE executor_legacy_resources; DROP TABLE executor_legacy_barriers;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=16","schema_version=7",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,7,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v8_fixture; DROP TABLE runtime_v8_fixture; CREATE VIEW executor_local_drafts AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT launch_key FROM executor_local_launches),(SELECT state FROM executor_local_launches) FROM executor_runtime")
    testing.expect(t,len(rows)==1 && rows[0][0]=="7" && rows[0][1]=="1" && rows[0][2]==launch.launch_key && rows[0][3]=="active")
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_local_drafts"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT launch_key FROM executor_local_launches),(SELECT state FROM executor_local_launches) FROM executor_runtime")
    testing.expect(t,len(rows)==1 && rows[0][0]=="16" && rows[0][1]=="2" && rows[0][2]==launch.launch_key && rows[0][3]=="active")
    // Retained shared-admission triggers must reference the NEW runtime, not
    // SQLite's temporary rename target; the live child still excludes a rival.
    p:=document("prepare");set(p,"executor_incarnation","2");set(p,"instance_id",launch.instance)
    testing.expect(t,complete_recovery(&f.store,1200)==false)
    recovered,_:=local_launch(&f.store,launch.id)
    testing.expect(t,observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,true}))
    testing.expect(t,complete_recovery(&f.store,1200))
    testing.expect_value(t,reserve(f,p,&f.owner1,1200).code,"resource_conflict")
}
