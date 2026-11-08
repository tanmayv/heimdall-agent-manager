#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"

local_schema_drop_for_test :: `DROP TABLE executor_local_draft_receipts; DROP TABLE executor_local_drafts;
 DROP TRIGGER reservation_shared_admission; DROP TRIGGER local_shared_admission;
 DROP VIEW executor_live_resources; DROP TABLE executor_local_observations; DROP TABLE executor_local_launches;`

// A native generation: no policy, slot, capacity or signed directory exists.
local_inputs :: proc(t:^testing.T,f:^Fixture,source:="native-generation",instance:="")->(Local_Draft,json.Object,Local_Resources) {
    c:=document("local_configuration")
    if instance!="" do set(c,"instance_id",instance)
    d,code:=stage_local_draft(&f.store,contracts.owner_payload_digest(source),encode(c),"{\"token\":\"native-secret\"}")
    testing.expect_value(t,code,"ok")
    return d,c,local_resources(c)
}
local_resources :: proc(c:json.Object)->Local_Resources {return {contracts.owner_payload_digest(encode(c)),field(c,"spawn_digest"),"/repo",true}}
local_admit :: proc(f:^Fixture,d:Local_Draft,r:Local_Resources,now:i64=1000)->Result {
    return authorize_native_local(&f.store,d.id,now,r)
}
local_snapshot :: proc(t:^testing.T,f:^Fixture,result:Result)->Local_Launch {
    testing.expect_value(t,result.code,"ok")
    launch,ok:=local_launch(&f.store,body_field(result,"launch_id"));testing.expect(t,ok)
    return launch
}
local_live :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_local_launches WHERE state!='released'")
    return rows[0][0]
}

@(test)
executor_local_native_admission_needs_no_policy_slot_or_directory :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    rows,_:=query(f.store.db,"SELECT policy_revision,device_capacity,(SELECT count(*) FROM executor_directories),(SELECT count(*) FROM executor_slots WHERE enabled=1) FROM executor_runtime")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"0","0","0","0"}}))
    d,c,r:=local_inputs(t,f)
    bad:=r;bad.resolved=false
    testing.expect_value(t,local_admit(f,d,bad).code,"invalid_resources")
    bad=r;bad.spawn_digest=strings.repeat("d",64,context.temp_allocator)
    testing.expect_value(t,local_admit(f,d,bad).code,"invalid_resources")
    bad=r;bad.configuration_digest=strings.repeat("e",64,context.temp_allocator)
    testing.expect_value(t,local_admit(f,d,bad).code,"invalid_resources")
    testing.expect_value(t,authorize_native_local(&f.store,strings.repeat("f",64,context.temp_allocator),1000,r).code,"draft_not_found")
    result:=local_admit(f,d,r)
    launch:=local_snapshot(t,f,result)
    testing.expect_value(t,launch.state,"admitted")
    native,_:=local_draft_native(&f.store,d.id)
    testing.expect(t,native.state=="authorized" && native.launch_id==launch.id && native.principal==LOCAL_NATIVE_PRINCIPAL)
    // A retry returns the same admission; it never mints a second one.
    replay:=local_admit(f,d,r,1100)
    testing.expect(t,replay.code=="ok" && body_field(replay,"launch_id")==launch.id)
    testing.expect(t,local_begin_dispatch(&f.store,launch,1100,r))
    testing.expect(t,local_dispatch_current(&f.store,launch,1100))
    testing.expect(t,!local_dispatch_current(&f.store,launch,1099))
    testing.expect(t,!local_begin_dispatch(&f.store,launch,1100,r))
    testing.expect(t,!cancel_local_admission(&f.store,launch.id))
    // Native launches are not charged against the policy-governed resources:
    // installing (or changing) a policy needs no drain.
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM executor_live_resources),(SELECT count(*) FROM executor_local_launches),(SELECT slot_id||'|'||directory_key FROM executor_local_launches)")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"0","1","native_local|"}}))
    testing.expect_value(t,install_policy(&f.store,signed(document("policy"),"policy",&f.operator),f.operator.public,1200).code,"ok")
    p:=document("policy");set(p,"policy_revision","2")
    testing.expect_value(t,install_policy(&f.store,signed(p,"policy",&f.operator),f.operator.public,1200).code,"ok")
    // The reserved native slot can never be enabled by a signed policy.
    q:=document("policy");set(q,"policy_revision","3");set(q,"slots_json",`[{"slot_id":"native_local","provider_profile":"default","enabled":"1"}]`)
    testing.expect_value(t,install_policy(&f.store,signed(q,"policy",&f.operator),f.operator.public,1200).code,"invalid_slot")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_local_launches SET spawn_digest='changed'"))
    _=c
}

@(test)
executor_local_native_one_live_child_per_instance_without_capacity_limit :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,c,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,d,r))
    // No device capacity: other instances are admitted concurrently.
    for i in 0..<3 {
        other,_,ro:=local_inputs(t,f,source=strings.concatenate({"other-",encode(i)}),instance=strings.concatenate({"other_instance_",encode(i)}))
        testing.expect_value(t,local_admit(f,other,ro).code,"ok")
    }
    // A newer generation of the same instance waits for the exact child.
    next,_,rn:=local_inputs(t,f,source="native-generation-2")
    testing.expect_value(t,local_admit(f,next,rn).code,"instance_not_drained")
    p:=document("prepare");set(p,"instance_id",field(c,"instance_id"))
    policy(t,f)
    testing.expect_value(t,reserve(f,p,&f.owner1).code,"resource_conflict")
    testing.expect(t,local_begin_dispatch(&f.store,launch,1100,r))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,true}))
    testing.expect_value(t,local_admit(f,next,rn,1100).code,"instance_not_drained")
    // Only an exact trusted absence frees the instance.
    testing.expect(t,!observe_local_child(&f.store,launch,Child_Observation{launch.instance,strings.repeat("e",64,context.temp_allocator),1,false}))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    testing.expect_value(t,local_admit(f,next,rn,1100).code,"ok")
    listed,read:=local_instance_launches(&f.store,launch.instance)
    testing.expect(t,read && len(listed)==1 && listed[0].state=="admitted")
}

@(test)
executor_local_warm_child_survives_timeout_restart_and_stale_observation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    c:=document("local_configuration");set(c,"purpose","warm")
    d,code:=stage_local_draft(&f.store,contracts.owner_payload_digest("warm"),encode(c),"{}")
    testing.expect_value(t,code,"ok")
    r:=local_resources(c)
    launch:=local_snapshot(t,f,local_admit(f,d,r))
    testing.expect(t,local_begin_dispatch(&f.store,launch,1100,r))
    testing.expect(t,expire(&f.store,9000))
    testing.expect_value(t,local_live(f),"1")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,!complete_recovery(&f.store,9000))
    testing.expect(t,!local_begin_dispatch(&f.store,launch,9000,r))
    testing.expect(t,!observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    recovered,found:=local_launch(&f.store,launch.id);testing.expect(t,found)
    testing.expect(t,!observe_local_child(&f.store,recovered,Child_Observation{launch.instance,strings.repeat("e",64,context.temp_allocator),2,false}))
    testing.expect(t,observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,true}))
    testing.expect(t,complete_recovery(&f.store,9000))
    testing.expect_value(t,local_live(f),"1")
    testing.expect(t,observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,false}))
    testing.expect_value(t,local_live(f),"0")
    testing.expect(t,!local_begin_dispatch(&f.store,recovered,9000,r))
    testing.expect(t,!observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,true}))
}

@(test)
executor_local_v6_migration_collision_atomicity :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    testing.expect_value(t,perform(f,activate_document(p),&f.owner1).code,"ok")
    legacy_remove_v11_journal_fixture(t,&f.store)
    testing.expect(t,exec(f.store.db,local_schema_drop_for_test))
    testing.expect(t,exec(f.store.db,"DROP TABLE IF EXISTS executor_legacy_action_effects; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO executor_runtime_v7;"))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_commands; DROP TABLE executor_legacy_resources; DROP TABLE executor_legacy_barriers;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=16","schema_version=6",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,6,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v7; DROP TABLE executor_runtime_v7; CREATE VIEW executor_local_launches AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations) FROM executor_runtime")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"6","1","active"}}))
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_local_launches"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM executor_local_launches) FROM executor_runtime")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"16","2","active","0"}}))
}

@(test)
executor_local_observation_commit_fault_keeps_child :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,d,r))
    testing.expect(t,local_begin_dispatch(&f.store,launch,1100,r))
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fail_local_confirmation BEFORE UPDATE ON executor_local_launches BEGIN SELECT RAISE(ABORT,'injected transaction failure'); END;"))
    testing.expect(t,!observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_local_observations")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect_value(t,local_live(f),"1")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_local_confirmation"))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    testing.expect_value(t,local_live(f),"0")
}

@(test)
executor_local_final_dispatch_checks_recovery_and_clock :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,d,r))
    testing.expect(t,!local_begin_dispatch(&f.store,launch,999,r))
    testing.expect(t,complete_recovery(&f.store,1000))
    bad:=r;bad.spawn_digest=strings.repeat("d",64,context.temp_allocator)
    testing.expect(t,!local_begin_dispatch(&f.store,launch,1100,bad))
    testing.expect(t,local_begin_dispatch(&f.store,launch,1100,r))
    testing.expect(t,local_dispatch_current(&f.store,launch,1100))
    testing.expect(t,!local_dispatch_current(&f.store,launch,1099))
    // A stale-incarnation draft is never admitted after a restart.
    c:=document("local_configuration");set(c,"instance_id","stale_instance")
    stale,code:=stage_local_draft(&f.store,contracts.owner_payload_digest("stale"),encode(c),"{}")
    testing.expect_value(t,code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,complete_recovery(&f.store,1200)==false)
    testing.expect_value(t,local_admit(f,stale,local_resources(c),1200).code,"stale_incarnation")
}

// A restart retains abandoned admissions until an explicit exact cancel.
// Cancellation is never a substitute for observing a possibly dispatched child.
@(test)
executor_local_abandoned_admission_reopen_exact_cancel :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,d,r))
    close(&f.store)
    if !testing.expect(t,open(&f.store,f.path,"account","executor","operator")) do return
    testing.expect(t,complete_recovery(&f.store,9000))
    recovered,found:=local_launch(&f.store,launch.id)
    testing.expect(t,found && recovered.state=="admitted")
    // The old incarnation's admission is fenced from first I/O after restart.
    testing.expect(t,!local_begin_dispatch(&f.store,recovered,9000,r))
    testing.expect_value(t,local_live(f),"1")
    testing.expect(t,!cancel_local_admission(&f.store,"unrelated_launch"))
    testing.expect(t,cancel_local_admission(&f.store,launch.id))
    testing.expect_value(t,local_live(f),"0")
    // Re-authorizing the same generation cannot restore a released admission.
    replay:=local_admit(f,d,r,9000)
    testing.expect(t,replay.code=="ok" && body_field(replay,"state")=="released")
    testing.expect(t,!local_begin_dispatch(&f.store,recovered,9000,r))
}

@(test)
executor_local_cancel_and_first_dispatch_linearize :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    // Exercise both legal orderings without letting cancel refund a possible child.
    for _ in 0..<16 {
        f:=fixture(t)
        d,_,r:=local_inputs(t,f)
        launch:=local_snapshot(t,f,local_admit(f,d,r))
        Job :: struct {f:^Fixture,launch:Local_Launch,resources:Local_Resources,barrier:^sync.Barrier,cancel,ok:bool}
        barrier:sync.Barrier;sync.barrier_init(&barrier,3)
        jobs:=[2]Job{{f,launch,r,&barrier,true,false},{f,launch,r,&barrier,false,false}}
        threads:[2]^thread.Thread
        for i in 0..<2 {
            threads[i]=thread.create_and_start_with_data(&jobs[i],proc(data:rawptr) {
                context.allocator=context.temp_allocator
                j:=(^Job)(data);sync.barrier_wait(j.barrier)
                if j.cancel {j.ok=cancel_local_admission(&j.f.store,j.launch.id)}
                else {j.ok=local_begin_dispatch(&j.f.store,j.launch,1100,j.resources)}
            })
        }
        sync.barrier_wait(&barrier)
        for th in threads {thread.join(th);thread.destroy(th)}
        testing.expect(t,jobs[0].ok!=jobs[1].ok)
        current,found:=local_launch(&f.store,launch.id);testing.expect(t,found)
        if jobs[0].ok {
            testing.expect(t,current.state=="released")
            testing.expect_value(t,local_live(f),"0")
            testing.expect(t,!local_begin_dispatch(&f.store,launch,1100,r))
        } else {
            testing.expect(t,current.state=="dispatching")
            testing.expect_value(t,local_live(f),"1")
            testing.expect(t,!cancel_local_admission(&f.store,launch.id))
            testing.expect(t,stop_local_launch(&f.store,current))
            testing.expect(t,!cancel_local_admission(&f.store,launch.id))
        }
        destroy(f)
    }
}

@(test)
executor_local_cancel_failed_commit_retains_admission :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,d,r))
    // A deferred foreign key violation fails COMMIT after the UPDATE succeeds.
    testing.expect(t,exec(f.store.db,"CREATE TABLE cancel_commit_fault(id TEXT REFERENCES executor_local_launches(launch_id) DEFERRABLE INITIALLY DEFERRED)"))
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER cancel_commit_fault_trigger AFTER UPDATE OF state ON executor_local_launches WHEN NEW.state='released' BEGIN INSERT INTO cancel_commit_fault VALUES('missing_launch'); END"))
    testing.expect(t,!cancel_local_admission(&f.store,launch.id))
    retained,found:=local_launch(&f.store,launch.id)
    testing.expect(t,found && retained.state=="admitted")
    testing.expect_value(t,local_live(f),"1")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER cancel_commit_fault_trigger"))
    testing.expect(t,cancel_local_admission(&f.store,launch.id))
    testing.expect_value(t,local_live(f),"0")
}

@(test)
executor_local_native_admission_failed_commit_leaves_draft_pending :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,_,r:=local_inputs(t,f)
    testing.expect(t,exec(f.store.db,"CREATE TABLE admit_commit_fault(id TEXT REFERENCES executor_local_drafts(draft_id) DEFERRABLE INITIALLY DEFERRED)"))
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER admit_commit_fault_trigger AFTER INSERT ON executor_local_launches BEGIN INSERT INTO admit_commit_fault VALUES('missing'); END"))
    testing.expect_value(t,local_admit(f,d,r).code,"storage_error")
    retained,_:=local_draft_native(&f.store,d.id)
    testing.expect(t,retained.state=="pending" && retained.launch_id=="")
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_local_launches");testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER admit_commit_fault_trigger"))
    testing.expect_value(t,local_admit(f,d,r).code,"ok")
}
