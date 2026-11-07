#+feature dynamic-literals
package executor_local
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

genesis_document :: proc()->json.Object {
    o:=make(json.Object,context.temp_allocator)
    for pair in ([11][2]string{{"protocol_version","1"},{"account_id","account"},{"chain_id","chain"},{"creation_op","create"},
        {"owner_bridge_id","owner1"},{"owner_key_id","owner1"},{"creator_id","owner2"},{"creator_key_id","owner2"},{"schema_version","1"},
        {"creator_signature",strings.repeat("0",128,context.temp_allocator)},{"owner_signature",strings.repeat("0",128,context.temp_allocator)}}) {
        o[pair[0]]=json.String(pair[1])
    }
    return o
}
genesis_sign :: proc(g:json.Object,creator,owner:^Key)->string {
    canonical,ok:=contracts.owner_canonical("genesis",g)
    if !ok do return ""
    c,c_ok:=vault.sign_p256(&creator.private,transmute([]byte)canonical)
    o,o_ok:=vault.sign_p256(&owner.private,transmute([]byte)canonical)
    if !c_ok || !o_ok do return ""
    result:=g
    result["creator_signature"]=json.String(vault.hex_encode_lower(c.sig[:],context.temp_allocator))
    result["owner_signature"]=json.String(vault.hex_encode_lower(o.sig[:],context.temp_allocator))
    return encode(result)
}
@(test)
executor_owner_binding_is_immutable_current_key_checked_and_historical_creator_not_reauthorized :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);f.owner2.public.kind="device"
    g:=genesis_document();raw:=genesis_sign(g,&f.owner2,&f.owner1)
    revoked:=f.owner2.public;revoked.revoked=true
    testing.expect_value(t,bind_owner(&f.store,raw,revoked,f.owner1.public,1000).code,"invalid_scope")
    first:=bind_owner(&f.store,raw,f.owner2.public,f.owner1.public,1000)
    testing.expect_value(t,first.code,"ok")
    old:=bind_owner(&f.store,raw,revoked,f.owner1.public,999)
    testing.expect(t,old.code=="ok" && old.replay && old.body==first.body)
    p:=document("prepare");raw_p:=signed(p,"prepare",&f.owner1);p,_=contracts.executor_parse(raw_p,"prepare")
    testing.expect(t,owner_bound(&f.store,p,"prepare",f.owner1.public))
    other:=document("prepare");set(other,"owner_bridge_id","executor");set(other,"key_id","operator")
    other_raw:=signed(other,"prepare",&f.operator);other,_=contracts.executor_parse(other_raw,"prepare")
    testing.expect(t,!owner_bound(&f.store,other,"prepare",f.operator.public),"another enrolled Bridge cannot claim immutable owner")
    replaced:=genesis_document();set(replaced,"owner_bridge_id","executor");set(replaced,"owner_key_id","operator")
    testing.expect_value(t,bind_owner(&f.store,genesis_sign(replaced,&f.owner2,&f.operator),f.owner2.public,f.operator.public,1000).code,"owner_mismatch")
    replacement:=genesis_document();set(replacement,"creation_op","another_creation")
    testing.expect_value(t,bind_owner(&f.store,genesis_sign(replacement,&f.owner2,&f.owner1),f.owner2.public,f.owner1.public,1000).code,"owner_mismatch")
    revoked=f.owner1.public;revoked.revoked=true
    testing.expect_value(t,bind_owner(&f.store,raw,f.owner2.public,revoked,1000).code,"invalid_scope")
    testing.expect(t,!owner_bound(&f.store,p,"prepare",revoked))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_chain_owners SET owner_key_id='other'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_chain_owners"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    revoked=f.owner2.public;revoked.revoked=true
    old=bind_owner(&f.store,raw,revoked,f.owner1.public,3000);testing.expect(t,old.code=="ok" && old.replay)
}
@(test)
executor_fresh_prepare_uses_only_exact_locally_issued_configuration :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    consent,selection,resources:=issuance_inputs(f)
    result:=issue_fixture(f,consent,selection,resources)
    if !testing.expect_value(t,result.code,"ok") do return
    value,_:=contracts.owner_content_document(result.body);bundle,_:=value.(json.Object)
    c,_:=contracts.owner_parse(field(bundle,"configuration"),"remote_configuration")
    p:=document("prepare")
    for name in ([14]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","instance_id",
        "launch_epoch","run_count","token_generation","configuration_revision","executor_incarnation","policy_revision","slot_id","provider_profile"}) {set(p,name,field(c,name))}
    set(p,"directory_key",field(c,"directory_key"))
    resolved,ok:=issued_prepare_resources(&f.store,p);testing.expect(t,ok && resolved.instance_id==field(c,"instance_id"))
    for name in ([10]string{"chain_id","task_id","instance_id","launch_epoch","token_generation","configuration_revision","executor_incarnation","policy_revision","slot_id","provider_profile"}) {
        old:=field(p,name)
        set(p,name,"2" if name=="configuration_revision" || name=="executor_incarnation" || name=="policy_revision" else (strings.repeat("b",64,context.temp_allocator) if name=="token_generation" else "other"))
        _,valid:=issued_prepare_resources(&f.store,p);testing.expect(t,!valid,name)
        set(p,name,old)
    }
    d:=document("directory");set(d,"revision","2");set(d,"enabled","0")
    testing.expect_value(t,install_directory(&f.store,signed(d,"directory",&f.operator),f.operator.public,1200,"").code,"ok")
    _,ok=issued_prepare_resources(&f.store,p);testing.expect(t,!ok,"disabled mapping cannot be reused through old issuance")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    _,ok=issued_prepare_resources(&f.store,p);testing.expect(t,!ok,"old executor incarnation cannot fresh-prepare")
}

@(test)
executor_owner_binding_v2_upgrade_collision_rolls_back_issuance_and_active_resources :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    consent,selection,resources:=issuance_inputs(f)
    issued:=issue_fixture(f,consent,selection,resources)
    if !testing.expect_value(t,issued.code,"ok") do return
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1,1200).code,"ok")
    testing.expect_value(t,perform(f,activate_document(p),&f.owner1,true,1300).code,"ok")
    legacy_remove_v11_journal_fixture(t,&f.store)
    testing.expect(t,exec(f.store.db,local_schema_drop_for_test))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_renewals; DROP TABLE executor_controls; DROP TABLE executor_readiness; DROP TABLE executor_bootstraps; DROP TABLE executor_chain_owners; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO executor_runtime_v3;"))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_legacy_commands; DROP TABLE executor_legacy_resources; DROP TABLE executor_legacy_barriers;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=12","schema_version=2",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,2,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v3; DROP TABLE executor_runtime_v3; CREATE TABLE executor_chain_owners(collision TEXT);"))
    close(&f.store)
    testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db)==0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT result_json FROM executor_issuances) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="2" && rows[0][1]=="1" && rows[0][2]=="active" && rows[0][3]==issued.body)
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_chain_owners"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT result_json FROM executor_issuances) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="12" && rows[0][1]=="2" && rows[0][2]=="active" && rows[0][3]==issued.body)
}
