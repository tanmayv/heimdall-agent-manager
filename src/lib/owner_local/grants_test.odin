#+feature dynamic-literals
package owner_local

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

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
grant_call :: proc(f:^Fixture,c,p:string,key:contracts.Owner_Verified_Key,proof:Grant_Proof={},now:i64=1000)->Result {
    if !observe_directory(&f.store,1,"head") do return fail("invalid_scope")
    return execute(&f.store,c,p,f.genesis,key,f.owner,1,"head",now,&f.kr,Signer{&f.owner_priv,test_sign},grant_proof=proof)
}
grant_revision :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    return rows[0][0]
}
grant_payload :: proc(key:contracts.Owner_Verified_Key,expires:i64=10000,mutate:bool=true)->string {
    return encode(doc(map[string]string{"principal_id"=key.principal_id,"key_id"=key.key_id,"expires_ms"=fmt.tprintf("%d",expires),"can_read"="1","can_mutate"="1" if mutate else "0"}))
}
grant_admin_call :: proc(f:^Fixture,method,op,p:string,proof:Grant_Proof={},now:i64=1000)->Result {
    return grant_call(f,command(f,method,op,"",p,grant_revision(f),now+1000),p,f.creator,proof,now)
}
@(test)
signed_grants_scope_mutation_replay_search_revocation_and_expiry :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    read:=`{"cursor":"","limit":"20"}`
    c:=grant_command(f,b.key,&b.priv,"task.read","before","task",read,"0")
    testing.expect_value(t,grant_call(f,c,read,b.key).code,"invalid_scope")
    p:=grant_payload(b.key,5000,false)
    testing.expect_value(t,grant_admin_call(f,"grant.set","grant_b",p,Grant_Proof{target=b.key}).code,"ok")
    testing.expect_value(t,grant_call(f,c,read,b.key).code,"ok")
    search:=encode(doc(map[string]string{"query_cipher"=cipher(f,"private"),"limit"="20"}))
    search_c:=grant_command(f,b.key,&b.priv,"chain.search","search_b","",search,"0")
    found:=grant_call(f,search_c,search,b.key)
    testing.expect(t,found.code=="ok" && strings.contains(found.body,"private body"))
    comment:=encode(doc(map[string]string{"body_cipher"=cipher(f,"B signed comment")}))
    write:=grant_command(f,b.key,&b.priv,"task.comment","write_b","task",comment,"1")
    testing.expect_value(t,grant_call(f,write,comment,b.key).code,"invalid_scope")
    p=grant_payload(b.key,5000,true)
    testing.expect_value(t,grant_admin_call(f,"grant.set","upgrade_b",p,Grant_Proof{target=b.key}).code,"ok")
    first:=grant_call(f,write,comment,b.key)
    testing.expect_value(t,first.code,"ok")
    p=grant_payload(b.key,5000,false)
    testing.expect_value(t,grant_admin_call(f,"grant.set","downgrade_b",p,Grant_Proof{target=b.key}).code,"ok")
    replay:=grant_call(f,write,comment,b.key,now=3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body,"current read grant permits historical reply without new write authority")
    revoke:=encode(doc(map[string]string{"principal_id"=b.key.principal_id,"key_id"=b.key.key_id}))
    testing.expect_value(t,grant_admin_call(f,"grant.revoke","revoke_b",revoke).code,"ok")
    for raw,i in ([3]string{c,write,search_c}) {
        payload:=read if i==0 else comment if i==1 else search
        denied:=grant_call(f,raw,payload,b.key)
        testing.expect(t,denied.code=="invalid_scope" && denied.body=="","revocation precedes replies and snippets")
    }
    p=grant_payload(b.key,4000,true)
    testing.expect_value(t,grant_admin_call(f,"grant.set","renew_b",p,Grant_Proof{target=b.key}).code,"ok")
    testing.expect_value(t,grant_call(f,c,read,b.key,now=3999).code,"expired")
    fresh:=grant_command(f,b.key,&b.priv,"task.read","fresh","task",read,"0",4500)
    testing.expect_value(t,grant_call(f,fresh,read,b.key,now=3999).code,"ok")
    testing.expect_value(t,grant_call(f,write,comment,b.key,now=4000).code,"invalid_scope")
    testing.expect_value(t,grant_call(f,search_c,search,b.key,now=4000).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*),(SELECT count(*) FROM task_comments) FROM local_grant_audit")
    testing.expect(t,rows[0][0]=="5" && rows[0][1]=="1","grant updates audited and comment never duplicated")
}
@(test)
grants_reject_delegated_admin_wrong_account_chain_key_and_unenrolled_target :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    p:=grant_payload(b.key)
    testing.expect_value(t,grant_admin_call(f,"grant.set","missing_target",p).code,"invalid_scope")
    revoked:=b.key;revoked.revoked=true
    testing.expect_value(t,grant_admin_call(f,"grant.set","revoked_target",p,Grant_Proof{target=revoked}).code,"invalid_scope")
    other:=b.key;other.account_id="other"
    testing.expect_value(t,grant_admin_call(f,"grant.set","foreign_target",p,Grant_Proof{target=other}).code,"invalid_scope")
    testing.expect_value(t,grant_admin_call(f,"grant.set","b",p,Grant_Proof{target=b.key}).code,"ok")
    for method,i in ([4]string{"grant.set","grant.revoke","grant.policy","grant.read"}) {
        payload:=p
        switch method {
        case "grant.revoke":payload=encode(doc(map[string]string{"principal_id"=b.key.principal_id,"key_id"=b.key.key_id}))
        case "grant.policy":payload=`{"policy_revision":"1","recovery_enabled":"1"}`
        case "grant.read":payload=`{"cursor":"","limit":"20"}`
        }
        raw:=grant_command(f,b.key,&b.priv,method,fmt.tprintf("delegate_%d",i),"",payload,grant_revision(f))
        testing.expect_value(t,grant_call(f,raw,payload,b.key,Grant_Proof{target=b.key}).code,"invalid_scope")
    }
    read:=`{"cursor":"","limit":"20"}`
    raw:=grant_command(f,b.key,&b.priv,"chain.read","other_chain","",read,"0",chain="ungranted")
    testing.expect_value(t,grant_call(f,raw,read,b.key).code,"invalid_scope")
    raw=grant_command(f,b.key,&b.priv,"chain.read","same_chain","",read,"0")
    testing.expect_value(t,grant_call(f,raw,read,other).code,"invalid_scope")
    other=b.key;other.key_id="another_key"
    testing.expect_value(t,grant_call(f,raw,read,other).code,"invalid_scope")
    other=b.key;other.enrolled=false
    testing.expect_value(t,grant_call(f,raw,read,other).code,"bad_signature")
    p=grant_payload(b.key,1000+GRANT_MAX_TTL_MS+1)
    testing.expect_value(t,grant_admin_call(f,"grant.set","unbounded",p,Grant_Proof{target=b.key}).code,"expired")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_grant_audit")
    testing.expect_value(t,rows[0][0],"1")
}
@(test)
paired_root_recovery_requires_explicit_policy_current_signature_and_immutable_binding :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    root:=grant_device(t);defer ecdsa.private_key_clear(&root.priv)
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    p:=grant_payload(b.key)
    proof:=Grant_Proof{root=root.root,target=b.key}
    recovery:=grant_command(f,root.key,&root.priv,"grant.recover","recover","",p,grant_revision(f))
    testing.expect_value(t,grant_call(f,recovery,p,root.key,proof).code,"invalid_scope")
    policy:=`{"policy_revision":"1","recovery_enabled":"1"}`
    testing.expect_value(t,grant_admin_call(f,"grant.policy","enable_recovery",policy).code,"ok")
    testing.expect_value(t,grant_admin_call(f,"grant.policy","stale_policy",policy).code,"stale_revision")
    revoke:=`{"principal_id":"device","key_id":"device"}`
    testing.expect_value(t,grant_admin_call(f,"grant.revoke","revoke_creator",revoke).code,"ok")
    testing.expect_value(t,grant_admin_call(f,"grant.policy","revoked_creator",policy).code,"invalid_scope")
    root_read:=grant_command(f,root.key,&root.priv,"grant.read","policy_read","",`{"cursor":"","limit":"20"}`,"0")
    listed:=grant_call(f,root_read,`{"cursor":"","limit":"20"}`,root.key,proof)
    testing.expect(t,listed.code=="ok" && strings.contains(listed.body,"policy_revision"))
    recovery=grant_command(f,root.key,&root.priv,"grant.recover","recover","",p,grant_revision(f))
    wrong_proof:=proof;wrong_proof.root=b.root
    testing.expect_value(t,grant_call(f,recovery,p,root.key,wrong_proof).code,"invalid_scope")
    revoked:=root.key;revoked.revoked=true
    testing.expect_value(t,grant_call(f,recovery,p,revoked,proof).code,"invalid_scope")
    fake:=grant_command(f,root.key,&b.priv,"grant.recover","bad_signature","",p,grant_revision(f))
    testing.expect_value(t,grant_call(f,fake,p,root.key,proof).code,"bad_signature")
    testing.expect_value(t,grant_call(f,recovery,p,root.key,proof).code,"ok")
    read:=`{"cursor":"","limit":"20"}`
    testing.expect_value(t,grant_call(f,grant_command(f,b.key,&b.priv,"task.read","replaced","task",read,"0"),read,b.key).code,"ok")
    // Root may recover its own bounded access, then explicitly disable policy.
    own:=grant_payload(root.key)
    own_command:=grant_command(f,root.key,&root.priv,"grant.recover","root_access","",own,grant_revision(f))
    testing.expect_value(t,grant_call(f,own_command,own,root.key,Grant_Proof{root=root.root,target=root.key}).code,"ok")
    disable:=`{"policy_revision":"2","recovery_enabled":"0"}`
    disable_command:=grant_command(f,root.key,&root.priv,"grant.policy","disable","",disable,grant_revision(f))
    testing.expect_value(t,grant_call(f,disable_command,disable,root.key,proof).code,"ok")
    testing.expect_value(t,grant_call(f,recovery,p,root.key,proof).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT creator,creator_key,(SELECT genesis_json FROM chain_genesis),(SELECT owner_bridge_id FROM runtime_database),(SELECT owner_key_id FROM runtime_database) FROM task_chains")
    testing.expect(t,rows[0][0]=="device" && rows[0][1]=="device" && rows[0][2]==f.genesis && rows[0][3]=="bridge" && rows[0][4]=="bridge_key")
    testing.expect(t,!exec(f.store.db,"UPDATE local_grant_audit SET payload_json='forged'"),"signed grant evidence immutable")
}

@(test)
grant_changes_are_atomic_and_list_cursors_are_revision_bound :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    p:=grant_payload(b.key)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER grant_receipt_failure BEFORE INSERT ON command_receipts BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;"))
    testing.expect_value(t,grant_admin_call(f,"grant.set","atomic",p,Grant_Proof{target=b.key}).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_grants),(SELECT count(*) FROM local_grant_audit),(SELECT revision FROM task_chains)")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="0" && rows[0][2]=="2")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER grant_receipt_failure"))
    testing.expect_value(t,grant_admin_call(f,"grant.set","atomic",p,Grant_Proof{target=b.key}).code,"ok")
    read:=`{"cursor":"","limit":"1"}`
    result:=grant_call(f,command(f,"grant.read","page","",read,"0"),read,f.creator)
    testing.expect_value(t,result.code,"ok")
    page:struct{revision,policy_revision,recovery_enabled,next_cursor:string,grants:[][]string}
    testing.expect_value(t,json.unmarshal_string(result.body,&page,.JSON,context.temp_allocator),nil)
    testing.expect(t,len(page.grants)==1 && page.next_cursor!="" && page.recovery_enabled=="0")
    next:=encode(doc(map[string]string{"cursor"=page.next_cursor,"limit"="1"}))
    result=grant_call(f,command(f,"grant.read","next","",next,"0"),next,f.creator)
    testing.expect_value(t,result.code,"ok")
    testing.expect_value(t,json.unmarshal_string(result.body,&page,.JSON,context.temp_allocator),nil)
    testing.expect(t,len(page.grants)==1 && page.next_cursor=="")
    policy:=`{"policy_revision":"1","recovery_enabled":"1"}`
    testing.expect_value(t,grant_admin_call(f,"grant.policy","change",policy).code,"ok")
    testing.expect_value(t,grant_call(f,command(f,"grant.read","stale","",next,"0"),next,f.creator).code,"stale_cursor")
    rows,_=query(f.store.db,"SELECT command_json,payload_json FROM local_grant_audit WHERE operation_id='atomic'")
    c,ok:=contracts.owner_parse(rows[0][0],"command")
    testing.expect(t,ok && rows[0][1]==p && contracts.owner_verify_signature("command",c,"signature",f.creator))
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    read_command:=grant_command(f,b.key,&b.priv,"chain.read","after_restart","",read,"0")
    testing.expect_value(t,grant_call(f,read_command,read,b.key).code,"ok")
}

@(test)
grants_v7_upgrade_bounds_legacy_authority_and_rolls_back_collision_and_commit_failure :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,V9_TEST_DROP+"DROP TABLE IF EXISTS local_chain_context;"+"DROP TABLE local_grant_audit; DROP TABLE local_grant_policy;"))
    prefix:=string(MIGRATION_007)
    prefix=prefix[:strings.index(prefix,"CREATE TABLE local_controls")]
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=7; CREATE INDEX local_review_holder ON local_review_sessions(json_extract(child,'$.instance')); UPDATE local_grants SET revision=revision+1,expires_ms=9223372036854775807; CREATE VIEW local_grant_policy AS SELECT 1;"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT expires_ms FROM local_grants) FROM runtime_database")
    testing.expect(t,rows[0][0]=="7" && rows[0][1]=="7" && rows[0][2]=="9223372036854775807")
    testing.expect(t,exec(db,"DROP VIEW local_grant_policy"))
    testing.expect(t,exec(db,`CREATE TABLE grant_upgrade_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE grant_upgrade_ref(id INTEGER REFERENCES grant_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER grant_upgrade_failure AFTER UPDATE ON schema_migrations WHEN NEW.version=8 BEGIN INSERT INTO grant_upgrade_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT expires_ms FROM local_grants),(SELECT count(*) FROM sqlite_master WHERE name='local_grant_policy') FROM runtime_database")
    testing.expect(t,rows[0][0]=="7" && rows[0][1]=="7" && rows[0][2]=="9223372036854775807" && rows[0][3]=="0")
    testing.expect(t,exec(db,"DROP TRIGGER grant_upgrade_failure"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT expires_ms FROM local_grants),(SELECT count(*) FROM local_grant_policy),(SELECT body FROM tasks),(SELECT count(*) FROM command_receipts) FROM runtime_database")
    testing.expect(t,rows[0][0]=="13" && rows[0][1]=="13" && number(rows[0][2])==1000+GRANT_MAX_TTL_MS && rows[0][3]=="0" && rows[0][4]=="private body" && rows[0][5]=="2")
}

@(test)
grant_expiry_cannot_revive_below_durable_clock_high_water :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    b:=grant_device(t);defer ecdsa.private_key_clear(&b.priv)
    p:=grant_payload(b.key,4000,true)
    testing.expect_value(t,grant_admin_call(f,"grant.set","bounded",p,Grant_Proof{target=b.key}).code,"ok")
    comment:=encode(doc(map[string]string{"body_cipher"=cipher(f,"before expiry")}))
    c:=grant_command(f,b.key,&b.priv,"task.comment","old","task",comment,"1")
    testing.expect_value(t,grant_call(f,c,comment,b.key).code,"ok")
    edit:=encode(doc(map[string]string{"title_cipher"=cipher(f,"later durable observation"),"description_cipher"=cipher(f,"clock")}))
    later:=command(f,"chain.edit","later","",edit,grant_revision(f),6000)
    testing.expect_value(t,grant_call(f,later,edit,f.creator,now=5000).code,"ok")
    testing.expect_value(t,grant_call(f,c,comment,b.key,now=1000).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT expires_ms FROM local_grants WHERE principal_id='device'")
    testing.expect_value(t,number(rows[0][0]),1000+GRANT_MAX_TTL_MS)
}
