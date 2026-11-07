#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:sync"
import "core:thread"
import contracts "odin_test:contracts"

draft_inputs :: proc(t:^testing.T,f:^Fixture)->(Local_Draft,json.Object,Local_Resources) {
    _,c,r:=local_inputs(t,f)
    d,code:=stage_local_draft(&f.store,contracts.owner_payload_digest("native-generation"),encode(c),"{\"token\":\"native-secret\"}")
    testing.expect_value(t,code,"ok")
    o:=document("local_draft")
    set(o,"principal_id",f.owner2.public.principal_id);set(o,"key_id",f.owner2.public.key_id)
    set(o,"draft_id",d.id);set(o,"configuration_digest",r.configuration_digest)
    return d,o,r
}
draft_command :: proc(f:^Fixture,o:json.Object,method,op:string,now:i64=1000,r:Local_Resources={})->Result {
    set(o,"method",method);set(o,"operation_id",op)
    return local_draft_command(&f.store,signed(o,"local_draft",&f.owner2),f.owner2.public,now,r)
}
@(test)
executor_draft_retains_native_random_material_and_principal_owned_projection :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,o,r:=draft_inputs(t,f)
    testing.expect_value(t,draft_command(f,o,"inspect","unowned").code,"draft_not_owned")
    prepared:=draft_command(f,o,"prepare","prepare")
    testing.expect_value(t,prepared.code,"ok")
    testing.expect(t,!strings.contains(prepared.body,"native-secret") && !strings.contains(prepared.body,"launch_key"))
    changed,code:=stage_local_draft(&f.store,contracts.owner_payload_digest("native-generation"),d.configuration,"{\"token\":\"replacement-secret\"}")
    testing.expect_value(t,code,"ok");testing.expect_value(t,changed.material,d.material)
    f.owner1.public.kind="device"
    alien:=document("local_draft")
    for k,v in o do alien[k]=v
    set(alien,"key_id",f.owner1.public.key_id);set(alien,"principal_id",f.owner1.public.principal_id)
    for method in ([4]string{"prepare","inspect","authorize","cancel"}) {
        set(alien,"method",method)
        testing.expect_value(t,local_draft_command(&f.store,signed(alien,"local_draft",&f.owner1),f.owner1.public,1000,r).code,"draft_not_owned")
    }
    raw:=signed(o,"local_draft",&f.owner2)
    revoked:=f.owner2.public;revoked.revoked=true
    testing.expect_value(t,local_draft_command(&f.store,raw,revoked,1000,r).code,"invalid_scope")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    retained,found:=local_draft_native(&f.store,d.id)
    testing.expect(t,found && retained.material==d.material && retained.principal==f.owner2.public.principal_id)
    replay:=local_draft_command(&f.store,raw,f.owner2.public,9000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==prepared.body)
    testing.expect_value(t,draft_command(f,o,"authorize","late",1100,r).code,"recovery_required")
    testing.expect_value(t,draft_command(f,o,"cancel","cancel",1100).code,"ok")
}
@(test)
executor_draft_authorize_cancel_restart_and_replay_never_revive :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,o,r:=draft_inputs(t,f)
    testing.expect_value(t,draft_command(f,o,"prepare","prepare").code,"ok")
    result:=draft_command(f,o,"authorize","authorize",1100,r)
    testing.expect_value(t,result.code,"ok")
    raw:=signed(o,"local_draft",&f.owner2)
    native,found:=local_draft_native(&f.store,d.id);testing.expect(t,found && native.launch_id!="")
    launch,exists:=local_launch(&f.store,native.launch_id);testing.expect(t,exists)
    // Reauthorizing with a new operation remains the SAME physical admission.
    testing.expect_value(t,draft_command(f,o,"authorize","authorize-again",1100,r).code,"ok")
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_local_launches");testing.expect_value(t,rows[0][0],"1")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    cancelled:=draft_command(f,o,"cancel","cancel",1200)
    testing.expect_value(t,cancelled.code,"ok");testing.expect_value(t,body_field(cancelled,"launch_state"),"released")
    replay:=local_draft_command(&f.store,raw,f.owner2.public,9000,r)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==result.body)
    recovered,_:=local_launch(&f.store,launch.id)
    testing.expect_value(t,recovered.state,"released")
    testing.expect(t,!local_begin_dispatch(&f.store,recovered,f.owner2.public,1200,r))
    testing.expect_value(t,draft_command(f,o,"authorize","revive",1200,r).code,"draft_cancelled")
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")
}
@(test)
executor_draft_exact_cancel_retains_dispatched_charge_until_trusted_absence :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,o,r:=draft_inputs(t,f)
    testing.expect_value(t,draft_command(f,o,"prepare","prepare").code,"ok")
    testing.expect_value(t,draft_command(f,o,"authorize","authorize",1100,r).code,"ok")
    native,_:=local_draft_native(&f.store,d.id);launch,_:=local_launch(&f.store,native.launch_id)
    testing.expect(t,local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
    testing.expect(t,local_dispatch_current(&f.store,launch,f.owner2.public,1100))
    cancelled:=draft_command(f,o,"cancel","cancel",1200)
    testing.expect_value(t,body_field(cancelled,"launch_state"),"stopping")
    testing.expect(t,!local_dispatch_current(&f.store,launch,f.owner2.public,1200))
    raw:=signed(o,"local_draft",&f.owner2)
    testing.expect(t,local_draft_command(&f.store,raw,f.owner2.public,9000).replay)
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,launch.incarnation,true}))
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,launch.incarnation,false}))
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")
}
@(test)
executor_draft_wrong_revision_digest_method_and_operation_conflicts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    _,o,_:=draft_inputs(t,f)
    testing.expect_value(t,draft_command(f,o,"prepare","prepare").code,"ok")
    set(o,"draft_revision","2")
    testing.expect_value(t,draft_command(f,o,"cancel","cancel").code,"draft_conflict")
    set(o,"draft_revision","1");set(o,"configuration_digest",strings.repeat("e",64,context.temp_allocator))
    testing.expect_value(t,draft_command(f,o,"inspect","inspect").code,"draft_conflict")
    native,_:=local_draft_native(&f.store,field(o,"draft_id"))
    set(o,"configuration_digest",contracts.owner_payload_digest(native.configuration))
    testing.expect_value(t,draft_command(f,o,"cancel","prepare").code,"operation_conflict")
    testing.expect_value(t,draft_command(f,o,"cancel","cancel").code,"ok")
    testing.expect_value(t,draft_command(f,o,"cancel","cancel-again").code,"ok")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_local_drafts SET material='{}'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_local_drafts"))
}

@(test)
executor_draft_authorize_and_cancel_failed_commit_roll_back_receipts_and_quota :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    d,o,r:=draft_inputs(t,f)
    testing.expect_value(t,draft_command(f,o,"prepare","prepare").code,"ok")
    testing.expect(t,exec(f.store.db,"CREATE TABLE draft_commit_fault(id TEXT REFERENCES executor_local_drafts(draft_id) DEFERRABLE INITIALLY DEFERRED)"))
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER draft_commit_fault_trigger AFTER INSERT ON executor_local_draft_receipts BEGIN INSERT INTO draft_commit_fault VALUES('missing'); END"))
    testing.expect_value(t,draft_command(f,o,"authorize","authorize",1100,r).code,"storage_error")
    retained,_:=local_draft_native(&f.store,d.id);testing.expect(t,retained.state=="prepared" && retained.launch_id=="")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_local_launches),(SELECT count(*) FROM executor_local_draft_receipts)")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"0","1"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER draft_commit_fault_trigger"))
    testing.expect_value(t,draft_command(f,o,"authorize","authorize",1100,r).code,"ok")
    retained,_=local_draft_native(&f.store,d.id)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER draft_commit_fault_trigger AFTER INSERT ON executor_local_draft_receipts BEGIN INSERT INTO draft_commit_fault VALUES('missing'); END"))
    testing.expect_value(t,draft_command(f,o,"cancel","cancel",1200).code,"storage_error")
    current,_:=local_launch(&f.store,retained.launch_id);testing.expect_value(t,current.state,"admitted")
    unchanged,_:=local_draft_native(&f.store,d.id);testing.expect_value(t,unchanged.state,"authorized")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM executor_live_resources),(SELECT count(*) FROM executor_local_draft_receipts)")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"1","2"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER draft_commit_fault_trigger"))
    testing.expect_value(t,draft_command(f,o,"cancel","cancel",1200).code,"ok")
}
@(test)
executor_draft_signed_cancel_races_dispatch_without_refunding_uncertain_child :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for _ in 0..<12 {
        f:=fixture(t)
        d,o,r:=draft_inputs(t,f)
        testing.expect_value(t,draft_command(f,o,"prepare","prepare").code,"ok")
        testing.expect_value(t,draft_command(f,o,"authorize","authorize",1100,r).code,"ok")
        native,_:=local_draft_native(&f.store,d.id);launch,_:=local_launch(&f.store,native.launch_id)
        set(o,"method","cancel");set(o,"operation_id","cancel")
        raw:=signed(o,"local_draft",&f.owner2)
        Job :: struct {f:^Fixture,launch:Local_Launch,resources:Local_Resources,raw:string,barrier:^sync.Barrier,cancel,ok:bool}
        barrier:sync.Barrier;sync.barrier_init(&barrier,3)
        jobs:=[2]Job{{f,launch,r,raw,&barrier,true,false},{f,launch,r,raw,&barrier,false,false}}
        threads:[2]^thread.Thread
        for i in 0..<2 {
            threads[i]=thread.create_and_start_with_data(&jobs[i],proc(data:rawptr) {
                context.allocator=context.temp_allocator
                j:=(^Job)(data);sync.barrier_wait(j.barrier)
                if j.cancel {j.ok=local_draft_command(&j.f.store,j.raw,j.f.owner2.public,1100).code=="ok"}
                else {j.ok=local_begin_dispatch(&j.f.store,j.launch,j.f.owner2.public,1100,j.resources)}
            })
        }
        sync.barrier_wait(&barrier)
        for th in threads {thread.join(th);thread.destroy(th)}
        testing.expect(t,jobs[0].ok)
        current,_:=local_launch(&f.store,launch.id)
        rows,_:=query(f.store.db,"SELECT count(*) FROM executor_live_resources")
        if jobs[1].ok {
            testing.expect_value(t,current.state,"stopping");testing.expect_value(t,rows[0][0],"1")
        } else {
            testing.expect_value(t,current.state,"released");testing.expect_value(t,rows[0][0],"0")
        }
        destroy(f)
    }
}
@(test)
executor_draft_v7_migration_collision_retains_exact_live_local_child :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    o,c,r:=local_inputs(t,f)
    launch:=local_snapshot(t,f,local_admit(f,o,c))
    testing.expect(t,local_begin_dispatch(&f.store,launch,f.owner2.public,1100,r))
    testing.expect(t,observe_local_child(&f.store,launch,Child_Observation{launch.instance,launch.launch_key,1,true}))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_local_draft_receipts; DROP TABLE executor_local_drafts; PRAGMA legacy_alter_table=ON; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO runtime_v8_fixture;"))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_commands; DROP TABLE executor_legacy_resources; DROP TABLE executor_legacy_barriers;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=9","schema_version=7",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,7,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM runtime_v8_fixture; DROP TABLE runtime_v8_fixture; CREATE VIEW executor_local_drafts AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT launch_key FROM executor_local_launches),(SELECT state FROM executor_local_launches) FROM executor_runtime")
    testing.expect(t,len(rows)==1 && rows[0][0]=="7" && rows[0][1]=="1" && rows[0][2]==launch.launch_key && rows[0][3]=="active")
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_local_drafts"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT launch_key FROM executor_local_launches),(SELECT state FROM executor_local_launches) FROM executor_runtime")
    testing.expect(t,len(rows)==1 && rows[0][0]=="9" && rows[0][1]=="2" && rows[0][2]==launch.launch_key && rows[0][3]=="active")
    // Retained shared-admission triggers must reference the NEW runtime, not
    // SQLite's temporary rename target; the live child still excludes a rival.
    p:=document("prepare");set(p,"executor_incarnation","2")
    testing.expect(t,complete_recovery(&f.store,1200)==false)
    recovered,_:=local_launch(&f.store,launch.id)
    testing.expect(t,observe_local_child(&f.store,recovered,Child_Observation{launch.instance,launch.launch_key,2,true}))
    testing.expect(t,complete_recovery(&f.store,1200))
    testing.expect_value(t,reserve(f,p,&f.owner1,1200).code,"resource_conflict")
}
