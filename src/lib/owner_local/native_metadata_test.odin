#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:testing"
import "core:fmt"
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
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_fact_snapshots),(SELECT count(*) FROM native_fact_chain),(SELECT count(*) FROM native_fact_task),(SELECT count(*) FROM native_fact_comment),(SELECT count(*) FROM native_fact_summary),(SELECT count(*) FROM native_metadata_origins),(SELECT count(*) FROM native_metadata_snapshots),(SELECT count(*) FROM native_metadata_members),(SELECT count(*) FROM native_metadata_directories),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_events),(SELECT revision FROM task_chains),(SELECT revision FROM tasks),(SELECT count(*) FROM local_leases),(SELECT count(*) FROM runtime_intents),(SELECT commit_seq FROM runtime_database)")
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
    f.creator.revoked=true // the device itself is revoked (account-level trust; no per-chain grant)
    testing.expect_value(t,native_metadata_test_read(f,"member").code,"invalid_scope")
}


NATIVE_FACT_FIXTURES :: [4]string{
    string(#load("../../contracts/fixtures/owner-native-metadata-chain.json")),
    string(#load("../../contracts/fixtures/owner-native-metadata-task.json")),
    string(#load("../../contracts/fixtures/owner-native-metadata-comment.json")),
    string(#load("../../contracts/fixtures/owner-native-metadata-summary.json")),
}
@(test)
native_facts_roundtrip_exact_scalars_history_restart_and_no_live_state :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    revision:i64=2
    for raw in NATIVE_FACT_FIXTURES {
        bundle,ok:=contracts.owner_metadata_import_parse(raw)
        if !testing.expect(t,ok) do return
        result:=native_metadata_test_call(f,raw,fmt.tprintf("native_fact_%s",bundle.kind),fmt.tprintf("%d",revision))
        if !testing.expect_value(t,result.code,"ok") do return
        revision+=1
        read:=native_metadata_test_read(f,bundle.kind)
        if !testing.expect_value(t,read.code,"ok") do return
        value,_:=contracts.owner_content_document(read.body);root,_:=value.(json.Object)
        items,_:=root["items"].(json.Array)
        if !testing.expect_value(t,len(items),1) do return
        row,_:=items[0].(json.Object)
        testing.expect_value(t,len(row),len(bundle.records[0]))
        for key,original in bundle.records[0] { testing.expect_value(t,encode(row[key]),encode(original)) }
        // A later immutable source snapshot preserves original facts.
        value,_=contracts.owner_content_document(raw);root,_=value.(json.Object)
        root["source_revision"]=json.String("native_revision_8")
        records,_:=root["records"].(json.Array);later,_:=records[0].(json.Object)
        name:="body"
        if bundle.kind=="chain" || bundle.kind=="task" do name="title"
        later[name]=json.String("later native fact")
        root["records"]=json.Array{later}
        testing.expect_value(t,native_metadata_test_call(f,encode(root),fmt.tprintf("%s_later",bundle.kind),fmt.tprintf("%d",revision)).code,"ok")
        revision+=1
        old_value,_:=contracts.owner_content_document(native_metadata_test_read(f,bundle.kind).body)
        old_root,_:=old_value.(json.Object);old_items,_:=old_root["items"].(json.Array);old_row,_:=old_items[0].(json.Object)
        for key,original in bundle.records[0] { testing.expect_value(t,encode(old_row[key]),encode(original)) }
        testing.expect_value(t,native_metadata_test_read(f,bundle.kind,"native_revision_8").code,"ok")
        testing.expect(t,!exec(f.store.db,fmt.tprintf("UPDATE native_fact_%s SET owner_user_id='forged'",bundle.kind)))
    }
    rows,_:=query(f.store.db,"SELECT title,revision FROM tasks")
    testing.expect_value(t,rows[0][1],"1")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_fleet),(SELECT count(*) FROM local_controls),(SELECT count(*) FROM local_leases)")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"0","0","0"}}))
    close(&f.store);if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    for raw in NATIVE_FACT_FIXTURES {
        bundle,_:=contracts.owner_metadata_import_parse(raw)
        testing.expect_value(t,native_metadata_test_read(f,bundle.kind).code,"ok")
        testing.expect_value(t,native_metadata_test_read(f,bundle.kind,"native_revision_8").code,"ok")
    }
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
@(test)
native_facts_import_statement_commit_rollback_replay_and_scope :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for raw in NATIVE_FACT_FIXTURES {
        f:=fixture(t);seed(t,f)
        bundle,_:=contracts.owner_metadata_import_parse(raw)
        before:=native_metadata_test_state(f)
        testing.expect(t,exec(f.store.db,"CREATE TRIGGER fact_fail BEFORE INSERT ON local_events WHEN NEW.kind='native.metadata.import' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
        testing.expect_value(t,native_metadata_test_call(f,raw,"statement","2").code,"storage_error")
        testing.expect_value(t,native_metadata_test_state(f),before)
        testing.expect(t,exec(f.store.db,"DROP TRIGGER fact_fail"))
        testing.expect(t,exec(f.store.db,fmt.tprintf("CREATE TABLE fact_parent(id INTEGER PRIMARY KEY); CREATE TABLE fact_ref(id INTEGER REFERENCES fact_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fact_fail AFTER INSERT ON native_fact_%s BEGIN INSERT INTO fact_ref VALUES(1); END",bundle.kind)))
        testing.expect_value(t,native_metadata_test_call(f,raw,"commit","2").code,"storage_error")
        testing.expect_value(t,native_metadata_test_state(f),before)
        testing.expect(t,exec(f.store.db,"DROP TRIGGER fact_fail"))
        p:=encode(doc(map[string]string{"body_cipher"=cipher(f,raw)}))
        c:=command(f,"native.metadata.import","accepted","",p,"2")
        accepted:=invoke(f,c,p)
        if !testing.expect_value(t,accepted.code,"ok") { destroy(f);continue }
        before=native_metadata_test_state(f)
        replay:=invoke(f,c,p,3000)
        testing.expect(t,replay.code=="ok" && replay.replay && replay.body==accepted.body)
        testing.expect_value(t,native_metadata_test_state(f),before)
        testing.expect_value(t,native_metadata_test_call(f,raw,"stale","2").code,"stale_revision")
        value,_:=contracts.owner_content_document(raw);root,_:=value.(json.Object)
        records,_:=root["records"].(json.Array);row,_:=records[0].(json.Object)
        row["owner_user_id"]=json.String("other_owner")
        root["owner_user_id"]=json.String("other_owner");root["records"]=json.Array{row}
        root["source_revision"]=json.String("new_source")
        testing.expect_value(t,native_metadata_test_call(f,encode(root),"owner","3").code,"operation_conflict")
        testing.expect_value(t,native_metadata_test_state(f),before)
        f.creator.revoked=true // the device itself is revoked (account-level trust; no per-chain grant)
        testing.expect_value(t,native_metadata_test_read(f,bundle.kind).code,"invalid_scope")
        destroy(f)
    }
}
