package contracts

import "core:encoding/json"
import "core:strings"
import "core:testing"

migration_fixture :: proc(t:^testing.T) -> (json.Object,json.Object,json.Object,json.Object,json.Object,Owner_Verified_Key,Owner_Verified_Key) {
    v,ok:=owner_content_document(#load("fixtures/owner-migration-v1.json",string))
    testing.expect(t,ok)
    f,_:=v.(json.Object)
    selection:=owner_fixture_document(t,f,"migration_selection")
    genesis:=owner_fixture_document(t,f,"genesis")
    receipt:=owner_fixture_document(t,f,"migration_import_receipt")
    control:=owner_fixture_document(t,f,"migration_control")
    device:=Owner_Verified_Key{"account","device","device_key",owner_string(f,"device_public_key"),"device",true,false}
    owner:=Owner_Verified_Key{"account","bridge","bridge_key",owner_string(f,"owner_public_key"),"bridge",true,false}
    return f,selection,genesis,receipt,control,device,owner
}

@(test)
migration_signed_selection_requires_explicit_current_device_and_owner :: proc(t:^testing.T) {
    f,s,_,_,_,device,owner:=migration_fixture(t)
    rows,_:=f["valid"].(json.Array)
    for row in rows {
        entry,_:=row.(json.Object)
        kind:=owner_string(entry,"kind")
        o,ok:=owner_parse(owner_string(entry,"raw"),kind)
        testing.expect(t,ok)
        canonical,_:=owner_canonical(kind,o);digest,_:=owner_digest(kind,o)
        testing.expect_value(t,canonical,owner_string(entry,"canonical"))
        testing.expect_value(t,digest,owner_string(entry,"digest"))
        // Every authority field, including keys, deadline and large decimal
        // revision, is covered by a distinct canonical signature domain.
        signer:=device
        signature:="signature"
        if kind=="migration_import_receipt" do signer=owner
        if kind=="genesis" { signer=owner;signature="owner_signature" }
        testing.expect(t,owner_verify_signature(kind,o,signature,signer))
        for field in owner_schema(kind) {
            if field.kind=="signature" do continue
            old:=o[field.name]
            o[field.name]=json.String("changed")
            testing.expectf(t,!owner_verify_signature(kind,o,signature,signer),"tampered %s.%s",kind,field.name)
            o[field.name]=old
        }
    }
    testing.expect_value(t,owner_verify_migration_selection(s,"account","chain",device,owner),Owner_Auth_Error.None)
    old_revision:=s["expected_work_revision"]
    s["expected_work_revision"]=json.String("0")
    testing.expect(t,owner_document_valid("migration_selection",s),"empty legacy chain work revision remains zero")
    testing.expect_value(t,owner_migration_admit("migration_selection",s,1000,0),Owner_Auth_Error.None)
    s["expected_work_revision"]=old_revision
    testing.expect_value(t,owner_verify_migration_selection(s,"other","chain",device,owner),Owner_Auth_Error.Invalid_Scope)
    testing.expect_value(t,owner_verify_migration_selection(s,"account","other",device,owner),Owner_Auth_Error.Invalid_Scope)
    changed:=owner;changed.principal_id="another_bridge"
    testing.expect_value(t,owner_verify_migration_selection(s,"account","chain",device,changed),Owner_Auth_Error.Owner_Mismatch)
    changed=owner;changed.revoked=true
    testing.expect_value(t,owner_verify_migration_selection(s,"account","chain",device,changed),Owner_Auth_Error.Owner_Mismatch)
    changed=device;changed.kind="bridge"
    testing.expect_value(t,owner_verify_migration_selection(s,"account","chain",changed,owner),Owner_Auth_Error.Invalid_Scope)
    changed=device;changed.revoked=true
    testing.expect_value(t,owner_verify_migration_selection(s,"account","chain",changed,owner),Owner_Auth_Error.Bad_Signature)
    testing.expect_value(t,owner_migration_admit("migration_selection",s,1000,9007199254740993),Owner_Auth_Error.None)
    testing.expect_value(t,owner_migration_admit("migration_selection",s,1000,9007199254740992),Owner_Auth_Error.Stale_Revision)
    testing.expect_value(t,owner_migration_admit("migration_selection",s,2000,9007199254740993),Owner_Auth_Error.Expired)
    testing.expect_value(t,owner_migration_admit("migration_selection",s,-1,9007199254740993),Owner_Auth_Error.Expired)
    // Authentication itself is independent of admission expiry for replay.
    testing.expect_value(t,owner_verify_migration_selection(s,"account","chain",device,owner),Owner_Auth_Error.None)
}

@(test)
migration_import_and_control_bind_exact_selection_manifest_genesis_and_evidence :: proc(t:^testing.T) {
    f,s,g,r,c,device,owner:=migration_fixture(t)
    manifest:=owner_string(f,"manifest_digest")
    evidence,_:=owner_digest("migration_import_receipt",r)
    testing.expect_value(t,owner_verify_migration_import(r,s,g,manifest,owner),Owner_Auth_Error.None)
    testing.expect_value(t,owner_verify_migration_import(r,s,g,strings.repeat("b",64,context.temp_allocator),owner),Owner_Auth_Error.Digest_Mismatch)
    testing.expect_value(t,owner_verify_migration_control(c,s,evidence,device),Owner_Auth_Error.None)
    testing.expect_value(t,owner_verify_migration_control(c,s,manifest,device),Owner_Auth_Error.Digest_Mismatch)
    testing.expect_value(t,owner_migration_admit("migration_control",c,1000,3),Owner_Auth_Error.None)
    testing.expect_value(t,owner_migration_admit("migration_control",c,1000,2),Owner_Auth_Error.Stale_Revision)
    testing.expect_value(t,owner_migration_admit("migration_control",c,2000,3),Owner_Auth_Error.Expired)
    changed:=owner;changed.revoked=true
    testing.expect_value(t,owner_verify_migration_import(r,s,g,manifest,changed),Owner_Auth_Error.Bad_Signature)
    old:=c["action"];c["action"]=json.String("resume")
    testing.expect_value(t,owner_verify_migration_control(c,s,evidence,device),Owner_Auth_Error.Bad_Signature)
    c["action"]=old
    old=r["migration_id"];r["migration_id"]=json.String("other")
    testing.expect_value(t,owner_verify_migration_import(r,s,g,manifest,owner),Owner_Auth_Error.Invalid_Scope)
    r["migration_id"]=old
    old=g["creation_op"];g["creation_op"]=json.String("other")
    testing.expect_value(t,owner_verify_migration_import(r,s,g,manifest,owner),Owner_Auth_Error.Digest_Mismatch)
    g["creation_op"]=old
    testing.expect(t,!owner_verify_signature("migration_selection",c,"signature",device),"domain separation")
    _,parsed:=owner_parse(`{"protocol_version":"1","protocol_version":"1"}`,"migration_selection")
    testing.expect(t,!parsed)
    c["action"]=json.String("activate")
    testing.expect(t,!owner_document_valid("migration_control",c))
}
