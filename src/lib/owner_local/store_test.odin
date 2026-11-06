#+feature dynamic-literals
package owner_local

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

Fixture :: struct { store:Store, creator_priv,owner_priv:ecdsa.Private_Key, creator,owner:contracts.Owner_Verified_Key, kr:vault.Vault_Keyring, path,genesis:string }
test_sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,ok:=contracts.owner_canonical(kind,o)
    if !ok do return "",false
    sig,signed:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)canonical)
    if !signed do return "",false
    return vault.hex_encode_lower(sig.sig[:],context.temp_allocator),true
}
fixture :: proc(t:^testing.T)->^Fixture {
    f:=new(Fixture)
    testing.expect(t,vault.p256_private_key_generate(&f.creator_priv))
    testing.expect(t,vault.p256_private_key_generate(&f.owner_priv))
    pub:[65]byte
    ecdsa.private_key_public_bytes(&f.creator_priv,pub[:])
    f.creator={"account","device","device",strings.clone(vault.hex_encode_lower(pub[:],context.temp_allocator)),"device",true,false}
    ecdsa.private_key_public_bytes(&f.owner_priv,pub[:])
    f.owner={"account","bridge","bridge_key",strings.clone(vault.hex_encode_lower(pub[:],context.temp_allocator)),"bridge",true,false}
    id,_:=vault.vault_id_from_root_sign_pub(f.creator.public_key)
    key:[32]byte
    key[0]=5
    f.kr,_=vault.keyring_from_single_key("account",id,1,key[:])
    home:=os.get_env("HOME",context.temp_allocator)
    f.path=fmt.aprintf("%s/.cache/heimdall-tests/owner-unit-%d.sqlite",home,time.to_unix_nanoseconds(time.now()))
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do testing.fail_now(t,"open")
    g:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","creation_op"="create","owner_bridge_id"="bridge","owner_key_id"="bridge_key","creator_id"="device","creator_key_id"="device","schema_version"="1","creator_signature"=strings.repeat("0",128,context.temp_allocator),"owner_signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(&f.creator_priv,"genesis",g);g["creator_signature"]=json.String(sig)
    sig,_=test_sign(&f.owner_priv,"genesis",g);g["owner_signature"]=json.String(sig)
    f.genesis=strings.clone(encode(g))
    return f
}
destroy :: proc(f:^Fixture) {
    close(&f.store)
    for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",f.path,suffix))
    ecdsa.private_key_clear(&f.creator_priv);ecdsa.private_key_clear(&f.owner_priv);vault.keyring_wipe(&f.kr)
    delete(f.path);delete(f.genesis);delete(f.creator.public_key);delete(f.owner.public_key);free(f)
}
cipher :: proc(f:^Fixture,body:string)->string { out,_:=vault.seal_string(body,&f.kr,context.temp_allocator);return out }
command :: proc(f:^Fixture,method,op,task,payload,revision:string,expires:i64=2000)->string {
    c:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","immutable_owner_bridge"="bridge","principal_id"="device","operation_id"=op,"method"=method,"task_id"=task,"expected_revision"=revision,"request_expires_ms"=fmt.tprintf("%d",expires),"payload_digest"=contracts.owner_payload_digest(payload),"key_id"="device","signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(&f.creator_priv,"command",c);c["signature"]=json.String(sig)
    return encode(c)
}
invoke :: proc(f:^Fixture,c,p:string,now:i64=1000)->Result {
    return execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",now,&f.kr,Signer{&f.owner_priv,test_sign})
}
seed :: proc(t:^testing.T,f:^Fixture) {
    g,_:=contracts.owner_parse(f.genesis,"genesis");digest,_:=contracts.owner_digest("genesis",g)
    p:=encode(doc(map[string]string{"genesis_digest"=digest,"title_cipher"=cipher(f,"chain title"),"description_cipher"=cipher(f,"chain description")}))
    testing.expect_value(t,invoke(f,command(f,"chain.create","create","",p,"0"),p).code,"ok")
    p=encode(doc(map[string]string{"title_cipher"=cipher(f,"task title"),"body_cipher"=cipher(f,"private body")}))
    testing.expect_value(t,invoke(f,command(f,"task.create","task","task",p,"1"),p).code,"ok")
}
@(test)
receipt_replay_precedes_expiry_revision_and_mutation_rights :: proc(t:^testing.T) {
    saved:=context.allocator
    context.allocator=context.temp_allocator
    defer { context.allocator=saved }
    f:=fixture(t);defer destroy(f)
    seed(t,f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"exactly once")}))
    c:=command(f,"task.comment","comment","task",p,"1")
    first:=invoke(f,c,p)
    testing.expect_value(t,first.code,"ok")
    _,_=query(f.store.db,"UPDATE local_grants SET can_mutate=0")
    replay:=invoke(f,c,p,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body,"expired request replays without mutation permission")
    changed:=command(f,"task.comment","comment","task",p,"0",4000)
    testing.expect_value(t,invoke(f,changed,p,3000).code,"operation_conflict")
    _,_=query(f.store.db,"UPDATE local_grants SET revoked=1")
    testing.expect_value(t,invoke(f,c,p,3000).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM task_comments")
    testing.expect_value(t,rows[0][0],"1")
}
@(test)
rollback_and_owner_restart_preserve_atomic_receipts :: proc(t:^testing.T) {
    saved:=context.allocator
    context.allocator=context.temp_allocator
    defer { context.allocator=saved }
    f:=fixture(t);defer destroy(f);seed(t,f)
    other:Store
    testing.expect(t,!open(&other,f.path,"account","bridge","bridge_key"),"second writer fails closed")
    _=exec(f.store.db,"CREATE TRIGGER fail_receipt BEFORE INSERT ON command_receipts BEGIN SELECT RAISE(ABORT,'disk failure'); END")
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"rolled back")}))
    c:=command(f,"task.comment","failed","task",p,"1")
    testing.expect_value(t,invoke(f,c,p).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT count(*) FROM task_comments")
    testing.expect_value(t,rows[0][0],"0")
    _=exec(f.store.db,"DROP TRIGGER fail_receipt")
    close(&f.store)
    testing.expect(t,!open(&other,f.path,"another_account","bridge","bridge_key"),"database account cannot change")
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,invoke(f,c,p).code,"ok")
    rows,_=query(f.store.db,"SELECT body FROM tasks")
    testing.expect_value(t,rows[0][0],"private body")
    testing.expect(t,!exec(f.store.db,"UPDATE chain_genesis SET genesis_digest='changed'"),"genesis immutable")
}

@(test)
reads_preserve_nul_content_and_reject_stale_cursor :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"before\x00after")}))
    testing.expect_value(t,invoke(f,command(f,"task.comment","nul","task",p,"1"),p).code,"ok")
    p=encode(doc(map[string]string{"cursor"="","limit"="1"}))
    read:=invoke(f,command(f,"task.read","read","task",p,"0"),p)
    value,_:=json.parse_string(read.body,.JSON,true,context.temp_allocator)
    object,_:=value.(json.Object);items,_:=object["items"].(json.Array)
    item,_:=items[0].(json.Object)
    testing.expect_value(t,field(item,"body"),"before\x00after")
    p=encode(doc(map[string]string{"cursor"="wrong:0","limit"="1"}))
    testing.expect_value(t,invoke(f,command(f,"task.read","cursor","task",p,"0"),p).code,"stale_cursor")
}
