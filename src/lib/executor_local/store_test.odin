#+feature dynamic-literals
package executor_local
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "core:thread"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

Key :: struct {private:ecdsa.Private_Key,public:contracts.Owner_Verified_Key}
Fixture :: struct {store:Store,operator,owner1,owner2:Key,path:string}
sequence:i64
new_key :: proc(t:^testing.T,id:string)->Key {
    k:Key
    testing.expect(t,vault.p256_private_key_generate(&k.private))
    pub:[65]byte;ecdsa.private_key_public_bytes(&k.private,pub[:])
    k.public={"account",id,id,strings.clone(vault.hex_encode_lower(pub[:],context.temp_allocator)),"bridge",true,false}
    return k
}
fixture :: proc(t:^testing.T)->^Fixture {
    f:=new(Fixture)
    f.operator=new_key(t,"executor");f.operator.public.key_id="operator"
    f.owner1=new_key(t,"owner1");f.owner2=new_key(t,"owner2")
    f.path=fmt.aprintf("%s/.cache/heimdall-tests/executor-%d-%d.sqlite",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()),sync.atomic_add(&sequence,1))
    if !testing.expect(t,open(&f.store,f.path,"account","executor","operator")) do testing.fail_now(t,"open executor")
    return f
}
destroy :: proc(f:^Fixture) {
    close(&f.store)
    for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",f.path,suffix))
    for k in ([]^Key{&f.operator,&f.owner1,&f.owner2}) {ecdsa.private_key_clear(&k.private);delete(k.public.public_key)}
    delete(f.path);free(f)
}
document :: proc(kind:string)->json.Object {
    v,_:=contracts.owner_content_document(#load("../../contracts/fixtures/executor-v1.json",string));root,_:=v.(json.Object);entries,_:=root["valid"].(json.Array)
    for item in entries {row,_:=item.(json.Object);if field(row,"kind")==kind {o,_:=contracts.executor_parse(field(row,"raw"),kind);return o}}
    return nil
}
set :: proc(o:json.Object,key,value:string) {m:=o;m[key]=json.String(value)}
signed :: proc(o:json.Object,kind:string,key:^Key)->string {
    canonical,ok:=contracts.executor_canonical(kind,o)
    if !ok do return encode(o)
    sig,s_ok:=vault.sign_p256(&key.private,transmute([]byte)canonical)
    if !s_ok do return ""
    m:=o;m["signature"]=json.String(vault.hex_encode_lower(sig.sig[:],context.temp_allocator))
    return encode(m)
}
policy :: proc(t:^testing.T,f:^Fixture) {
    testing.expect_value(t,install_policy(&f.store,signed(document("policy"),"policy",&f.operator),f.operator.public,1000).code,"ok")
}
resources :: proc(o:json.Object)->Resolved_Resources {return {field(o,"directory_key"),field(o,"provider_profile"),field(o,"instance_id"),field(o,"configuration_revision")}}
reserve :: proc(f:^Fixture,o:json.Object,key:^Key,now:i64=1000)->Result {return prepare(&f.store,signed(o,"prepare",key),key.public,now,resources(o))}
proof :: proc(o:json.Object)->Current_Owner_Fence {return {true,field(o,"prepare_digest"),num(o,"owner_incarnation"),num(o,"owner_commit_seq")}}
activate_document :: proc(prepared:json.Object)->json.Object {
    o:=document("action");digest,_:=contracts.executor_digest("prepare",prepared);set(o,"prepare_digest",digest)
    return o
}
perform :: proc(f:^Fixture,o:json.Object,key:^Key,current:=true,now:i64=1100)->Result {
    return action(&f.store,signed(o,"action",key),key.public,now,proof(o) if current else Current_Owner_Fence{})
}
body_field :: proc(result:Result,key:string)->string {v,_:=contracts.owner_content_document(result.body);o,_:=v.(json.Object);return field(o,key)}
observation :: proc(f:^Fixture,id:string,present:bool)->Child_Observation {
    rows,_:=query(f.store.db,"SELECT instance_id,launch_key FROM executor_reservations WHERE reservation_id=?",id)
    return {rows[0][0],rows[0][1],f.store.incarnation,present}
}
@(test)
executor_signed_prepare_replay_activation_requires_owner_and_at_most_once_intent :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");raw:=signed(p,"prepare",&f.owner1)
    prepared:=prepare(&f.store,raw,f.owner1.public,1000,resources(p))
    testing.expect_value(t,prepared.code,"ok")
    testing.expect_value(t,body_field(prepared,"state"),"prepared")
    replay:=prepare(&f.store,raw,f.owner1.public,4000,resources(p))
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==prepared.body)
    changed:=document("prepare");set(changed,"instance_id","changed")
    testing.expect_value(t,reserve(f,changed,&f.owner1).code,"operation_conflict")
    a:=activate_document(p)
    testing.expect_value(t,perform(f,a,&f.owner1,false).code,"owner_fence_not_current")
    testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    intent,taken:=take_intent(&f.store,1200);testing.expect(t,taken && intent.kind=="launch")
    _,taken=take_intent(&f.store,1200);testing.expect(t,!taken,"ambiguous launch cannot be reissued")
    replay=perform(f,a,&f.owner1,false,6000);testing.expect(t,replay.code=="ok" && replay.replay)
    _,taken=take_intent(&f.store,6000);testing.expect(t,!taken,"historical activation receipt cannot launch")
    testing.expect(t,observe_child(&f.store,"reservation",observation(f,"reservation",true)))
}
@(test)
executor_multiple_owners_manual_warm_instance_directory_and_policy_drain :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    q:=document("prepare");set(q,"owner_bridge_id","owner2");set(q,"key_id","owner2");set(q,"operation_id","other_prepare");set(q,"reservation_id","other")
    testing.expect_value(t,reserve(f,q,&f.owner2).code,"resource_conflict")
    set(q,"slot_id","slot2")
    testing.expect_value(t,reserve(f,q,&f.owner2).code,"resource_conflict")
    set(q,"instance_id","instance2")
    testing.expect_value(t,reserve(f,q,&f.owner2).code,"resource_conflict")
    set(q,"directory_key",strings.repeat("c",64,context.temp_allocator));set(q,"purpose","warm")
    testing.expect_value(t,reserve(f,q,&f.owner2).code,"ok")
    policy2:=document("policy");set(policy2,"policy_revision","2")
    testing.expect_value(t,install_policy(&f.store,signed(policy2,"policy",&f.operator),f.operator.public,1100).code,"resources_not_drained")
    a:=activate_document(p);testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    testing.expect(t,expire(&f.store,6000))
    state,_:=result_body(&f.store,"reservation");testing.expect(t,strings.contains(state,"stopping"))
    q2:=document("prepare");set(q2,"operation_id","manual_prepare");set(q2,"reservation_id","manual");set(q2,"request_expires_ms","7000");set(q2,"prepare_until_ms","8000");set(q2,"purpose","manual")
    testing.expect_value(t,reserve(f,q2,&f.owner1,6000).code,"resource_conflict")
    testing.expect(t,observe_child(&f.store,"reservation",observation(f,"reservation",false)))
    testing.expect_value(t,reserve(f,q2,&f.owner1,6000).code,"ok")
}
@(test)
executor_restart_exact_observation_required_before_new_admission :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    a:=activate_document(p);testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    _,taken:=take_intent(&f.store,1200);testing.expect(t,taken)
    old:=observation(f,"reservation",false)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,f.store.incarnation,i64(2))
    testing.expect(t,!observe_child(&f.store,"reservation",old))
    testing.expect(t,!complete_recovery(&f.store,1300))
    pending:=document("prepare");set(pending,"reservation_id","new");set(pending,"operation_id","new");set(pending,"executor_incarnation","2")
    testing.expect_value(t,reserve(f,pending,&f.owner1,1300).code,"recovery_required")
    seen:=observation(f,"reservation",true);seen.launch_key="wrong"
    testing.expect(t,!observe_child(&f.store,"reservation",seen))
    testing.expect(t,observe_child(&f.store,"reservation",observation(f,"reservation",true)))
    testing.expect(t,complete_recovery(&f.store,1300))
    testing.expect_value(t,reserve(f,pending,&f.owner1,1300).code,"resource_conflict")
    stale:=activate_document(p);set(stale,"operation_id","old_activate")
    testing.expect_value(t,perform(f,stale,&f.owner1,true,1300).code,"stale_incarnation")
    testing.expect(t,observe_child(&f.store,"reservation",observation(f,"reservation",false)))
    testing.expect_value(t,reserve(f,pending,&f.owner1,1300).code,"ok")
    testing.expect_value(t,perform(f,a,&f.owner1,false,1300).code,"ok")
}
@(test)
executor_statement_commit_failure_and_identity_fail_closed :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fail_prepare BEFORE INSERT ON executor_receipts BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,reserve(f,p,&f.owner1).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_reservations),(SELECT count(*) FROM executor_receipts),(SELECT count(*) FROM executor_owner_watermarks)")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"0","0","0"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_prepare; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE deferred(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_prepare AFTER INSERT ON executor_receipts BEGIN INSERT INTO deferred VALUES(1); END"))
    testing.expect_value(t,reserve(f,p,&f.owner1).code,"storage_error")
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_reservations");testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_prepare"))
    testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    bad_key:=f.owner1.public;bad_key.revoked=true
    testing.expect_value(t,prepare(&f.store,signed(p,"prepare",&f.owner1),bad_key,1000,resources(p)).code,"invalid_scope")
    bad_key=f.owner1.public;bad_key.account_id="other"
    testing.expect_value(t,prepare(&f.store,signed(p,"prepare",&f.owner1),bad_key,1000,resources(p)).code,"invalid_scope")
    wrong:=resources(p);wrong.directory_key=""
    historical:=prepare(&f.store,signed(p,"prepare",&f.owner1),f.owner1.public,4000,wrong)
    testing.expect(t,historical.code=="ok" && historical.replay,"resource validation is mutation admission, not historical read authority")
    fresh:=document("prepare");set(fresh,"operation_id","fresh_bad_resources")
    testing.expect_value(t,prepare(&f.store,signed(fresh,"prepare",&f.owner1),f.owner1.public,1000,wrong).code,"invalid_resources")
    other:Store
    testing.expect(t,!open(&other,f.path,"account","executor","operator"),"second writer cannot open ledger")
    close(&f.store)
    testing.expect(t,!open(&f.store,f.path,"other","executor","operator"))
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,complete_recovery(&f.store,1000))
}

@(test)
executor_two_owners_race_one_slot_exactly_one_prepare_commits :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    Job :: struct {store:^Store,raw:string,key:contracts.Owner_Verified_Key,resolved:Resolved_Resources,barrier:^sync.Barrier,status:int}
    barrier:sync.Barrier;sync.barrier_init(&barrier,3)
    jobs:[2]Job;threads:[2]^thread.Thread
    for i in 0..<2 {
        p:=document("prepare");key:=&f.owner1
        if i==1 {key=&f.owner2;set(p,"owner_bridge_id","owner2");set(p,"key_id","owner2");set(p,"reservation_id","reservation2");set(p,"instance_id","instance2");set(p,"directory_key",strings.repeat("c",64,context.temp_allocator))}
        jobs[i]=Job{&f.store,signed(p,"prepare",key),key.public,resources(p),&barrier,0}
        threads[i]=thread.create_and_start_with_data(&jobs[i],proc(data:rawptr) {
            context.allocator=context.temp_allocator
            job:=(^Job)(data);sync.barrier_wait(job.barrier)
            result:=prepare(job.store,job.raw,job.key,1000,job.resolved)
            job.status=1 if result.code=="ok" else (2 if result.code=="resource_conflict" else 3)
        })
    }
    sync.barrier_wait(&barrier)
    for th in threads {thread.join(th);thread.destroy(th)}
    wins:=0;conflicts:=0
    for job in jobs {
        if job.status==1 do wins+=1
        if job.status==2 do conflicts+=1
    }
    testing.expect_value(t,wins,1);testing.expect_value(t,conflicts,1)
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_reservations),(SELECT count(*) FROM executor_receipts)")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"1","1"}}))
}
@(test)
executor_expired_prepare_heartbeat_versions_and_stale_stop_cannot_hit_replacement :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    a:=activate_document(p)
    testing.expect_value(t,perform(f,a,&f.owner1,true,3000).code,"expired")
    testing.expect(t,expire(&f.store,3000))
    _,taken:=take_intent(&f.store,3000);testing.expect(t,!taken)
    // Create a new exact child/fence reusing the freed instance and slot.
    p2:=document("prepare");set(p2,"reservation_id","replacement");set(p2,"operation_id","replacement_prepare");set(p2,"request_expires_ms","4000");set(p2,"prepare_until_ms","5000");set(p2,"grant_generation","2")
    testing.expect_value(t,reserve(f,p2,&f.owner1,3000).code,"ok")
    a2:=activate_document(p2);set(a2,"reservation_id","replacement");set(a2,"operation_id","replacement_activate");set(a2,"grant_generation","2");set(a2,"request_expires_ms","4000")
    testing.expect_value(t,perform(f,a2,&f.owner1,true,3100).code,"ok")
    old_stop:=activate_document(p);set(old_stop,"method","stop");set(old_stop,"operation_id","old_stop");set(old_stop,"request_expires_ms","4000")
    testing.expect_value(t,perform(f,old_stop,&f.owner1,true,3200).code,"retired")
    heartbeat:=activate_document(p2);set(heartbeat,"reservation_id","replacement");set(heartbeat,"grant_generation","2");set(heartbeat,"method","heartbeat");set(heartbeat,"operation_id","renew");set(heartbeat,"deadline_version","2");set(heartbeat,"expires_ms","7000");set(heartbeat,"request_expires_ms","4000")
    testing.expect_value(t,perform(f,heartbeat,&f.owner1,true,3200).code,"ok")
    set(heartbeat,"operation_id","stale_renew");testing.expect_value(t,perform(f,heartbeat,&f.owner1,true,3300).code,"stale_deadline")
    stop:=activate_document(p2);set(stop,"reservation_id","replacement");set(stop,"grant_generation","2");set(stop,"method","stop");set(stop,"operation_id","stale_stop");set(stop,"request_expires_ms","4000")
    testing.expect_value(t,perform(f,stop,&f.owner1,true,3300).code,"stale_deadline")
    set(stop,"operation_id","stop");set(stop,"deadline_version","2")
    testing.expect_value(t,perform(f,stop,&f.owner1,true,3300).code,"ok")
    intent,ok:=take_intent(&f.store,3300);testing.expect(t,ok && intent.kind=="stop" && intent.reservation=="replacement")
    _,ok=take_intent(&f.store,3300);testing.expect(t,!ok,"no old launch can follow queued stop")
}
@(test)
executor_clock_regression_persists_quarantine_and_policy_requires_exact_host :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare")
    testing.expect_value(t,reserve(f,p,&f.owner1,999).code,"clock_uncertain")
    rows,_:=query(f.store.db,"SELECT recovery_state FROM executor_runtime");testing.expect_value(t,rows[0][0],"clock_uncertain")
    testing.expect_value(t,reserve(f,p,&f.owner1,1000).code,"recovery_required")
    testing.expect(t,complete_recovery(&f.store,1000))
    testing.expect_value(t,reserve(f,p,&f.owner1,1000).code,"ok")
    bad:=document("policy");set(bad,"policy_revision","2")
    testing.expect_value(t,install_policy(&f.store,signed(bad,"policy",&f.owner1),f.owner1.public,1100).code,"invalid_scope")
    key:=f.operator.public;key.revoked=true
    testing.expect_value(t,install_policy(&f.store,signed(document("policy"),"policy",&f.operator),key,1100).code,"invalid_scope")
    changed:=document("policy");set(changed,"device_capacity","3")
    testing.expect_value(t,install_policy(&f.store,signed(changed,"policy",&f.operator),f.operator.public,1100).code,"operation_conflict")
    testing.expect(t,expire(&f.store,4000))
    testing.expect_value(t,install_policy(&f.store,signed(bad,"policy",&f.operator),f.operator.public,4000).code,"ok")
    stale:=document("prepare");set(stale,"reservation_id","new");set(stale,"operation_id","new");set(stale,"prepare_until_ms","6000");set(stale,"request_expires_ms","5000")
    testing.expect_value(t,reserve(f,stale,&f.owner1,4000).code,"stale_policy")
}

sign_receipt :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,valid:=contracts.executor_canonical(kind,o)
    if !valid do return "",false
    sig,ok:=vault.sign_p256(&((^Key)(ctx)).private,transmute([]byte)canonical)
    if !ok do return "",false
    return vault.hex_encode_lower(sig.sig[:],context.temp_allocator),true
}
@(test)
executor_signed_receipts_bind_exact_result_and_never_relabel_old_incarnation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");raw:=signed(p,"prepare",&f.owner1)
    result:=prepare(&f.store,raw,f.owner1.public,1000,resources(p))
    if !testing.expect_value(t,result.code,"ok") do return
    sealed,ok:=seal_receipt(&f.store,p,"prepare",result,Signer{&f.operator,sign_receipt})
    if !testing.expect(t,ok) do return
    receipt,parsed:=contracts.executor_parse(sealed,"receipt")
    testing.expect(t,parsed && contracts.executor_verify("receipt",receipt,f.operator.public))
    testing.expect(t,contracts.executor_receipt_matches(receipt,p,"prepare",f.operator.public,1000))
    testing.expect(t,!contracts.executor_verify("receipt",receipt,f.owner1.public))
    set(receipt,"historical","1");testing.expect(t,!contracts.executor_verify("receipt",receipt,f.operator.public))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    result=prepare(&f.store,raw,f.owner1.public,4000,resources(p))
    testing.expect(t,result.code=="ok" && result.replay)
    sealed,ok=seal_receipt(&f.store,p,"prepare",result,Signer{&f.operator,sign_receipt})
    receipt,parsed=contracts.executor_parse(sealed,"receipt")
    testing.expect(t,ok && parsed && contracts.executor_verify("receipt",receipt,f.operator.public))
    testing.expect(t,!contracts.executor_receipt_matches(receipt,p,"prepare",f.operator.public,1000))
    testing.expect(t,contracts.executor_receipt_matches(receipt,p,"prepare",f.operator.public,1000,false))
    testing.expect_value(t,field(receipt,"historical"),"1")
    testing.expect_value(t,field(receipt,"executor_incarnation"),"1")
    testing.expect_value(t,f.store.incarnation,i64(2))
}

@(test)
executor_reconciled_child_keeps_physical_incarnation_under_new_runtime_receipts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    a:=activate_document(p);testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    _,taken:=take_intent(&f.store,1200);testing.expect(t,taken)
    testing.expect(t,observe_child(&f.store,"reservation",observation(f,"reservation",true)))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,observe_child(&f.store,"reservation",observation(f,"reservation",true)))
    testing.expect(t,complete_recovery(&f.store,1300))
    renew:=activate_document(p);set(renew,"executor_incarnation","2");set(renew,"operation_id","new_runtime_renew");set(renew,"method","heartbeat");set(renew,"deadline_version","2");set(renew,"expires_ms","7000")
    result:=perform(f,renew,&f.owner1,true,1300);testing.expect_value(t,result.code,"ok")
    sealed,ok:=seal_receipt(&f.store,renew,"action",result,Signer{&f.operator,sign_receipt})
    receipt,parsed:=contracts.executor_parse(sealed,"receipt")
    testing.expect(t,ok && parsed && contracts.executor_receipt_matches(receipt,renew,"action",f.operator.public,1300))
    testing.expect_value(t,field(receipt,"executor_incarnation"),"2")
    testing.expect_value(t,field(receipt,"child_incarnation"),"1")
    old:=activate_document(p);set(old,"operation_id","old_runtime_renew");set(old,"method","heartbeat");set(old,"deadline_version","3");set(old,"expires_ms","8000")
    testing.expect_value(t,perform(f,old,&f.owner1,true,1400).code,"stale_incarnation")
}

@(test)
executor_activation_and_stop_failures_roll_back_all_effects :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,"CREATE TABLE fault_parent(id INTEGER PRIMARY KEY); CREATE TABLE fault_ref(id INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fault_activate AFTER INSERT ON executor_intents BEGIN INSERT INTO fault_ref VALUES(1); END"))
    a:=activate_document(p)
    testing.expect_value(t,perform(f,a,&f.owner1).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT state,expires_ms,(SELECT count(*) FROM executor_intents),(SELECT count(*) FROM executor_receipts) FROM executor_reservations")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"prepared","3000","0","1"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fault_activate"))
    testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fault_stop BEFORE INSERT ON executor_receipts WHEN NEW.operation_id='stop' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    stop:=activate_document(p);set(stop,"method","stop");set(stop,"operation_id","stop")
    testing.expect_value(t,perform(f,stop,&f.owner1).code,"storage_error")
    rows,_=query(f.store.db,"SELECT state,(SELECT count(*) FROM executor_intents),(SELECT count(*) FROM executor_receipts) FROM executor_reservations")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"active","1","2"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fault_stop"))
    testing.expect_value(t,perform(f,stop,&f.owner1).code,"ok")
}
@(test)
executor_policy_commit_failure_preserves_prior_capacity_and_slots :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    testing.expect(t,exec(f.store.db,"CREATE TABLE fault_parent(id INTEGER PRIMARY KEY); CREATE TABLE fault_ref(id INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fault_policy AFTER INSERT ON executor_policies BEGIN INSERT INTO fault_ref VALUES(1); END"))
    policy2:=document("policy");set(policy2,"policy_revision","2");set(policy2,"device_capacity","1");set(policy2,"slots_json",`[{"slot_id":"slot2","provider_profile":"custom","enabled":"1"}]`)
    raw:=signed(policy2,"policy",&f.operator)
    testing.expect_value(t,install_policy(&f.store,raw,f.operator.public,1100).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT policy_revision,device_capacity,(SELECT count(*) FROM executor_policies),(SELECT count(*) FROM executor_slots WHERE enabled=1 AND provider_profile='default') FROM executor_runtime")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"1","2","1","2"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fault_policy"))
    testing.expect_value(t,install_policy(&f.store,raw,f.operator.public,1100).code,"ok")
    rows,_=query(f.store.db,"SELECT policy_revision,device_capacity,(SELECT count(*) FROM executor_slots WHERE enabled=1 AND provider_profile='custom') FROM executor_runtime")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"2","1","1"}}))
}
@(test)
executor_owner_incarnation_watermark_and_cross_owner_queries_fail_closed :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    a:=activate_document(p);testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    newer:=document("prepare");set(newer,"owner_incarnation","2");set(newer,"operation_id","new_owner_prepare");set(newer,"reservation_id","new_owner_reservation");set(newer,"slot_id","slot2");set(newer,"instance_id","instance2");set(newer,"directory_key",strings.repeat("c",64,context.temp_allocator))
    testing.expect_value(t,reserve(f,newer,&f.owner1,1200).code,"ok")
    renew:=activate_document(p);set(renew,"method","heartbeat");set(renew,"operation_id","old_owner_renew");set(renew,"deadline_version","2");set(renew,"expires_ms","7000")
    testing.expect_value(t,perform(f,renew,&f.owner1,true,1300).code,"stale_owner")
    set(renew,"operation_id","new_owner_renew");set(renew,"owner_incarnation","2");set(renew,"owner_commit_seq","2")
    testing.expect_value(t,perform(f,renew,&f.owner1,true,1300).code,"ok")
    q:=activate_document(p);set(q,"method","query");set(q,"operation_id","query");set(q,"owner_bridge_id","owner2");set(q,"key_id","owner2")
    testing.expect_value(t,perform(f,q,&f.owner2,true,1300).code,"invalid_scope")
    q=activate_document(p);set(q,"method","query");set(q,"operation_id","query");set(q,"chain_id","other_chain")
    testing.expect_value(t,perform(f,q,&f.owner1,true,1300).code,"invalid_scope")
}
@(test)
executor_retention_capacity_preserves_replay_and_safety_stop :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");prepared:=reserve(f,p,&f.owner1);testing.expect_value(t,prepared.code,"ok")
    a:=activate_document(p);testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    testing.expect(t,exec(f.store.db,`WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000)
      INSERT INTO executor_receipts SELECT 'fixture',printf('retained_%d',i),'action','fixture','reservation','{}' FROM n`))
    replay:=reserve(f,p,&f.owner1,6000);testing.expect(t,replay.code=="ok" && replay.replay && replay.body==prepared.body)
    fresh:=document("prepare");set(fresh,"operation_id","fresh");set(fresh,"reservation_id","fresh")
    testing.expect_value(t,reserve(f,fresh,&f.owner1,1200).code,"retention_capacity")
    testing.expect(t,expire(&f.store,6000))
    intent,ok:=take_intent(&f.store,6000);testing.expect(t,ok && intent.kind=="stop")
    testing.expect(t,observe_child(&f.store,"reservation",observation(f,"reservation",false)))
}
