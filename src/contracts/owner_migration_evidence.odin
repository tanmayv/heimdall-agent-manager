package contracts

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Supplied by the existing pinned, verified enrollment directory, freshly
// resolved at the mutation gate. A signed document cannot supply its own pin.
Owner_Migration_Directory_Pin :: struct {root,head:string,sequence,epoch:i64}

// These routines verify proof correlation only. They neither establish local
// observation completeness nor authorize task execution, physical stop, source
// freeze or import. Those transitions must compare retained native evidence
// and current journal/CAS under their own transaction and physical gates.
owner_migration_correlates :: proc(a,b:json.Object)->bool {
    for name in ([5]string{"account_id","chain_id","migration_id","selection_digest","source_generation"}) {
        if owner_string(a,name)!=owner_string(b,name) do return false
    }
    return true
}

owner_migration_observation_admit :: proc(kind:string,o:json.Object,now:i64)->Owner_Auth_Error {
    if kind!="migration_executor_inventory" && kind!="migration_executor_drain" && kind!="migration_origin_binding" do return .Malformed
    if !owner_document_valid(kind,o) do return .Malformed
    issued_field:="observed_ms"
    if kind=="migration_origin_binding" do issued_field="issued_ms"
    issued,_:=strconv.parse_i64(owner_string(o,issued_field))
    expires,_:=strconv.parse_i64(owner_string(o,"request_expires_ms"))
    if now<0 || issued>now || expires<=now || issued>=expires || expires-issued>OWNER_REQUEST_TTL_MS do return .Expired
    return .None
}

owner_verify_migration_executor_inventory :: proc(o,source:json.Object,challenge:string,key:Owner_Verified_Key)->Owner_Auth_Error {
    if !owner_document_valid("migration_executor_inventory",o) || !owner_document_valid("migration_source_inventory",source) || !owner_hex(challenge,64) do return .Malformed
    if key.kind!="bridge" || key.account_id!=owner_string(o,"account_id") || key.principal_id!=owner_string(o,"executor_bridge_id") || key.key_id!=owner_string(o,"key_id") do return .Invalid_Scope
    if !owner_migration_correlates(o,source) do return .Invalid_Scope
    digest,_:=owner_digest("migration_source_inventory",source)
    if owner_string(o,"source_inventory_digest")!=digest || owner_string(o,"challenge")!=challenge do return .Digest_Mismatch
    if owner_string(source,"admission_closed")!="1" || owner_string(source,"coverage_version")!="1" || owner_string(o,"coverage_version")!="1" || owner_string(o,"complete")!="1" || owner_string(o,"unknown_count")!="0" do return .Invalid_Scope
    if !owner_verify_signature("migration_executor_inventory",o,"signature",key) do return .Bad_Signature
    return .None
}

// Equality to source fields is correlation, not original authority. Callers
// must also match this entire mapping against the signed local inventory and
// retained native admission/current target, never just a source-supplied row.
owner_migration_mapping_matches :: proc(effect,mapping:json.Object)->bool {
    if !owner_document_valid("migration_effect",effect) || !owner_document_valid("migration_mapping",mapping) do return false
    digest,_:=owner_digest("migration_effect",effect)
    if owner_string(mapping,"effect_digest")!=digest do return false
    for name in ([10]string{"executor_bridge_id","effect_id","command_id","entry_index","kind","parent_digest","entry_digest","task_id","instance_id","lease_id"}) {
        if owner_string(mapping,name)!=owner_string(effect,name) do return false
    }
    kind:=owner_string(mapping,"target_kind")
    if kind=="never_admitted" {
        // This claim needs separately verified durable barrier/queue evidence;
        // a matching empty tuple can never authorize a physical close or grant.
        for field in ([10]string{"native_admission_digest","launch_key","launch_epoch","token_generation","configuration_digest","directory_id","directory_key","workdir_hash","repository_hash","branch"}) {
            if owner_string(mapping,field)!="" do return false
        }
        return owner_string(mapping,"run_count")=="0" && owner_string(mapping,"directory_revision")=="0"
    }
    if !owner_hex(owner_string(mapping,"native_admission_digest"),64) || !owner_hex(owner_string(mapping,"workdir_hash"),64) do return false
    if kind=="merge" {
        return owner_string(effect,"kind")=="merge" && owner_string(mapping,"task_id")!="" && owner_hex(owner_string(mapping,"repository_hash"),64) && owner_string(mapping,"branch")!="" && owner_string(mapping,"launch_key")=="" && owner_string(mapping,"run_count")=="0"
    }
    if owner_string(effect,"kind")=="merge" || owner_string(mapping,"instance_id")=="" || owner_string(mapping,"launch_epoch")=="" || owner_string(mapping,"directory_id")=="" || owner_string(mapping,"run_count")=="0" || owner_string(mapping,"directory_revision")=="0" do return false
    for name in ([4]string{"launch_key","token_generation","configuration_digest","directory_key"}) {
        if !owner_hex(owner_string(mapping,name),64) do return false
    }
    return true
}

owner_verify_migration_adoption :: proc(o,selection,source:json.Object,executor_set_digest,mapping_digest:string,mapping_count:i64,pin:Owner_Migration_Directory_Pin,device:Owner_Verified_Key)->Owner_Auth_Error {
    if !owner_document_valid("migration_origin_binding",o) || !owner_document_valid("migration_selection",selection) || !owner_document_valid("migration_source_inventory",source) || !owner_hex(executor_set_digest,64) || !owner_hex(mapping_digest,64) || mapping_count<0 do return .Malformed
    if device.kind!="device" || device.account_id!=owner_string(o,"account_id") || device.principal_id!=owner_string(o,"principal_id") || device.key_id!=owner_string(o,"key_id") do return .Invalid_Scope
    for name in ([5]string{"account_id","chain_id","migration_id","owner_bridge_id","owner_key_id"}) {
        if owner_string(o,name)!=owner_string(selection,name) do return .Invalid_Scope
    }
    if !owner_migration_correlates(o,source) || owner_string(o,"source_revision")!=owner_string(source,"source_revision") || owner_string(o,"executor_count")!=owner_string(source,"executor_count") || owner_string(source,"admission_closed")!="1" do return .Invalid_Scope
    selection_digest,_:=owner_digest("migration_selection",selection)
    source_digest,_:=owner_digest("migration_source_inventory",source)
    if owner_string(o,"selection_digest")!=selection_digest || owner_string(o,"source_inventory_digest")!=source_digest || owner_string(o,"executor_inventories_digest")!=executor_set_digest || owner_string(o,"mapping_digest")!=mapping_digest || owner_string(o,"mapping_count")!=fmt.tprintf("%d",mapping_count) do return .Digest_Mismatch
    if !owner_hex(pin.root,64) || !owner_hex(pin.head,64) || pin.sequence<0 || pin.epoch<=0 do return .Invalid_Scope
    if owner_string(o,"directory_root")!=pin.root || owner_string(o,"directory_head")!=pin.head || owner_string(o,"directory_sequence")!=fmt.tprintf("%d",pin.sequence) || owner_string(o,"directory_epoch")!=fmt.tprintf("%d",pin.epoch) do return .Invalid_Scope
    if !owner_verify_signature("migration_origin_binding",o,"signature",device) do return .Bad_Signature
    return .None
}

owner_verify_migration_executor_drain :: proc(o,inventory,binding:json.Object,barrier_digest,challenge:string,key:Owner_Verified_Key)->Owner_Auth_Error {
    if !owner_document_valid("migration_executor_drain",o) || !owner_document_valid("migration_executor_inventory",inventory) || !owner_document_valid("migration_origin_binding",binding) || !owner_hex(barrier_digest,64) || !owner_hex(challenge,64) do return .Malformed
    if key.kind!="bridge" || key.account_id!=owner_string(o,"account_id") || key.principal_id!=owner_string(o,"executor_bridge_id") || key.key_id!=owner_string(o,"key_id") do return .Invalid_Scope
    if !owner_migration_correlates(o,inventory) || !owner_migration_correlates(o,binding) do return .Invalid_Scope
    for name in ([3]string{"executor_bridge_id","key_id","executor_incarnation"}) {
        if owner_string(o,name)!=owner_string(inventory,name) do return .Invalid_Scope
    }
    old_sequence,_:=strconv.parse_i64(owner_string(inventory,"journal_sequence"))
    sequence,_:=strconv.parse_i64(owner_string(o,"journal_sequence"))
    if sequence<old_sequence || owner_string(o,"complete")!="1" do return .Invalid_Scope
    for name in ([5]string{"unresolved_count","admitted_handler_count","live_child_count","merge_count","queued_action_count"}) {
        if owner_string(o,name)!="0" do return .Invalid_Scope
    }
    inventory_digest,_:=owner_digest("migration_executor_inventory",inventory)
    binding_digest,_:=owner_digest("migration_origin_binding",binding)
    if owner_string(o,"inventory_digest")!=inventory_digest || owner_string(o,"binding_digest")!=binding_digest || owner_string(o,"barrier_receipt_digest")!=barrier_digest || owner_string(o,"challenge")!=challenge || owner_string(o,"mapping_digest")!=owner_string(binding,"mapping_digest") || owner_string(o,"source_inventory_digest")!=owner_string(binding,"source_inventory_digest") do return .Digest_Mismatch
    if !owner_verify_signature("migration_executor_drain",o,"signature",key) do return .Bad_Signature
    return .None
}

// Canonical complete sets are strictly ordered by typed identity. Incomplete
// pages must be assembled/verified before calling this; count alone is never
// coverage. Reject duplicate identities even when the duplicate body differs.
owner_migration_set_digest :: proc(kind:string,rows:[]json.Object)->(string,bool) {
    if len(rows)>100_000 do return "",false
    identity_fields:[]string
    switch kind {
    case "migration_effect": identity_fields=[]string{"effect_id","entry_index"}
    case "migration_mapping": identity_fields=[]string{"executor_bridge_id","effect_id","entry_index"}
    case "migration_inventory_reference": identity_fields=[]string{"executor_bridge_id"}
    case: return "",false
    }
    b:strings.Builder;strings.builder_init(&b,context.temp_allocator)
    strings.write_string(&b,fmt.tprintf("heimdall-migration-set/%s/v1\n%d:",kind,len(rows)))
    previous:=""
    for row,i in rows {
        canonical,valid:=owner_canonical(kind,row)
        if !valid do return "",false
        identity:strings.Builder;strings.builder_init(&identity,context.temp_allocator)
        for field in identity_fields {
            value:=owner_string(row,field)
            strings.write_string(&identity,fmt.tprintf("%d:%s,",len(value),value))
        }
        current:=strings.to_string(identity)
        if i>0 && strings.compare(previous,current)>=0 do return "",false
        previous=current
        strings.write_string(&b,fmt.tprintf("%d:%s,",len(canonical),canonical))
    }
    return owner_payload_digest(strings.to_string(b)),true
}
