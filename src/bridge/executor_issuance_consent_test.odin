package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

// bridge_executor_consent_key: who may consent to an issuance on this executor.
// A browser device of the account, or the chain's owner Bridge (cross-Bridge
// placement, origin/main parity). Never this executor itself, never a Bridge
// that is not the consent's owner_bridge_id, never a key outside the verified
// directory (unpaired, revoked, other account), never a key whose id does not
// derive from its public key.

executor_consent_test_key :: proc(t:^testing.T) -> (string,string) {
    priv:ecdsa.Private_Key
    testing.expect(t,vault.p256_private_key_generate(&priv))
    defer ecdsa.private_key_clear(&priv)
    pub:[65]byte
    ecdsa.private_key_public_bytes(&priv,pub[:])
    hex:=strings.clone(vault.hex_encode_lower(pub[:],context.temp_allocator),context.temp_allocator)
    id,ok:=vault.device_id_from_sign_pub(hex,context.temp_allocator)
    testing.expect(t,ok)
    return id,hex
}

executor_consent_test_consent :: proc(principal,key_id,owner_bridge:string) -> json.Object {
    o:=make(json.Object,context.temp_allocator)
    o["principal_id"]=json.String(principal);o["key_id"]=json.String(key_id)
    o["owner_bridge_id"]=json.String(owner_bridge);o["executor_bridge_id"]=json.String("brg_exec")
    return o
}

@(test)
test_executor_consent_key_admits_device_or_owner_bridge :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    device_id,device_pub:=executor_consent_test_key(t)
    owner_id,owner_pub:=executor_consent_test_key(t)
    self_id,self_pub:=executor_consent_test_key(t)
    _,stranger_pub:=executor_consent_test_key(t)
    dir:vault.Verified_Directory
    dir.trusted=make(map[string]vault.Verified_Directory_Device,context.temp_allocator)
    dir.trusted[device_id]={id=device_id,kind="browser",sign_public_key=device_pub}
    dir.trusted[owner_id]={id=owner_id,kind="bridge",sign_public_key=owner_pub}
    dir.trusted[self_id]={id=self_id,kind="bridge",sign_public_key=self_pub}
    // An approved entry whose id does not derive from its key.
    dir.trusted["key_mismatched"]={id="key_mismatched",kind="bridge",sign_public_key=stranger_pub}

    key,ok:=bridge_executor_consent_key(&dir,executor_consent_test_consent(device_id,device_id,"brg_owner"),"acct_1",self_id)
    testing.expect(t,ok && key.kind=="device" && key.key_id==device_id && key.principal_id==device_id && key.account_id=="acct_1","a browser device consents")

    key,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("brg_owner",owner_id,"brg_owner"),"acct_1",self_id)
    testing.expect(t,ok && key.kind=="bridge" && key.key_id==owner_id && key.principal_id=="brg_owner" && key.public_key==owner_pub,"the chain's owner Bridge consents")

    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("brg_other",owner_id,"brg_owner"),"acct_1",self_id)
    testing.expect(t,!ok,"a Bridge naming another principal than the owner never consents")
    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("brg_exec",self_id,"brg_exec"),"acct_1",self_id)
    testing.expect(t,!ok,"the executor never consents for itself (own key)")
    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("brg_exec",owner_id,"brg_exec"),"acct_1",self_id)
    testing.expect(t,!ok,"a consent whose owner is the executor is refused")
    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("brg_owner","key_mismatched","brg_owner"),"acct_1",self_id)
    testing.expect(t,!ok,"a key id that does not derive from its public key never consents")
    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("",owner_id,""),"acct_1",self_id)
    testing.expect(t,!ok,"an empty principal never consents")

    // Unpaired, revoked or other-account keys are absent from this account's
    // verified directory (vault.directory_verify keeps only approved,
    // unrevoked devices of the paired root), so they never resolve.
    unpaired_id,_:=executor_consent_test_key(t)
    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("brg_owner",unpaired_id,"brg_owner"),"acct_1",self_id)
    testing.expect(t,!ok,"a Bridge key outside the verified directory never consents")
    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent(unpaired_id,unpaired_id,"brg_owner"),"acct_1",self_id)
    testing.expect(t,!ok,"a device outside the verified directory never consents")
    delete_key(&dir.trusted,owner_id)
    _,ok=bridge_executor_consent_key(&dir,executor_consent_test_consent("brg_owner",owner_id,"brg_owner"),"acct_1",self_id)
    testing.expect(t,!ok,"a revoked (no longer trusted) owner Bridge key never consents")
}
