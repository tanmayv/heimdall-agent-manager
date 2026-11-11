#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"
import channel "odin_test:lib/executor_channel"
import executor "odin_test:lib/executor_local"

@(test)
owner_execution_encrypted_callback_binds_claim_and_rejects_account_key_forgery :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    if !testing.expect_value(t,execution_test_commit(x).code,"ok") do return
    claim:=execution_test_claim(t,f)
    pending:=execution_test_challenge(t,x,claim);defer executor.fence_challenge_destroy(&pending)
    request,_:=contracts.executor_parse(pending.request,"fence_request")
    digest,_:=contracts.executor_digest("fence_request",request)
    scope:=execution_test_document("transport_scope")
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=request[name]
    scope["method"]=json.String("fence_request");scope["direction"]=json.String("request")
    scope["input_digest"]=json.String(digest);scope["fence_digest"]=request["action_digest"]
    scope["issued_ms"]=request["issued_ms"];scope["request_expires_ms"]=request["request_expires_ms"]
    token,sealed:=channel.seal(pending.request,&f.kr,scope,1150,context.temp_allocator)
    if !testing.expect(t,sealed) do return
    before:=fleet_policy_test_state(f)
    result:=execution_fence_channel_reply(&f.store,token,scope,x.host_key,f.owner,1,"head",1200,&f.kr,{&f.owner_priv,execution_test_sign})
    if !testing.expect_value(t,result.code,"ok") do return
    testing.expect(t,field(scope,"direction")=="request","callback preserves the pending scope")
    testing.expect(t,fleet_policy_test_state(f)==before,"callback creates no grant or outbox mutation")
    response:=make(json.Object,context.temp_allocator)
    for name,value in scope do response[name]=value
    response["direction"]=json.String("response")
    reply,opened:=channel.open_signed(result.body,&f.kr,response,f.owner,1200,context.temp_allocator)
    if !testing.expect(t,opened) do return
    proof:=execution_test_accept(x,&pending,reply,f.owner,1200)
    testing.expect(t,proof.current && pending.consumed)
    testing.expect(t,!execution_test_accept(x,&pending,reply,f.owner,1200).current)
    // An account key holder can encrypt a different payload but cannot sign
    // as the enrolled executor or substitute its exact request digest.
    request["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    forged,forged_ok:=channel.seal(encode(request),&f.kr,scope,1200,context.temp_allocator)
    testing.expect(t,forged_ok)
    denied:=execution_fence_channel_reply(&f.store,forged,scope,x.host_key,f.owner,1,"head",1200,&f.kr,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,denied.code,"invalid_scope")
    denied=execution_fence_channel_reply(&f.store,token,response,x.host_key,f.owner,1,"head",1200,&f.kr,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,denied.code,"invalid_scope")
    denied=execution_fence_channel_reply(&f.store,token,scope,x.host_key,f.owner,2,"new_head",1200,&f.kr,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,denied.code,"invalid_scope")
    _,invalidated:=query(f.store.db,"INSERT INTO intent_invalidations VALUES(?,'device','cancel')",claim.id)
    testing.expect(t,invalidated)
    denied=execution_fence_channel_reply(&f.store,token,scope,x.host_key,f.owner,1,"head",1200,&f.kr,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,denied.code,"owner_fence_not_current")
    testing.expect_value(t,denied.body,"")
}
