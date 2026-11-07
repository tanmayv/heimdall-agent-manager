package main

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import channel "odin_test:lib/executor_channel"
import executor "odin_test:lib/executor_local"
import httpc "odin_test:lib/httpc"
import vault "odin_test:lib/vault"

Executor_Fence_Outcome :: struct {
    scope,envelope:string,
    directory:vault.Directory_Verification_Input,
}
Executor_Fence_Exchange :: proc(rawptr,string,i64)->Executor_Fence_Outcome

// Called only with the application executor mutex released. No Store pointer
// crosses this boundary, and the nonce deadline bounds all HTTP retry work.
bridge_executor_fence_exchange :: proc(_:rawptr,request_raw:string,generation:i64)->Executor_Fence_Outcome {
    return bridge_executor_reverse_exchange(request_raw,"fence_request","",generation)
}
bridge_executor_child_exchange :: proc(request_raw,input:string,generation:i64)->Executor_Fence_Outcome {
    return bridge_executor_reverse_exchange(request_raw,"child_request",input,generation)
}
bridge_executor_directory_fetch :: proc(generation:i64)->(vault.Directory_Verification_Input,bool) {
    credential:=bridge_credential_snapshot();defer delete(credential)
    headers:=[?]httpc.Header{httpc.bearer(credential)}
    if generation!=bridge_task_chain_search_generation() || sync.atomic_load(&bridge_hub_traffic_stopped) do return {},false
    response,err:=bridge_http_request_retry({method=.GET,url=bridge_hub_url(),path={"api","v1","executor","directory"},headers=headers[:],timeout_ms=5000})
    defer httpc.response_destroy(&response)
    if err!=.None || response.status!=200 || len(httpc.text(response))>3*1024*1024 || generation!=bridge_task_chain_search_generation() do return {},false
    wire:struct{data:vault.Directory_Verification_Input}
    if json.unmarshal_string(httpc.text(response),&wire,.JSON,context.temp_allocator)!=nil do return {},false
    return wire.data,true
}
bridge_executor_reverse_exchange :: proc(request_raw,kind,input:string,generation:i64)->Executor_Fence_Outcome {
    now:=time.to_unix_nanoseconds(time.now())/1000000
    q,valid:=contracts.executor_parse(request_raw,kind)
    get:=contracts.owner_string
    expires:=contracts.executor_number(q,"request_expires_ms")
    if !valid || expires<=now || generation!=bridge_task_chain_search_generation() || sync.atomic_load(&bridge_hub_traffic_stopped) do return {}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return {}
    scope:=make(json.Object,context.temp_allocator)
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=q[name]
    scope["protocol_version"]=json.String("1");scope["method"]=json.String(kind);scope["direction"]=json.String("request")
    request_id:=fmt.tprintf("executor_fence_%d",time.to_unix_nanoseconds(time.now()))
    scope["request_id"]=json.String(request_id)
    digest,_:=contracts.executor_digest(kind,q)
    scope["input_digest"]=json.String(digest);scope["fence_digest"]=q["prepare_digest"] if kind=="child_request" else q["action_digest"]
    scope["issued_ms"]=q["issued_ms"];scope["request_expires_ms"]=q["request_expires_ms"]
    token,sealed:=channel.seal(request_raw,&kr,scope,now,context.temp_allocator)
    if !sealed do return {}
    exchange:=bridge_owner_json(struct{scope,envelope:string}{bridge_owner_json(scope),token})
    if kind=="child_request" {
        exchange=bridge_owner_json(struct{scope,envelope,input:string}{bridge_owner_json(scope),token,input})
        if _,parsed:=contracts.executor_parse(exchange,"child_exchange");!parsed do return {}
    }
    outer,wrapped:=vault.seal(transmute([]byte)exchange,&kr,context.temp_allocator)
    if !wrapped do return {}
    relay:=struct{protocol_version,chain_id,bridge_id,request_id,expires_ms,envelope:string}{
        "1",get(q,"chain_id"),get(q,"owner_bridge_id"),request_id,get(q,"request_expires_ms"),outer}
    credential:=bridge_credential_snapshot();defer delete(credential)
    headers:=[?]httpc.Header{httpc.bearer(credential)}
    if generation!=bridge_task_chain_search_generation() || sync.atomic_load(&bridge_hub_traffic_stopped) do return {}
    route:="child" if kind=="child_request" else "fence"
    response,err:=bridge_http_request_retry({method=.POST,url=bridge_hub_url(),path={"api","v1","executor",route},
        headers=headers[:],body=httpc.json_body(relay),timeout_ms=5000},deadline_ns=expires*1000000)
    defer httpc.response_destroy(&response)
    if err!=.None || response.status!=200 || len(httpc.text(response))>3*1024*1024 || generation!=bridge_task_chain_search_generation() do return {}
    envelope:Owner_Executor_HTTP_Reply
    if json.unmarshal_string(httpc.text(response),&envelope,.JSON,context.temp_allocator)!=nil do return {}
    reply:Owner_Executor_Command_Reply
    if json.unmarshal_string(envelope.data.reply,&reply,.JSON,context.temp_allocator)!=nil ||
       reply.type!="command_result" || reply.request_id!=request_id || reply.code!="ok" {return {}}
    scope["direction"]=json.String("response")
    return {bridge_owner_json(scope),reply.envelope,envelope.data.directory}
}

// The caller has rechecked the current paired directory and exact owner key
// after I/O. Only this pending random challenge may yield a single-use fence.
bridge_executor_fence_accept :: proc(s:^executor.Store,pending:^executor.Fence_Challenge,outcome:Executor_Fence_Outcome,
    owner_key,executor_key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,now:i64)->executor.Current_Owner_Fence {
    scope,valid:=contracts.executor_parse(outcome.scope,"transport_scope")
    if !valid || contracts.owner_string(scope,"method")!="fence_request" || contracts.owner_string(scope,"direction")!="response" do return {}
    reply,authenticated:=channel.open_signed(outcome.envelope,kr,scope,owner_key,now,context.temp_allocator)
    if !authenticated do return {}
    defer crypto.zero_explicit(raw_data(reply),len(reply))
    return executor.fence_accept(s,pending,reply,owner_key,executor_key,now)
}
