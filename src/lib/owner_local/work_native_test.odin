#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"

@(test)
native_work_graph_records_roundtrip_exact_fields_generations_owners_and_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    value,_:=contracts.owner_content_document(#load("../../contracts/fixtures/owner-native-work.json",string));bundles,_:=value.(json.Object)
    for kind,raw in bundles {
        bundle,_:=raw.(json.Object)
        testing.expect_value(t,native_metadata_test_call(f,encode(bundle),kind,summary_revision(f)).code,"ok")
        p:=encode(doc(map[string]string{"source_revision"="source_7","kind"=kind,"cursor"="","limit"="1"}))
        got:=invoke(f,command(f,"native.metadata.read","native_work_read","",p,"0"),p)
        if !testing.expect_value(t,got.code,"ok") do return
        v,_:=contracts.owner_content_document(got.body);o,_:=v.(json.Object)
        a,_:=o["items"].(json.Array);testing.expect_value(t,len(a),1)
        row,_:=a[0].(json.Object);originals,_:=bundle["records"].(json.Array);expected,_:=originals[0].(json.Object)
        testing.expect_value(t,len(row),len(expected))
        for key,val in expected {
            if ref,obj:=val.(json.Object);obj {
                actual,_:=row[key].(json.Object)
                testing.expect_value(t,field(actual,"kind"),field(ref,"kind"));testing.expect_value(t,field(actual,"id"),field(ref,"id"))
            } else {testing.expect_value(t,encode(row[key]),encode(val))}
        }
        testing.expect(t,metadata_replay(f,kind).replay)
    }
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_work_records),(SELECT count(*) FROM local_work_dependencies),(SELECT count(*) FROM local_work_inputs),(SELECT count(*) FROM local_workflow_runs)")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"7","0","0","0"}}))
    testing.expect(t,!exec(f.store.db,"DELETE FROM native_work_records"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT json_extract(record_json,'$.decision_id') FROM native_work_records WHERE kind='work_scope'")
    testing.expect_value(t,rows[0][0],"9007199254740993")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}

@(test)
native_work_source_import_rollback_and_owner_conflicts_preserve_graph_provenance :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    value,_:=contracts.owner_content_document(#load("../../contracts/fixtures/owner-native-work.json",string));bundles,_:=value.(json.Object)
    bundle,_:=bundles["work_scope"].(json.Object)
    before:=work_state(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER native_work_fail BEFORE INSERT ON local_events WHEN NEW.kind='native.metadata.import' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"source_statement",summary_revision(f)).code,"storage_error")
    testing.expect_value(t,work_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER native_work_fail; CREATE TABLE native_work_parent(id INTEGER PRIMARY KEY); CREATE TABLE native_work_ref(id INTEGER REFERENCES native_work_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER native_work_fail AFTER INSERT ON native_work_records BEGIN INSERT INTO native_work_ref VALUES(1); END"))
    before=work_state(f)
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"source_commit",summary_revision(f)).code,"storage_error")
    testing.expect_value(t,work_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER native_work_fail"))
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"source_accept",summary_revision(f)).code,"ok")
    bundle["owner_user_id"]=json.String("other_original")
    records,_:=bundle["records"].(json.Array);record,_:=records[0].(json.Object);record["owner_user_id"]=json.String("other_original")
    bundle["source_revision"]=json.String("source_8")
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"owner_conflict",summary_revision(f)).code,"operation_conflict")
}

@(test)
native_work_preserves_bounded_long_manifest_and_spec_documents :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    all,_:=contracts.owner_content_document(string(#load("../../contracts/fixtures/owner-native-work.json")))
    bundles,_:=all.(json.Object);bundle,_:=bundles["work_run"].(json.Object)
    records,_:=bundle["records"].(json.Array);row,_:=records[0].(json.Object)
    original:=encode(doc(map[string]string{"long_source"=strings.repeat("x",5000,context.temp_allocator)}))
    row["spec_json"]=json.String(original)
    testing.expect_value(t,native_metadata_test_call(f,encode(bundle),"long_work_spec",summary_revision(f)).code,"ok")
    p:=encode(doc(map[string]string{"source_revision"=field(bundle,"source_revision"),"kind"="work_run","cursor"="","limit"="1"}))
    got:=invoke(f,command(f,"native.metadata.read","long_work_read","",p,"0"),p)
    if !testing.expect_value(t,got.code,"ok") do return
    v,valid:=contracts.owner_content_document(got.body);page,_:=v.(json.Object);items,_:=page["items"].(json.Array);item,_:=items[0].(json.Object)
    testing.expect(t,valid)
    testing.expect_value(t,field(item,"spec_json"),original)
}
