package contracts

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

// Cross-Bridge placement: an issuance consent may be signed by a device, or by
// the chain's owner Bridge naming itself as owner_bridge_id. No other Bridge
// of the account, no revoked or other-account key, and no Bridge for a local
// launch or draft.

executor_consent_test_doc :: proc(principal,key_id:string) -> json.Object {
    o:=make(json.Object,context.temp_allocator)
    for pair in ([16][2]string{{"protocol_version","1"},{"account_id","acct_1"},{"owner_bridge_id","brg_owner"},
        {"executor_bridge_id","brg_exec"},{"executor_key_id","key_exec"},{"chain_id","chain_1"},{"task_id","task_1"},
        {"agent_id","agt_1"},{"configuration_revision","1"},{"operation_id","op_1"},{"principal_id",principal},
        {"selection_digest",strings.repeat("a",64,context.temp_allocator)},{"issued_ms","1"},{"request_expires_ms","2"},
        {"key_id",key_id},{"signature",strings.repeat("0",128,context.temp_allocator)}}) {o[pair[0]]=json.String(pair[1])}
    return o
}

executor_consent_test_sign :: proc(t:^testing.T,k:^Bridge_Creator_Key,kind:string,o:^json.Object) {
    canonical,ok:=executor_canonical(kind,o^)
    if !testing.expect(t,ok,fmt.tprintf("%s canonical",kind)) do return
    sig,signed:=vault.sign_p256(&k.priv,transmute([]byte)canonical)
    testing.expect(t,signed)
    o^["signature"]=json.String(strings.clone(vault.hex_encode_lower(sig.sig[:],context.temp_allocator),context.temp_allocator))
}

@(test)
executor_issuance_consent_admits_device_or_owner_bridge_only :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    owner:=bridge_creator_key(t,"brg_owner","key_owner","bridge");defer ecdsa.private_key_clear(&owner.priv)
    other:=bridge_creator_key(t,"brg_other","key_other","bridge");defer ecdsa.private_key_clear(&other.priv)
    device:=bridge_creator_key(t,"dev_1","dev_1","device");defer ecdsa.private_key_clear(&device.priv)

    // A device consent: unchanged.
    c:=executor_consent_test_doc("dev_1","dev_1")
    executor_consent_test_sign(t,&device,"issuance_consent",&c)
    testing.expect(t,executor_verify("issuance_consent",c,device.key),"a device consents")

    // The chain's owner Bridge consents under its own identity.
    c=executor_consent_test_doc("brg_owner","key_owner")
    executor_consent_test_sign(t,&owner,"issuance_consent",&c)
    testing.expect(t,executor_verify("issuance_consent",c,owner.key),"the owner Bridge consents")
    revoked:=owner.key;revoked.revoked=true
    testing.expect(t,!executor_verify("issuance_consent",c,revoked),"a revoked owner key never consents")
    unenrolled:=owner.key;unenrolled.enrolled=false
    testing.expect(t,!executor_verify("issuance_consent",c,unenrolled),"an unenrolled owner key never consents")
    other_account:=owner.key;other_account.account_id="acct_2"
    testing.expect(t,!executor_verify("issuance_consent",c,other_account),"another account's key never consents")
    tampered:=c;tampered["task_id"]=json.String("task_2")
    testing.expect(t,!executor_verify("issuance_consent",tampered,owner.key),"the signature covers the consent")

    // Another Bridge of the same account cannot consent for a chain it does
    // not own, whether it names itself or claims the owner's identity.
    c=executor_consent_test_doc("brg_other","key_other")
    executor_consent_test_sign(t,&other,"issuance_consent",&c)
    testing.expect(t,!executor_verify("issuance_consent",c,other.key),"a non-owner Bridge never consents")
    impostor:=other.key;impostor.principal_id="brg_owner"
    c=executor_consent_test_doc("brg_owner","key_other")
    executor_consent_test_sign(t,&other,"issuance_consent",&c)
    testing.expect(t,executor_verify("issuance_consent",c,impostor),"the rule binds identity, not key: the caller binds the key to the directory")
    testing.expect(t,!executor_verify("issuance_consent",c,owner.key),"the owner's key does not verify another key's signature")

    // A content or unknown key kind never consents.
    content:=owner.key;content.kind="content"
    c=executor_consent_test_doc("brg_owner","key_owner")
    executor_consent_test_sign(t,&owner,"issuance_consent",&c)
    testing.expect(t,!executor_verify("issuance_consent",c,content),"a content key never consents")

    // Local launches and drafts stay device-only.
    testing.expect(t,!executor_signer_kind("local_launch",c,owner.key),"a Bridge never signs a local launch")
    testing.expect(t,!executor_signer_kind("local_draft",c,owner.key),"a Bridge never signs a local draft")
    testing.expect(t,executor_signer_kind("local_launch",c,device.key),"a device signs a local launch")
    // Bridge-signed kinds stay Bridge-only.
    testing.expect(t,!executor_signer_kind("receipt",c,device.key),"a device never signs a receipt")
    testing.expect(t,executor_signer_kind("receipt",c,owner.key),"a Bridge signs a receipt")
}
