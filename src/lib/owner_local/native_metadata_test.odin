#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"

NATIVE_MEMBERS :: #load("../../contracts/fixtures/owner-native-metadata-members.json")
NATIVE_DIRECTORIES :: #load("../../contracts/fixtures/owner-native-metadata-directories.json")
native_metadata_test_call :: proc(f:^Fixture,raw,op,revision:string) -> Result {
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,raw)}))
    return invoke(f,command(f,"native.metadata.import",op,"",p,revision),p)
}
native_metadata_test_read :: proc(f:^Fixture,kind:string,source:="native_revision_7",cursor:="",limit:="20") -> Result {
    p:=encode(doc(map[string]string{"source_revision"=source,"kind"=kind,"cursor"=cursor,"limit"=limit}))
    return invoke(f,command(f,"native.metadata.read","metadata_read","",p,"0"),p)
}
native_metadata_test_state :: proc(f:^Fixture) -> string {
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_metadata_origins),(SELECT count(*) FROM native_metadata_snapshots),(SELECT count(*) FROM native_metadata_members),(SELECT count(*) FROM native_metadata_directories),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_events),(SELECT revision FROM task_chains),(SELECT revision FROM tasks),(SELECT count(*) FROM local_leases),(SELECT count(*) FROM runtime_intents),(SELECT commit_seq FROM runtime_database)")
    return encode(rows)
}
@(test)
native_metadata_preserves_fields_history_and_exact_replay_without_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_MEMBERS),"members","2").code,"ok")
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,string(NATIVE_DIRECTORIES))}))
    c:=command(f,"native.metadata.import","directories","",p,"3")
    accepted:=invoke(f,c,p)
    if !testing.expect_value(t,accepted.code,"ok") do return
    before:=native_metadata_test_state(f)
    again:=invoke(f,c,p,3000)
    testing.expect(t,again.code=="ok" && again.replay && again.body==accepted.body)
    testing.expect_value(t,native_metadata_test_state(f),before)
    for kind,raw in (map[string]string{"member"=string(NATIVE_MEMBERS),"directory"=string(NATIVE_DIRECTORIES)}) {
        result:=native_metadata_test_read(f,kind)
        if !testing.expect_value(t,result.code,"ok") do return
        value,valid:=contracts.owner_content_document(result.body);root,obj:=value.(json.Object)
        items,_:=root["items"].(json.Array)
        expected,_:=contracts.owner_metadata_import_parse(raw)
        testing.expect(t,valid && obj && len(items)==len(expected.records))
        for item in items {
            row,_:=item.(json.Object)
            matched:=false
            for original in expected.records {
                equal:=true
                for key,v in original { if field(row,key)!=string(v.(json.String)) do equal=false }
                if equal do matched=true
            }
            testing.expect(t,matched)
        }
    }
    root_value,_:=contracts.owner_content_document(string(NATIVE_MEMBERS));bundle,_:=root_value.(json.Object)
    bundle["source_revision"]=json.String("native_revision_8")
    items,_:=bundle["records"].(json.Array);member,_:=items[0].(json.Object)
    member["role"]=json.String("reviewer")
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"later","4").code,"ok")
    rows,_:=query(f.store.db,"SELECT role FROM native_metadata_members WHERE agent_instance_id='native_instance' ORDER BY source_revision")
    testing.expect_value(t,encode(rows),encode([2][1]string{{"coordinator"},{"reviewer"}}))
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_fleet),(SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_controls),(SELECT revision FROM tasks)")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"0","0","0","1"}}))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,native_metadata_test_read(f,"member").code,"ok")
    testing.expect_value(t,native_metadata_test_read(f,"member","native_revision_8").code,"ok")
    testing.expect(t,!exec(f.store.db,"UPDATE native_metadata_members SET role='worker'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM native_metadata_snapshots"))
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
@(test)
native_metadata_rejects_scope_owner_conflicts_and_rolls_back_statement_and_commit :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=string(NATIVE_DIRECTORIES)
    before:=native_metadata_test_state(f)
    value,_:=contracts.owner_content_document(raw);bundle,_:=value.(json.Object)
    bundle["chain_id"]=json.String("other")
    items,_:=bundle["records"].(json.Array);row,_:=items[0].(json.Object);row["chain_id"]=json.String("other")
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"scope","2").code,"invalid_scope")
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER metadata_fail BEFORE INSERT ON local_events WHEN NEW.kind='native.metadata.import' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,native_metadata_test_call(f,raw,"statement","2").code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER metadata_fail"))
    testing.expect(t,exec(f.store.db,"CREATE TABLE metadata_parent(id INTEGER PRIMARY KEY); CREATE TABLE metadata_ref(id INTEGER REFERENCES metadata_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER metadata_fail AFTER INSERT ON native_metadata_directories BEGIN INSERT INTO metadata_ref VALUES(1); END"))
    testing.expect_value(t,native_metadata_test_call(f,raw,"commit","2").code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER metadata_fail"))
    testing.expect_value(t,native_metadata_test_call(f,raw,"accepted","2").code,"ok")
    before=native_metadata_test_state(f)
    testing.expect_value(t,native_metadata_test_call(f,raw,"stale","2").code,"stale_revision")
    bundle["chain_id"]=json.String("chain");row["chain_id"]=json.String("chain");row["path"]=json.String("/changed")
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"conflict","3").code,"operation_conflict")
    bundle["source_revision"]=json.String("native_revision_8")
    bundle["owner_user_id"]=json.String("forged");row["owner_user_id"]=json.String("forged")
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"owner","3").code,"operation_conflict")
    testing.expect_value(t,native_metadata_test_state(f),before)
}
@(test)
native_metadata_pages_bind_source_kind_and_current_read_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_MEMBERS),"members","2").code,"ok")
    first:=native_metadata_test_read(f,"member","native_revision_7","","1")
    if !testing.expect_value(t,first.code,"ok") do return
    value,_:=contracts.owner_content_document(first.body);root,_:=value.(json.Object)
    cursor:=field(root,"next_cursor")
    testing.expect(t,cursor!="")
    second:=native_metadata_test_read(f,"member","native_revision_7",cursor,"1")
    testing.expect_value(t,second.code,"ok")
    next_value,_:=contracts.owner_content_document(second.body);next,_:=next_value.(json.Object)
    testing.expect_value(t,field(next,"next_cursor"),"")
    testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_DIRECTORIES),"directories","3").code,"ok")
    testing.expect_value(t,native_metadata_test_read(f,"directory","native_revision_7",cursor).code,"stale_cursor")
    testing.expect_value(t,native_metadata_test_read(f,"member","absent").code,"invalid_scope")
    testing.expect(t,exec(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1"))
    testing.expect_value(t,native_metadata_test_read(f,"member").code,"invalid_scope")
}

@(test)
native_metadata_v17_migration_collision_commit_rollback_and_live_capability :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    keep:="SELECT (SELECT json_group_array(json_array(lease_id,capability_json,retired_seq)) FROM local_leases),(SELECT json_group_array(json_array(seq,evidence_json)) FROM local_events),(SELECT json_group_array(json_array(principal_id,operation_id,result_json)) FROM command_receipts),(SELECT commit_seq FROM runtime_database)"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_017);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_fleet_policy_versions")]
    testing.expect(t,exec(db,"DROP TABLE native_metadata_members; DROP TABLE native_metadata_directories; DROP TABLE native_metadata_snapshots; DROP TABLE native_metadata_origins"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=17; CREATE VIEW native_metadata_origins AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="17" && rows[0][1]=="17")
    after,_:=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP VIEW native_metadata_origins; CREATE TABLE metadata_migrate_parent(id INTEGER PRIMARY KEY); CREATE TABLE metadata_migrate_ref(id INTEGER REFERENCES metadata_migrate_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER metadata_migrate_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=18 BEGIN INSERT INTO metadata_migrate_ref VALUES(1); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='native_metadata_origins') FROM runtime_database")
    testing.expect(t,rows[0][0]=="17" && rows[0][1]=="17" && rows[0][2]=="0")
    after,_=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER metadata_migrate_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    after,_=query(f.store.db,keep);testing.expect_value(t,encode(after),encode(before))
    chain,_:=query(f.store.db,"SELECT revision FROM task_chains")
    testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_MEMBERS),"live_snapshot",chain[0][0]).code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","metadata_keeps_child",`{"requirements_revision":"1"}`,cap).code,"ok")
}
