package contracts

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

// Agent `task-chain create`: the owner Bridge may be the genesis creator, but
// only with its OWN owner key. Any other Bridge key, even enrolled in the same
// account, is refused; every non-create command still needs a device.

Bridge_Creator_Key :: struct { priv: ecdsa.Private_Key, key: Owner_Verified_Key }

bridge_creator_key :: proc(t: ^testing.T, principal, key_id, kind: string) -> Bridge_Creator_Key {
    k: Bridge_Creator_Key
    testing.expect(t, vault.p256_private_key_generate(&k.priv))
    pub: [65]byte
    ecdsa.private_key_public_bytes(&k.priv, pub[:])
    k.key = Owner_Verified_Key{"acct_1", principal, key_id, strings.clone(vault.hex_encode_lower(pub[:], context.temp_allocator), context.temp_allocator), kind, true, false}
    return k
}
bridge_creator_sign :: proc(t: ^testing.T, k: ^Bridge_Creator_Key, kind: string, o: ^json.Object, field: string) {
    canonical, ok := owner_canonical(kind, o^)
    testing.expect(t, ok)
    sig, signed := vault.sign_p256(&k.priv, transmute([]byte)canonical)
    testing.expect(t, signed)
    o^[field] = json.String(strings.clone(vault.hex_encode_lower(sig.sig[:], context.temp_allocator), context.temp_allocator))
}
bridge_creator_genesis :: proc(t: ^testing.T, creator_id, creator_key: string, creator, owner: ^Bridge_Creator_Key) -> json.Object {
    g := make(json.Object, context.temp_allocator)
    zeros := strings.repeat("0", 128, context.temp_allocator)
    for pair in ([11][2]string{{"protocol_version", "1"}, {"account_id", "acct_1"}, {"chain_id", "chain_1"}, {"creation_op", "op_create"},
        {"owner_bridge_id", "brg_1"}, {"owner_key_id", owner.key.key_id}, {"creator_id", creator_id}, {"creator_key_id", creator_key},
        {"schema_version", "1"}, {"creator_signature", zeros}, {"owner_signature", zeros}}) { g[pair[0]] = json.String(pair[1]) }
    bridge_creator_sign(t, creator, "genesis", &g, "creator_signature")
    bridge_creator_sign(t, owner, "genesis", &g, "owner_signature")
    return g
}

@(test)
owner_genesis_accepts_device_or_own_owner_bridge_only :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    owner := bridge_creator_key(t, "brg_1", "brg_key_1", "bridge");defer ecdsa.private_key_clear(&owner.priv)
    other_bridge := bridge_creator_key(t, "brg_2", "brg_key_2", "bridge");defer ecdsa.private_key_clear(&other_bridge.priv)
    device := bridge_creator_key(t, "dev_1", "dev_1", "device");defer ecdsa.private_key_clear(&device.priv)
    // Device creator: unchanged.
    g := bridge_creator_genesis(t, "dev_1", "dev_1", &device, &owner)
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", device.key, owner.key), Owner_Auth_Error.None)
    // The owner Bridge's own key as creator.
    g = bridge_creator_genesis(t, "brg_1", "brg_key_1", &owner, &owner)
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", owner.key, owner.key), Owner_Auth_Error.None)
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_2", owner.key, owner.key), Owner_Auth_Error.Owner_Mismatch)
    tampered := owner.key;tampered.kind = "content"
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", tampered, owner.key), Owner_Auth_Error.Invalid_Scope)
    g["creation_op"] = json.String("op_other")
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", owner.key, owner.key), Owner_Auth_Error.Bad_Signature)
    // A foreign enrolled Bridge key, under its own identity, is never a creator.
    g = bridge_creator_genesis(t, "brg_2", "brg_key_2", &other_bridge, &owner)
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", other_bridge.key, owner.key), Owner_Auth_Error.Invalid_Scope)
    // ...nor when it claims the owner's principal or key id.
    claim := other_bridge.key;claim.principal_id = "brg_1"
    g = bridge_creator_genesis(t, "brg_1", "brg_key_2", &other_bridge, &owner)
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", claim, owner.key), Owner_Auth_Error.Invalid_Scope)
    claim.key_id = "brg_key_1"
    g = bridge_creator_genesis(t, "brg_1", "brg_key_1", &other_bridge, &owner)
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", claim, owner.key), Owner_Auth_Error.Invalid_Scope)
    // The owner key, but the genesis names a different creator identity.
    g = bridge_creator_genesis(t, "brg_1", "other_key", &owner, &owner)
    other := owner.key;other.key_id = "other_key"
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", other, owner.key), Owner_Auth_Error.Invalid_Scope)
    // A foreign Bridge cannot co-sign as the owner of someone else's chain.
    g = bridge_creator_genesis(t, "brg_1", "brg_key_1", &owner, &other_bridge)
    testing.expect_value(t, owner_verify_genesis(g, "acct_1", "brg_1", owner.key, other_bridge.key), Owner_Auth_Error.Owner_Mismatch)
}

@(test)
owner_command_bridge_key_only_for_own_chain_create :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    owner := bridge_creator_key(t, "brg_1", "brg_key_1", "bridge");defer ecdsa.private_key_clear(&owner.priv)
    other_bridge := bridge_creator_key(t, "brg_2", "brg_key_2", "bridge");defer ecdsa.private_key_clear(&other_bridge.priv)
    cipher := "vault:v2:0123456789abcdef:e1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
    command :: proc(t: ^testing.T, k: ^Bridge_Creator_Key, method, payload: string) -> json.Object {
        c := make(json.Object, context.temp_allocator)
        for pair in ([13][2]string{{"protocol_version", "1"}, {"account_id", "acct_1"}, {"chain_id", "chain_1"}, {"immutable_owner_bridge", "brg_1"},
            {"principal_id", k.key.principal_id}, {"operation_id", "op_create"}, {"method", method}, {"task_id", ""}, {"expected_revision", "0"},
            {"request_expires_ms", "2000"}, {"payload_digest", owner_payload_digest(payload)}, {"key_id", k.key.key_id}, {"signature", strings.repeat("0", 128, context.temp_allocator)}}) {
            c[pair[0]] = json.String(pair[1])
        }
        bridge_creator_sign(t, k, "command", &c, "signature")
        return c
    }
    payload := strings.concatenate({`{"genesis_digest":"`, strings.repeat("a", 64, context.temp_allocator), `","title_cipher":"`, cipher, `","description_cipher":"`, cipher, `"}`})
    grant := Owner_Read_Grant{"acct_1", "brg_1", "chain_1", "brg_1", "brg_key_1", "", "chain.create", 1, 1000000, true, true, false}
    c := command(t, &owner, "chain.create", payload)
    testing.expect_value(t, owner_authenticate_command(c, payload, owner.key, grant, 1000), Owner_Auth_Error.None)
    // Any other method signed by the owner Bridge key is not a device command.
    comment := `{"body_cipher":"vault:v2:0123456789abcdef:e1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="}`
    g := grant;g.method = "chain.edit"
    edit := command(t, &owner, "chain.edit", comment)
    testing.expect_value(t, owner_authenticate_command(edit, comment, owner.key, g, 1000), Owner_Auth_Error.Invalid_Scope)
    // A foreign Bridge key signing chain.create for this owner is refused.
    fg := grant;fg.principal_id = "brg_2";fg.key_id = "brg_key_2"
    fc := command(t, &other_bridge, "chain.create", payload)
    testing.expect_value(t, owner_authenticate_command(fc, payload, other_bridge.key, fg, 1000), Owner_Auth_Error.Invalid_Scope)
}
