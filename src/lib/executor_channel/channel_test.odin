package executor_channel

import "core:encoding/json"
import "core:crypto/ecdsa"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

@(test)
channel_query_discovery_changes_only_serving_metadata_never_child_or_mutation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    v,kr:=fixture(t);defer vault.keyring_wipe(&kr)
    value,_:=contracts.owner_content_document(#load("../../contracts/fixtures/executor-v1.json",string))
    root,_:=value.(json.Object);items,_:=root["valid"].(json.Array)
    q,r:json.Object
    for item in items {
        row,_:=item.(json.Object)
        if contracts.owner_string(row,"kind")=="action" {q,_=contracts.executor_parse(contracts.owner_string(row,"raw"),"action")}
        if contracts.owner_string(row,"kind")=="receipt" {r,_=contracts.executor_parse(contracts.owner_string(row,"raw"),"receipt")}
    }
    q["method"]=json.String("query")
    scalar:[32]byte;scalar[31]=7
    private:ecdsa.Private_Key;testing.expect(t,ecdsa.private_key_set_bytes(&private,.SECP256R1,scalar[:]))
    defer ecdsa.private_key_clear(&private)
    pub:[65]byte;ecdsa.private_key_public_bytes(&private,pub[:])
    key:=contracts.Owner_Verified_Key{"account",contracts.owner_string(q,"executor_bridge_id"),contracts.owner_string(r,"key_id"),
        vault.hex_encode_lower(pub[:],context.temp_allocator),"bridge",true,false}
    for name in ([9]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","operation_id","grant_generation","prepare_digest","hard_ms"}) do r[name]=q[name]
    r["method"]=json.String("query");r["historical"]=json.String("0")
    r["executor_incarnation"]=json.String("2");r["child_incarnation"]=q["executor_incarnation"]
    digest,_:=contracts.executor_digest("action",q);r["input_digest"]=json.String(digest)
    scope:=clone(v.reply_scope)
    for name in ([6]string{"account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id","executor_incarnation"}) do scope[name]=q[name]
    scope["method"]=json.String("action");scope["input_digest"]=json.String(digest);scope["fence_digest"]=q["prepare_digest"]
    launch:=contracts.owner_string(r,"launch_key")
    for mutation in ([8]string{"","chain_id","reservation_id","operation_id","grant_generation","launch_key","child_incarnation","method"}) {
        changed:=clone(r)
        if mutation!="" {changed[mutation]=json.String("heartbeat" if mutation=="method" else ("9" if mutation=="child_incarnation" || mutation=="grant_generation" else strings.repeat("e",64,context.temp_allocator)))}
        canonical,_:=contracts.executor_canonical("receipt",changed)
        signature,_:=vault.sign_p256(&private,transmute([]byte)canonical)
        changed["signature"]=json.String(vault.hex_encode_lower(signature.sig[:],context.temp_allocator))
        bytes,_:=json.marshal(changed,allocator=context.temp_allocator)
        token,sealed:=seal(string(bytes),&kr,scope,1200);testing.expect(t,sealed)
        plain,opened:=open_signed(token,&kr,scope,key,1200,query_discovery=true)
        matches:=contracts.executor_query_receipt_matches(changed,q,key,1200,launch)
        testing.expect(t,(opened && matches)==(mutation==""),mutation)
        if mutation=="" {
            testing.expect(t,plain==string(bytes))
            _,strict:=open_signed(token,&kr,scope,key,1200)
            testing.expect(t,!strict,"ordinary channel remains exact-incarnation")
            revoked:=key;revoked.revoked=true
            testing.expect(t,!contracts.executor_query_receipt_matches(changed,q,revoked,1200,launch))
        }
    }
}

Vector :: struct {
    scope,reply_scope:json.Object,
    request,reply,aad,token,reply_token,old_token,content_token:string,
    vault_id,epoch_key_hex,old_epoch_key_hex,nonce_hex,reply_nonce_hex:string,
    epoch:u32,
    owner_key,executor_key:contracts.Owner_Verified_Key,
}
fixture :: proc(t:^testing.T)->(Vector,vault.Vault_Keyring) {
    v:Vector
    testing.expect(t,json.unmarshal_string(#load("../../contracts/fixtures/executor-channel-v1.json",string),&v,.JSON,context.temp_allocator)==nil)
    id:vault.Vault_Id
    current,old:[32]byte
    testing.expect(t,vault.hex_decode_into(id[:],v.vault_id) && vault.hex_decode_into(current[:],v.epoch_key_hex) && vault.hex_decode_into(old[:],v.old_epoch_key_hex))
    kr,ok:=vault.keyring_from_single_key("account",id,1,old[:]);testing.expect(t,ok)
    kr.entries[1]={2,current};kr.count=2;kr.current_epoch=2
    return v,kr
}
clone :: proc(source:json.Object)->json.Object {
    target:=make(json.Object,context.temp_allocator)
    for k,v in source do target[k]=v
    return target
}
@(test)
channel_child_results_reject_account_key_forgery_and_correlated_body_substitution :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    _,kr:=fixture(t);defer vault.keyring_wipe(&kr)
    value,_:=contracts.owner_content_document(#load("../../contracts/fixtures/executor-child-v1.json",string))
    f,_:=value.(json.Object)
    get:=contracts.owner_string
    request,_:=contracts.executor_parse(get(f,"child"),"child_request")
    key_doc,_:=f["owner_key"].(json.Object)
    key:=contracts.Owner_Verified_Key{"account",get(key_doc,"principal_id"),get(key_doc,"key_id"),get(key_doc,"public_key"),"bridge",true,false}
    scope:=make(json.Object,context.temp_allocator)
    for name in ([8]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=request[name]
    digest,_:=contracts.executor_digest("child_request",request)
    scope["request_id"]=json.String("child_result");scope["method"]=json.String("child_request");scope["direction"]=json.String("response")
    scope["input_digest"]=json.String(digest);scope["fence_digest"]=request["prepare_digest"]
    scope["issued_ms"]=json.String("1200");scope["request_expires_ms"]=json.String("1800")
    body:=get(f,"result_body")
    receipt:=get(f,"child_result")
    encoded,_:=json.marshal(struct{receipt,body:string}{receipt,body},allocator=context.temp_allocator)
    token,sealed:=seal(string(encoded),&kr,scope,1400)
    testing.expect(t,sealed)
    opened,verified:=open_child_result(token,&kr,scope,request,key,1400)
    testing.expect(t,verified && opened==body)
    // An account-key holder can reseal changed plaintext but cannot replace
    // the separately owner-signed result digest.
    encoded,_=json.marshal(struct{receipt,body:string}{receipt,"forged"},allocator=context.temp_allocator)
    token,sealed=seal(string(encoded),&kr,scope,1400);testing.expect(t,sealed)
    _,verified=open_child_result(token,&kr,scope,request,key,1400);testing.expect(t,!verified)
}

@(test)
channel_cross_runtime_ciphertext_aad_and_bilateral_signed_records :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    v,kr:=fixture(t);defer vault.keyring_wipe(&kr)
    associated,ok:=aad(v.scope,kr.vault_id,kr.current_epoch)
    testing.expect(t,ok);testing.expect_value(t,associated,v.aad)
    nonce:[12]byte;testing.expect(t,vault.hex_decode_into(nonce[:],v.nonce_hex))
    sealed,sealed_ok:=seal_with_nonce(v.request,&kr,v.scope,1200,nonce[:])
    testing.expect(t,sealed_ok);testing.expect_value(t,sealed,v.token)
    plain,opened:=open_signed(v.token,&kr,v.scope,v.owner_key,1200)
    testing.expect(t,opened);testing.expect_value(t,plain,v.request)
    reply,verified:=open_signed(v.reply_token,&kr,v.reply_scope,v.executor_key,1200)
    testing.expect(t,verified);testing.expect_value(t,reply,v.reply)
    _,wrong:=open_signed(v.reply_token,&kr,v.reply_scope,v.owner_key,1200)
    testing.expect(t,!wrong)
    a,a_ok:=seal(v.request,&kr,v.scope,1200);b,b_ok:=seal(v.request,&kr,v.scope,1200)
    testing.expect(t,a_ok && b_ok && a!=b)
    _,opened=open_signed(a,&kr,v.scope,v.owner_key,1200);testing.expect(t,opened)
}

@(test)
channel_rejects_scope_swaps_rotation_expiry_and_content_reflection :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    v,kr:=fixture(t);defer vault.keyring_wipe(&kr)
    for pair in ([15][2]string{{"protocol_version","2"},{"account_id","other"},{"owner_bridge_id","other"},
        {"executor_bridge_id","other"},{"chain_id","other"},{"reservation_id","other"},{"request_id","other"},
        {"method","action"},{"direction","response"},{"input_digest",strings.repeat("e",64,context.temp_allocator)},
        {"fence_digest",strings.repeat("f",64,context.temp_allocator)},{"owner_incarnation","2"},{"executor_incarnation","2"},
        {"issued_ms","1100"},{"request_expires_ms","2500"}}) {
        changed:=clone(v.scope);changed[pair[0]]=json.String(pair[1])
        _,ok:=open(v.token,&kr,changed,1200)
        testing.expect(t,!ok,pair[0])
    }
    for now in ([3]i64{999,2000,10000}) {
        _,ok:=open(v.token,&kr,v.scope,now);testing.expect(t,!ok)
    }
    _,retained:=vault.keyring_key_for_epoch(&kr,1);testing.expect(t,retained)
    _,opened:=open(v.old_token,&kr,v.scope,1200);testing.expect(t,!opened)
    _,opened=open(v.content_token,&kr,v.scope,1200);testing.expect(t,!opened)
    _,result:=vault.open(v.token,&kr,context.temp_allocator);testing.expect(t,result!=.Ok)
    wrong_vault:=kr;wrong_vault.vault_id[0]~=1
    _,opened=open(v.token,&wrong_vault,v.scope,1200);testing.expect(t,!opened)
    _,oversized:=seal(strings.repeat("x",32769,context.temp_allocator),&kr,v.scope,1200);testing.expect(t,!oversized)
}

@(test)
channel_account_key_does_not_replace_enrolled_signature_or_exact_correlation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    v,kr:=fixture(t);defer vault.keyring_wipe(&kr)
    request,parsed:=contracts.executor_parse(v.request,"prepare");testing.expect(t,parsed)
    request["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    raw,e:=json.marshal(request,allocator=context.temp_allocator);testing.expect(t,e==nil)
    forged,sealed:=seal(string(raw),&kr,v.scope,1200);testing.expect(t,sealed)
    _,aead:=open(forged,&kr,v.scope,1200);testing.expect(t,aead)
    _,authenticated:=open_signed(forged,&kr,v.scope,v.owner_key,1200);testing.expect(t,!authenticated)
    revoked:=v.owner_key;revoked.revoked=true
    _,authenticated=open_signed(v.token,&kr,v.scope,revoked,1200);testing.expect(t,!authenticated)
    changed:=clone(v.scope);changed["input_digest"]=json.String(strings.repeat("e",64,context.temp_allocator))
    rebound,rebound_ok:=seal(v.request,&kr,changed,1200);testing.expect(t,rebound_ok)
    _,authenticated=open_signed(rebound,&kr,changed,v.owner_key,1200);testing.expect(t,!authenticated)
    changed=clone(v.scope);changed["fence_digest"]=json.String(strings.repeat("e",64,context.temp_allocator))
    rebound,rebound_ok=seal(v.request,&kr,changed,1200);testing.expect(t,rebound_ok)
    _,authenticated=open_signed(rebound,&kr,changed,v.owner_key,1200);testing.expect(t,!authenticated)
    changed=clone(v.scope);changed["method"]=json.String("enrollment");changed["reservation_id"]=json.String("")
    rebound,rebound_ok=seal(v.request,&kr,changed,1200);testing.expect(t,rebound_ok)
    _,authenticated=open_signed(rebound,&kr,changed,v.owner_key,1200);testing.expect(t,!authenticated,"issuance requires its own signed consent contract")
}

@(test)
channel_notification_and_checkpoint_nonce_bind_exact_signed_scope :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    _,kr:=fixture(t);defer vault.keyring_wipe(&kr)
    value,_:=contracts.owner_content_document(#load("../../contracts/fixtures/executor-notification-v1.json",string))
    f,_:=value.(json.Object);get:=contracts.owner_string
    owner_doc,_:=f["owner_key"].(json.Object);executor_doc,_:=f["executor_key"].(json.Object)
    owner:=contracts.Owner_Verified_Key{"account",get(owner_doc,"principal_id"),get(owner_doc,"key_id"),get(owner_doc,"public_key"),"bridge",true,false}
    executor:=contracts.Owner_Verified_Key{"account",get(executor_doc,"principal_id"),get(executor_doc,"key_id"),get(executor_doc,"public_key"),"bridge",true,false}
    for pair in ([2][4]string{{"notification","notification","notification_result","result"},
        {"notification_fence_request","notification_fence_request","notification_fence_reply","fence"}}) {
        raw:=get(f,"notification" if pair[0]=="notification" else "challenge")
        request,_:=contracts.executor_parse(raw,pair[1])
        scope:=make(json.Object,context.temp_allocator)
        for name in ([8]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=request[name]
        digest,_:=contracts.executor_digest(pair[1],request)
        scope["request_id"]=json.String("notification_call");scope["method"]=json.String(pair[0]);scope["direction"]=json.String("request")
        scope["input_digest"]=json.String(digest)
        scope["fence_digest"]=request["prepare_digest"] if pair[0]=="notification" else request["action_digest"]
        scope["issued_ms"]=json.String("1300");scope["request_expires_ms"]=json.String("1700")
        token,sealed:=seal(raw,&kr,scope,1400);testing.expect(t,sealed)
        sender:=owner if pair[0]=="notification" else executor
        plain,opened:=open_signed(token,&kr,scope,sender,1400)
        testing.expect(t,opened && plain==raw)
        forged_scope:=clone(scope);forged_scope["input_digest"]=json.String(strings.repeat("e",64,context.temp_allocator))
        forged,forged_ok:=seal(raw,&kr,forged_scope,1400);testing.expect(t,forged_ok)
        _,opened=open_signed(forged,&kr,forged_scope,sender,1400);testing.expect(t,!opened)
        scope["direction"]=json.String("response")
        response:=get(f,pair[3])
        token,sealed=seal(response,&kr,scope,1400);testing.expect(t,sealed)
        receiver:=executor if pair[0]=="notification" else owner
        plain,opened=open_signed(token,&kr,scope,receiver,1400)
        testing.expect(t,opened && plain==response)
        _,opened=open_signed(token,&kr,scope,sender,1400);testing.expect(t,!opened)
    }
}
