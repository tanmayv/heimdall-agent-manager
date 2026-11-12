#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// One pending exchange, owned by the serialized executor dispatcher. Never
// persist or restore it: restart must generate a new unpredictable challenge.
Fence_Challenge :: struct {request,action:string,consumed:bool,started:time.Tick}
fence_challenge_destroy :: proc(p:^Fence_Challenge) {
    delete(p.request);delete(p.action);p^={}
}
fence_challenge :: proc(s:^Store,action_raw,intent_id:string,attempt:i64,owner_key,executor_key:contracts.Owner_Verified_Key,
    now:i64,sign:Signer)->(Fence_Challenge,bool) {
    now:=store_now(s,now) // C1: the store's single clock source
    started:=time.tick_now()
    a,valid:=contracts.executor_parse(action_raw,"action")
    if !valid || !scope(s,a) || !contracts.executor_verify("action",a,owner_key) || (field(a,"method")!="activate" && field(a,"method")!="heartbeat") ||
       num(a,"executor_incarnation")!=s.incarnation || !contracts.owner_field_valid(intent_id,"hash") || attempt<=0 ||
       now<=0 || now>0x7fffffffffffffff-contracts.EXECUTOR_FENCE_TTL_MS || !contracts.executor_peer_unexpired(num(a,"request_expires_ms"),now) ||
       !contracts.executor_peer_unexpired(num(a,"expires_ms"),now) || sign.sign==nil {return {},false}
    nonce:[32]byte
    if !random.fill(nonce[:]) do return {},false
    digest,_:=contracts.executor_digest("action",a)
    request:=make(json.Object,context.temp_allocator)
    for name in ([8]string{"protocol_version","account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation","owner_incarnation"}) do request[name]=a[name]
    request["intent_id"]=json.String(intent_id);request["claim_attempt"]=json.String(fmt.tprintf("%d",attempt))
    request["action_digest"]=json.String(digest);request["challenge"]=json.String(vault.hex_encode_lower(nonce[:],context.temp_allocator))
    request["issued_ms"]=json.String(fmt.tprintf("%d",now))
    request["request_expires_ms"]=json.String(fmt.tprintf("%d",min(now+contracts.EXECUTOR_FENCE_TTL_MS,num(a,"request_expires_ms"),num(a,"expires_ms"))))
    request["key_id"]=json.String(executor_key.key_id);request["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    signature,signed:=sign.sign(sign.ctx,"fence_request",request)
    if !signed do return {},false
    request["signature"]=json.String(signature)
    if !contracts.executor_verify("fence_request",request,executor_key) do return {},false
    return Fence_Challenge{strings.clone(encode(request)),strings.clone(action_raw),false,started},true
}

// Caller serializes access to the pending exchange and rechecks the exact
// ledger intent before physical I/O. This returns no durable launch permission.
fence_accept :: proc(s:^Store,p:^Fence_Challenge,reply_raw:string,owner_key,executor_key:contracts.Owner_Verified_Key,now:i64)->Current_Owner_Fence {
    now:=store_now(s,now) // C1: the store's single clock source
    if p==nil || p.consumed || s.db==nil || s.unusable do return {}
    q,q_ok:=contracts.executor_parse(p.request,"fence_request")
    a,a_ok:=contracts.executor_parse(p.action,"action")
    r,r_ok:=contracts.executor_parse(reply_raw,"fence_reply")
    if !q_ok || !a_ok || !r_ok do return {}
    elapsed:=time.tick_since(p.started)
    if elapsed<0 || elapsed>=time.Duration(num(q,"request_expires_ms")-num(q,"issued_ms"))*time.Millisecond || now>=num(q,"request_expires_ms") {
        p.consumed=true
        return {}
    }
    if !scope(s,q) || num(q,"executor_incarnation")!=s.incarnation ||
       !contracts.executor_fence_reply_matches(r,q,a,owner_key,executor_key,now) {return {}}
    p.consumed=true
    return {true,field(r,"prepare_digest"),num(r,"owner_incarnation"),num(r,"owner_commit_seq")}
}
