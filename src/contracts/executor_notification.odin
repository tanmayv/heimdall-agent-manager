package contracts

import "core:encoding/json"

// Owner-authorized checkpoint action only. This is neither a launch grant nor
// a child notification.send command. Unicode message bytes live inside the
// encrypted outer exchange and are committed by message_digest.
executor_notification_fields := [?]Owner_Field{
    {"protocol_version","version"},
    {"account_id","id"},
    {"owner_bridge_id","id"},
    {"executor_bridge_id","id"},
    {"chain_id","id"},
    {"task_id","id"},
    {"lease_id","id"},
    {"reservation_id","id"},
    {"instance_id","id"},
    {"launch_epoch","id"},
    {"run_count","positive"},
    {"token_generation","hash"},
    {"configuration_revision","positive"},
    {"grant_generation","positive"},
    {"owner_incarnation","positive"},
    {"executor_incarnation","positive"},
    {"prepare_digest","hash"},
    {"launch_key","hash"},
    {"deadline_version","positive"},
    {"expires_ms","positive"},
    {"hard_ms","positive"},
    {"intent_id","hash"},
    {"owner_commit_seq","positive"},
    {"message_digest","hash"},
    {"issued_ms","positive"},
    {"request_expires_ms","positive"},
    {"key_id","id"},
    {"signature","signature"},
}
executor_notification_result_fields := [?]Owner_Field{
    {"protocol_version","version"},
    {"account_id","id"},
    {"owner_bridge_id","id"},
    {"executor_bridge_id","id"},
    {"chain_id","id"},
    {"reservation_id","id"},
    {"owner_incarnation","positive"},
    {"executor_incarnation","positive"},
    {"prepare_digest","hash"},
    {"input_digest","hash"},
    {"intent_id","hash"},
    {"pid","counter"},
    {"ticket","optional"},
    {"input_profile","optional"},
    {"esc_written","executor_flag"},
    {"message_bytes_written","counter"},
    {"enter_written","executor_flag"},
    {"status","notification_status"},
    {"issued_ms","positive"},
    {"request_expires_ms","positive"},
    {"key_id","id"},
    {"signature","signature"},
}

executor_notification_fence_request_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"owner_bridge_id","id"},{"chain_id","id"},{"reservation_id","id"},
    {"executor_incarnation","positive"},{"owner_incarnation","positive"},
    {"intent_id","hash"},{"claim_attempt","positive"},{"action_digest","hash"},
    {"challenge","hash"},{"issued_ms","positive"},{"request_expires_ms","positive"},
    {"key_id","id"},{"signature","signature"},
    {"notification","document"},
}
executor_notification_exchange_fields := [?]Owner_Field{
    {"scope","document"},{"envelope","required_cipher"},{"message","document"},{"claim_attempt","positive"},
}
executor_notification_matches :: proc(n,b:json.Object,message:string,owner_key:Owner_Verified_Key,now:i64)->bool {
    if !executor_verify("notification",n,owner_key) || !executor_verify("bootstrap",b,owner_key) ||
       !pty_notification_message_valid(message) || owner_string(n,"message_digest")!=owner_payload_digest(message) {return false}
    for name in ([20]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","lease_id",
        "reservation_id","instance_id","launch_epoch","run_count","token_generation","configuration_revision","grant_generation",
        "owner_incarnation","executor_incarnation","prepare_digest","launch_key","hard_ms","key_id"}) {
        if owner_string(n,name)!=owner_string(b,name) do return false
    }
    return now>=executor_number(n,"issued_ms") && now<executor_number(n,"request_expires_ms") &&
        now<executor_number(n,"expires_ms") && now<executor_number(n,"hard_ms")
}
executor_notification_result_matches :: proc(r,n:json.Object,message:string,key:Owner_Verified_Key,now:i64)->bool {
    if !executor_valid(n,"notification") || !executor_verify("notification_result",r,key) ||
       owner_string(n,"message_digest")!=owner_payload_digest(message) || !pty_notification_message_valid(message) {return false}
    for name in ([10]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id",
        "owner_incarnation","executor_incarnation","prepare_digest","intent_id"}) {
        if owner_string(r,name)!=owner_string(n,name) do return false
    }
    digest,_:=executor_digest("notification",n)
    if owner_string(r,"input_digest")!=digest || now<executor_number(r,"issued_ms") || now>=executor_number(r,"request_expires_ms") ||
       executor_number(r,"message_bytes_written")>i64(len(message)) {return false}
    status:=owner_string(r,"status")
    if status=="unsupported_not_delivered" {
        return owner_string(r,"pid")=="0" && owner_string(r,"ticket")=="" && owner_string(r,"input_profile")=="" &&
            owner_string(r,"esc_written")=="0" && owner_string(r,"message_bytes_written")=="0" && owner_string(r,"enter_written")=="0"
    }
    if status=="partial" || status=="delivered" {
        if !owner_field_valid(owner_string(r,"pid"),"positive") || !pty_notification_id_valid(owner_string(r,"ticket")) ||
           !pty_notification_id_valid(owner_string(r,"input_profile")) {return false}
        written:=executor_number(r,"message_bytes_written")
        esc,enter:=owner_string(r,"esc_written")=="1",owner_string(r,"enter_written")=="1"
        if !esc && (written>0 || enter) || enter && written!=i64(len(message)) do return false
        complete:=esc && enter && written==i64(len(message))
        return complete if status=="delivered" else !complete
    }
    return status=="recovery_required" || status=="child_mismatch"
}
// Separate signature domains prevent activation proof reuse for checkpoints.
// The owner callback must revalidate the original claimed hold intent before
// signing; this pure matcher cannot itself authorize a held target.
executor_notification_fence_matches :: proc(r,q,n:json.Object,owner_key,executor_key:Owner_Verified_Key,now:i64)->bool {
    if !executor_verify("notification_fence_request",q,executor_key) ||
       !executor_verify("notification_fence_reply",r,owner_key) || !executor_verify("notification",n,owner_key) {return false}
    for name in ([8]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation","owner_incarnation","request_expires_ms"}) {
        if owner_string(r,name)!=owner_string(q,name) do return false
    }
    for name in ([7]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation","owner_incarnation"}) {
        if owner_string(q,name)!=owner_string(n,name) do return false
    }
    bound,parsed:=executor_parse(owner_string(q,"notification"),"notification")
    nd,_:=executor_digest("notification",n);bd,_:=executor_digest("notification",bound)
    qd,_:=executor_digest("notification_fence_request",q)
    if !parsed || nd!=bd || owner_string(bound,"signature")!=owner_string(n,"signature") do return false
    return owner_string(q,"intent_id")==owner_string(n,"intent_id") &&
        owner_string(q,"action_digest")==nd && owner_string(r,"action_digest")==nd && owner_string(r,"request_digest")==qd &&
        owner_string(r,"prepare_digest")==owner_string(n,"prepare_digest") && owner_string(r,"challenge")==owner_string(q,"challenge") &&
        owner_string(r,"owner_commit_seq")==owner_string(n,"owner_commit_seq") &&
        executor_number(r,"checked_ms")>=executor_number(q,"issued_ms") && now>=executor_number(r,"checked_ms") &&
        now<executor_number(q,"request_expires_ms") && now<executor_number(n,"request_expires_ms") &&
        now<executor_number(n,"expires_ms") && now<executor_number(n,"hard_ms")
}
