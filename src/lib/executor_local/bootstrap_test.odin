#+feature dynamic-literals
package executor_local
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

Bootstrap_Fixture :: struct {p,a,b:json.Object,raw,body,action,configuration:string}
bootstrap_fixture :: proc(t:^testing.T,f:^Fixture)->Bootstrap_Fixture {
    policy(t,f)
    consent,selection,res:=issuance_inputs(f)
    issued:=issue_fixture(f,consent,selection,res)
    testing.expect_value(t,issued.code,"ok")
    value,_:=contracts.owner_content_document(issued.body);bundle,_:=value.(json.Object)
    configuration:=field(bundle,"configuration")
    c,_:=contracts.owner_parse(configuration,"remote_configuration")
    p:=document("prepare")
    for name in ([15]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","instance_id",
        "launch_epoch","run_count","token_generation","configuration_revision","executor_incarnation","policy_revision","slot_id","provider_profile"}) {set(p,name,field(c,name))}
    set(p,"directory_key",field(c,"directory_key"))
    resources,ok:=issued_prepare_resources(&f.store,p);testing.expect(t,ok)
    raw_p:=signed(p,"prepare",&f.owner1)
    testing.expect_value(t,prepare(&f.store,raw_p,f.owner1.public,1200,resources).code,"ok")
    a:=activate_document(p)
    raw_a:=signed(a,"action",&f.owner1)
    testing.expect_value(t,action(&f.store,raw_a,f.owner1.public,1250,proof(a)).code,"ok")
    testing.expect_value(t,bind_owner(&f.store,genesis_sign(genesis_document(),&f.owner2,&f.owner1),f.owner2.public,f.owner1.public,1250).code,"ok")
    rows,_:=query(f.store.db,"SELECT launch_key FROM executor_reservations")
    b:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("bootstrap") {
        v:=field(p,entry.name)
        if v=="" do v=field(a,entry.name)
        b[entry.name]=json.String(v)
    }
    body:=encode(struct{agents_md,memory_md,task_md,skills_json:string}{"# Authoritative owner instructions","","# Assigned task","[]"})
    pd,_:=contracts.executor_digest("prepare",p);ad,_:=contracts.executor_digest("action",a)
    for pair in ([8][2]string{{"prepare_digest",pd},{"action_digest",ad},{"configuration_digest",contracts.owner_payload_digest(configuration)},
        {"body_digest",contracts.owner_payload_digest(body)},{"launch_key",rows[0][0]},{"issued_ms","1250"},{"request_expires_ms","1900"},{"key_id",f.owner1.public.key_id}}) {set(b,pair[0],pair[1])}
    raw:=signed(b,"bootstrap",&f.owner1)
    return {p,a,b,raw,body,raw_a,configuration}
}
@(test)
executor_bootstrap_requires_committed_activation_and_replays_without_relaunch_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,{}).code,"owner_fence_not_current")
    intent,taken:=take_intent(&f.store,1300);testing.expect(t,taken)
    _,available:=launch_material(&f.store,intent,1300);testing.expect(t,!available,"activation alone has no bootstrap/credentials")
    result:=accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a))
    testing.expect_value(t,result.code,"ok")
    material,ready:=launch_material(&f.store,intent,1300);testing.expect(t,ready)
    testing.expect(t,material.bootstrap==x.raw && material.body==x.body && material.configuration==x.configuration)
    testing.expect(t,contracts.owner_payload_digest(material.token_secret)==field(x.p,"token_generation"))
    testing.expect(t,!strings.contains(result.body,material.token_secret))
    // The accepted bytes survive a reply loss/expiry, not a launch grant.
    historical:=accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,3000,{})
    testing.expect(t,historical.code=="ok" && historical.replay && historical.body==result.body)
    changed:=x.b;set(changed,"body_digest",contracts.owner_payload_digest("changed"))
    testing.expect_value(t,accept_bootstrap(&f.store,signed(changed,"bootstrap",&f.owner1),"changed",x.action,f.owner1.public,1300,proof(x.a)).code,"operation_conflict")
    revoked:=f.owner1.public;revoked.revoked=true
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,revoked,1300,proof(x.a)).code,"invalid_scope")
    testing.expect(t,begin_dispatch(&f.store,intent,1300))
    _,ready=launch_material(&f.store,intent,1300);testing.expect(t,!ready,"crossed dispatch never rematerializes a running child")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_bootstraps SET body='changed'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_bootstraps"))
    testing.expect(t,expire(&f.store,5000))
    _,ready=launch_material(&f.store,intent,5000);testing.expect(t,!ready)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    historical=accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,3000,{})
    testing.expect(t,historical.code=="ok" && historical.replay)
    _,ready=launch_material(&f.store,intent,1300);testing.expect(t,!ready,"old incarnation never recovers fresh launch credentials")
}
@(test)
executor_bootstrap_rolls_back_commit_failure_and_rejects_substituted_activation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    wrong:=x.a;set(wrong,"operation_id","uncommitted")
    wrong_raw:=signed(wrong,"action",&f.owner1)
    ad,_:=contracts.executor_digest("action",wrong)
    set(x.b,"action_digest",ad)
    changed:=signed(x.b,"bootstrap",&f.owner1)
    testing.expect_value(t,accept_bootstrap(&f.store,changed,x.body,wrong_raw,f.owner1.public,1300,proof(wrong)).code,"activation_not_committed")
    ad,_=contracts.executor_digest("action",x.a);set(x.b,"action_digest",ad)
    // x.a aliases wrong; restore the original committed action.
    original,_:=contracts.executor_parse(x.action,"action")
    ad,_=contracts.executor_digest("action",original);set(x.b,"action_digest",ad)
    raw:=signed(x.b,"bootstrap",&f.owner1)
    testing.expect(t,exec(f.store.db,"CREATE TABLE bootstrap_parent(id INTEGER PRIMARY KEY); CREATE TABLE bootstrap_probe(id INTEGER REFERENCES bootstrap_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER bootstrap_commit_fail AFTER INSERT ON executor_bootstraps BEGIN INSERT INTO bootstrap_probe VALUES(1); END;"))
    testing.expect_value(t,accept_bootstrap(&f.store,raw,x.body,x.action,f.owner1.public,1300,proof(original)).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_bootstraps),(SELECT count(*) FROM bootstrap_probe)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER bootstrap_commit_fail"))
    testing.expect_value(t,accept_bootstrap(&f.store,raw,x.body,x.action,f.owner1.public,1300,proof(original)).code,"ok")
}

@(test)
executor_bootstrap_v3_upgrade_collision_rolls_back_without_reissuing_credentials :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    creds,_:=query(f.store.db,"SELECT token_secret,configuration FROM executor_issuances")
    legacy_remove_v11_journal_fixture(t,&f.store)
    testing.expect(t,exec(f.store.db,local_schema_drop_for_test))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_renewals; DROP TABLE executor_controls; DROP TABLE executor_readiness; DROP TABLE executor_bootstraps; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO executor_runtime_v4;"))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_commands; DROP TABLE executor_legacy_resources; DROP TABLE executor_legacy_barriers;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=11","schema_version=3",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,3,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v4; DROP TABLE executor_runtime_v4; CREATE TABLE executor_bootstraps(collision TEXT);"))
    close(&f.store)
    testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db)==0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT token_secret FROM executor_issuances) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="3" && rows[0][1]=="1" && rows[0][2]=="active" && rows[0][3]==creds[0][0])
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_bootstraps"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT configuration FROM executor_issuances) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="11" && rows[0][1]=="2" && rows[0][2]=="active" && rows[0][3]==creds[0][1])
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"stale_intent")
}
