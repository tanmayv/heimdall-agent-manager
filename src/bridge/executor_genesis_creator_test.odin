package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Mundus .13: every prepare for an agent-created chain was refused by the
// executor (bind_owner invalid_scope) because the genesis creator (the owner
// Bridge, creator_id brg_..., creator_key_id dev_...) was looked up by
// creator_id as a device. The executor must derive the creator the way
// owner_verify_genesis accepts it, and nothing wider.

genesis_creator_test_key :: proc(t:^testing.T,priv:^ecdsa.Private_Key)->string {
    testing.expect(t,vault.p256_private_key_generate(priv))
    pub:[65]byte
    ecdsa.private_key_public_bytes(priv,pub[:])
    return strings.clone(vault.hex_encode_lower(pub[:],context.temp_allocator),context.temp_allocator)
}

genesis_creator_test_document :: proc(t:^testing.T,creator_id,creator_key_id:string,creator,owner:^ecdsa.Private_Key)->json.Object {
    g:=make(json.Object,context.temp_allocator)
    zeros:=strings.repeat("0",128,context.temp_allocator)
    for pair in ([11][2]string{{"protocol_version","1"},{"account_id","acct_1"},{"chain_id","chain_1"},{"creation_op","op_create"},
        {"owner_bridge_id","brg_owner"},{"owner_key_id","dev_owner"},{"creator_id",creator_id},{"creator_key_id",creator_key_id},
        {"schema_version","1"},{"creator_signature",zeros},{"owner_signature",zeros}}) { g[pair[0]]=json.String(pair[1]) }
    canonical,ok:=contracts.owner_canonical("genesis",g)
    testing.expect(t,ok)
    c,c_ok:=vault.sign_p256(creator,transmute([]byte)canonical)
    o,o_ok:=vault.sign_p256(owner,transmute([]byte)canonical)
    testing.expect(t,c_ok && o_ok)
    g["creator_signature"]=json.String(strings.clone(vault.hex_encode_lower(c.sig[:],context.temp_allocator),context.temp_allocator))
    g["owner_signature"]=json.String(strings.clone(vault.hex_encode_lower(o.sig[:],context.temp_allocator),context.temp_allocator))
    return g
}

@(test)
test_executor_genesis_creator_accepts_agent_created_chains_only_as_the_owner_key :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    owner_priv,other_priv,device_priv:ecdsa.Private_Key
    defer ecdsa.private_key_clear(&owner_priv);defer ecdsa.private_key_clear(&other_priv);defer ecdsa.private_key_clear(&device_priv)
    owner_pub:=genesis_creator_test_key(t,&owner_priv)
    other_pub:=genesis_creator_test_key(t,&other_priv)
    device_pub:=genesis_creator_test_key(t,&device_priv)
    dir:vault.Verified_Directory
    dir.trusted=make(map[string]vault.Verified_Directory_Device,context.temp_allocator)
    dir.trusted["dev_owner"]={id="dev_owner",kind="bridge",sign_public_key=owner_pub}
    dir.trusted["dev_other"]={id="dev_other",kind="bridge",sign_public_key=other_pub}
    dir.trusted["dev_browser"]={id="dev_browser",kind="browser",sign_public_key=device_pub}
    owner_key:=contracts.Owner_Verified_Key{"acct_1","brg_owner","dev_owner",owner_pub,"bridge",true,false}

    // Agent-created chain: creator == owner Bridge (principal brg_owner, key dev_owner).
    g:=genesis_creator_test_document(t,"brg_owner","dev_owner",&owner_priv,&owner_priv)
    creator:=bridge_executor_genesis_creator(&dir,g,"acct_1")
    testing.expect_value(t,creator.kind,"bridge")
    testing.expect_value(t,creator.principal_id,"brg_owner")
    testing.expect_value(t,creator.key_id,"dev_owner")
    testing.expect_value(t,contracts.owner_verify_genesis(g,"acct_1","brg_owner",creator,owner_key),contracts.Owner_Auth_Error.None)
    // The previous derivation (by creator_id, as a device) is what refused it.
    _,by_principal:=dir.trusted["brg_owner"]
    testing.expect(t,!by_principal,"creator_id is a Bridge principal, not a directory key id")

    // Browser device creator: unchanged (looked up by creator_id, kind device).
    g=genesis_creator_test_document(t,"dev_browser","dev_browser",&device_priv,&owner_priv)
    creator=bridge_executor_genesis_creator(&dir,g,"acct_1")
    testing.expect_value(t,creator.kind,"device")
    testing.expect(t,creator.enrolled && !creator.revoked)
    testing.expect_value(t,contracts.owner_verify_genesis(g,"acct_1","brg_owner",creator,owner_key),contracts.Owner_Auth_Error.None)

    // Another enrolled Bridge of the account is never accepted as creator.
    g=genesis_creator_test_document(t,"brg_other","dev_other",&other_priv,&owner_priv)
    creator=bridge_executor_genesis_creator(&dir,g,"acct_1")
    testing.expect(t,contracts.owner_verify_genesis(g,"acct_1","brg_owner",creator,owner_key)!=.None)
    // ...nor when it claims the owner's principal with its own key.
    g=genesis_creator_test_document(t,"brg_owner","dev_other",&other_priv,&owner_priv)
    creator=bridge_executor_genesis_creator(&dir,g,"acct_1")
    testing.expect(t,contracts.owner_verify_genesis(g,"acct_1","brg_owner",creator,owner_key)!=.None)

    // An unknown creator stays revoked/unenrolled.
    g=genesis_creator_test_document(t,"dev_gone","dev_gone",&device_priv,&owner_priv)
    creator=bridge_executor_genesis_creator(&dir,g,"acct_1")
    testing.expect(t,creator.revoked && !creator.enrolled)
}
