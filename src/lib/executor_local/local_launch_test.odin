#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

local_schema_drop_for_test :: `DROP TABLE executor_local_draft_receipts; DROP TABLE executor_local_drafts;
 DROP TRIGGER reservation_shared_admission; DROP TRIGGER local_shared_admission;
 DROP VIEW executor_live_resources; DROP TABLE executor_local_observations; DROP TABLE executor_local_launches;`

local_inputs :: proc(t:^testing.T,f:^Fixture)->(json.Object,json.Object,Local_Resources) {
    policy(t,f)
    d:=document("directory")
    testing.expect_value(t,install_directory(&f.store,signed(d,"directory",&f.operator),f.operator.public,1000,"/repo").code,"ok")
    c:=document("local_configuration")
    set(c,"provider_profile",field(document("prepare"),"provider_profile"))
    set(c,"directory_key",directory_key(f.store.executor,"/repo"))
    o:=document("local_launch");set(o,"key_id",f.owner2.public.key_id);set(o,"principal_id",f.owner2.public.principal_id)
    f.owner2.public.kind="device"
    r:=local_resources(c)
    set(o,"configuration_digest",r.configuration_digest)
    return o,c,r
}
local_resources :: proc(c:json.Object)->Local_Resources {return {contracts.owner_payload_digest(encode(c)),field(c,"spawn_digest"),"/repo",true}}
local_admit :: proc(f:^Fixture,o,c:json.Object,now:i64=1000)->Result {
    consent:=o;set(consent,"configuration_digest",contracts.owner_payload_digest(encode(c)))
    return admit_local(&f.store,signed(consent,"local_launch",&f.owner2),encode(c),f.owner2.public,now,local_resources(c))
}
local_snapshot :: proc(t:^testing.T,f:^Fixture,result:Result)->Local_Launch {
    testing.expect_value(t,result.code,"ok")
    launch,ok:=local_launch(&f.store,body_field(result,"launch_id"));testing.expect(t,ok)
    return launch
}

@(test)
executor_local_device_consent_exact_configuration_replay_and_revocation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,r:=local_inputs(t,f);raw:=signed(o,"local_launch",&f.owner2);configuration:=encode(c)
    key:=f.owner2.public;key.kind="bridge"
    testing.expect_value(t,admit_local(&f.store,raw,configuration,key,1000,r).code,"invalid_scope")
    key=f.owner2.public;key.revoked=true
    testing.expect_value(t,admit_local(&f.store,raw,configuration,key,1000,r).code,"invalid_scope")
    key=f.owner2.public;key.account_id="other"
    testing.expect_value(t,admit_local(&f.store,raw,configuration,key,1000,r).code,"invalid_scope")
    changed:=document("local_configuration");set(changed,"model","other")
    testing.expect_value(t,admit_local(&f.store,raw,encode(changed),f.owner2.public,1000,r).code,"digest_mismatch")
    bad:=r;bad.resolved=false
    testing.expect_value(t,admit_local(&f.store,raw,configuration,f.owner2.public,1000,bad).code,"invalid_resources")
    bad=r;bad.spawn_digest=strings.repeat("d",64,context.temp_allocator)
    testing.expect_value(t,admit_local(&f.store,raw,configuration,f.owner2.public,1000,bad).code,"invalid_resources")
    result:=admit_local(&f.store,raw,configuration,f.owner2.public,1000,r)
    launch:=local_snapshot(t,f,result)
    revoked:=f.owner2.public;revoked.revoked=true
    testing.expect(t,!local_begin_dispatch(&f.store,launch,revoked,1100,r))
    testing.expect(t,local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
    testing.expect(t,!local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
    testing.expect(t,!cancel_local_admission(&f.store,launch.id))
    replay:=admit_local(&f.store,raw,configuration,f.owner2.public,9000,{})
    testing.expect(t,replay.code=="ok" && replay.replay && body_field(replay,"state")=="dispatching")
    set(c,"model","other")
    testing.expect_value(t,local_admit(f,o,c,1100).code,"operation_conflict")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_local_launches),(SELECT count(*) FROM executor_reservations)")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"1","0"}}))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_local_launches SET spawn_digest='changed'"))
}

@(test)
executor_local_unicode_configuration_and_all_shared_resource_keys :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,_:=local_inputs(t,f);set(c,"model","模型 🚀")
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    for resource in ([3]string{"slot","instance","directory"}) {
        p:=document("prepare");set(p,"slot_id","slot2");set(p,"instance_id","other")
        set(p,"directory_key",strings.repeat("e",64,context.temp_allocator))
        switch resource {
        case "slot":set(p,"slot_id",field(c,"slot_id"))
        case "instance":set(p,"instance_id",field(c,"instance_id"))
        case "directory":set(p,"directory_key",field(c,"directory_key"))
        }
        testing.expect_value(t,reserve(f,p,&f.owner1).code,"resource_conflict")
    }
    testing.expect(t,cancel_local_admission(&f.store,launch.id))
    // Remote-first admission must exclude the same resources symmetrically.
    p:=document("prepare");set(p,"instance_id",field(c,"instance_id"));set(p,"directory_key",field(c,"directory_key"))
    testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    set(o,"operation_id","new_local")
    testing.expect_value(t,local_admit(f,o,c).code,"resource_conflict")
}

@(test)
executor_local_warm_charge_survives_timeout_restart_and_stale_observation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,r:=local_inputs(t,f);set(c,"purpose","warm");r=local_resources(c)
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    testing.expect(t,local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
    testing.expect(t,expire(&f.store,9000))
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,!complete_recovery(&f.store,9000))
    testing.expect(t,!local_begin_dispatch(&f.store,launch,f.owner2.public,9000,r))
    testing.expect(t,!observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    recovered,found:=local_launch(&f.store,launch.id);testing.expect(t,found)
    testing.expect(t,!observe_local_child(&f.store,recovered,Child_Observation{launch.instance,strings.repeat("e",64,context.temp_allocator),2,false}))
    testing.expect(t,observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,true}))
    testing.expect(t,complete_recovery(&f.store,9000))
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,false}))
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,!local_begin_dispatch(&f.store,recovered,f.owner2.public,9000,r))
    testing.expect(t,!observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,true}))
}

@(test)
executor_local_manual_and_remote_owner_race_shared_slot :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,r:=local_inputs(t,f)
    p:=document("prepare")
    Job :: struct {f:^Fixture,raw,configuration:string,resources:Local_Resources,barrier:^sync.Barrier,local:bool,status:int}
    barrier:sync.Barrier;sync.barrier_init(&barrier,3)
    jobs:=[2]Job{{f,signed(o,"local_launch",&f.owner2),encode(c),r,&barrier,true,0},{f,signed(p,"prepare",&f.owner1),"",{},&barrier,false,0}}
    threads:[2]^thread.Thread
    for i in 0..<2 {
        threads[i]=thread.create_and_start_with_data(&jobs[i],proc(data:rawptr) {
            context.allocator=context.temp_allocator
            j:=(^Job)(data);sync.barrier_wait(j.barrier)
            result:Result
            if j.local {result=admit_local(&j.f.store,j.raw,j.configuration,j.f.owner2.public,1000,j.resources)}
            else {doc,_:=contracts.executor_parse(j.raw,"prepare");result=prepare(&j.f.store,j.raw,j.f.owner1.public,1000,resources(doc))}
            j.status=1 if result.code=="ok" else (2 if result.code=="resource_conflict" else 3)
        })
    }
    sync.barrier_wait(&barrier)
    for th in threads {thread.join(th);thread.destroy(th)}
    testing.expect(t,(jobs[0].status==1 && jobs[1].status==2) || (jobs[0].status==2 && jobs[1].status==1))
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
}

@(test)
executor_local_directory_policy_drain_and_explicit_undispatched_cancel :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,_:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    d:=document("directory");set(d,"revision","2");set(d,"enabled","0")
    testing.expect_value(t,install_directory(&f.store,signed(d,"directory",&f.operator),f.operator.public,1100,"").code,"resources_not_drained")
    p:=document("policy");set(p,"policy_revision","2")
    testing.expect_value(t,install_policy(&f.store,signed(p,"policy",&f.operator),f.operator.public,1100).code,"resources_not_drained")
    testing.expect(t,expire(&f.store,9000))
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,cancel_local_admission(&f.store,launch.id))
    testing.expect(t,!cancel_local_admission(&f.store,launch.id))
    testing.expect_value(t,install_directory(&f.store,signed(d,"directory",&f.operator),f.operator.public,9000,"").code,"ok")
    testing.expect_value(t,install_policy(&f.store,signed(p,"policy",&f.operator),f.operator.public,9000).code,"ok")
}

@(test)
executor_local_v6_migration_collision_atomicity :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    testing.expect_value(t,perform(f,activate_document(p),&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,local_schema_drop_for_test))
    testing.expect(t,exec(f.store.db,"PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO executor_runtime_v7;"))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_commands; DROP TABLE executor_legacy_resources; DROP TABLE executor_legacy_barriers;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=10","schema_version=6",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,6,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v7; DROP TABLE executor_runtime_v7; CREATE VIEW executor_local_launches AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations) FROM executor_runtime")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"6","1","active"}}))
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_local_launches"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM executor_local_launches) FROM executor_runtime")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"10","2","active","0"}}))
}

@(test)
executor_local_capacity_and_observation_commit_fault_keep_charges :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    testing.expect(t,local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
    p:=document("prepare");set(p,"slot_id","slot2");set(p,"instance_id","remote_other")
    testing.expect_value(t,reserve(f,p,&f.owner1,1100).code,"ok")
    fresh:=document("prepare");set(fresh,"reservation_id","fresh");set(fresh,"operation_id","fresh")
    testing.expect_value(t,reserve(f,fresh,&f.owner1,1100).code,"capacity_exhausted")
    set(o,"operation_id","another_local")
    testing.expect_value(t,local_admit(f,o,c,1100).code,"capacity_exhausted")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fail_local_confirmation BEFORE UPDATE ON executor_local_launches BEGIN SELECT RAISE(ABORT,'injected transaction failure'); END;"))
    testing.expect(t,!observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_live_resources),(SELECT count(*) FROM executor_local_observations)")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"2","0"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_local_confirmation"))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,false}))
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
}

@(test)
executor_local_final_dispatch_checks_consent_and_monotonic_admission_window :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    testing.expect(t,!local_begin_dispatch(&f.store,launch,f.owner2.public,5000,r))
    testing.expect(t,!local_begin_dispatch(&f.store,launch,f.owner2.public,999,r))
    testing.expect(t,complete_recovery(&f.store,1000))
    testing.expect(t,local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
    testing.expect(t,local_dispatch_current(&f.store,launch,f.owner2.public,1100))
    testing.expect(t,!local_dispatch_current(&f.store,launch,f.owner2.public,1099))
    testing.expect(t,!local_dispatch_current(&f.store,launch,f.owner2.public,5000))
    // Test the monotonic check independently of the wall clock; an old tick
    // cannot regain admission merely because wall time is again in range.
    consent,_:=contracts.executor_parse(signed(o,"local_launch",&f.owner2),"local_launch")
    old_tick:=time.tick_now()._nsec-i64(5*time.Second)
    testing.expect(t,!local_time_live(consent,1100,1000,old_tick))
    testing.expect(t,!local_time_live(consent,1100,1000,time.tick_now()._nsec+i64(time.Second)))
}

// A restart must retain abandoned admissions until an explicit exact cancel.
// Cancellation is never a substitute for observing a possibly dispatched child.
@(test)
executor_local_abandoned_admission_reopen_exact_cancel :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    close(&f.store)
    if !testing.expect(t,open(&f.store,f.path,"account","executor","operator")) do return
    testing.expect(t,complete_recovery(&f.store,9000))
    testing.expect(t,expire(&f.store,9000))
    recovered,found:=local_launch(&f.store,launch.id)
    testing.expect(t,found && recovered.state=="admitted")
    testing.expect(t,!local_begin_dispatch(&f.store,recovered,f.owner2.public,9000,r))
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,!cancel_local_admission(&f.store,"unrelated_launch"))
    testing.expect(t,cancel_local_admission(&f.store,launch.id))
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect_value(t,rows[0][0],"0")
    // A historical signed retry cannot restore a cancelled admission.
    replay:=local_admit(f,o,c,9000)
    testing.expect(t,replay.replay && body_field(replay,"state")=="released")
    testing.expect(t,!local_begin_dispatch(&f.store,recovered,f.owner2.public,9000,r))
    close(&f.store)
    if !testing.expect(t,open(&f.store,f.path,"account","executor","operator")) do return
    testing.expect(t,complete_recovery(&f.store,9000))
    retained,loaded:=local_launch(&f.store,launch.id)
    testing.expect(t,loaded && retained.state=="released")
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect_value(t,rows[0][0],"0")
}

@(test)
executor_local_cancel_and_first_dispatch_linearize :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    // Exercise both legal orderings without letting cancel refund a possible child.
    for _ in 0..<16 {
        f:=fixture(t)
        o,c,r:=local_inputs(t,f)
        launch:=local_snapshot(t,f,local_admit(f,o,c))
        Job :: struct {f:^Fixture,launch:Local_Launch,resources:Local_Resources,barrier:^sync.Barrier,cancel,ok:bool}
        barrier:sync.Barrier;sync.barrier_init(&barrier,3)
        jobs:=[2]Job{{f,launch,r,&barrier,true,false},{f,launch,r,&barrier,false,false}}
        threads:[2]^thread.Thread
        for i in 0..<2 {
            threads[i]=thread.create_and_start_with_data(&jobs[i],proc(data:rawptr) {
                context.allocator=context.temp_allocator
                j:=(^Job)(data);sync.barrier_wait(j.barrier)
                if j.cancel {j.ok=cancel_local_admission(&j.f.store,j.launch.id)}
                else {j.ok=local_begin_dispatch(&j.f.store,j.launch,j.f.owner2.public,1100,j.resources)}
            })
        }
        sync.barrier_wait(&barrier)
        for th in threads {thread.join(th);thread.destroy(th)}
        testing.expect(t,jobs[0].ok!=jobs[1].ok)
        current,found:=local_launch(&f.store,launch.id);testing.expect(t,found)
        rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources")
        if jobs[0].ok {
            testing.expect(t,current.state=="released")
            testing.expect_value(t,rows[0][0],"0")
            testing.expect(t,!local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
        } else {
            testing.expect(t,current.state=="dispatching")
            testing.expect_value(t,rows[0][0],"1")
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
    o,c,_:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    // A deferred foreign key violation fails COMMIT after the UPDATE succeeds.
    testing.expect(t,exec(f.store.db,"CREATE TABLE cancel_commit_fault(id TEXT REFERENCES executor_local_launches(launch_id) DEFERRABLE INITIALLY DEFERRED)"))
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER cancel_commit_fault_trigger AFTER UPDATE OF state ON executor_local_launches WHEN NEW.state='released' BEGIN INSERT INTO cancel_commit_fault VALUES('missing_launch'); END"))
    testing.expect(t,!cancel_local_admission(&f.store,launch.id))
    retained,found:=local_launch(&f.store,launch.id)
    testing.expect(t,found && retained.state=="admitted")
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER cancel_commit_fault_trigger"))
    testing.expect(t,cancel_local_admission(&f.store,launch.id))
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect_value(t,rows[0][0],"0")
}
