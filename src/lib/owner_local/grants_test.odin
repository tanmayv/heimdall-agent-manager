#+feature dynamic-literals
package owner_local

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// The 30-day bound migration_008 applied to legacy grant rows.
LEGACY_GRANT_TTL_MS :: 30*24*60*60*1000
Grant_Device :: struct { priv:ecdsa.Private_Key, key:contracts.Owner_Verified_Key, root:vault.Root_Pin }
grant_device :: proc(t:^testing.T)->Grant_Device {
    d:Grant_Device
    testing.expect(t,vault.p256_private_key_generate(&d.priv))
    pub:[65]byte
    ecdsa.private_key_public_bytes(&d.priv,pub[:])
    public:=vault.hex_encode_lower(pub[:],context.temp_allocator)
    id,ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    testing.expect(t,ok)
    d.key=contracts.Owner_Verified_Key{"account",id,id,public,"device",true,false}
    d.root,ok=vault.root_pin_from_hex(id,vault.SIGN_ALG_ECDSA_P256_SHA256,public)
    testing.expect(t,ok)
    return d
}
grant_command :: proc(f:^Fixture,key:contracts.Owner_Verified_Key,priv:^ecdsa.Private_Key,method,op,task,payload,revision:string,expires:i64=2000,chain:string="chain")->string {
    c,_:=contracts.owner_parse(command(f,method,op,task,payload,revision,expires),"command")
    c["principal_id"]=json.String(key.principal_id);c["key_id"]=json.String(key.key_id);c["chain_id"]=json.String(chain)
    sig,_:=test_sign(priv,"command",c);c["signature"]=json.String(sig)
    return encode(c)
}
grant_call :: proc(f:^Fixture,c,p:string,key:contracts.Owner_Verified_Key,now:i64=1000)->Result {
    if !observe_directory(&f.store,1,"head") do return fail("invalid_scope")
    return execute(&f.store,c,p,f.genesis,key,f.owner,1,"head",now,&f.kr,Signer{&f.owner_priv,test_sign})
}
grant_revision :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    return rows[0][0]
}
grant_payload :: proc(key:contracts.Owner_Verified_Key,expires:i64=10000,mutate:bool=true)->string {
    return encode(doc(map[string]string{"principal_id"=key.principal_id,"key_id"=key.key_id,"expires_ms"=fmt.tprintf("%d",expires),"can_read"="1","can_mutate"="1" if mutate else "0"}))
}
// Per-chain grants are gone: grant.* is no longer a method, chain.create
// issues no grant or recovery policy, and a second paired device needs none.
@(test)
grant_methods_are_removed_and_chain_create_issues_no_grant :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_grants),(SELECT count(*) FROM local_grant_policy),(SELECT count(*) FROM local_grant_audit)")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"0","0","0"}}))
    p:=grant_payload(b.key)
    for method in ([5]string{"grant.set","grant.recover","grant.revoke","grant.policy","grant.read"}) {
        testing.expect(t,!contracts.owner_method_valid(method))
        testing.expect_value(t,grant_call(f,command(f,method,fmt.tprintf("gone_%s",method),"",p,grant_revision(f),2000),p,f.creator).code,"malformed")
    }
    read:=`{"cursor":"","limit":"1"}`
    second:=grant_command(f,b.key,&b.priv,"chain.read","second_reads","",read,"0")
    testing.expect_value(t,grant_call(f,second,read,b.key).code,"ok")
}

@(test)
paired_devices_share_account_access_and_unpaired_revoked_or_foreign_are_refused :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    // A second paired device of the account: no grant row, no recovery.
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    read:=`{"cursor":"","limit":"20"}`
    c:=grant_command(f,b.key,&b.priv,"task.read","b_read","task",read,"0")
    testing.expect_value(t,grant_call(f,c,read,b.key).code,"ok")
    search:=encode(doc(map[string]string{"query_cipher"=cipher(f,"private"),"limit"="20"}))
    found:=grant_call(f,grant_command(f,b.key,&b.priv,"chain.search","b_search","",search,"0"),search,b.key)
    testing.expect(t,found.code=="ok" && strings.contains(found.body,"private body"),"search covers the chain without a grant")
    comment:=encode(doc(map[string]string{"body_cipher"=cipher(f,"B signed comment")}))
    write:=grant_command(f,b.key,&b.priv,"task.comment","b_write","task",comment,"1")
    first:=grant_call(f,write,comment,b.key)
    testing.expect_value(t,first.code,"ok")
    replay:=grant_call(f,write,comment,b.key,now=1500)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    // Refusals: revoked, unenrolled, another account, a mismatched key id.
    for i in 0..<4 {
        k:=b.key
        switch i {
        case 0:k.revoked=true
        case 1:k.enrolled=false
        case 2:k.account_id="other"
        case 3:k.key_id="another_key"
        }
        for raw,j in ([2]string{c,write}) {
            denied:=grant_call(f,raw,read if j==0 else comment,k)
            testing.expect(t,denied.code=="invalid_scope" && denied.body=="","an unpaired, revoked or foreign key gets nothing, not even a replay")
        }
    }
    // A key not signing for itself (wrong signer) is a bad signature.
    forged:=grant_command(f,b.key,&f.creator_priv,"task.read","forged","task",read,"0")
    testing.expect_value(t,grant_call(f,forged,read,b.key).code,"bad_signature")
    // Freshness: a request that expired below the durable clock high water is refused.
    edit:=encode(doc(map[string]string{"title_cipher"=cipher(f,"later durable observation"),"description_cipher"=cipher(f,"clock")}))
    testing.expect_value(t,grant_call(f,command(f,"chain.edit","later","",edit,grant_revision(f),6000),edit,f.creator,now=5000).code,"ok")
    stale:=grant_command(f,b.key,&b.priv,"task.comment","stale","task",comment,"0",2000)
    testing.expect(t,grant_call(f,stale,comment,b.key,now=1000).code!="ok","no revival below the durable clock")
    rows,_:=query(f.store.db,"SELECT count(*) FROM task_comments")
    testing.expect_value(t,rows[0][0],"1")
}

// The Bridge replies with the directory refusal reason instead of a blanket
// invalid_scope: unusable evidence is directory_unverified, another account's
// directory is account_mismatch.
@(test)
verify_directory_code_names_the_reason :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    d:=grant_device(t);defer ecdsa.private_key_clear(&d.priv)
    kr:vault.Vault_Keyring
    other:=`{"owner":"other_account","root_device_id":"","head_hash":"","version":1,"current_epoch":1,"log":[],"devices":[]}`
    _,_,_,_,code:=verify_directory_code(other,"account","bridge",d.key.public_key,d.key.principal_id,d.key.key_id,{},1,"head",&kr)
    testing.expect_value(t,code,"directory_unverified") // no paired root at all
    _,_,_,_,code=verify_directory_code(other,"account","bridge",d.key.public_key,d.key.principal_id,d.key.key_id,d.root,1,"head",&kr)
    testing.expect_value(t,code,"account_mismatch")
    _,_,_,_,code=verify_directory_code("not json","account","bridge",d.key.public_key,d.key.principal_id,d.key.key_id,d.root,1,"head",&kr)
    testing.expect_value(t,code,"directory_unverified")
    unsigned:=`{"owner":"account","root_device_id":"","head_hash":"","version":1,"current_epoch":1,"log":[],"devices":[]}`
    _,_,_,_,code=verify_directory_code(unsigned,"account","bridge",d.key.public_key,d.key.principal_id,d.key.key_id,d.root,1,"head",&kr)
    testing.expect_value(t,code,"directory_unverified")
    _,_,_,_,ok:=verify_directory(unsigned,"account","bridge",d.key.public_key,d.key.principal_id,d.key.key_id,d.root,1,"head",&kr)
    testing.expect(t,!ok)
}
