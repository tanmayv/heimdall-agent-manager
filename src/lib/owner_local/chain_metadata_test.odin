#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

summary_call :: proc(f:^Fixture,body,op,revision:string) -> Result {
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
    return invoke(f,command(f,"chain.summary.set",op,"",p,revision),p)
}
summary_revision :: proc(f:^Fixture) -> string {
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    return rows[0][0]
}
@(test)
summary_signed_cas_exact_history_restart_context_and_scope :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    old:=summary_revision(f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"curated original 界")}))
    c:=command(f,"chain.summary.set","summary_first","",p,old)
    accepted:=invoke(f,c,p)
    if !testing.expect_value(t,accepted.code,"ok") do return
    snapshot:=native_metadata_test_state(f)
    replay:=invoke(f,c,p,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==accepted.body)
    testing.expect_value(t,native_metadata_test_state(f),snapshot)
    testing.expect_value(t,summary_call(f,"stale","summary_stale",old).code,"stale_revision")
    got:=context_call(f,"chain.metadata.read","summary_read","")
    testing.expect_value(t,got.code,"ok")
    testing.expect(t,strings.contains(got.body,"curated original"))
    ctx:=context_call(f,"chain.read","summary_context","")
    testing.expect(t,ctx.code=="ok" && strings.contains(ctx.body,"Curated notes: curated original"))
    sources,ok:=context_sources(&f.store,"chain")
    testing.expect(t,ok)
    found,priority:=false,false
    for row in sources {
        if row[0]=="curated_summary" && strings.contains(row[2],"curated original") do found=true
        if row[0]=="task" && strings.contains(row[2],`"priority":"p2"`) do priority=true
    }
    testing.expect(t,found && priority)
    // Multiple versions are retained and a changed revision invalidates pages.
    read_p:=encode(doc(map[string]string{"cursor"="","limit"="1"}))
    for i in 0..<3 do testing.expect_value(t,summary_call(f,fmt.tprintf("notes %d",i),fmt.tprintf("summary%d",i),summary_revision(f)).code,"ok")
    page:=invoke(f,command(f,"chain.metadata.read","page","",read_p,"0"),read_p)
    v,_:=contracts.owner_content_document(page.body);o,_:=v.(json.Object)
    cursor:=field(o,"next_cursor")
    testing.expect(t,cursor!="")
    testing.expect_value(t,summary_call(f,"","summary_clear",summary_revision(f)).code,"ok")
    testing.expect_value(t,context_call(f,"chain.metadata.read","stale_summary_page",cursor).code,"stale_cursor")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_chain_summary_versions")
    testing.expect_value(t,rows[0][0],"5")
    testing.expect(t,!exec(f.store.db,"UPDATE local_chain_summary_versions SET curated_body='rewrite'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_chain_summary_versions"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,context_call(f,"chain.metadata.read","restart_summary","").code,"ok")
    ctx=context_call(f,"chain.read","cleared_context","")
    testing.expect(t,ctx.code=="ok" && !strings.contains(ctx.body,"Curated notes:"))
    testing.expect(t,exec(f.store.db,"UPDATE local_grants SET can_mutate=0,revision=revision+1"))
    testing.expect_value(t,summary_call(f,"forbidden","summary_readonly",summary_revision(f)).code,"invalid_scope")
    testing.expect_value(t,context_call(f,"chain.metadata.read","readonly_summary","").code,"ok")
}
@(test)
summary_statement_and_commit_rollback_preserve_context_and_receipts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,context_call(f,"chain.read","initial_context","").code,"ok")
    before:=native_metadata_test_state(f)
    ctx,_:=query(f.store.db,"SELECT * FROM local_chain_context")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER summary_fail BEFORE INSERT ON local_events WHEN NEW.kind='chain.summary.set' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,summary_call(f,"notes","summary_statement",summary_revision(f)).code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER summary_fail; CREATE TABLE summary_parent(id INTEGER PRIMARY KEY); CREATE TABLE summary_ref(id INTEGER REFERENCES summary_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER summary_fail AFTER INSERT ON local_chain_summary_versions BEGIN INSERT INTO summary_ref VALUES(1); END"))
    testing.expect_value(t,summary_call(f,"notes","summary_commit",summary_revision(f)).code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    after,_:=query(f.store.db,"SELECT * FROM local_chain_context")
    testing.expect_value(t,encode(after),encode(ctx))
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_chain_summary_versions")
    testing.expect_value(t,rows[0][0],"0")
}

@(test)
summary_v20_upgrade_collision_commit_rollback_preserves_live_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    before,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_020)
    prefix=prefix[:strings.index(prefix,"CREATE TABLE local_task_priority_versions")]
    testing.expect(t,exec(db,V23_TEST_DROP))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS local_metadata_retirements; DROP TABLE IF EXISTS local_brief_inputs; DROP TABLE IF EXISTS local_coordinator_revocations; DROP TABLE IF EXISTS local_config_revocations; DROP TABLE IF EXISTS local_chain_directory_versions; DROP TABLE IF EXISTS local_chain_member_versions; DROP TABLE IF EXISTS local_member_chains; DROP TABLE local_chain_defaults_versions; DROP TABLE local_chain_summary_versions"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=20; CREATE VIEW local_chain_summary_versions AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"20","20"}}))
    testing.expect(t,exec(db,"DROP VIEW local_chain_summary_versions; CREATE TABLE summary_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE summary_upgrade_ref(id INTEGER REFERENCES summary_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER summary_upgrade_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=21 BEGIN INSERT INTO summary_upgrade_ref VALUES(1); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_chain_summary_versions') FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"20","20","0"}}))
    testing.expect(t,exec(db,"DROP TRIGGER summary_upgrade_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,summary_call(f,"new curated notes","live_summary",summary_revision(f)).code,"ok")
    after,_=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","summary_present",`{"requirements_revision":"1"}`,cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
}

defaults_call :: proc(f:^Fixture,body,op,revision:string) -> Result {
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
    return invoke(f,command(f,"chain.defaults.set",op,"",p,revision),p)
}
@(test)
defaults_signed_cas_exact_history_restart_rollback_and_separate_installation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    leases,_:=query(f.store.db,"SELECT lease_id,capability_json,retired_seq FROM local_leases")
    roles,_:=query(f.store.db,"SELECT * FROM local_role_configs")
    original:=`{ "review_roles": {"reviewer":"Precise 界 description"}, "proposal":{"state":"pending","priority":7} }`
    old:=summary_revision(f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,original)}))
    c:=command(f,"chain.defaults.set","defaults_original","",p,old)
    got:=invoke(f,c,p)
    if !testing.expect_value(t,got.code,"ok") do return
    testing.expect(t,invoke(f,c,p).replay)
    testing.expect_value(t,defaults_call(f,"{}","defaults_stale",old).code,"stale_revision")
    row,_:=contracts.owner_content_document(context_call(f,"chain.read","defaults_chain","").body)
    obj,_:=row.(json.Object)
    testing.expect_value(t,field(obj,"defaults_json"),original)
    state:=native_metadata_test_state(f)
    for invalid,i in ([4]string{"[]","true","null",`{"duplicate":1,"duplicate":2}`}) {
        testing.expect_value(t,defaults_call(f,invalid,fmt.tprintf("bad_defaults%d",i),summary_revision(f)).code,"invalid_content")
        testing.expect_value(t,native_metadata_test_state(f),state)
    }
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER defaults_fail BEFORE INSERT ON local_events WHEN NEW.kind='chain.defaults.set' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,defaults_call(f,"{}","defaults_statement",summary_revision(f)).code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),state)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER defaults_fail; CREATE TABLE defaults_parent(id INTEGER PRIMARY KEY); CREATE TABLE defaults_ref(id INTEGER REFERENCES defaults_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER defaults_fail AFTER INSERT ON local_chain_defaults_versions BEGIN INSERT INTO defaults_ref VALUES(1); END"))
    testing.expect_value(t,defaults_call(f,"{}","defaults_commit",summary_revision(f)).code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),state)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER defaults_fail"))
    testing.expect_value(t,defaults_call(f,"{}","defaults_clear",summary_revision(f)).code,"ok")
    rows,_:=query(f.store.db,"SELECT defaults_json FROM local_chain_defaults_versions ORDER BY accepted_seq")
    testing.expect_value(t,encode(rows),encode([2][1]string{{original},{"{}"}}))
    testing.expect(t,!exec(f.store.db,"UPDATE local_chain_defaults_versions SET defaults_json='{}'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_chain_defaults_versions"))
    after,_:=query(f.store.db,"SELECT lease_id,capability_json,retired_seq FROM local_leases")
    testing.expect_value(t,encode(after),encode(leases))
    installed,_:=query(f.store.db,"SELECT * FROM local_role_configs")
    testing.expect_value(t,encode(installed),encode(roles))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    row,_=contracts.owner_content_document(context_call(f,"chain.read","defaults_restart","").body)
    obj,_=row.(json.Object)
    testing.expect_value(t,field(obj,"defaults_json"),"{}")
    testing.expect(t,invoke(f,c,p).replay)
}

@(test)
context_v1_cached_projection_is_rebuilt_at_unchanged_source_checkpoint :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,context_call(f,"chain.read","context_v2_seed","").code,"ok")
    // Simulate a V20 persisted projection at exactly the current commit_seq.
    testing.expect(t,exec(f.store.db,"UPDATE local_chain_context SET algorithm=1,body='OLD PROJECTION',source_digest='old_digest'"))
    before,_:=query(f.store.db,"SELECT source_seq,version FROM local_chain_context")
    got:=context_call(f,"chain.read","context_v2_refresh","")
    testing.expect(t,got.code=="ok" && !strings.contains(got.body,"OLD PROJECTION"))
    after,_:=query(f.store.db,"SELECT source_seq,version,algorithm,source_digest FROM local_chain_context")
    testing.expect(t,after[0][0]==before[0][0] && number(after[0][1])==number(before[0][1])+1 && after[0][2]=="2" && after[0][3]!="old_digest")
}
