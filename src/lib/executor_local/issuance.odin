#+feature dynamic-literals
package executor_local

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// Trusted output of the Bridge's directory/trusted-root/catalog/profile
// resolver. Never decode this proof from a client request. Selection binds all
// requested selectors; this proof does not authorize a launch or consume a slot.
Issuance_Resources :: struct {
    selection_digest,directory_key,directory_path:string,
    // For an owner-Bridge (auto) consent only: the concrete selection this
    // executor chose for itself (same provider and model, no "auto"). Empty
    // for a device consent, whose explicit selection is used as is.
    selection:string,
    resolved:bool,
}
issuance_sign :: proc(o:json.Object,kind:string,sign:Signer,key:contracts.Owner_Verified_Key)->(string,bool) {
    signature,signed:=sign.sign(sign.ctx,kind,o)
    if !signed do return "",false
    m:=o;m["signature"]=json.String(signature)
    return encode(m),contracts.executor_verify(kind,m,key)
}
// Only enrolled device consent, or the chain's owner Bridge with an auto
// selection (cross-Bridge placement), may allocate a remote identity. Current device
// and executor keys must be resolved from paired enrollment before this call.
// Replays return original immutable historical output; no resolver, randomness,
// signer, policy or incarnation refresh is needed to return a saved result.
issue :: proc(s:^Store,consent_raw,selection_raw:string,device_key,executor_key:contracts.Owner_Verified_Key,
    now:i64,resources:Issuance_Resources,sign:Signer)->Result {
    context.allocator=context.temp_allocator
    consent,valid:=contracts.executor_parse(consent_raw,"issuance_consent")
    selection,selected:=contracts.executor_parse(selection_raw,"issuance_selection")
    if !valid || !selected do return fail("malformed")
    if !scope(s,consent) || !contracts.executor_verify("issuance_consent",consent,device_key) ||
       !executor_key.enrolled || executor_key.revoked || executor_key.kind!="bridge" || executor_key.account_id!=s.account ||
       executor_key.principal_id!=s.executor || executor_key.key_id!=field(consent,"executor_key_id") ||
       field(consent,"owner_bridge_id")==s.executor || !contracts.executor_selection_admissible(selection,device_key) {return fail("invalid_scope")}
    digest,_:=contracts.executor_digest("issuance_consent",consent)
    selection_digest:=contracts.owner_payload_digest(selection_raw)
    if field(consent,"selection_digest")!=selection_digest do return fail("digest_mismatch")
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    now:=store_now(s,now) // C1: decide with max(caller clock, store clock), under the store mutex
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    rows,read:=query(s.db,"SELECT input_digest,result_json FROM executor_issuances WHERE principal_id=? AND operation_id=?",
        field(consent,"principal_id"),field(consent,"operation_id"))
    if !read do return fail("storage_error")
    if len(rows)>0 {
        if rows[0][0]!=digest do return fail("operation_conflict")
        return Result{"ok",rows[0][1],true}
    }
    if !contracts.executor_peer_issued(num(consent,"issued_ms"),now) || !request_live(consent,now) do return fail("expired")
    if code:=clock(s,now);code!="" do return fail(code)
    if !resources.resolved || resources.selection_digest!=selection_digest ||
       !contracts.owner_field_valid(resources.directory_key,"hash") || resources.directory_path=="" ||
       !contracts.owner_field_valid(resources.directory_path,"path") {return fail("invalid_resources")}
    if contracts.executor_selection_auto(selection) {
        chosen,chosen_ok:=contracts.executor_parse(resources.selection,"issuance_selection")
        if !chosen_ok || field(chosen,"provider")!=field(selection,"provider") || field(chosen,"model")!=field(selection,"model") do return fail("invalid_resources")
        for name in ([3]string{"provider_profile","directory_id","slot_id"}) do if field(chosen,name)==contracts.EXECUTOR_AUTO_SELECTOR do return fail("invalid_resources")
        selection=chosen
    } else if resources.selection!="" && resources.selection!=selection_raw {return fail("invalid_resources")}
    mapping,mapped:=query(s.db,"SELECT directory_path,directory_key,enabled FROM executor_directories WHERE directory_id=? ORDER BY revision DESC LIMIT 1",field(selection,"directory_id"))
    if !mapped do return fail("storage_error")
    if len(mapping)!=1 || mapping[0][2]!="1" || mapping[0][0]!=resources.directory_path || mapping[0][1]!=resources.directory_key do return fail("invalid_resources")
    policy,policy_ok:=query(s.db,"SELECT 1 FROM executor_runtime WHERE policy_revision=? AND EXISTS(SELECT 1 FROM executor_slots WHERE slot_id=? AND provider_profile=? AND enabled=1)",
        field(selection,"policy_revision"),field(selection,"slot_id"),field(selection,"provider_profile"))
    if !policy_ok do return fail("storage_error")
    if len(policy)!=1 do return fail("stale_policy")
    quota,quota_ok:=query(s.db,"SELECT count(*) FROM executor_issuances")
    if !quota_ok do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    if sign.sign==nil do return fail("signer_unavailable")
    // The caller never chooses physical credentials or instance/launch facts.
    entropy:[80]byte
    if !random.fill(entropy[:]) do return fail("random_unavailable")
    defer crypto.zero_explicit(raw_data(entropy[:]),len(entropy))
    instance:=fmt.tprintf("inst_%s",vault.hex_encode_lower(entropy[:16],context.temp_allocator))
    epoch:=fmt.tprintf("launch_%s",vault.hex_encode_lower(entropy[16:32],context.temp_allocator))
    secret:=vault.hex_encode_lower(entropy[32:],context.temp_allocator)
    defer crypto.zero_explicit(raw_data(secret),len(secret))
    config:=make(json.Object,context.temp_allocator)
    for f in contracts.owner_schema("remote_configuration") do config[f.name]=json.String("")
    for name in ([9]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","executor_key_id","chain_id","task_id","agent_id","configuration_revision"}) do config[name]=consent[name]
    for name in ([6]string{"provider","model","provider_profile","directory_id","policy_revision","slot_id"}) do config[name]=selection[name]
    config["instance_id"]=json.String(instance);config["launch_epoch"]=json.String(epoch)
    config["run_count"]=json.String("1");config["token_generation"]=json.String(contracts.owner_payload_digest(secret))
    config["executor_incarnation"]=json.String(fmt.tprintf("%d",s.incarnation))
    config["directory_key"]=json.String(resources.directory_key);config["directory_path"]=json.String(resources.directory_path)
    if !contracts.owner_document_valid("remote_configuration",config) do return fail("invalid_resources")
    configuration:=encode(config)
    attestation:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("enrollment") do attestation[f.name]=json.String("")
    for name in ([8]string{"protocol_version","account_id","executor_bridge_id","owner_bridge_id","chain_id","task_id","instance_id","configuration_revision"}) do attestation[name]=config[name]
    attestation["configuration_digest"]=json.String(contracts.owner_payload_digest(configuration))
    attestation["issued_ms"]=json.String(fmt.tprintf("%d",now));attestation["request_expires_ms"]=consent["request_expires_ms"]
    attestation["key_id"]=json.String(executor_key.key_id);attestation["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    enrollment,signed:=issuance_sign(attestation,"enrollment",sign,executor_key)
    if !signed do return fail("signer_unavailable")
    receipt:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("issuance_receipt") do receipt[f.name]=json.String("")
    for name in ([8]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","operation_id","principal_id"}) do receipt[name]=consent[name]
    receipt["request_digest"]=json.String(digest);receipt["configuration_digest"]=attestation["configuration_digest"]
    enrollment_digest,_:=contracts.executor_digest("enrollment",attestation)
    receipt["enrollment_digest"]=json.String(enrollment_digest)
    for name in ([4]string{"issued_ms","request_expires_ms","key_id","signature"}) do receipt[name]=attestation[name]
    issuance,sealed:=issuance_sign(receipt,"issuance_receipt",sign,executor_key)
    if !sealed do return fail("signer_unavailable")
    body:=encode(struct{configuration,attestation,issuance_receipt:string}{configuration,enrollment,issuance})
    if _,written:=query(s.db,"INSERT INTO executor_issuances VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        field(consent,"principal_id"),field(consent,"operation_id"),field(consent,"owner_bridge_id"),
        field(consent,"chain_id"),field(consent,"task_id"),digest,consent_raw,selection_raw,instance,secret,configuration,body);!written do return fail("storage_error")
    if !commit(s) do return fail("storage_error")
    return Result{code="ok",body=body}
}

// Owner-Bridge (auto) selection: the current policy revision and the first
// enabled slot for profile. revision 0 means no policy is installed yet.
auto_slot :: proc(s:^Store,profile:string)->(revision:i64,slot:string,ok:bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return 0,"",false
    rows,read:=query(s.db,"SELECT policy_revision,(SELECT slot_id FROM executor_slots WHERE provider_profile=? AND enabled=1 ORDER BY slot_id LIMIT 1) FROM executor_runtime WHERE singleton=1",profile)
    if !read || len(rows)!=1 do return 0,"",false
    revision=number(rows[0][0])
    if revision<=0 || rows[0][1]=="" do return revision,"",false
    return revision,strings.clone(rows[0][1]),true
}
