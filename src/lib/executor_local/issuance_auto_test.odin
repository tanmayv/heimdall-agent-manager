#+feature dynamic-literals
package executor_local
import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"

// Owner-Bridge consent (cross-Bridge placement, option b): the consent names
// only provider and model; the executor chooses its own selectors and returns
// them in the signed configuration.
auto_selection :: proc()->string {
    o:=document("issuance_selection")
    for name in ([3]string{"provider_profile","directory_id","slot_id"}) do set(o,name,contracts.EXECUTOR_AUTO_SELECTOR)
    set(o,"policy_revision","1")
    return encode(o)
}
owner_bridge_consent :: proc(f:^Fixture,selection:string,operation:="auto_issuance")->string {
    c:=document("issuance_consent")
    set(c,"owner_bridge_id","owner1");set(c,"principal_id","owner1");set(c,"key_id","owner1")
    set(c,"operation_id",operation);set(c,"selection_digest",contracts.owner_payload_digest(selection))
    return signed(c,"issuance_consent",&f.owner1)
}
auto_resources :: proc(requested,chosen:string)->Issuance_Resources {
    return Issuance_Resources{selection_digest=contracts.owner_payload_digest(requested),directory_key=directory_key("executor","/repo"),directory_path="/repo",selection=chosen,resolved=true}
}
@(test)
executor_issuance_owner_bridge_auto_selection_is_resolved_by_the_executor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    _=install_directory(&f.store,signed(document("directory"),"directory",&f.operator),f.operator.public,1000,"/repo")
    requested:=auto_selection()
    chosen:=encode(document("issuance_selection"))
    consent:=owner_bridge_consent(f,requested)
    sign:=Signer{&f.operator,sign_receipt}
    result:=issue(&f.store,consent,requested,f.owner1.public,f.operator.public,1100,auto_resources(requested,chosen),sign)
    if !testing.expect_value(t,result.code,"ok") do return
    v,_:=contracts.owner_content_document(result.body);body,_:=v.(json.Object)
    config,valid:=contracts.owner_parse(field(body,"configuration"),"remote_configuration")
    testing.expect(t,valid)
    for name in ([4]string{"provider_profile","directory_id","policy_revision","slot_id"}) {
        testing.expectf(t,field(config,name)==field(document("issuance_selection"),name),"%s is the executor's choice",name)
    }
    testing.expect_value(t,field(config,"directory_path"),"/repo")
    c,_:=contracts.executor_parse(consent,"issuance_consent")
    r,_:=contracts.executor_parse(field(body,"issuance_receipt"),"issuance_receipt")
    a,_:=contracts.executor_parse(field(body,"attestation"),"enrollment")
    testing.expect(t,contracts.executor_issuance_matches(r,c,requested,field(body,"configuration"),a,f.owner1.public,f.operator.public,1200),
        "the owner Bridge verifies the executor's chosen selectors")
    // The executor's choice must keep the requested provider and model and
    // name real selectors.
    other_model:=document("issuance_selection");set(other_model,"model","other")
    testing.expect_value(t,issue(&f.store,owner_bridge_consent(f,requested,"op2"),requested,f.owner1.public,f.operator.public,1100,
        auto_resources(requested,encode(other_model)),sign).code,"invalid_resources")
    testing.expect_value(t,issue(&f.store,owner_bridge_consent(f,requested,"op3"),requested,f.owner1.public,f.operator.public,1100,
        auto_resources(requested,requested),sign).code,"invalid_resources")
    testing.expect_value(t,issue(&f.store,owner_bridge_consent(f,requested,"op4"),requested,f.owner1.public,f.operator.public,1100,
        auto_resources(requested,""),sign).code,"invalid_resources")
    // An owner Bridge never names B-local selectors, and a device never uses auto.
    explicit:=encode(document("issuance_selection"))
    testing.expect_value(t,issue(&f.store,owner_bridge_consent(f,explicit,"op5"),explicit,f.owner1.public,f.operator.public,1100,
        Issuance_Resources{selection_digest=contracts.owner_payload_digest(explicit),directory_key=directory_key("executor","/repo"),directory_path="/repo",resolved=true},sign).code,"invalid_scope")
    device:=f.owner2.public;device.kind="device"
    dc:=document("issuance_consent");set(dc,"operation_id","op6");set(dc,"selection_digest",contracts.owner_payload_digest(requested))
    testing.expect_value(t,issue(&f.store,signed(dc,"issuance_consent",&f.owner2),requested,device,f.operator.public,1100,
        auto_resources(requested,chosen),sign).code,"invalid_scope")
    // Revoked, other-account or non-owner Bridge keys never consent.
    revoked:=f.owner1.public;revoked.revoked=true
    testing.expect_value(t,issue(&f.store,owner_bridge_consent(f,requested,"op7"),requested,revoked,f.operator.public,1100,
        auto_resources(requested,chosen),sign).code,"invalid_scope")
    other_account:=f.owner1.public;other_account.account_id="other"
    testing.expect_value(t,issue(&f.store,owner_bridge_consent(f,requested,"op8"),requested,other_account,f.operator.public,1100,
        auto_resources(requested,chosen),sign).code,"invalid_scope")
    nc:=document("issuance_consent");set(nc,"principal_id","owner2");set(nc,"key_id","owner2");set(nc,"operation_id","op9")
    set(nc,"selection_digest",contracts.owner_payload_digest(requested))
    testing.expect_value(t,issue(&f.store,signed(nc,"issuance_consent",&f.owner2),requested,f.owner2.public,f.operator.public,1100,
        auto_resources(requested,chosen),sign).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_issuances")
    testing.expect_value(t,rows[0][0],"1")
}
