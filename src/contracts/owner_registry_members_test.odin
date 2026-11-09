package contracts

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"

// A chain registry row may carry its member ids and roles (members_json
// selects the registry_members shape and signing domain). Rows without the
// fields keep the original shape, canonical bytes and signatures.

registry_members_row :: proc(t: ^testing.T, members, agent, instance: string) -> json.Object {
    f := owner_fixture(t)
    base := owner_fixture_document(t, f, "registry")
    o := make(json.Object, context.temp_allocator)
    for k, v in base do o[k] = v
    o["coordinator_agent_id"] = json.String(agent)
    o["coordinator_instance_id"] = json.String(instance)
    o["members_json"] = json.String(members)
    return o
}

@(test)
owner_registry_members_shape_and_signature :: proc(t: ^testing.T) {
    owner := bridge_creator_key(t, "brg_1", "bridge_key", "bridge")
    defer ecdsa.private_key_clear(&owner.priv)
    members := `[{"agent_id":"agt_1","instance_id":"inst_1","role":"coordinator","enabled":"1"},{"agent_id":"agt_2","instance_id":"inst_2","role":"worker","enabled":"0"}]`
    o := registry_members_row(t, members, "agt_1", "inst_1")
    testing.expect(t, owner_document_valid("registry", o), "members select the registry_members schema")
    canonical, ok := owner_canonical("registry", o)
    testing.expect(t, ok && strings.has_prefix(canonical, "heimdall-owner-local/registry_members/v1\n"), "a separate signing domain")
    testing.expect(t, strings.contains(canonical, members))
    bridge_creator_sign(t, &owner, "registry", &o, "signature")
    digest := owner_string(o, "genesis_digest")
    testing.expect_value(t, owner_verify_registry(o, "acct_1", "brg_1", digest, owner.key), Owner_Auth_Error.None)
    raw, _ := json.marshal(o, allocator = context.temp_allocator)
    parsed, parsed_ok := owner_parse(string(raw), "registry")
    testing.expect(t, parsed_ok && owner_verify_registry(parsed, "acct_1", "brg_1", digest, owner.key) == .None, "the Hub parse verifies")
    // The members are signed: no field changes without breaking the signature.
    for name in ([3]string{"coordinator_agent_id", "coordinator_instance_id", "members_json"}) {
        forged := make(json.Object, context.temp_allocator)
        for k, v in o do forged[k] = v
        if name == "members_json" {
            forged[name] = json.String(`[{"agent_id":"agt_1","instance_id":"inst_1","role":"coordinator","enabled":"1"}]`)
        } else {
            forged["coordinator_agent_id"] = json.String("")
            forged["coordinator_instance_id"] = json.String("")
        }
        testing.expect_value(t, owner_verify_registry(forged, "acct_1", "brg_1", digest, owner.key), Owner_Auth_Error.Bad_Signature)
    }
    // Stripping the members falls back to the plain domain, so the signature fails.
    stripped := make(json.Object, context.temp_allocator)
    for k, v in o { if k != "coordinator_agent_id" && k != "coordinator_instance_id" && k != "members_json" do stripped[k] = v }
    testing.expect_value(t, owner_verify_registry(stripped, "acct_1", "brg_1", digest, owner.key), Owner_Auth_Error.Bad_Signature)
    // An empty membership is explicit: no coordinator.
    testing.expect(t, owner_document_valid("registry", registry_members_row(t, "[]", "", "")))
    // The old shape stays valid with its fixture signature (owner_signed_genesis_and_registry).
    f := owner_fixture(t)
    plain := owner_fixture_document(t, f, "registry")
    plain_canonical, plain_ok := owner_canonical("registry", plain)
    testing.expect(t, plain_ok && strings.has_prefix(plain_canonical, "heimdall-owner-local/registry/v1\n"))
}

@(test)
owner_registry_members_rejects_malformed_membership :: proc(t: ^testing.T) {
    coordinator :: `{"agent_id":"agt_1","instance_id":"inst_1","role":"coordinator","enabled":"1"}`
    cases := [?][3]string{
        {`[]`, "agt_1", "inst_1"},                                  // coordinator not a member
        {`[` + coordinator + `]`, "agt_other", "inst_1"},            // agent mismatch
        {`[` + coordinator + `]`, "agt_1", ""},                      // agent without instance
        {`[{"agent_id":"agt_1","instance_id":"inst_1","role":"worker","enabled":"1"}]`, "agt_1", "inst_1"},
        {`[{"agent_id":"agt_1","instance_id":"inst_1","role":"coordinator","enabled":"0"}]`, "agt_1", "inst_1"},
        {`[` + coordinator + `,` + coordinator + `]`, "agt_1", "inst_1"}, // duplicate instance
        {`[{"agent_id":"agt_1","instance_id":"inst_1","role":"coordinator","enabled":"1","title":"x"}]`, "agt_1", "inst_1"},
        {`[{"agent_id":"agt 1","instance_id":"inst_1","role":"worker","enabled":"1"}]`, "", ""},
        {`{"agent_id":"agt_1"}`, "", ""},                            // not a list
        {`not json`, "", ""},
        {``, "", ""},
    }
    for c in cases {
        testing.expectf(t, !owner_document_valid("registry", registry_members_row(t, c[0], c[1], c[2])), "must reject %s / %s / %s", c[0], c[1], c[2])
    }
    // Members belong on a live chain row only.
    task := registry_members_row(t, "[]", "", "")
    task["task_id"] = json.String("task_1")
    task["task_title_cipher"] = task["chain_title_cipher"]
    task["chain_title_cipher"] = json.String("")
    task["chain_description_cipher"] = json.String("")
    testing.expect(t, !owner_document_valid("registry", task))
    tomb := registry_members_row(t, "[]", "", "")
    tomb["deleted"] = json.String("1")
    tomb["chain_title_cipher"] = json.String("")
    tomb["chain_description_cipher"] = json.String("")
    testing.expect(t, !owner_document_valid("registry", tomb))
    // At most OWNER_REGISTRY_MEMBERS_MAX members.
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "[")
    for i in 0..=OWNER_REGISTRY_MEMBERS_MAX {
        if i > 0 do strings.write_string(&b, ",")
        strings.write_string(&b, `{"agent_id":"agt","instance_id":"inst_`)
        strings.write_int(&b, i)
        strings.write_string(&b, `","role":"worker","enabled":"1"}`)
    }
    strings.write_string(&b, "]")
    testing.expect(t, !owner_document_valid("registry", registry_members_row(t, strings.to_string(b), "", "")))
}
