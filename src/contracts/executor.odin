package contracts

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import vault "odin_test:lib/vault"

// Executor records allocate device resources only. They confer no task authority.
// All directory/key inputs must already be resolved by the execution Bridge.
EXECUTOR_DOCUMENT_MAX :: 32768
EXECUTOR_CAPACITY_MAX :: 128
EXECUTOR_PREPARE_TTL_MS :: 30000
// A fence response is evidence for one outstanding random challenge only.
// Transport callers must consume the challenge and recheck local intent state.
EXECUTOR_FENCE_TTL_MS :: 5000
EXECUTOR_TRANSPORT_TTL_MS :: 60000
executor_transport_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"owner_bridge_id","id"},{"executor_bridge_id","id"},
    {"chain_id","id"},{"reservation_id","optional"},{"request_id","id"},
    {"method","executor_transport_method"},{"direction","executor_direction"},
    {"input_digest","hash"},{"fence_digest","hash"},{"owner_incarnation","positive"},{"executor_incarnation","positive"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},
}
// Issuance consent carries selectors, never caller-chosen runtime credentials.
executor_exchange_fields := [?]Owner_Field{
    {"scope","document"},{"envelope","required_cipher"},
}
// The encrypted owner claim context is a selector, not authority. Only a fresh
// signed nonce reply for this exact claimed action can admit activation.
executor_activation_exchange_fields := [?]Owner_Field{
    {"scope","document"},{"envelope","required_cipher"},{"intent_id","hash"},{"claim_attempt","positive"},
}
executor_issuance_exchange_fields := [?]Owner_Field{
    {"scope","document"},{"envelope","required_cipher"},{"selection","document"},
}
executor_issuance_bundle_fields := [?]Owner_Field{
    {"configuration","document"},{"attestation","document"},{"issuance_receipt","document"},
}
executor_directory_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"directory_id","id"},{"revision","positive"},{"directory_path","path"},{"enabled","executor_flag"},
    {"key_id","id"},{"signature","signature"},
}
executor_issuance_selection_fields := [?]Owner_Field{
    {"provider","label"},{"model","label"},{"provider_profile","id"},
    {"directory_id","id"},{"policy_revision","positive"},{"slot_id","id"},
}
executor_issuance_consent_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"owner_bridge_id","id"},
    {"executor_bridge_id","id"},{"executor_key_id","id"},{"chain_id","id"},{"task_id","id"},
    {"agent_id","id"},{"configuration_revision","positive"},{"operation_id","id"},
    {"principal_id","id"},{"selection_digest","hash"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}
executor_issuance_receipt_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"owner_bridge_id","id"},
    {"executor_bridge_id","id"},{"chain_id","id"},{"task_id","id"},{"operation_id","id"},
    {"principal_id","id"},{"request_digest","hash"},{"configuration_digest","hash"},{"enrollment_digest","hash"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}
executor_enrollment_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"owner_bridge_id","id"},{"chain_id","id"},{"task_id","id"},{"instance_id","id"},
    {"configuration_revision","positive"},{"configuration_digest","hash"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}
executor_fence_request_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"owner_bridge_id","id"},{"chain_id","id"},{"reservation_id","id"},
    {"executor_incarnation","positive"},{"owner_incarnation","positive"},
    {"intent_id","hash"},{"claim_attempt","positive"},{"action_digest","hash"},
    {"challenge","hash"},{"issued_ms","positive"},{"request_expires_ms","positive"},
    {"key_id","id"},{"signature","signature"},
}
executor_fence_reply_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"owner_bridge_id","id"},{"chain_id","id"},{"reservation_id","id"},
    {"executor_incarnation","positive"},{"owner_incarnation","positive"},
    {"request_digest","hash"},{"action_digest","hash"},{"prepare_digest","hash"},
    {"challenge","hash"},{"owner_commit_seq","positive"},{"checked_ms","positive"},
    {"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}
executor_policy_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"policy_revision","positive"},{"device_capacity","positive"},{"slots_json","document"},
    {"key_id","id"},{"signature","signature"},
}
executor_prepare_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"owner_bridge_id","id"},{"chain_id","id"},{"task_id","id"},{"lease_id","id"},
    {"reservation_id","id"},{"operation_id","id"},{"instance_id","id"},
    {"launch_epoch","id"},{"run_count","positive"},{"token_generation","hash"},
    {"configuration_revision","positive"},{"grant_generation","positive"},
    {"owner_incarnation","positive"},{"executor_incarnation","positive"},
    {"policy_revision","positive"},{"slot_id","id"},{"provider_profile","id"},
    {"directory_key","optional"},{"purpose","executor_purpose"},
    {"prepare_until_ms","positive"},{"hard_ms","positive"},{"request_expires_ms","positive"},
    {"key_id","id"},{"signature","signature"},
}
executor_action_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"owner_bridge_id","id"},{"chain_id","id"},{"reservation_id","id"},{"operation_id","id"},
    {"method","executor_method"},{"prepare_digest","hash"},{"executor_incarnation","positive"},
    {"owner_incarnation","positive"},{"owner_commit_seq","positive"},
    {"grant_generation","positive"},{"deadline_version","positive"},
    {"expires_ms","positive"},{"hard_ms","positive"},{"request_expires_ms","positive"},
    {"key_id","id"},{"signature","signature"},
}
executor_receipt_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"owner_bridge_id","id"},{"chain_id","id"},{"reservation_id","id"},{"operation_id","id"},
    {"method","executor_receipt_method"},{"input_digest","hash"},{"prepare_digest","hash"},
    {"executor_incarnation","positive"},{"child_incarnation","positive"},{"grant_generation","positive"},{"deadline_version","positive"},
    {"expires_ms","positive"},{"hard_ms","positive"},{"launch_key","hash"},
    {"state","executor_state"},{"historical","executor_flag"},{"key_id","id"},{"signature","signature"},
}
executor_schema :: proc(kind:string)->[]Owner_Field {
    switch kind {
    case "bootstrap_content":return executor_bootstrap_content_fields[:]
    case "bootstrap":return executor_bootstrap_fields[:]
    case "child_request":return executor_child_request_fields[:]
    case "exchange":return executor_exchange_fields[:]
    case "activation_exchange":return executor_activation_exchange_fields[:]
    case "issuance_exchange":return executor_issuance_exchange_fields[:]
    case "issuance_bundle":return executor_issuance_bundle_fields[:]
    case "directory":return executor_directory_fields[:]
    case "issuance_selection":return executor_issuance_selection_fields[:]
    case "issuance_consent":return executor_issuance_consent_fields[:]
    case "issuance_receipt":return executor_issuance_receipt_fields[:]
    case "policy":return executor_policy_fields[:]
    case "prepare":return executor_prepare_fields[:]
    case "action":return executor_action_fields[:]
    case "receipt":return executor_receipt_fields[:]
    case "fence_request":return executor_fence_request_fields[:]
    case "fence_reply":return executor_fence_reply_fields[:]
    case "enrollment":return executor_enrollment_fields[:]
    case "transport_scope":return executor_transport_fields[:]
    }
    return nil
}
executor_number :: proc(o:json.Object,key:string)->i64 { n,_:=strconv.parse_i64(owner_string(o,key));return n }
executor_valid :: proc(o:json.Object,kind:string)->bool {
    fields:=executor_schema(kind)
    if len(fields)==0 || len(o)!=len(fields) do return false
    for f in fields {
        value,is_string:=o[f.name].(json.String)
        if !is_string do return false
        s:=string(value)
        switch f.kind {
        case "executor_transport_method":
            if s!="enrollment" && s!="prepare" && s!="action" && s!="fence_request" do return false
        case "executor_direction":
            if s!="request" && s!="response" do return false
        case "executor_receipt_method":
            if s!="prepare" && s!="activate" && s!="heartbeat" && s!="stop" && s!="query" do return false
        case "executor_state":
            if s!="prepared" && s!="active" && s!="stopping" && s!="released" do return false
        case "executor_flag":
            if s!="0" && s!="1" do return false
        case "executor_purpose":
            if s!="work" && s!="review" && s!="manual" && s!="warm" do return false
        case "executor_method":
            if s!="activate" && s!="heartbeat" && s!="stop" && s!="query" do return false
        case:
            if !owner_field_valid(s,f.kind) do return false
        }
    }
    if kind=="bootstrap_content" && !executor_bootstrap_content_valid(o) do return false
    if kind=="bootstrap" || kind=="child_request" {
        start,end:=executor_number(o,"issued_ms"),executor_number(o,"request_expires_ms")
        if end<=start || end-start>EXECUTOR_FENCE_TTL_MS || end>executor_number(o,"expires_ms") || executor_number(o,"expires_ms")>executor_number(o,"hard_ms") do return false
    }
    if kind=="directory" && owner_string(o,"directory_path")=="" do return false
    if kind=="policy" {
        cap:=executor_number(o,"device_capacity")
        if cap>EXECUTOR_CAPACITY_MAX do return false
        v,ok:=owner_request_document(owner_string(o,"slots_json"));slots,arr:=v.(json.Array)
        if !ok || !arr || len(slots)>int(cap) do return false
        seen:=make(map[string]bool,context.temp_allocator)
        for slot in slots {
            row,obj:=slot.(json.Object)
            if !obj || len(row)!=3 do return false
            for key in ([2]string{"slot_id","provider_profile"}) {
                if v,str:=row[key].(json.String);!str || !owner_field_valid(string(v),"id") do return false
            }
            enabled,str:=row["enabled"].(json.String)
            if !str || (enabled!="0" && enabled!="1") || seen[owner_string(row,"slot_id")] do return false
            seen[owner_string(row,"slot_id")]=true
        }
    }
    if kind=="prepare" {
        if executor_number(o,"prepare_until_ms")>executor_number(o,"hard_ms") do return false
        directory:=owner_string(o,"directory_key")
        if directory!="" && !owner_field_valid(directory,"hash") do return false
    }
    if (kind=="action" || kind=="receipt") && executor_number(o,"expires_ms")>executor_number(o,"hard_ms") do return false
    if kind=="fence_request" || kind=="fence_reply" {
        start:=executor_number(o,"issued_ms" if kind=="fence_request" else "checked_ms")
        end:=executor_number(o,"request_expires_ms")
        if end<=start || end-start>EXECUTOR_FENCE_TTL_MS do return false
    }
    if kind=="enrollment" || kind=="issuance_consent" || kind=="issuance_receipt" {
        issued,end:=executor_number(o,"issued_ms"),executor_number(o,"request_expires_ms")
        if end<=issued || end-issued>OWNER_REQUEST_TTL_MS do return false
    }
    if kind=="transport_scope" {
        issued,end:=executor_number(o,"issued_ms"),executor_number(o,"request_expires_ms")
        if end<=issued || end-issued>EXECUTOR_TRANSPORT_TTL_MS do return false
        reservation:=owner_string(o,"reservation_id")
        if owner_string(o,"method")=="enrollment" {
            if reservation!="" do return false
        } else if !owner_field_valid(reservation,"id") {return false}
    }
    return true
}
executor_parse :: proc(raw,kind:string)->(json.Object,bool) {
    if len(raw)>EXECUTOR_DOCUMENT_MAX do return nil,false
    v:json.Value;ok:bool
    if kind=="bootstrap_content" || kind=="issuance_selection" || kind=="issuance_exchange" || kind=="issuance_bundle" {v,ok=owner_content_document(raw)} else {v,ok=owner_request_document(raw)}
    o,obj:=v.(json.Object)
    if !ok || !obj || !executor_valid(o,kind) do return nil,false
    return o,true
}
executor_canonical :: proc(kind:string,o:json.Object)->(string,bool) {
    if !executor_valid(o,kind) do return "",false
    b:strings.Builder;strings.builder_init(&b,context.temp_allocator)
    strings.write_string(&b,fmt.tprintf("heimdall-executor/%s/v1\n",kind))
    for f in executor_schema(kind) {
        if f.kind=="signature" do continue
        s:=owner_string(o,f.name)
        strings.write_string(&b,fmt.tprintf("%d:%s,",len(s),s))
    }
    return strings.to_string(b),true
}
executor_digest :: proc(kind:string,o:json.Object)->(string,bool) {
    canonical,ok:=executor_canonical(kind,o)
    if !ok do return "",false
    return owner_payload_digest(canonical),true
}
executor_verify :: proc(kind:string,o:json.Object,key:Owner_Verified_Key)->bool {
    if !key.enrolled || key.revoked || (key.kind!="device" if kind=="issuance_consent" else key.kind!="bridge") || key.account_id!=owner_string(o,"account_id") ||
       key.key_id!=owner_string(o,"key_id") { return false }
    identity:="owner_bridge_id"
    if kind=="policy" || kind=="receipt" || kind=="fence_request" || kind=="enrollment" || kind=="issuance_receipt" || kind=="directory" || kind=="child_request" do identity="executor_bridge_id"
    if kind=="issuance_consent" do identity="principal_id"
    if key.principal_id!=owner_string(o,identity) do return false
    canonical,ok:=executor_canonical(kind,o)
    if !ok do return false
    sig,valid:=vault.signature_text_from_parts("ecdsa-p256-sha256",owner_string(o,"signature"),context.temp_allocator)
    return valid && vault.verify("ecdsa-p256-sha256",key.public_key,transmute([]byte)canonical,sig)
}

// Enrollment attests a reserved configuration, never a running child or lease.
// The separate signed device command must authorize these exact config bytes.
executor_enrollment_matches :: proc(attestation:json.Object,configuration_raw:string,key:Owner_Verified_Key,now:i64,current_admission:=true)->bool {
    c,valid:=owner_parse(configuration_raw,"remote_configuration")
    if !valid || !executor_verify("enrollment",attestation,key) || owner_string(c,"owner_bridge_id")==owner_string(c,"executor_bridge_id") ||
       owner_string(c,"directory_path")=="" || owner_string(c,"executor_key_id")!=key.key_id ||
       owner_string(attestation,"configuration_digest")!=owner_payload_digest(configuration_raw) {return false}
    for name in ([8]string{"protocol_version","account_id","executor_bridge_id","owner_bridge_id","chain_id","task_id","instance_id","configuration_revision"}) {
        if owner_string(attestation,name)!=owner_string(c,name) do return false
    }
    return !current_admission || (now>=executor_number(attestation,"issued_ms") && now<executor_number(attestation,"request_expires_ms"))
}

// Both signatures and the exact pending request are required. This helper is
// stateless; the executor consumes its locally held nonce after success.
executor_fence_reply_matches :: proc(reply,request,action:json.Object,owner_key,executor_key:Owner_Verified_Key,now:i64)->bool {
    if !executor_verify("fence_request",request,executor_key) || !executor_verify("fence_reply",reply,owner_key) ||
       !executor_verify("action",action,owner_key) || owner_string(action,"method")!="activate" {return false}
    for name in ([8]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation","owner_incarnation","request_expires_ms"}) {
        if owner_string(reply,name)!=owner_string(request,name) do return false
    }
    for name in ([7]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation","owner_incarnation"}) {
        if owner_string(request,name)!=owner_string(action,name) do return false
    }
    request_digest,_:=executor_digest("fence_request",request)
    action_digest,_:=executor_digest("action",action)
    return owner_string(reply,"request_digest")==request_digest &&
       owner_string(reply,"challenge")==owner_string(request,"challenge") &&
       owner_string(request,"action_digest")==action_digest && owner_string(reply,"action_digest")==action_digest &&
       owner_string(reply,"prepare_digest")==owner_string(action,"prepare_digest") &&
       owner_string(reply,"owner_commit_seq")==owner_string(action,"owner_commit_seq") &&
       now>=executor_number(reply,"checked_ms") && executor_number(reply,"checked_ms")>=executor_number(request,"issued_ms") &&
       now<executor_number(request,"request_expires_ms") && now<executor_number(action,"request_expires_ms") &&
       now<executor_number(action,"expires_ms") && now<executor_number(action,"hard_ms")
}

// Exact signed receipt binding. Historical results are useful for recovery,
// never a fresh reservation or launch capability.
executor_receipt_matches :: proc(receipt,request:json.Object,kind:string,key:Owner_Verified_Key,now:i64,current_admission:=true)->bool {
    if (kind!="prepare" && kind!="action") || !executor_valid(request,kind) || !executor_valid(receipt,"receipt") ||
       !executor_verify("receipt",receipt,key) { return false }
    for name in ([7]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","operation_id","grant_generation"}) {
        if owner_string(receipt,name)!=owner_string(request,name) do return false
    }
    digest,_:=executor_digest(kind,request)
    if owner_string(receipt,"input_digest")!=digest || owner_string(receipt,"executor_incarnation")!=owner_string(request,"executor_incarnation") ||
       owner_string(receipt,"hard_ms")!=owner_string(request,"hard_ms") { return false }
    method:="prepare" if kind=="prepare" else owner_string(request,"method")
    if owner_string(receipt,"method")!=method do return false
    prepare_digest:=digest if kind=="prepare" else owner_string(request,"prepare_digest")
    if owner_string(receipt,"prepare_digest")!=prepare_digest do return false
    if !current_admission do return true
    if now<0 || owner_string(receipt,"historical")!="0" || executor_number(receipt,"expires_ms")<=now do return false
    state:=owner_string(receipt,"state")
    if method=="prepare" {
        return state=="prepared" && owner_string(receipt,"child_incarnation")==owner_string(request,"executor_incarnation") &&
          owner_string(receipt,"expires_ms")==owner_string(request,"prepare_until_ms") && owner_string(receipt,"deadline_version")=="1"
    }
    if method=="activate" || method=="heartbeat" {
        return state=="active" && owner_string(receipt,"expires_ms")==owner_string(request,"expires_ms") &&
          owner_string(receipt,"deadline_version")==owner_string(request,"deadline_version")
    }
    return method=="query" || (method=="stop" && (state=="stopping" || state=="released"))
}

// Verify the requested selectors and generated response together. This does not
// authorize a task grant, reserve capacity, or establish a current launch fence.
executor_issuance_matches :: proc(receipt,consent:json.Object,selection_raw,configuration_raw:string,
    enrollment:json.Object,device_key,executor_key:Owner_Verified_Key,now:i64,current_admission:=true)->bool {
    selection,selected:=executor_parse(selection_raw,"issuance_selection")
    c,configured:=owner_parse(configuration_raw,"remote_configuration")
    if !selected || !configured || !executor_verify("issuance_consent",consent,device_key) ||
       !executor_verify("issuance_receipt",receipt,executor_key) ||
       !executor_enrollment_matches(enrollment,configuration_raw,executor_key,now,current_admission) {return false}
    for name in ([8]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","operation_id","principal_id"}) {
        if owner_string(receipt,name)!=owner_string(consent,name) do return false
    }
    for name in ([9]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","executor_key_id","chain_id","task_id","agent_id","configuration_revision"}) {
        if owner_string(c,name)!=owner_string(consent,name) do return false
    }
    for name in ([6]string{"provider","model","provider_profile","directory_id","policy_revision","slot_id"}) {
        if owner_string(c,name)!=owner_string(selection,name) do return false
    }
    request_digest,_:=executor_digest("issuance_consent",consent)
    enrollment_digest,_:=executor_digest("enrollment",enrollment)
    return owner_string(consent,"selection_digest")==owner_payload_digest(selection_raw) &&
        owner_string(receipt,"request_digest")==request_digest &&
        owner_string(receipt,"configuration_digest")==owner_payload_digest(configuration_raw) &&
        owner_string(receipt,"enrollment_digest")==enrollment_digest &&
        (!current_admission || (now>=executor_number(consent,"issued_ms") && now<executor_number(consent,"request_expires_ms") &&
          now>=executor_number(receipt,"issued_ms") && now<executor_number(receipt,"request_expires_ms")))
}
