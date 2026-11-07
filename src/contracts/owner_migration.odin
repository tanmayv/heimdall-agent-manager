package contracts

import "core:encoding/json"
import "core:strconv"

// These proofs authenticate migration consent/evidence only. None grants task
// authority. The source must persist freeze, receipt and route CAS boundaries;
// the destination remains quarantined until the correlated cutover completes.
// As with command receipts, authenticate before looking up replay, and check
// expiry/revision only on a receipt miss.
owner_verify_migration_selection :: proc(o:json.Object, account, chain:string, device, owner:Owner_Verified_Key) -> Owner_Auth_Error {
    if !owner_document_valid("migration_selection",o) do return .Malformed
    if owner_string(o,"account_id")!=account || owner_string(o,"chain_id")!=chain || device.account_id!=account || owner.account_id!=account do return .Invalid_Scope
    if device.kind!="device" || device.principal_id!=owner_string(o,"principal_id") || device.key_id!=owner_string(o,"key_id") do return .Invalid_Scope
    if owner.kind!="bridge" || owner.principal_id!=owner_string(o,"owner_bridge_id") || owner.key_id!=owner_string(o,"owner_key_id") do return .Owner_Mismatch
    // Approval of the selected enrolled identity is separate from content-key
    // possession and from the consenting device's signature.
    if !owner.enrolled || owner.revoked do return .Owner_Mismatch
    if !owner_verify_signature("migration_selection",o,"signature",device) do return .Bad_Signature
    return .None
}

owner_migration_admit :: proc(kind:string, o:json.Object, now, expected_revision:i64) -> Owner_Auth_Error {
    if kind!="migration_selection" && kind!="migration_control" do return .Malformed
    if !owner_document_valid(kind,o) do return .Malformed
    expires,_:=strconv.parse_i64(owner_string(o,"request_expires_ms"))
    if now<0 || expires<=now || expires-now>OWNER_REQUEST_TTL_MS do return .Expired
    revision_field:="expected_revision"
    if kind=="migration_selection" do revision_field="expected_work_revision"
    revision,_:=strconv.parse_i64(owner_string(o,revision_field))
    if revision!=expected_revision do return .Stale_Revision
    return .None
}

owner_verify_migration_import :: proc(receipt, selection, genesis:json.Object, manifest_digest:string, owner:Owner_Verified_Key) -> Owner_Auth_Error {
    if !owner_document_valid("migration_import_receipt",receipt) || !owner_document_valid("migration_selection",selection) || !owner_document_valid("genesis",genesis) || !owner_hex(manifest_digest,64) do return .Malformed
    account,chain:=owner_string(selection,"account_id"),owner_string(selection,"chain_id")
    if owner.kind!="bridge" || owner.account_id!=account || owner.principal_id!=owner_string(selection,"owner_bridge_id") || owner.key_id!=owner_string(selection,"owner_key_id") do return .Owner_Mismatch
    for object in ([2]json.Object{receipt,genesis}) {
        if owner_string(object,"account_id")!=account || owner_string(object,"chain_id")!=chain do return .Invalid_Scope
        if owner_string(object,"owner_bridge_id")!=owner.principal_id do return .Owner_Mismatch
    }
    if owner_string(receipt,"key_id")!=owner.key_id || owner_string(genesis,"owner_key_id")!=owner.key_id do return .Owner_Mismatch
    selection_digest,_:=owner_digest("migration_selection",selection)
    genesis_digest,_:=owner_digest("genesis",genesis)
    if owner_string(receipt,"selection_digest")!=selection_digest || owner_string(receipt,"manifest_digest")!=manifest_digest || owner_string(receipt,"genesis_digest")!=genesis_digest do return .Digest_Mismatch
    if owner_string(receipt,"migration_id")!=owner_string(selection,"migration_id") || owner_string(genesis,"creation_op")!=owner_string(selection,"migration_id") do return .Invalid_Scope
    if owner_string(genesis,"creator_id")!=owner_string(selection,"principal_id") || owner_string(genesis,"creator_key_id")!=owner_string(selection,"key_id") do return .Invalid_Scope
    if owner_string(receipt,"schema_version")!=owner_string(genesis,"schema_version") do return .Invalid_Scope
    if !owner_verify_signature("migration_import_receipt",receipt,"signature",owner) || !owner_verify_signature("genesis",genesis,"owner_signature",owner) do return .Bad_Signature
    return .None
}

// For cutover, evidence_digest names the exact verified import receipt. For
// resume, it must name a verified destination discard/retirement receipt. A
// signed request alone cannot establish either fact or enable either writer.
owner_verify_migration_control :: proc(o, selection:json.Object, evidence_digest:string, device:Owner_Verified_Key) -> Owner_Auth_Error {
    if !owner_document_valid("migration_control",o) || !owner_document_valid("migration_selection",selection) || !owner_hex(evidence_digest,64) do return .Malformed
    account:=owner_string(selection,"account_id")
    if device.kind!="device" || device.account_id!=account || device.principal_id!=owner_string(o,"principal_id") || device.key_id!=owner_string(o,"key_id") do return .Invalid_Scope
    for name in ([4]string{"account_id","chain_id","migration_id","owner_bridge_id"}) do if owner_string(o,name)!=owner_string(selection,name) do return .Invalid_Scope
    digest,_:=owner_digest("migration_selection",selection)
    if owner_string(o,"selection_digest")!=digest || owner_string(o,"evidence_digest")!=evidence_digest do return .Digest_Mismatch
    if !owner_verify_signature("migration_control",o,"signature",device) do return .Bad_Signature
    return .None
}
