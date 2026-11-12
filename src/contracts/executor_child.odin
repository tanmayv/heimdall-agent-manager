package contracts

import "core:encoding/json"
import "core:strings"

// These records travel only inside the sealed Bridge channel. A bootstrap is
// owner-authored content, not executable argv or a replacement task grant.
// A child request attests one exact locally observed child and input; the owner
// must still check its journal, current assignment, capability and operation.
executor_bootstrap_content_fields := [?]Owner_Field{
    {"agents_md","document"},{"memory_md","optional_document"},{"task_md","document"},{"skills_json","document"},
}
executor_bootstrap_skill_name_valid :: proc(s:string)->bool {
    if len(s)==0 || len(s)>160 do return false
    for c in s do if !(c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='-') do return false
    return true
}
executor_bootstrap_content_valid :: proc(o:json.Object)->bool {
    context.allocator=context.temp_allocator
    value,parsed:=owner_content_document(owner_string(o,"skills_json"))
    skills,array:=value.(json.Array)
    if !parsed || !array || len(skills)>64 do return false
    seen:=make(map[string]bool,context.temp_allocator)
    for item in skills {
        skill,obj:=item.(json.Object)
        if !obj || len(skill)!=2 do return false
        name,named:=skill["name"].(json.String)
        content,text:=skill["content"].(json.String)
        if !named || !text || !executor_bootstrap_skill_name_valid(string(name)) ||
           !owner_field_valid(string(content),"document") || seen[strings.to_lower(string(name))] {return false}
        seen[strings.to_lower(string(name))]=true
    }
    return true
}
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

// A remote child's ordinary agent verb (ham-ctl lease/task/review). Like a
// lease input it names the child's own chain/task/lease/revision, which the
// child request binds to its bootstrap; the owner runs the verb as that child.
executor_agent_verb_fields := [?]Owner_Field{
    {"protocol_version","version"},{"chain_id","id"},{"task_id","id"},{"lease_id","id"},
    {"configuration_revision","positive"},{"method","executor_agent_verb"},{"params","document"},
}
EXECUTOR_AGENT_VERBS := [?]string{
    "agent.lease.next","agent.lease.heartbeat","agent.lease.submit","agent.lease.handoff","agent.lease.block",
    "agent.task.show","agent.task.comments","agent.task.comment","agent.review.post",
}
executor_agent_verb :: proc(method:string)->bool {
    for verb in EXECUTOR_AGENT_VERBS do if verb==method do return true
    return false
}

executor_child_exchange_fields := [?]Owner_Field{
    {"scope","document"},{"envelope","required_cipher"},{"input","document"},
}
executor_child_result_bundle_fields := [?]Owner_Field{
    {"receipt","document"},{"body","document"},
}
// Owner attestation binds one complete child request and the exact result
// bytes. It does not itself grant or renew a task lease.
executor_child_result_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"owner_bridge_id","id"},{"executor_bridge_id","id"},
    {"chain_id","id"},{"reservation_id","id"},{"owner_incarnation","positive"},{"executor_incarnation","positive"},
    {"prepare_digest","hash"},{"request_digest","hash"},{"input_digest","hash"},{"result_digest","hash"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}

executor_bootstrap_matches :: proc(b,p,a:json.Object,configuration_raw,body_raw,launch_key:string,
    owner_key:Owner_Verified_Key,now:i64)->bool {
    c,configured:=owner_parse(configuration_raw,"remote_configuration")
    _,content_valid:=executor_parse(body_raw,"bootstrap_content")
    if !configured || !content_valid || !executor_verify("bootstrap",b,owner_key) || !executor_verify("prepare",p,owner_key) ||
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
executor_child_request_matches :: proc(r,b:json.Object,input_raw:string,executor_key,owner_key:Owner_Verified_Key,now:i64,renewal:json.Object=nil)->bool {
    if !executor_verify("child_request",r,executor_key) || !executor_verify("bootstrap",b,owner_key) ||
       owner_string(b,"owner_bridge_id")==owner_string(b,"executor_bridge_id") {return false}
    if !executor_child_deadline_matches(r,b,renewal,owner_key) do return false
    for name in ([20]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","lease_id",
        "reservation_id","instance_id","launch_epoch","run_count","token_generation","configuration_revision","grant_generation",
        "owner_incarnation","executor_incarnation","prepare_digest","launch_key","hard_ms","bootstrap_digest"}) {
        if name=="bootstrap_digest" {
            digest,_:=executor_digest("bootstrap",b)
            if owner_string(r,name)!=digest do return false
        } else if owner_string(r,name)!=owner_string(b,name) {return false}
    }
    input,valid:=owner_parse(input_raw,"lease_input")
    if !valid {input,valid=owner_parse(input_raw,"lifecycle_input")}
    if !valid {input,valid=executor_parse(input_raw,"agent_verb")}
    if !valid || owner_string(r,"input_digest")!=owner_payload_digest(input_raw) do return false
    for name in ([4]string{"chain_id","task_id","lease_id","configuration_revision"}) {
        if owner_string(input,name)!=owner_string(r,name) do return false
    }
    // r is stamped by the executor's clock, b by the owner's (this receiver).
    return executor_peer_issued(executor_number(r,"issued_ms"),now) && executor_peer_issued(executor_number(b,"issued_ms"),executor_number(r,"issued_ms")) &&
        executor_peer_unexpired(executor_number(r,"request_expires_ms"),now)
}

executor_child_result_matches :: proc(result,request:json.Object,body:string,owner_key:Owner_Verified_Key,now:i64)->bool {
    if !executor_verify("child_result",result,owner_key) || !executor_valid(request,"child_request") do return false
    for name in ([10]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id",
        "owner_incarnation","executor_incarnation","prepare_digest","input_digest"}) {
        if owner_string(result,name)!=owner_string(request,name) do return false
    }
    digest,_:=executor_digest("child_request",request)
    return owner_string(result,"request_digest")==digest && owner_string(result,"result_digest")==owner_payload_digest(body) &&
        // The result is stamped by the owner's clock; its expiry is this
        // executor's own request expiry, compared exactly.
        executor_peer_issued(executor_number(result,"issued_ms"),now) && executor_peer_issued(executor_number(request,"issued_ms"),executor_number(result,"issued_ms")) &&
        now<executor_number(result,"request_expires_ms") &&
        executor_number(result,"request_expires_ms")<=executor_number(request,"request_expires_ms")
}

// Local startup acknowledgement; readiness grants no owner task authority.
Executor_Readiness_Ack :: struct {accepted:bool,ready_ms:string}


// A signed renewal supplements only the deadline of the immutable bootstrap.
// Its source must be the local owner outbox or the executor's daemon-confirmed
// journal, never a document selected by the remote child.
executor_child_deadline_matches :: proc(r,b,a:json.Object,key:Owner_Verified_Key)->bool {
    if a==nil do return owner_string(r,"deadline_version")==owner_string(b,"deadline_version") &&
        owner_string(r,"expires_ms")==owner_string(b,"expires_ms")
    if !executor_verify("action",a,key) || owner_string(a,"method")!="heartbeat" do return false
    for name in ([11]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id",
        "reservation_id","grant_generation","owner_incarnation","executor_incarnation","prepare_digest","hard_ms"}) {
        if owner_string(a,name)!=owner_string(b,name) do return false
    }
    return executor_number(a,"deadline_version")>executor_number(b,"deadline_version") &&
        executor_number(a,"expires_ms")>=executor_number(b,"expires_ms") &&
        owner_string(r,"deadline_version")==owner_string(a,"deadline_version") &&
        owner_string(r,"expires_ms")==owner_string(a,"expires_ms")
}
