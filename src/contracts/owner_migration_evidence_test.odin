package contracts

import "core:encoding/json"
import "core:strings"
import "core:testing"

migration_evidence_fixture :: proc(t:^testing.T)->json.Object {
    value,ok:=owner_content_document(#load("fixtures/migration-evidence-v1.json",string))
    testing.expect(t,ok)
    root,_:=value.(json.Object)
    return root
}

@(test)
migration_evidence_domains_signatures_and_complete_set_bytes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=migration_evidence_fixture(t)
    valid,_:=f["valid"].(json.Array)
    for row in valid {
        entry,_:=row.(json.Object)
        kind:=owner_string(entry,"kind")
        o,parsed:=owner_parse(owner_string(entry,"raw"),kind)
        testing.expect(t,parsed)
        canonical,ok:=owner_canonical(kind,o);digest,_:=owner_digest(kind,o)
        testing.expect(t,ok && canonical==owner_string(entry,"canonical") && digest==owner_string(entry,"digest"))
        if "signature" in o {
            device:=kind=="migration_selection" || kind=="migration_origin_binding"
            key:=Owner_Verified_Key{"account","device" if device else "executor","device_key" if device else "executor_key",owner_string(f,"device_public_key" if device else "executor_public_key"),"device" if device else "bridge",true,false}
            testing.expect(t,owner_verify_signature(kind,o,"signature",key))
            for field in owner_schema(kind) {
                if field.kind=="signature" do continue
                old:=o[field.name];o[field.name]=json.String("tampered")
                testing.expectf(t,!owner_verify_signature(kind,o,"signature",key),"signature binds %s.%s",kind,field.name)
                o[field.name]=old
            }
        }
    }
    sets,_:=f["sets"].(json.Object)
    for pair in ([3][2]string{{"migration_effect","effects"},{"migration_mapping","mappings"},{"migration_inventory_reference","executors"}}) {
        row:=owner_fixture_document(t,f,pair[0])
        digest,ok:=owner_migration_set_digest(pair[0],[]json.Object{row})
        testing.expect(t,ok && digest==owner_string(sets,pair[1]))
        _,ok=owner_migration_set_digest(pair[0],[]json.Object{row,row})
        testing.expect(t,!ok,"duplicate complete identities cannot masquerade as coverage")
    }
}

@(test)
migration_adoption_is_separate_and_binds_selection_pin_inventory_and_mapping :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=migration_evidence_fixture(t)
    selection:=owner_fixture_document(t,f,"migration_selection")
    source:=owner_fixture_document(t,f,"migration_source_inventory")
    inventory:=owner_fixture_document(t,f,"migration_executor_inventory")
    binding:=owner_fixture_document(t,f,"migration_origin_binding")
    effect:=owner_fixture_document(t,f,"migration_effect")
    mapping:=owner_fixture_document(t,f,"migration_mapping")
    device:=Owner_Verified_Key{"account","device","device_key",owner_string(f,"device_public_key"),"device",true,false}
    executor:=Owner_Verified_Key{"account","executor","executor_key",owner_string(f,"executor_public_key"),"bridge",true,false}
    pin:=Owner_Migration_Directory_Pin{owner_string(binding,"directory_root"),owner_string(binding,"directory_head"),5,2}
    inventories,mappings:=owner_string(binding,"executor_inventories_digest"),owner_string(binding,"mapping_digest")
    testing.expect_value(t,owner_verify_migration_executor_inventory(inventory,source,owner_string(binding,"nonce"),executor),Owner_Auth_Error.None)
    testing.expect_value(t,owner_verify_migration_adoption(binding,selection,source,inventories,mappings,1,pin,device),Owner_Auth_Error.None)
    testing.expect(t,owner_migration_mapping_matches(effect,mapping))
    for name in ([7]string{"parent_digest","entry_digest","effect_id","command_id","task_id","instance_id","lease_id"}) {
        old:=mapping[name];mapping[name]=json.String("other")
        testing.expect(t,!owner_migration_mapping_matches(effect,mapping),"batch/entry/target relabel denied")
        mapping[name]=old
    }
    old_key:=mapping["launch_key"];mapping["launch_key"]=json.String(strings.repeat("f",64,context.temp_allocator))
    changed,ok:=owner_migration_set_digest("migration_mapping",[]json.Object{mapping})
    testing.expect(t,ok && changed!=mappings,"native child substitution changes adopted mapping")
    mapping["launch_key"]=old_key
    testing.expect_value(t,owner_verify_migration_adoption(binding,selection,source,inventories,changed,1,pin,device),Owner_Auth_Error.Digest_Mismatch)
    testing.expect_value(t,owner_verify_migration_adoption(binding,selection,source,inventories,mappings,0,pin,device),Owner_Auth_Error.Digest_Mismatch)
    changed_pin:=pin;changed_pin.sequence=4
    testing.expect_value(t,owner_verify_migration_adoption(binding,selection,source,inventories,mappings,1,changed_pin,device),Owner_Auth_Error.Invalid_Scope)
    revoked:=device;revoked.revoked=true
    testing.expect_value(t,owner_verify_migration_adoption(binding,selection,source,inventories,mappings,1,pin,revoked),Owner_Auth_Error.Bad_Signature)
    old:=binding["signature"];binding["signature"]=selection["signature"]
    testing.expect_value(t,owner_verify_migration_adoption(binding,selection,source,inventories,mappings,1,pin,device),Owner_Auth_Error.Bad_Signature)
    binding["signature"]=old
    old=binding["purpose"];binding["purpose"]=json.String("launch")
    testing.expect(t,!owner_document_valid("migration_origin_binding",binding),"adoption has no task execution purpose")
    binding["purpose"]=old
    old=source["source_generation"];source["source_generation"]=json.String("9007199254740992")
    testing.expect_value(t,owner_verify_migration_adoption(binding,selection,source,inventories,mappings,1,pin,device),Owner_Auth_Error.Invalid_Scope)
    source["source_generation"]=old
}

@(test)
migration_drain_refuses_unknown_live_partial_stale_and_expired_evidence :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=migration_evidence_fixture(t)
    source:=owner_fixture_document(t,f,"migration_source_inventory")
    inventory:=owner_fixture_document(t,f,"migration_executor_inventory")
    binding:=owner_fixture_document(t,f,"migration_origin_binding")
    drain:=owner_fixture_document(t,f,"migration_executor_drain")
    executor:=Owner_Verified_Key{"account","executor","executor_key",owner_string(f,"executor_public_key"),"bridge",true,false}
    barrier,challenge:=owner_string(drain,"barrier_receipt_digest"),owner_string(drain,"challenge")
    testing.expect_value(t,owner_verify_migration_executor_drain(drain,inventory,binding,barrier,challenge,executor),Owner_Auth_Error.None)
    for name in ([5]string{"unresolved_count","admitted_handler_count","live_child_count","merge_count","queued_action_count"}) {
        old:=drain[name];drain[name]=json.String("1")
        testing.expect_value(t,owner_verify_migration_executor_drain(drain,inventory,binding,barrier,challenge,executor),Owner_Auth_Error.Invalid_Scope)
        drain[name]=old
    }
    old:=inventory["unknown_count"];inventory["unknown_count"]=json.String("1")
    testing.expect_value(t,owner_verify_migration_executor_inventory(inventory,source,owner_string(inventory,"challenge"),executor),Owner_Auth_Error.Invalid_Scope)
    inventory["unknown_count"]=old
    old=drain["executor_incarnation"];drain["executor_incarnation"]=json.String("2")
    testing.expect_value(t,owner_verify_migration_executor_drain(drain,inventory,binding,barrier,challenge,executor),Owner_Auth_Error.Invalid_Scope)
    drain["executor_incarnation"]=old
    testing.expect_value(t,owner_verify_migration_executor_drain(drain,inventory,binding,barrier,owner_string(inventory,"challenge"),executor),Owner_Auth_Error.Digest_Mismatch)
    for kind in ([3]string{"migration_executor_inventory","migration_executor_drain","migration_origin_binding"}) {
        doc:=owner_fixture_document(t,f,kind)
        testing.expect_value(t,owner_migration_observation_admit(kind,doc,1000),Owner_Auth_Error.None)
        testing.expect_value(t,owner_migration_observation_admit(kind,doc,999),Owner_Auth_Error.Expired)
        testing.expect_value(t,owner_migration_observation_admit(kind,doc,2000),Owner_Auth_Error.Expired)
        // Expiry is a receipt-miss admission rule, not proof authentication.
        doc["source_generation"]=json.String("0")
        testing.expect(t,owner_document_valid(kind,doc),"zero generation is valid syntax, not unknown-history clearance")
    }
}
