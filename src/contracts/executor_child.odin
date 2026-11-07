package contracts

import "core:encoding/json"

// These records travel only inside the sealed Bridge channel. A bootstrap is
// owner-authored content, not executable argv or a replacement task grant.
// A child request attests one exact locally observed child and input; the owner
// must still check its journal, current assignment, capability and operation.
executor_bootstrap_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"owner_bridge_id","id"},{"executor_bridge_id","id"},
    {"chain_id","id"},{"task_id","id"},{"lease_id","id"},{"reservation_id","id"},
    {"instance_id","id"},{"launch_epoch","id"},{"run_count","positive"},{"token_generation","hash"},
    {"configuration_revision","positive"},{"grant_generation","positive"},
    {"owner_incarnation","positive"},{"executor_incarnation","positive"},
    {"prepare_digest","hash"},{"action_digest","hash"},{"configuration_digest","hash"},{"body_digest","hash"},
    {"launch_key","hash"},{"deadline_version","positive"},{"expires_ms","positive"},{"hard_ms","positive"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}
executor_child_request_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"owner_bridge_id","id"},{"executor_bridge_id","id"},
    {"chain_id","id"},{"task_id","id"},{"lease_id","id"},{"reservation_id","id"},
    {"instance_id","id"},{"launch_epoch","id"},{"run_count","positive"},{"token_generation","hash"},
    {"configuration_revision","positive"},{"grant_generation","positive"},
    {"owner_incarnation","positive"},{"executor_incarnation","positive"},
    {"prepare_digest","hash"},{"bootstrap_digest","hash"},{"input_digest","hash"},{"launch_key","hash"},
    {"deadline_version","positive"},{"expires_ms","positive"},{"hard_ms","positive"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}

executor_bootstrap_matches :: proc(b,p,a:json.Object,configuration_raw,body_raw,launch_key:string,
    owner_key:Owner_Verified_Key,now:i64)->bool {
    c,configured:=owner_parse(configuration_raw,"remote_configuration")
    if !configured || !executor_verify("bootstrap",b,owner_key) || !executor_verify("prepare",p,owner_key) ||
       !executor_verify("action",a,owner_key) || owner_string(a,"method")!="activate" ||
       owner_string(p,"owner_bridge_id")==owner_string(p,"executor_bridge_id") ||
       !owner_field_valid(launch_key,"hash") || owner_string(b,"launch_key")!=launch_key ||
       len(body_raw)==0 || len(body_raw)>EXECUTOR_DOCUMENT_MAX {return false}
    for name in ([17]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","lease_id",
        "reservation_id","instance_id","launch_epoch","run_count","token_generation","configuration_revision","grant_generation",
        "owner_incarnation","executor_incarnation","hard_ms"}) {
        if owner_string(b,name)!=owner_string(p,name) do return false
    }
    for name in ([14]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id",
        "instance_id","launch_epoch","run_count","token_generation","configuration_revision","executor_incarnation","policy_revision","slot_id"}) {
        if owner_string(p,name)!=owner_string(c,name) do return false
    }
    for name in ([2]string{"provider_profile","directory_key"}) {
        if owner_string(p,name)!=owner_string(c,name) do return false
    }
    for name in ([12]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id",
        "owner_incarnation","executor_incarnation","grant_generation","deadline_version","expires_ms","hard_ms"}) {
        if owner_string(b,name)!=owner_string(a,name) do return false
    }
    pd,_:=executor_digest("prepare",p)
    ad,_:=executor_digest("action",a)
    return owner_string(b,"prepare_digest")==pd && owner_string(a,"prepare_digest")==pd &&
        owner_string(b,"action_digest")==ad && owner_string(b,"configuration_digest")==owner_payload_digest(configuration_raw) &&
        owner_string(b,"body_digest")==owner_payload_digest(body_raw) &&
        now>=executor_number(b,"issued_ms") && now<executor_number(b,"request_expires_ms") &&
        now<executor_number(a,"request_expires_ms") && now<executor_number(a,"expires_ms")
}

// The caller supplies the currently accepted bootstrap, not one selected by the
// remote sender. Replays must reach the owner's ordinary operation receipt path.
// This does not renew a deadline or establish that a process is still present.
executor_child_request_matches :: proc(r,b:json.Object,input_raw:string,executor_key,owner_key:Owner_Verified_Key,now:i64)->bool {
    if !executor_verify("child_request",r,executor_key) || !executor_verify("bootstrap",b,owner_key) ||
       owner_string(b,"owner_bridge_id")==owner_string(b,"executor_bridge_id") {return false}
    for name in ([22]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","lease_id",
        "reservation_id","instance_id","launch_epoch","run_count","token_generation","configuration_revision","grant_generation",
        "owner_incarnation","executor_incarnation","prepare_digest","launch_key","deadline_version","expires_ms","hard_ms","bootstrap_digest"}) {
        if name=="bootstrap_digest" {
            digest,_:=executor_digest("bootstrap",b)
            if owner_string(r,name)!=digest do return false
        } else if owner_string(r,name)!=owner_string(b,name) {return false}
    }
    input,valid:=owner_parse(input_raw,"lease_input")
    if !valid {input,valid=owner_parse(input_raw,"lifecycle_input")}
    if !valid || owner_string(r,"input_digest")!=owner_payload_digest(input_raw) do return false
    for name in ([4]string{"chain_id","task_id","lease_id","configuration_revision"}) {
        if owner_string(input,name)!=owner_string(r,name) do return false
    }
    return now>=executor_number(r,"issued_ms") && executor_number(r,"issued_ms")>=executor_number(b,"issued_ms") &&
        now<executor_number(r,"request_expires_ms") && now<executor_number(input,"request_expires_ms")
}
