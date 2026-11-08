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

@(test)
owner_runtime_proof_vectors_bind_all_child_fields :: proc(t:^testing.T) {
    f:=owner_fixture(t)
    _,bridge:=owner_fixture_keys(f)
    for kind in ([2]string{"capability","lease_command"}) {
        o:=owner_fixture_document(t,f,kind)
        testing.expect(t,owner_verify_signature(kind,o,"signature",bridge))
        for name in ([8]string{"account_id","chain_id","task_id","lease_id","instance_id","launch_epoch","token_generation","configuration_revision"}) {
            original:=o[name]
            if name=="token_generation" {o[name]=json.String(strings.repeat("b",64,context.temp_allocator))} else if name=="configuration_revision" {o[name]=json.String("4")} else {o[name]=json.String("other")}
            testing.expectf(t,!owner_verify_signature(kind,o,"signature",bridge),"tampered %s %s",kind,name)
            o[name]=original
        }
    }
}

@(test)
owner_lifecycle_signature_binds_payload_and_child :: proc(t:^testing.T) {
    f:=owner_fixture(t)
    _,bridge:=owner_fixture_keys(f)
    c:=owner_fixture_document(t,f,"lifecycle_command")
    testing.expect(t,owner_verify_signature("lifecycle_command",c,"signature",bridge))
    c["payload_digest"]=json.String(strings.repeat("b",64,context.temp_allocator))
    testing.expect(t,!owner_verify_signature("lifecycle_command",c,"signature",bridge))
}

@(test)
owner_controls_require_task_mutation_and_switch_exact_fields :: proc(t:^testing.T) {
    f:=owner_fixture(t)
    o:=owner_fixture_document(t,f,"command")
    for method in ([6]string{"task.hold","task.release","task.cancel","task.reopen","task.resolve","merge.retry"}) {
        o["method"]=json.String(method)
        g:=owner_fixture_grant();g.method=method;g.can_mutate=false
        testing.expect(t,owner_document_valid("command",o))
        testing.expect_value(t,owner_live_admit(o,g,1000,9007199254740993),Owner_Auth_Error.Invalid_Scope)
        g.can_mutate=true
        testing.expect_value(t,owner_live_admit(o,g,1000,9007199254740993),Owner_Auth_Error.None)
        o["task_id"]=json.String("")
        testing.expect(t,!owner_document_valid("command",o))
        o["task_id"]=json.String("task_1")
    }
    raw:=`{"requirements_revision":"1","summary":"switch","next_steps":"","destination_chain_id":"chain","destination_task_id":"task","destination_revision":"4","destination_configuration_revision":"2","destination_requirements_revision":"3","destination_lease_id":"lease"}`
    p,ok:=owner_parse(raw,"switch_payload");testing.expect(t,ok)
    p["destination_revision"]=json.String("0")
    testing.expect(t,!owner_document_valid("switch_payload",p))
    p["destination_revision"]=json.String("4");p["owner_bridge_id"]=json.String("other")
    testing.expect(t,!owner_document_valid("switch_payload",p))
    p,ok=owner_parse(`{"requirements_revision":"1","attempt":"1","head":"","summary":"unfinished review","next_steps":"continue"}`,"checkpoint_payload")
    testing.expect(t,ok)
    p["verdict"]=json.String("approve")
    testing.expect(t,!owner_document_valid("checkpoint_payload",p),"checkpoint cannot carry a verdict")
}

@(test)
owner_workflow_language_shapes_and_output_variant_bind_all_fields :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    p,ok:=owner_parse(`{"requirements_revision":"1","head":"","summary":"done","output":"{}"}`,"submit_payload")
    if !testing.expect(t,ok) do return
    a,valid:=owner_canonical("submit_payload",p)
    testing.expect(t,valid)
    p["output"]=json.String(`{"changed":true}`)
    b,changed:=owner_canonical("submit_payload",p)
    testing.expect(t,changed && a!=b)
    _,ok=owner_parse(`{"configuration_revision":"1","agent_id":"agent","instance_id":"instance"}`,"coordinator_payload")
    testing.expect(t,ok)
    testing.expect_value(t,owner_payload_kind("workflow.gate.post"),"workflow_gate")
    testing.expect(t,owner_field_valid("workflow.gate.post","lifecycle_method"))
    testing.expect(t,!owner_field_valid("workflow.gate.post,task.reopen","coordinator_methods"))
}

@(test)
history_contracts_are_read_only_chain_scoped_and_strict :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for method in ([2]string{"history.read","history.fetch"}) {
        testing.expect(t,owner_method_valid(method))
        testing.expect_value(t,owner_payload_kind(method),("read_payload" if method=="history.read" else "history_fetch_payload"))
    }
    for raw in ([3]string{`{"seq":"0","offset":"0"}`,`{"seq":"1","offset":"-1"}`,`{"seq":"1","offset":"0","task_id":"other"}`}) {
        _,ok:=owner_parse(raw,"history_fetch_payload");testing.expect(t,!ok)
    }
    _,ok:=owner_parse(`{"seq":"9007199254740993","offset":"0"}`,"history_fetch_payload")
    testing.expect(t,ok)
}

@(test)
native_attempt_contract_is_task_scoped_read_only_and_validates_time_outcome :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=owner_fixture(t);c:=owner_fixture_document(t,f,"command")
    c["method"]=json.String("attempt.read");c["expected_revision"]=json.String("0")
    g:=owner_fixture_grant();g.method="attempt.read";g.can_mutate=false
    testing.expect_value(t,owner_live_admit(c,g,1000,1),Owner_Auth_Error.None)
    c["task_id"]=json.String("")
    testing.expect(t,!owner_document_valid("command",c))
    for raw in ([3]string{`{"attempt":"0"}`,`{"attempt":"-1"}`,`{"attempt":"1","lease_id":"forged"}`}) {
        _,ok:=owner_parse(raw,"attempt_read_payload");testing.expect(t,!ok)
    }
    raw:=`{"account_id":"account","chain_id":"chain","task_id":"task","attempt_no":"1","started_ms":"1000","ended_ms":"1100","holder_instance_id":"instance","outcome":"submitted","work_lease_id":"lease","completeness":"full"}`
    r,ok:=owner_parse(raw,"native_attempt");testing.expect(t,ok)
    r["outcome"]=json.String("expired:chain_closed")
    testing.expect(t,owner_document_valid("native_attempt",r))
    r["ended_ms"]=json.String("999");testing.expect(t,!owner_document_valid("native_attempt",r))
    r["ended_ms"]=json.String("");testing.expect(t,!owner_document_valid("native_attempt",r))
    r["outcome"]=json.String("");testing.expect(t,owner_document_valid("native_attempt",r))
    r["counted"]=json.String("1");testing.expect(t,!owner_document_valid("native_attempt",r))
}

@(test)
native_history_contracts_bind_snapshot_scope_typed_keys_and_mutation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    fixture:=owner_fixture(t);c:=owner_fixture_document(t,fixture,"command")
    for method in ([3]string{"native.history.import","native.history.read","native.history.fetch"}) {
        c["method"]=json.String(method);c["expected_revision"]=json.String("0")
        g:=owner_fixture_grant();g.method=method;g.can_mutate=false
        expected:=Owner_Auth_Error.None
        if method=="native.history.import" do expected=.Invalid_Scope
        testing.expect_value(t,owner_live_admit(c,g,1000,1),expected)
    }
    for raw in ([4]string{
        `{"source_revision":"original_7","kind":"facet","cursor":"","limit":"101"}`,
        `{"source_revision":"original_7","kind":"summary","cursor":"","limit":"1"}`,
        `{"source_revision":"original_7","kind":"facet","cursor":"","limit":"0"}`,
        `{"source_revision":"original_7","kind":"facet","cursor":"","limit":"1","task_id":"forged"}`}) {
        _,ok:=owner_parse(raw,"native_history_read");testing.expect(t,!ok)
    }
    _,ok:=owner_parse(`{"source_revision":"original_7","kind":"facet","cursor":"hash:[\"3\",\"output\",\"2\"]","limit":"100"}`,"native_history_read")
    testing.expect(t,ok)
}

@(test)
native_placement_facet_zero_is_not_a_work_attempt :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    raw:=string(#load("fixtures/owner-native-placement-pregrant.json"))
    bundle,valid:=owner_parse(raw,"native_history_bundle")
    if !testing.expect(t,valid) do return
    value,_:=owner_request_document(owner_string(bundle,"facets"));items,_:=value.(json.Array)
    text,_:=items[0].(json.String);facet,ok:=owner_parse(string(text),"native_history_facet")
    if !testing.expect(t,ok) do return
    testing.expect_value(t,owner_string(facet,"attempt_no"),"0")
    testing.expect_value(t,owner_string(facet,"kind"),"placement")
    facet["kind"]=json.String("handoff");testing.expect(t,!owner_document_valid("native_history_facet",facet))
    facet["kind"]=json.String("placement");facet["attempt_no"]=json.String("1")
    testing.expect(t,owner_document_valid("native_history_facet",facet))
    facet["attempt_no"]=json.String("-1");testing.expect(t,!owner_document_valid("native_history_facet",facet))
    testing.expect(t,!owner_field_valid("0","positive"))
}

@(test)
operational_metadata_contracts_are_chain_scoped_strict_mutations :: proc(t:^testing.T) {
    f:=owner_fixture(t)
    for method in ([2]string{"chain.member.set","chain.directory.set"}) {
        c:=owner_fixture_document(t,f,"command")
        c["method"]=json.String(method);c["task_id"]=json.String("")
        testing.expect(t,owner_document_valid("command",c))
        c["task_id"]=json.String("task")
        testing.expect(t,!owner_document_valid("command",c))
    }
    _,valid:=owner_parse("{\"instance_id\":\"instance\",\"agent_id\":\"agent\",\"role\":\"worker\",\"enabled\":\"1\"}","member_payload")
    testing.expect(t,valid)
    for raw in ([3]string{
        "{\"instance_id\":\"instance\",\"agent_id\":\"agent\",\"role\":\"security role\",\"enabled\":\"1\"}",
        "{\"instance_id\":\"instance\",\"agent_id\":\"agent\",\"role\":\"worker\",\"enabled\":true}",
        "{\"instance_id\":\"instance\",\"agent_id\":\"agent\",\"role\":\"worker\",\"enabled\":\"1\",\"capability\":\"grant\"}",
    }) { _,ok:=owner_parse(raw,"member_payload");testing.expect(t,!ok) }
}

@(test)
brief_pinned_reference_vocabulary_rejects_mutable_latest_and_unknown_types :: proc(t:^testing.T) {
    for raw in ([7]string{"#7","output:task:1:2","facet:task:1:handoff","facet:task:1:output:2","output:task:durable:1:2","facet:task:durable:1:output:2","facet:task:0:placement:1"}) {
        _,ok:=owner_pinned_ref(raw);testing.expect(t,ok)
    }
    for raw in ([8]string{"output:task","output:task:1","output:task:01:1","#0","facet:task:1:unknown","facet:task:1:output:0","artifact:mutable"," file@main"}) {
        _,ok:=owner_pinned_ref(raw);testing.expect(t,!ok)
    }
}

// P-CS CC-B: coordinator work payloads and methods are additive; existing
// payload shapes are unchanged.
@(test)
owner_coordinator_work_payloads_are_strict :: proc(t:^testing.T) {
    for m in ([4]string{"lifecycle.force_submit","task.complete","task.split","chain.policy.set"}) do testing.expectf(t,owner_method_valid(m),"%s is an owner method",m)
    testing.expect_value(t,owner_payload_kind("lifecycle.force_submit"),"force_submit_payload")
    testing.expect_value(t,owner_payload_kind("task.complete"),"complete_payload")
    testing.expect_value(t,owner_payload_kind("task.split"),"comment_payload")
    testing.expect_value(t,owner_payload_kind("chain.policy.set"),"chain_policy_payload")
    _,ok:=owner_parse(`{"policy":"coordinator_force_done","value":"0"}`,"chain_policy_payload")
    testing.expect(t,ok)
    _,ok=owner_parse(`{"policy":"anything_else","value":"0"}`,"chain_policy_payload")
    testing.expect(t,!ok,"only named policies")
    _,ok=owner_parse(`{"attempt":"1","head":"","force":"yes","body_cipher":""}`,"complete_payload")
    testing.expect(t,!ok,"force is a flag and the reason cipher is required")
    _,ok=owner_parse(`{"requirements_revision":"1","head":"not-a-commit","summary":"s","override_ack":"0","body_cipher":""}`,"force_submit_payload")
    testing.expect(t,!ok,"head must be a commit or empty")
    // Unchanged: lease submit keeps its exact shape.
    _,ok=owner_parse(`{"requirements_revision":"1","head":"","summary":"s"}`,"submit_payload")
    testing.expect(t,ok)
}
