#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

linked_test_object :: proc(f:^Fixture,kind,id,body:string,refs:="[]",task:="task",revision:="1")->string {
    return encode(doc(map[string]string{"account_id"="account","owner_bridge_id"="bridge","chain_id"="chain","task_id"=task,"kind"=kind,"object_id"=id,"revision"=revision,"author_id"="original_author","created_ms"="37","media_type"="text/plain","body_cipher"=cipher(f,body),"references"=refs,"provenance"="synthetic original record"}))
}
linked_test_ref :: proc(kind,id:string,revision:="1")->string {
    return encode([1]json.Object{doc(map[string]string{"kind"=kind,"object_id"=id,"revision"=revision})})
}
linked_test_call :: proc(f:^Fixture,method,op,body:string)->Result {
    p:=body
    if method=="linked.put" || method=="linked.restore" do p=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    return invoke(f,command(f,method,op,"",p,rows[0][0]),p)
}
linked_test_fetch :: proc(f:^Fixture,kind,id:string,revision:="1",offset:="0")->Result {
    return linked_test_call(f,"linked.fetch","fetch",encode(doc(map[string]string{"kind"=kind,"object_id"=id,"revision"=revision,"offset"=offset})))
}
linked_test_delete :: proc(f:^Fixture,kind,id,op:string,revision:="1")->Result {
    return linked_test_call(f,"linked.delete",op,encode(doc(map[string]string{"kind"=kind,"object_id"=id,"revision"=revision})))
}
linked_test_page :: proc(f:^Fixture,cursor:="",limit:="1")->Result {
    return linked_test_call(f,"linked.backup","backup",encode(doc(map[string]string{"cursor"=cursor,"limit"=limit})))
}
linked_test_json :: proc(raw:string)->json.Object {
    v,_:=json.parse_string(raw,.JSON,true,context.temp_allocator);o,_:=v.(json.Object);return o
}
linked_test_restore_bundle :: proc(objects:[]string,tombstones:[]json.Object=nil)->string {
    return encode(doc(map[string]string{"account_id"="account","owner_bridge_id"="bridge","chain_id"="chain","format"="1","objects"=encode(objects),"tombstones"=encode(tombstones)}))
}

@(test)
linked_signed_roundtrip_replay_search_restart_and_revocation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=linked_test_object(f,"message","message_original","linkedneedle 世界😀\x00tail")
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,raw)}))
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains")
    signed:=command(f,"linked.put","message_put","",payload,rows[0][0])
    result:=invoke(f,signed,payload)
    if !testing.expect_value(t,result.code,"ok") do return
    replay:=invoke(f,signed,payload,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && result.body==replay.body)
    got:=linked_test_json(linked_test_fetch(f,"message","message_original").body)
    testing.expect_value(t,field(got,"record"),raw)
    testing.expect_value(t,search_for(f,"linkedneedle").code,"ok")
    testing.expect_value(t,len(search_hits(search_for(f,"linkedneedle"))),1)
    artifact:=linked_test_object(f,"artifact","artifact_secret","artifactneedle")
    testing.expect_value(t,linked_test_call(f,"linked.put","artifact_put",artifact).code,"ok")
    testing.expect_value(t,len(search_hits(search_for(f,"artifactneedle"))),0)
    before,_:=query(f.store.db,"SELECT record_json,vault_id,key_epoch FROM linked_bodies ORDER BY object_id")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_:=query(f.store.db,"SELECT record_json,vault_id,key_epoch FROM linked_bodies ORDER BY object_id")
    testing.expect_value(t,encode(before),encode(after))
    testing.expect_value(t,len(search_hits(search_for(f,"linkedneedle"))),1)
    testing.expect(t,!exec(f.store.db,"UPDATE linked_bodies SET prose='forged'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM linked_bodies"))
    testing.expect_value(t,linked_test_call(f,"linked.put","same_body",raw).code,"ok")
    changed:=linked_test_object(f,"message","message_original","changed body")
    testing.expect_value(t,linked_test_call(f,"linked.put","conflicting",changed).code,"operation_conflict")
    _,_=query(f.store.db,"UPDATE local_grants SET can_mutate=0,revision=revision+1")
    testing.expect_value(t,linked_test_fetch(f,"message","message_original").code,"ok")
    testing.expect_value(t,linked_test_call(f,"linked.put","read_only",raw).code,"invalid_scope")
    _,_=query(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1")
    testing.expect_value(t,linked_test_fetch(f,"message","message_original").code,"invalid_scope")
    testing.expect_value(t,invoke(f,signed,payload).code,"invalid_scope")
}

@(test)
linked_scope_reference_validation_and_atomic_failure :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=linked_test_object(f,"message","scoped","private")
    o:=linked_test_json(raw)
    for key in ([4]string{"account_id","owner_bridge_id","chain_id","task_id"}) {
        original:=field(o,key);o[key]=json.String("another")
        testing.expect_value(t,linked_test_call(f,"linked.put",fmt.tprintf("bad_%s",key),encode(o)).code,"invalid_scope")
        o[key]=json.String(original)
    }
    testing.expect_value(t,linked_test_call(f,"linked.put","missing_ref",linked_test_object(f,"artifact","missing","manifest",linked_test_ref("blob","unknown"))).code,"invalid_scope")
    testing.expect_value(t,linked_test_call(f,"linked.put","self_ref",linked_test_object(f,"artifact","self","manifest",linked_test_ref("artifact","self"))).code,"invalid_content")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER linked_failure BEFORE INSERT ON local_events WHEN NEW.kind='linked.put' BEGIN SELECT RAISE(ABORT,'synthetic disk error'); END"))
    testing.expect_value(t,linked_test_call(f,"linked.put","rolled_back",raw).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM linked_bodies),(SELECT count(*) FROM linked_identities),(SELECT count(*) FROM search_docs WHERE kind='message'),(SELECT count(*) FROM command_receipts)")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"0","0","0","2"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER linked_failure"))
    // A deferred FK makes COMMIT fail after body, search, event and receipt writes.
    testing.expect(t,exec(f.store.db,"CREATE TABLE linked_parent(id INTEGER PRIMARY KEY); CREATE TABLE linked_commit_ref(id INTEGER REFERENCES linked_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER linked_commit_failure AFTER INSERT ON linked_bodies BEGIN INSERT INTO linked_commit_ref VALUES(1); END"))
    testing.expect_value(t,linked_test_call(f,"linked.put","commit_failed",raw).code,"storage_error")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM linked_bodies),(SELECT count(*) FROM linked_identities),(SELECT count(*) FROM search_docs WHERE kind='message'),(SELECT count(*) FROM command_receipts)")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"0","0","0","2"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER linked_commit_failure"))
    testing.expect_value(t,linked_test_call(f,"linked.put","after_failure",raw).code,"ok")
    rows,_=query(f.store.db,"PRAGMA substituted_key_check");testing.expect_value(t,len(rows),0)
}

@(test)
linked_reference_delete_shared_blob_gc_tombstones_and_task_delete :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    blob:=linked_test_object(f,"blob","chunk","YmluYXJ5bmVlZGxl")
    testing.expect_value(t,linked_test_call(f,"linked.put","blob",blob).code,"ok")
    for id in ([2]string{"artifact_a","artifact_b"}) {
        testing.expect_value(t,linked_test_call(f,"linked.put",id,linked_test_object(f,"artifact",id,"manifest",linked_test_ref("blob","chunk"))).code,"ok")
    }
    testing.expect_value(t,linked_test_delete(f,"artifact","artifact_a","delete_a").code,"ok")
    testing.expect_value(t,linked_test_fetch(f,"blob","chunk").code,"ok")
    testing.expect_value(t,linked_test_delete(f,"artifact","artifact_b","delete_b").code,"ok")
    testing.expect_value(t,linked_test_fetch(f,"blob","chunk").code,"retired")
    testing.expect_value(t,linked_test_call(f,"linked.put","resurrect_chunk",blob).code,"retired")
    testing.expect(t,!exec(f.store.db,"DELETE FROM linked_tombstones"))
    testing.expect_value(t,linked_test_call(f,"linked.put","message",linked_test_object(f,"message","task_message","goneword")).code,"ok")
    p:=`{"protocol_version":"1"}`
    testing.expect_value(t,invoke(f,command(f,"task.delete","delete_task","task",p,"1"),p).code,"ok")
    testing.expect_value(t,linked_test_fetch(f,"message","task_message").code,"retired")
    testing.expect_value(t,len(search_hits(search_for(f,"goneword"))),0)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,linked_test_fetch(f,"blob","chunk").code,"retired")
}

@(test)
linked_encrypted_manifest_pages_restore_and_tombstone_dominance :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    blob:=linked_test_object(f,"blob","first_chunk",strings.repeat("a",7000,context.temp_allocator))
    message:=linked_test_object(f,"message","second_message","restoreneedle")
    artifact:=linked_test_object(f,"artifact","third_artifact","exact manifest",linked_test_ref("blob","first_chunk"))
    for raw,i in ([3]string{blob,message,artifact}) {
        testing.expect_value(t,linked_test_call(f,"linked.put",fmt.tprintf("put_%d",i),raw).code,"ok")
    }
    pages:=make([dynamic]string,context.temp_allocator);cursor:=""
    for _ in 0..<10 {
        result:=linked_test_page(f,cursor)
        if !testing.expect_value(t,result.code,"ok") do return
        page:=linked_test_json(result.body)
        plain,opened:=vault.open(field(page,"manifest_cipher"),&f.kr,context.temp_allocator)
        testing.expect(t,opened==.Ok)
        testing.expect_value(t,field(page,"manifest_digest"),contracts.owner_payload_digest(plain))
        testing.expect(t,len(result.body)<=MAX_PAGE)
        append(&pages,plain)
        cursor=field(page,"next_cursor")
        if cursor=="" do break
    }
    testing.expect(t,len(pages)==4 && cursor=="")
    g:=fixture(t);defer destroy(g);seed(t,g)
    original_kr:=g.kr;g.kr=f.kr;defer {g.kr=original_kr}
    for page,i in pages {
        testing.expect_value(t,linked_test_call(g,"linked.restore",fmt.tprintf("restore_%d",i),page).code,"ok")
    }
    testing.expect_value(t,field(linked_test_json(linked_test_fetch(g,"message","second_message").body),"record"),message)
    testing.expect_value(t,field(linked_test_json(linked_test_fetch(g,"artifact","third_artifact").body),"record"),artifact)
    testing.expect_value(t,len(search_hits(search_for(g,"restoreneedle"))),1)
    testing.expect_value(t,linked_test_delete(g,"message","second_message","newer_deletion").code,"ok")
    // Old pages cannot overwrite a newer destination deletion.
    for page,i in pages {testing.expect_value(t,linked_test_call(g,"linked.restore",fmt.tprintf("old_restore_%d",i),page).code,"ok")}
    testing.expect_value(t,linked_test_fetch(g,"message","second_message").code,"retired")
    // Tombstones within the same import win before any body is inserted.
    tomb:=doc(map[string]string{"kind"="artifact","object_id"="third_artifact","revision"="1","task_id"="task"})
    blob_tomb:=doc(map[string]string{"kind"="blob","object_id"="first_chunk","revision"="1","task_id"="task"})
    bundle:=linked_test_restore_bundle([]string{artifact},[]json.Object{tomb,blob_tomb})
    testing.expect_value(t,linked_test_call(g,"linked.restore","tombstone_first",bundle).code,"ok")
    testing.expect_value(t,linked_test_fetch(g,"artifact","third_artifact").code,"retired")
    testing.expect_value(t,linked_test_fetch(g,"blob","first_chunk").code,"retired")
    close(&g.store);testing.expect(t,open(&g.store,g.path,"account","bridge","bridge_key"))
    testing.expect_value(t,linked_test_fetch(g,"message","second_message").code,"retired")
    rows,_:=query(g.store.db,"PRAGMA substituted_key_check");testing.expect_value(t,len(rows),0)
}

@(test)
linked_inventory_change_scope_epoch_and_facet_resolution :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"history","1").code,"ok")
    raw:=linked_test_object(f,"artifact","art_original","canonical artifact body","[]","task","7")
    testing.expect_value(t,linked_test_call(f,"linked.put","native_artifact",raw).code,"ok")
    p:=encode(doc(map[string]string{"task_id"="task","source_revision"="snapshot_7","key"=encode([3]string{"3","artifacts","1"})}))
    // Select the original fixture's actual artifact-bearing facet identity.
    bundle,_:=contracts.owner_parse(native_history_fixture(),"native_history_bundle")
    v,_:=json.parse_string(field(bundle,"facets"),.JSON,true,context.temp_allocator);facets,_:=v.(json.Array)
    found:=false
    for value in facets {
        text,_:=value.(json.String);facet,_:=native_content_parse(string(text),"native_history_facet")
        if !strings.contains(field(facet,"references_json"),"art_original") do continue
        key:=encode([3]string{field(facet,"attempt_no"),field(facet,"kind"),field(facet,"v")})
        p=encode(doc(map[string]string{"task_id"="task","source_revision"="snapshot_7","key"=key}));found=true;break
    }
    testing.expect(t,found)
    resolved:=linked_test_call(f,"linked.facet.read","resolve",p)
    testing.expect_value(t,resolved.code,"ok")
    testing.expect(t,strings.contains(resolved.body,"resolved"))
    before,_:=query(f.store.db,"SELECT record_json FROM native_history_records ORDER BY record_kind,record_key")
    page:=linked_test_json(linked_test_page(f).body);cursor:=field(page,"next_cursor")
    testing.expect(t,cursor!="")
    testing.expect_value(t,linked_test_delete(f,"artifact","art_original","delete_original","7").code,"ok")
    testing.expect_value(t,linked_test_page(f,cursor).code,"stale_cursor")
    resolved=linked_test_call(f,"linked.facet.read","resolve_deleted",p)
    testing.expect(t,strings.contains(resolved.body,"deleted"))
    after,_:=query(f.store.db,"SELECT record_json FROM native_history_records ORDER BY record_kind,record_key")
    testing.expect_value(t,encode(after),encode(before))
    inventory:=linked_test_call(f,"envelope.read","envelopes",`{"cursor":"","limit":"100"}`)
    testing.expect_value(t,inventory.code,"ok")
    testing.expect(t,strings.contains(inventory.body,"vault.v2") && strings.contains(inventory.body,"cipher_digest") && strings.contains(inventory.body,"epoch"))
}


@(test)
linked_signed_inventory_and_restore_reject_substituted_scope_and_stale_keys :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=linked_test_object(f,"message","scope_message","scopeword")
    testing.expect_value(t,linked_test_call(f,"linked.put","scope_message",raw).code,"ok")
    page:=linked_test_call(f,"linked.read","inventory",`{"cursor":"","limit":"100"}`)
    testing.expect_value(t,page.code,"ok")
    testing.expect_value(t,linked_test_call(f,"linked.backup","huge_limit",`{"cursor":"","limit":"101"}`).code,"malformed")
    bundle:=linked_test_restore_bundle([]string{raw})
    wrong:=linked_test_json(bundle);wrong["chain_id"]=json.String("other_chain")
    testing.expect_value(t,linked_test_call(f,"linked.restore","substituted_restore",encode(wrong)).code,"invalid_scope")
    other:=fixture(t);defer destroy(other)
    substituted:=linked_test_json(raw);substituted["body_cipher"]=json.String(cipher(other,"wrong vault key"))
    substituted["object_id"]=json.String("bad_cipher")
    testing.expect_value(t,linked_test_call(f,"linked.put","bad_cipher",encode(substituted)).code,"invalid_content")
    _,_=query(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1")
    testing.expect_value(t,linked_test_call(f,"linked.backup","revoked_backup",`{"cursor":"","limit":"100"}`).code,"invalid_scope")
    testing.expect_value(t,linked_test_call(f,"envelope.read","revoked_envelopes",`{"cursor":"","limit":"100"}`).code,"invalid_scope")
}

@(test)
linked_v24_upgrade_collision_commit_rollback_and_live_capability_preservation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    keep:="SELECT (SELECT json_group_array(evidence_json) FROM local_events),(SELECT json_group_array(result_json) FROM command_receipts),(SELECT capability_json FROM local_leases WHERE retired_seq IS NULL LIMIT 1)"
    before,_:=query(f.store.db,keep)
    close(&f.store);db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,string(#load("migration_025_test_drop.sql"))))
    prefix:=string(MIGRATION_024);prefix=prefix[:strings.index(prefix,"CREATE TABLE native_record_snapshots")]
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=24; CREATE VIEW linked_identities AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"24","24"}}))
    testing.expect(t,exec(db,"DROP VIEW linked_identities; CREATE TABLE linked_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE linked_upgrade_ref(id INTEGER REFERENCES linked_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER linked_upgrade_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=25 BEGIN INSERT INTO linked_upgrade_ref VALUES(1); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='linked_bodies') FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"24","24","0"}}))
    after,_:=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER linked_upgrade_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_=query(f.store.db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","after_linked_upgrade",`{"requirements_revision":"1"}`,cap).code,"ok")
    testing.expect_value(t,linked_test_call(f,"linked.put","after_upgrade",linked_test_object(f,"message","upgraded_message","migrationword")).code,"ok")
    rows,_=query(f.store.db,"PRAGMA substituted_key_check");testing.expect_value(t,len(rows),0)
}

@(test)
linked_task_tombstone_suppresses_unknown_restored_message_and_delete_rolls_back :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    blob:=linked_test_object(f,"blob","rollback_blob","binary")
    artifact:=linked_test_object(f,"artifact","rollback_artifact","manifest",linked_test_ref("blob","rollback_blob"))
    testing.expect_value(t,linked_test_call(f,"linked.put","rollback_blob",blob).code,"ok")
    testing.expect_value(t,linked_test_call(f,"linked.put","rollback_artifact",artifact).code,"ok")
    before,_:=query(f.store.db,"SELECT (SELECT json_group_array(record_json) FROM linked_bodies),(SELECT count(*) FROM linked_references),(SELECT count(*) FROM linked_tombstones),(SELECT count(*) FROM command_receipts)")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER linked_delete_failure BEFORE INSERT ON local_events WHEN NEW.kind='linked.delete' BEGIN SELECT RAISE(ABORT,'delete failure'); END"))
    testing.expect_value(t,linked_test_delete(f,"artifact","rollback_artifact","delete_fails").code,"storage_error")
    after,_:=query(f.store.db,"SELECT (SELECT json_group_array(record_json) FROM linked_bodies),(SELECT count(*) FROM linked_references),(SELECT count(*) FROM linked_tombstones),(SELECT count(*) FROM command_receipts)")
    testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER linked_delete_failure"))
    unknown:=linked_test_object(f,"message","unknown_old_message","neverresurrect")
    p:=`{"protocol_version":"1"}`
    testing.expect_value(t,invoke(f,command(f,"task.delete","task_tombstone","task",p,"1"),p).code,"ok")
    testing.expect_value(t,linked_test_call(f,"linked.restore","unknown_old_backup",linked_test_restore_bundle([]string{unknown})).code,"ok")
    testing.expect_value(t,linked_test_fetch(f,"message","unknown_old_message").code,"retired")
    identities,_:=query(f.store.db,"SELECT task_id FROM linked_identities WHERE object_id='unknown_old_message'")
    testing.expect_value(t,identities[0][0],"task")
    testing.expect_value(t,len(search_hits(search_for(f,"neverresurrect"))),0)
}

@(test)
linked_manifest_encoded_byte_budget_pages_every_admitted_record :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    for i in 0..<8 {
        raw:=linked_test_object(f,"message",fmt.tprintf("budget_%d",i),strings.repeat("a",8192,context.temp_allocator))
        testing.expect_value(t,linked_test_call(f,"linked.put",fmt.tprintf("budget_%d",i),raw).code,"ok")
    }
    cursor:="";count,pages:=0,0
    for _ in 0..<20 {
        result:=linked_test_page(f,cursor,"100")
        if !testing.expect_value(t,result.code,"ok") do return
        testing.expect(t,len(result.body)<=MAX_PAGE)
        page:=linked_test_json(result.body)
        plain,opened:=vault.open(field(page,"manifest_cipher"),&f.kr,context.temp_allocator)
        testing.expect(t,opened==.Ok)
        bundle:=linked_test_json(plain);objects,valid:=linked_array(field(bundle,"objects"))
        testing.expect(t,valid);count+=len(objects);pages+=1
        cursor=field(page,"next_cursor");if cursor=="" do break
    }
    testing.expect(t,count==8 && pages>2 && cursor=="")
    too_large:=linked_test_json(linked_test_object(f,"message","unexportable",strings.repeat("a",8192,context.temp_allocator)))
    too_large["provenance"]=json.String(strings.repeat("\"",4096,context.temp_allocator))
    testing.expect_value(t,linked_test_call(f,"linked.put","unexportable",encode(too_large)).code,"invalid_content")
}

@(test)
linked_tombstone_manifest_restores_original_task_association :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,linked_test_call(f,"linked.put","source_message",linked_test_object(f,"message","deleted_original","tombstone_metadata")).code,"ok")
    testing.expect_value(t,linked_test_delete(f,"message","deleted_original","source_delete").code,"ok")
    page:=linked_test_json(linked_test_page(f).body)
    raw,opened:=vault.open(field(page,"manifest_cipher"),&f.kr,context.temp_allocator)
    testing.expect(t,opened==.Ok)
    bundle:=linked_test_json(raw);tombs,ok:=linked_array(field(bundle,"tombstones"))
    testing.expect(t,ok && len(tombs)==1)
    tomb,obj:=tombs[0].(json.Object);testing.expect(t,obj)
    testing.expect_value(t,field(tomb,"task_id"),"task")
    g:=fixture(t);defer destroy(g);seed(t,g)
    testing.expect_value(t,linked_test_call(g,"linked.restore","restore_deleted",raw).code,"ok")
    rows,_:=query(g.store.db,"SELECT task_id FROM linked_identities WHERE object_id='deleted_original'")
    testing.expect_value(t,rows[0][0],"task")
    testing.expect_value(t,linked_test_fetch(g,"message","deleted_original").code,"retired")
    tomb["task_id"]=json.String("")
    bundle["tombstones"]=json.String(encode([1]json.Object{tomb}))
    testing.expect_value(t,linked_test_call(g,"linked.restore","retarget_deleted",encode(bundle)).code,"operation_conflict")
    rows,_=query(g.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
