#+feature dynamic-literals
package executor_local
import "core:encoding/json"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"

issuance_inputs :: proc(f:^Fixture)->(string,string,Issuance_Resources) {
    f.owner2.public.kind="device"
    mapping:=document("directory")
    _=install_directory(&f.store,signed(mapping,"directory",&f.operator),f.operator.public,1000,"/repo")
    selection:=encode(document("issuance_selection"))
    c:=document("issuance_consent");set(c,"selection_digest",contracts.owner_payload_digest(selection))
    consent:=signed(c,"issuance_consent",&f.owner2)
    return consent,selection,Issuance_Resources{contracts.owner_payload_digest(selection),directory_key("executor","/repo"),"/repo",true}
}
issue_fixture :: proc(f:^Fixture,consent,selection:string,resources:Issuance_Resources,now:i64=1100)->Result {
    return issue(&f.store,consent,selection,f.owner2.public,f.operator.public,now,resources,Signer{&f.operator,sign_receipt})
}
issuance_valid :: proc(f:^Fixture,result:Result,consent,selection:string,now:i64,current:=true)->bool {
    c,_:=contracts.executor_parse(consent,"issuance_consent")
    v,_:=contracts.owner_content_document(result.body);body,_:=v.(json.Object)
    r,_:=contracts.executor_parse(field(body,"issuance_receipt"),"issuance_receipt")
    a,_:=contracts.executor_parse(field(body,"attestation"),"enrollment")
    return contracts.executor_issuance_matches(r,c,selection,field(body,"configuration"),a,f.owner2.public,f.operator.public,now,current)
}
@(test)
executor_issuance_generates_exact_identity_once_and_retains_historical_replay :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    consent,selection,resources:=issuance_inputs(f)
    result:=issue_fixture(f,consent,selection,resources)
    if !testing.expect_value(t,result.code,"ok") do return
    testing.expect(t,issuance_valid(f,result,consent,selection,1200))
    testing.expect(t,!issuance_valid(f,result,consent,selection,2000))
    testing.expect(t,issuance_valid(f,result,consent,selection,3000,false))
    body,_:=contracts.owner_content_document(result.body);bundle,_:=body.(json.Object)
    config,valid:=contracts.owner_parse(field(bundle,"configuration"),"remote_configuration");testing.expect(t,valid)
    testing.expect_value(t,field(config,"model"),"模型🚀")
    testing.expect(t,strings.has_prefix(field(config,"instance_id"),"inst_"))
    rows,_:=query(f.store.db,"SELECT instance_id,token_secret,configuration,(SELECT count(*) FROM executor_reservations),(SELECT count(*) FROM executor_intents) FROM executor_issuances")
    testing.expect(t,len(rows)==1 && rows[0][0]==field(config,"instance_id"))
    testing.expect(t,!strings.contains(result.body,rows[0][1]),"credential must never enter response")
    testing.expect_value(t,field(config,"token_generation"),contracts.owner_payload_digest(rows[0][1]))
    testing.expect(t,rows[0][3]=="0" && rows[0][4]=="0","issuance creates neither reservation nor launch")
    replay:=issue(&f.store,consent,selection,f.owner2.public,f.operator.public,3000,{},{});testing.expect(t,replay.code=="ok" && replay.replay && replay.body==result.body)
    changed,_:=contracts.executor_parse(consent,"issuance_consent");set(changed,"task_id","changed")
    testing.expect_value(t,issue_fixture(f,signed(changed,"issuance_consent",&f.owner2),selection,{},3000).code,"operation_conflict")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    replay=issue(&f.store,consent,selection,f.owner2.public,f.operator.public,3000,{},{});testing.expect(t,replay.code=="ok" && replay.replay && replay.body==result.body)
    // Replaying a saved response never relabels the old physical incarnation.
    testing.expect_value(t,field(config,"executor_incarnation"),"1")
    testing.expect_value(t,f.store.incarnation,i64(2))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_issuances SET token_secret='other'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_issuances"))
}
@(test)
executor_issuance_denies_forgery_unresolved_resources_and_rolls_back_failed_commit :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    consent,selection,resources:=issuance_inputs(f)
    testing.expect_value(t,issue_fixture(f,consent,selection,{}).code,"invalid_resources")
    testing.expect_value(t,issue_fixture(f,consent,selection,resources,999).code,"expired")
    testing.expect_value(t,issue_fixture(f,consent,selection,resources,2000).code,"expired")
    forged:=f.owner2.public;forged.kind="bridge"
    testing.expect_value(t,issue(&f.store,consent,selection,forged,f.operator.public,1100,resources,Signer{&f.operator,sign_receipt}).code,"invalid_scope")
    revoked:=f.owner2.public;revoked.revoked=true
    testing.expect_value(t,issue(&f.store,consent,selection,revoked,f.operator.public,1100,resources,Signer{&f.operator,sign_receipt}).code,"invalid_scope")
    testing.expect_value(t,issue_fixture(f,consent,strings.concatenate({selection," "},context.temp_allocator),resources).code,"digest_mismatch")
    testing.expect_value(t,issue(&f.store,consent,selection,f.owner2.public,f.operator.public,1100,resources,Signer{&f.owner1,sign_receipt}).code,"signer_unavailable")
    // Deferred FK makes INSERT succeed and COMMIT fail, proving no success or
    // generated identity survives a transaction failure.
    testing.expect(t,exec(f.store.db,"CREATE TABLE issuance_parent(id INTEGER PRIMARY KEY); CREATE TABLE issuance_commit_probe(id INTEGER REFERENCES issuance_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER issuance_commit_fail AFTER INSERT ON executor_issuances BEGIN INSERT INTO issuance_commit_probe VALUES(1); END;"))
    testing.expect_value(t,issue_fixture(f,consent,selection,resources).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_issuances),(SELECT count(*) FROM issuance_commit_probe)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER issuance_commit_fail"))
    result:=issue_fixture(f,consent,selection,resources);testing.expect_value(t,result.code,"ok")
    revoked=f.operator.public;revoked.revoked=true
    testing.expect_value(t,issue(&f.store,consent,selection,f.owner2.public,revoked,3000,{},{}).code,"invalid_scope")
    second,_:=contracts.executor_parse(consent,"issuance_consent");set(second,"operation_id","second")
    next:=issue_fixture(f,signed(second,"issuance_consent",&f.owner2),selection,resources)
    testing.expect_value(t,next.code,"ok")
    rows,_=query(f.store.db,"SELECT count(DISTINCT instance_id),count(DISTINCT token_secret) FROM executor_issuances")
    testing.expect(t,rows[0][0]=="2" && rows[0][1]=="2")
}
@(test)
executor_issuance_v1_migration_is_atomic_and_preserves_live_reservations :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    testing.expect_value(t,perform(f,activate_document(p),&f.owner1).code,"ok")
    // Reconstruct the actual prior schema, retaining live V1 reservations.
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_chain_owners; DROP TABLE executor_enrollment_pin; DROP TABLE executor_directories; DROP TABLE executor_issuances; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO executor_runtime_v2;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=3","schema_version=1",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,1,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v2; DROP TABLE executor_runtime_v2; CREATE TABLE executor_issuances(collision TEXT);"))
    close(&f.store)
    testing.expect(t,!open(&f.store,f.path,"account","executor","operator"),"migration collision must fail closed")
    // Inspect failed migration on a raw connection; original schema and child survive.
    testing.expect(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db)==0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="1" && rows[0][2]=="active")
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_issuances"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT count(*) FROM executor_receipts) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="3" && rows[0][1]=="2" && rows[0][2]=="active" && rows[0][3]=="2")
}

@(test)
executor_issuance_sealed_consent_and_response_bind_pending_exchange :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    consent_raw,selection,resources:=issuance_inputs(f)
    consent,_:=contracts.executor_parse(consent_raw,"issuance_consent")
    result:=issue_fixture(f,consent_raw,selection,resources)
    if !testing.expect_value(t,result.code,"ok") do return
    id:vault.Vault_Id;id[0]=1
    key:[32]byte;key[0]=2
    kr,k_ok:=vault.keyring_from_single_key("account",id,1,key[:]);testing.expect(t,k_ok);defer vault.keyring_wipe(&kr)
    scope:=document("transport_scope")
    set(scope,"method","enrollment");set(scope,"reservation_id","")
    digest,_:=contracts.executor_digest("issuance_consent",consent)
    set(scope,"input_digest",digest);set(scope,"fence_digest",field(consent,"selection_digest"))
    token,sealed:=channel.seal(consent_raw,&kr,scope,1200);testing.expect(t,sealed)
    plain,opened:=channel.open_signed(token,&kr,scope,f.owner2.public,1200)
    testing.expect(t,opened && plain==consent_raw)
    _,opened=channel.open_signed(token,&kr,scope,f.operator.public,1200);testing.expect(t,!opened)
    set(scope,"direction","response")
    response,r_ok:=channel.seal(result.body,&kr,scope,1200);testing.expect(t,r_ok)
    plain,opened=channel.open_issuance(response,&kr,scope,consent,selection,f.owner2.public,f.operator.public,1200)
    testing.expect(t,opened && plain==result.body)
    set(scope,"input_digest",strings.repeat("d",64,context.temp_allocator))
    rebound,_:=channel.seal(result.body,&kr,scope,1200)
    _,opened=channel.open_issuance(rebound,&kr,scope,consent,selection,f.owner2.public,f.operator.public,1200);testing.expect(t,!opened)
    set(scope,"input_digest",digest);set(scope,"executor_incarnation","2")
    rebound,_=channel.seal(result.body,&kr,scope,1200)
    _,opened=channel.open_issuance(rebound,&kr,scope,consent,selection,f.owner2.public,f.operator.public,1200);testing.expect(t,!opened,"old physical configuration cannot be fresh admission")
    _,opened=channel.open_issuance(rebound,&kr,scope,consent,selection,f.owner2.public,f.operator.public,1200,false);testing.expect(t,opened,"read-only history retains original physical facts")
}
