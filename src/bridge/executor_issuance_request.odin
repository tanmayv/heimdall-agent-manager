package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import httpc "odin_test:lib/httpc"
import channel "odin_test:lib/executor_channel"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// Owner-Bridge side of cross-Bridge placement (#10, origin/main parity): the
// chain's owner Bridge consents, in its own name, to an issuance on another
// Bridge of the account and relays it through the Hub with its Bridge token
// (POST /api/v1/executor/issuance). This mirrors the device requester in
// src/ui/api/executorIssuance.ts. The executor admits the consent only when
// principal_id == owner_bridge_id == the Hub-stamped relaying Bridge
// (bridge_executor_consent_key), so this builder always names this Bridge as
// both. Keep the returned request for lost-reply recovery: a retry must reuse
// its consent and operation id, never regenerate them.
Executor_Issuance_Request_Input :: struct {
    account,owner_bridge,owner_key_id,executor_bridge,executor_key_id:string,
    chain_id,task_id,agent_id,configuration_revision:string,
    owner_incarnation,executor_incarnation:string,
    selection:json.Object,
    operation_id:string, // "" generates a fresh one
    now:i64,
}
Executor_Issuance_Request :: struct {
    consent,selection:string,
    consent_doc,scope:json.Object,
    // The Hub relay body, and its encoding as the executor parses it.
    relay_body:Executor_Issuance_Relay,
    relay:string,
}
Executor_Issuance_Relay :: struct {protocol_version,chain_id,bridge_id,request_id,expires_ms,envelope:string}

EXECUTOR_ISSUANCE_CONSENT_TTL_MS :: 300000
EXECUTOR_ISSUANCE_REQUEST_TTL_MS :: 60000

bridge_executor_random_id :: proc(prefix:string)->(string,bool) {
    entropy:[16]byte
    if !random.fill(entropy[:]) do return "",false
    return fmt.tprintf("%s%s",prefix,vault.hex_encode_lower(entropy[:],context.temp_allocator)),true
}

// Signer for the owner Bridge's consent only. bridge_executor_sign never signs
// a consent: an executor must not consent for itself.
bridge_executor_consent_sign :: proc(_:rawptr,kind:string,o:json.Object)->(string,bool) {
    if kind!="issuance_consent" do return "",false
    return bridge_owner_sign(nil,"executor.issuance_consent",o)
}

bridge_executor_issuance_request :: proc(input:Executor_Issuance_Request_Input,kr:^vault.Vault_Keyring,
    sign:executor.Signer)->(request:Executor_Issuance_Request,ok:bool) {
    context.allocator=context.temp_allocator
    if input.owner_bridge=="" || input.executor_bridge=="" || input.owner_bridge==input.executor_bridge ||
       input.owner_key_id=="" || input.executor_key_id=="" || input.owner_key_id==input.executor_key_id || sign.sign==nil {return}
    selection:=executor.encode(input.selection)
    if _,valid:=contracts.executor_parse(selection,"issuance_selection");!valid do return
    operation:=input.operation_id
    if operation=="" {
        generated,generated_ok:=bridge_executor_random_id("issue_")
        if !generated_ok do return
        operation=generated
    }
    request_id,request_ok:=bridge_executor_random_id("req_")
    if !request_ok do return
    consent:=make(json.Object)
    for f in contracts.executor_schema("issuance_consent") do consent[f.name]=json.String("")
    for pair in ([16][2]string{{"protocol_version","1"},{"account_id",input.account},{"owner_bridge_id",input.owner_bridge},
        {"executor_bridge_id",input.executor_bridge},{"executor_key_id",input.executor_key_id},{"chain_id",input.chain_id},
        {"task_id",input.task_id},{"agent_id",input.agent_id},{"configuration_revision",input.configuration_revision},
        {"operation_id",operation},{"principal_id",input.owner_bridge},{"selection_digest",contracts.owner_payload_digest(selection)},
        {"issued_ms",fmt.tprintf("%d",input.now)},{"request_expires_ms",fmt.tprintf("%d",input.now+EXECUTOR_ISSUANCE_CONSENT_TTL_MS)},
        {"key_id",input.owner_key_id},{"signature",strings.repeat("0",128)}}) {consent[pair[0]]=json.String(pair[1])}
    signature,signed:=sign.sign(sign.ctx,"issuance_consent",consent)
    if !signed do return
    consent["signature"]=json.String(signature)
    consent_raw:=executor.encode(consent)
    if _,valid:=contracts.executor_parse(consent_raw,"issuance_consent");!valid do return
    input_digest,digest_ok:=contracts.executor_digest("issuance_consent",consent)
    if !digest_ok do return
    scope:=make(json.Object)
    for f in contracts.executor_schema("transport_scope") do scope[f.name]=json.String("")
    for pair in ([15][2]string{{"protocol_version","1"},{"account_id",input.account},{"owner_bridge_id",input.owner_bridge},
        {"executor_bridge_id",input.executor_bridge},{"chain_id",input.chain_id},{"reservation_id",""},{"request_id",request_id},
        {"method","enrollment"},{"direction","request"},{"input_digest",input_digest},{"fence_digest",contracts.owner_string(consent,"selection_digest")},
        {"owner_incarnation",input.owner_incarnation},{"executor_incarnation",input.executor_incarnation},
        {"issued_ms",fmt.tprintf("%d",input.now)},{"request_expires_ms",fmt.tprintf("%d",input.now+EXECUTOR_ISSUANCE_REQUEST_TTL_MS)}}) {scope[pair[0]]=json.String(pair[1])}
    if _,valid:=contracts.executor_parse(executor.encode(scope),"transport_scope");!valid do return
    envelope,sealed:=channel.seal(consent_raw,kr,scope,input.now)
    if !sealed do return
    exchange:=executor.encode(struct{scope,envelope,selection:string}{executor.encode(scope),envelope,selection})
    if _,valid:=contracts.executor_parse(exchange,"issuance_exchange");!valid do return
    outer,outer_ok:=vault.seal(transmute([]byte)exchange,kr)
    if !outer_ok do return
    body:=Executor_Issuance_Relay{"1",input.chain_id,input.executor_bridge,request_id,contracts.owner_string(scope,"request_expires_ms"),outer}
    return Executor_Issuance_Request{consent_raw,selection,consent,scope,body,executor.encode(body)},true
}

// Opens the executor's reply to bridge_executor_issuance_request and returns
// the verified issuance_bundle (configuration, enrollment attestation and
// receipt), bound to this exact consent, selection and executor key.
bridge_executor_issuance_reply_open :: proc(request:Executor_Issuance_Request,code,request_id,envelope:string,kr:^vault.Vault_Keyring,
    owner_key,executor_key:contracts.Owner_Verified_Key,now:i64)->(bundle:string,ok:bool) {
    if code!="ok" || envelope=="" || request_id!=contracts.owner_string(request.scope,"request_id") do return "",false
    expected:=make(json.Object,context.temp_allocator)
    for k,v in request.scope do expected[k]=v
    expected["direction"]=json.String("response")
    return channel.open_issuance(envelope,kr,expected,request.consent_doc,request.selection,owner_key,executor_key,now,true,context.temp_allocator)
}

// The executor's reply as the Hub relays it: data is the executor's own
// command_result ({type,command_id,request_id,code,envelope}).
Executor_Issuance_HTTP_Reply :: struct {data:struct{type,request_id,code,envelope:string}}

// Sends the relay with this Bridge's own token only (never an agent instance
// token: the Hub admits only the user or a Bridge token here and stamps
// from_bridge_id from it). Returns the executor's code, request id and sealed
// reply for bridge_executor_issuance_reply_open.
bridge_executor_issuance_send :: proc(request:Executor_Issuance_Request)->(code,request_id,envelope:string,ok:bool) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    credential:=bridge_credential_snapshot();defer delete(credential)
    headers:=[?]httpc.Header{httpc.bearer(credential)}
    if sync.atomic_load(&bridge_hub_traffic_stopped) do return
    expires:=contracts.executor_number(request.scope,"request_expires_ms")
    response,err:=bridge_http_request_retry({method=.POST,url=bridge_hub_url(),path={"api","v1","executor","issuance"},
        headers=headers[:],body=httpc.json_body(request.relay_body),timeout_ms=15000},deadline_ns=expires*1000000)
    defer httpc.response_destroy(&response)
    if err!=.None || response.status!=200 || len(httpc.text(response))>3*1024*1024 || generation!=bridge_task_chain_search_generation() do return
    reply:Executor_Issuance_HTTP_Reply
    if json.unmarshal_string(httpc.text(response),&reply,.JSON,context.temp_allocator)!=nil do return
    if reply.data.type!="command_result" && reply.data.code!="executor_unavailable" do return
    return reply.data.code,reply.data.request_id,reply.data.envelope,true
}
