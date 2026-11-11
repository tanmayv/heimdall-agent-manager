#+feature dynamic-literals
package owner_local

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

remote_request :: proc(method:string,expires:i64,account:="account",owner:="bridge",from:="brg_b",key_id:="brg_b_key") -> string {
    return encode(map[string]json.Value{"account_id"=json.String(account),"owner_bridge_id"=json.String(owner),"from_bridge_id"=json.String(from),
        "from_key_id"=json.String(key_id),"request_id"=json.String("req_1"),"method"=json.String(method),"params"=json.String(`{"task_id":"task"}`),
        "expires_ms"=json.Integer(expires),"instance"=json.String("inst_remote"),"epoch"=json.String("epoch_remote"),
        "token_generation"=json.String(strings.repeat("e",64,context.temp_allocator)),"agent_id"=json.String("agt_remote"),"run_count"=json.Integer(1)})
}
remote_sign :: proc(priv:^ecdsa.Private_Key,request:string) -> string {
    sig,_:=vault.sign_p256(priv,remote_agent_message(request))
    return vault.hex_encode_lower(sig.sig[:],context.temp_allocator)
}

// An agent on another paired Bridge of the account: the request is checked
// before any key lookup, then signed by an enrolled, unrevoked Bridge key.
@(test)
remote_agent_request_checks_account_owner_freshness_verb_and_signature :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    key:=b.key;key.kind="bridge"
    ok_req:=remote_request("agent.task.show",1500)
    r,child,code:=remote_agent_parse("account","bridge",ok_req,1000)
    testing.expect_value(t,code,"ok")
    testing.expect(t,r.from_bridge_id=="brg_b" && child.instance=="inst_remote" && child.agent_id=="agt_remote")
    testing.expect_value(t,remote_agent_signed(ok_req,remote_sign(&b.priv,ok_req),key),"ok")
    for method in ([6]string{"agent.task.show","agent.task.comments","agent.task.comment","agent.task_chain.show","agent.review.post","agent.lease.next"}) {
        _,_,code=remote_agent_parse("account","bridge",remote_request(method,1500),1000)
        testing.expect_value(t,code,"ok")
    }
    // Writes, assignment, placement and work-lease verbs are not relayable.
    for method in ([6]string{"agent.task.create","agent.task.update","agent.lease.heartbeat","agent.task_chain.set_summary","agent.lease.submit","agent.lease.switch"}) {
        _,_,code=remote_agent_parse("account","bridge",remote_request(method,1500),1000)
        testing.expectf(t,code=="invalid_scope","%s: %s",method,code)
    }
    _,_,code=remote_agent_parse("account","bridge",remote_request("agent.task.show",1500,account="other"),1000)
    testing.expect_value(t,code,"account_mismatch")
    _,_,code=remote_agent_parse("account","bridge",remote_request("agent.task.show",1500,owner="brg_c"),1000)
    testing.expect_value(t,code,"owner_mismatch")
    _,_,code=remote_agent_parse("account","bridge",remote_request("agent.task.show",1000),1000)
    testing.expect_value(t,code,"expired")
    _,_,code=remote_agent_parse("account","bridge",remote_request("agent.task.show",1000+REMOTE_AGENT_TTL_MS+1),1000)
    testing.expect_value(t,code,"expired")
    _,_,code=remote_agent_parse("account","bridge",remote_request("agent.task.show",1500,from="bridge"),1000)
    testing.expect_value(t,code,"malformed")
    _,_,code=remote_agent_parse("account","bridge","{not json",1000)
    testing.expect_value(t,code,"malformed")
    // Signature: other bytes, another key, a revoked or browser key.
    other:=grant_device(t);defer ecdsa.private_key_clear(&other.priv)
    testing.expect_value(t,remote_agent_signed(ok_req,remote_sign(&other.priv,ok_req),key),"bad_signature")
    tampered,_:=strings.replace_all(ok_req,"task.show","task.comments")
    testing.expect_value(t,remote_agent_signed(tampered,remote_sign(&b.priv,ok_req),key),"bad_signature")
    revoked:=key;revoked.revoked=true
    testing.expect_value(t,remote_agent_signed(ok_req,remote_sign(&b.priv,ok_req),revoked),"invalid_scope")
    testing.expect_value(t,remote_agent_signed(ok_req,remote_sign(&b.priv,ok_req),b.key),"invalid_scope")
}

// The full admission against a real signed directory: a key that is not an
// approved Bridge key of this account (a browser, an unknown key, another
// account's directory) is invalid_scope; no paired root is directory_unverified.
@(test)
remote_agent_admission_requires_an_approved_bridge_key_of_this_account :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    vector:struct {keyring_hex,device_id,bridge_device_id:string,job:vault.Control_Job}
    if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_worker_v2.json",string),&vector,.JSON,context.temp_allocator)==nil) do return
    raw:=make([]byte,len(vector.keyring_hex)/2,context.temp_allocator)
    testing.expect(t,vault.hex_decode_into(raw,vector.keyring_hex))
    kr,parsed:=vault.keyring_parse(raw,vector.job.owner);defer vault.keyring_wipe(&kr)
    if !testing.expect(t,parsed) do return
    directory,verified:=vault.directory_verify(vector.job.directory)
    if !testing.expect(t,verified) do return
    root,_:=vault.root_pin_from_hex(directory.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,directory.root_public_key)
    proof:=encode(vector.job.directory)
    account:=vector.job.owner
    admit :: proc(proof,account,key_id:string,root:vault.Root_Pin,version:i64,head:string,kr:^vault.Vault_Keyring) -> string {
        req:=remote_request("agent.task.show",1500,account=account,key_id=key_id)
        _,_,_,code:=remote_agent_admit(proof,account,"bridge",req,strings.repeat("0",128,context.temp_allocator),root,version,head,kr,1000)
        return code
    }
    // The approved Bridge key passes the directory; the zero signature then fails.
    testing.expect_value(t,admit(proof,account,vector.bridge_device_id,root,directory.version,directory.head_hash,&kr),"bad_signature")
    testing.expect_value(t,admit(proof,account,vector.device_id,root,directory.version,directory.head_hash,&kr),"invalid_scope")
    testing.expect_value(t,admit(proof,account,"unknown",root,directory.version,directory.head_hash,&kr),"invalid_scope")
    testing.expect_value(t,admit(proof,account,vector.bridge_device_id,{},directory.version,directory.head_hash,&kr),"directory_unverified")
    // Another account: the request names it, the directory does not match.
    req:=remote_request("agent.task.show",1500,account="other_account",key_id=vector.bridge_device_id)
    _,_,_,code:=remote_agent_admit(proof,"other_account","bridge",req,"",root,directory.version,directory.head_hash,&kr,1000)
    testing.expect_value(t,code,"invalid_scope")
    _=fmt.tprintf
    _=contracts.OWNER_REQUEST_TTL_MS
}
