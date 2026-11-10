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
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=7; CREATE INDEX local_review_holder ON local_review_sessions(json_extract(child,'$.instance')); UPDATE local_grants SET revision=revision+1,expires_ms=9223372036854775807; CREATE VIEW local_grant_policy AS SELECT 1;"))
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
    testing.expect(t,rows[0][0]=="37" && rows[0][1]=="37" && number(rows[0][2])==1000+GRANT_MAX_TTL_MS && rows[0][3]=="0" && rows[0][4]=="private body" && rows[0][5]=="2")
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
