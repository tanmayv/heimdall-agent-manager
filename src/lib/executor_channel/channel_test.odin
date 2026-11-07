package executor_channel

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

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
