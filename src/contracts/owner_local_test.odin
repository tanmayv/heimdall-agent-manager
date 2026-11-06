package contracts

import "core:encoding/json"
import "core:strings"
import "core:testing"

owner_fixture :: proc(t: ^testing.T) -> json.Object {
    v, err := json.parse_string(#load("fixtures/owner-local-v1.json", string), .JSON, true, context.temp_allocator)
    testing.expect(t, err == .None)
    o, ok := v.(json.Object)
    testing.expect(t, ok)
    return o
}
owner_fixture_document :: proc(t: ^testing.T, f: json.Object, kind: string) -> json.Object {
    entries, _ := f["valid"].(json.Array)
    for entry in entries {
        e, _ := entry.(json.Object)
        if owner_string(e, "kind") == kind {
            o, ok := owner_parse(owner_string(e, "raw"), kind)
            testing.expect(t, ok)
            return o
        }
    }
    testing.expect(t, false)
    return nil
}
owner_fixture_keys :: proc(f: json.Object) -> (Owner_Verified_Key, Owner_Verified_Key) {
    return Owner_Verified_Key{"acct_1", "dev_1", "device_key", owner_string(f, "creator_public_key"), "device", true, false},
           Owner_Verified_Key{"acct_1", "brg_1", "bridge_key", owner_string(f, "bridge_public_key"), "bridge", true, false}
}
owner_fixture_grant :: proc() -> Owner_Read_Grant {
    return {"acct_1", "brg_1", "chain_1", "dev_1", "device_key", "task_1", "task.comment", 1, 1000000, true, true, false}
}

@(test)
owner_shared_wire_vectors :: proc(t: ^testing.T) {
    f := owner_fixture(t)
    valid, _ := f["valid"].(json.Array)
    for entry in valid {
        e, _ := entry.(json.Object)
        kind := owner_string(e, "kind")
        o, ok := owner_parse(owner_string(e, "raw"), kind)
        testing.expectf(t, ok, "parse %s", kind)
        canonical, c_ok := owner_canonical(kind, o)
        digest, d_ok := owner_digest(kind, o)
        testing.expect(t, c_ok && d_ok)
        testing.expect_value(t, canonical, owner_string(e, "canonical"))
        testing.expect_value(t, digest, owner_string(e, "digest"))
    }
    invalid, _ := f["invalid"].(json.Array)
    for entry in invalid {
        e, _ := entry.(json.Object)
        _, ok := owner_parse(owner_string(e, "raw"), owner_string(e, "kind"))
        testing.expectf(t, !ok, "must reject %s", owner_string(e, "name"))
    }
    _, ok := owner_parse(strings.repeat(" ", OWNER_DOCUMENT_MAX + 1, context.temp_allocator), "command")
    testing.expect(t, !ok)
}

@(test)
owner_signed_genesis_and_registry :: proc(t: ^testing.T) {
    f := owner_fixture(t)
    creator, bridge := owner_fixture_keys(f)
    genesis := owner_fixture_document(t, f, "genesis")
    testing.expect_value(t, owner_verify_genesis(genesis, "acct_1", "brg_1", creator, bridge), Owner_Auth_Error.None)
    testing.expect_value(t, owner_verify_genesis(genesis, "acct_other", "brg_1", creator, bridge), Owner_Auth_Error.Invalid_Scope)
    testing.expect_value(t, owner_verify_genesis(genesis, "acct_1", "brg_other", creator, bridge), Owner_Auth_Error.Owner_Mismatch)
    swapped := creator
    swapped.kind = "bridge"
    testing.expect_value(t, owner_verify_genesis(genesis, "acct_1", "brg_1", swapped, bridge), Owner_Auth_Error.Invalid_Scope)
    old := owner_string(genesis, "creation_op")
    genesis["creation_op"] = json.String("op_other")
    testing.expect_value(t, owner_verify_genesis(genesis, "acct_1", "brg_1", creator, bridge), Owner_Auth_Error.Bad_Signature)
    genesis["creation_op"] = json.String(old)
    registry := owner_fixture_document(t, f, "registry")
    digest, _ := owner_digest("genesis", genesis)
    testing.expect_value(t, owner_verify_registry(registry, "acct_1", "brg_1", digest, bridge), Owner_Auth_Error.None)
    testing.expect_value(t, owner_verify_registry(registry, "acct_1", "brg_1", strings.repeat("0", 64, context.temp_allocator), bridge), Owner_Auth_Error.Digest_Mismatch)
    registry["metadata_revision"] = json.String("2")
    testing.expect_value(t, owner_verify_registry(registry, "acct_1", "brg_1", digest, bridge), Owner_Auth_Error.Bad_Signature)
}

@(test)
owner_authentication_and_replay_admission_order :: proc(t: ^testing.T) {
    f := owner_fixture(t)
    key, _ := owner_fixture_keys(f)
    o := owner_fixture_document(t, f, "command")
    payload := owner_string(f, "payload")
    g := owner_fixture_grant()
    testing.expect_value(t, owner_authenticate_command(o, payload, key, g, 1000), Owner_Auth_Error.None)
    testing.expect_value(t, owner_live_admit(o, g, 1000, 9007199254740993), Owner_Auth_Error.None)
    wrong := g
    wrong.chain_id = "other"
    testing.expect_value(t, owner_live_admit(o, wrong, 1000, 9007199254740993), Owner_Auth_Error.Invalid_Scope)
    wrong = g
    wrong.owner_bridge_id = "other"
    testing.expect_value(t, owner_live_admit(o, wrong, 1000, 9007199254740993), Owner_Auth_Error.Owner_Mismatch)
    // Historical receipt auth survives original expiry and old expected revision.
    testing.expect_value(t, owner_authenticate_command(o, payload, key, g, 10000), Owner_Auth_Error.None)
    testing.expect_value(t, owner_live_admit(o, g, 10000, 9007199254740994), Owner_Auth_Error.Expired)
    testing.expect_value(t, owner_live_admit(o, g, 1000, 9007199254740994), Owner_Auth_Error.Stale_Revision)
    testing.expect_value(t, owner_authenticate_command(o, "changed", key, g, 1000), Owner_Auth_Error.Digest_Mismatch)
    revoked := g
    revoked.revoked = true
    testing.expect_value(t, owner_authenticate_command(o, payload, key, revoked, 10000), Owner_Auth_Error.Invalid_Scope)
    for field in ([6]string{"account_id", "chain_id", "principal_id", "key_id", "method", "task_id"}) {
        old := owner_string(o, field)
        o[field] = json.String("other")
        if field == "method" do o[field] = json.String("task.read")
        testing.expect_value(t, owner_authenticate_command(o, payload, key, g, 1000), Owner_Auth_Error.Invalid_Scope)
        o[field] = json.String(old)
    }
    o["immutable_owner_bridge"] = json.String("brg_other")
    testing.expect_value(t, owner_authenticate_command(o, payload, key, g, 1000), Owner_Auth_Error.Owner_Mismatch)
    o["immutable_owner_bridge"] = json.String("brg_1")
    for kind in ([4]string{"content", "bridge", "agent", ""}) {
        bad := key
        bad.kind = kind
        testing.expect_value(t, owner_authenticate_command(o, payload, bad, g, 1000), Owner_Auth_Error.Invalid_Scope)
    }
    untrusted := key
    untrusted.enrolled = false
    testing.expect_value(t, owner_authenticate_command(o, payload, untrusted, g, 1000), Owner_Auth_Error.Bad_Signature)
    // A still-readable result scope cannot grant a new mutation.
    readonly := g
    readonly.can_mutate = false
    testing.expect_value(t, owner_authenticate_command(o, payload, key, readonly, 1000), Owner_Auth_Error.None)
    testing.expect_value(t, owner_live_admit(o, readonly, 1000, 9007199254740993), Owner_Auth_Error.Invalid_Scope)
    o["operation_id"] = json.String("tampered")
    testing.expect_value(t, owner_authenticate_command(o, payload, key, g, 10000), Owner_Auth_Error.Bad_Signature)
}

@(test)
owner_vertical_slice_methods_and_creation_binding :: proc(t: ^testing.T) {
    f := owner_fixture(t)
    key, bridge := owner_fixture_keys(f)
    genesis := owner_fixture_document(t, f, "genesis")
    entries, _ := f["commands"].(json.Array)
    for entry in entries {
        e, _ := entry.(json.Object)
        o, ok := owner_parse(owner_string(e, "raw"), "command")
        testing.expect(t, ok)
        g := owner_fixture_grant()
        g.task_id = ""
        g.method = owner_string(o, "method")
        payload := owner_string(e, "payload")
        testing.expect_value(t, owner_authenticate_command(o, payload, key, g, 1000), Owner_Auth_Error.None)
        testing.expect_value(t, owner_live_admit(o, g, 1000, 0), Owner_Auth_Error.None)
        if g.method == "chain.create" {
            testing.expect_value(t, owner_verify_genesis(genesis, "acct_1", "brg_1", key, bridge), Owner_Auth_Error.None)
            testing.expect(t, owner_create_binding(o, genesis, payload))
            genesis["creation_op"] = json.String("other")
            testing.expect(t, !owner_create_binding(o, genesis, payload))
            genesis["creation_op"] = json.String("op_create")
        }
        if g.method == "chain.read" || g.method == "task.read" || g.method == "receipt.read" {
            testing.expect_value(t, owner_live_admit(o, g, 1000, 99), Owner_Auth_Error.None)
            o["expected_revision"] = json.String("98")
            testing.expect_value(t, owner_live_admit(o, g, 1000, 99), Owner_Auth_Error.Stale_Revision)
            o["expected_revision"] = json.String("0")
        }
        // Every method denies an expired current read grant, even for replay.
        g.expires_ms = 1000
        testing.expect_value(t, owner_authenticate_command(o, payload, key, g, 1000), Owner_Auth_Error.Invalid_Scope)
    }
}
