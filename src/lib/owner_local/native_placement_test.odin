#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"

NATIVE_PLACEMENT_PREGRANT :: #load("../../contracts/fixtures/owner-native-placement-pregrant.json")
NATIVE_PLACEMENT_LATER :: #load("../../contracts/fixtures/owner-native-placement-later.json")

native_placement_verify :: proc(t:^testing.T,f:^Fixture,raw:string) {
    bundle,valid:=contracts.owner_parse(raw,"native_history_bundle")
    if !testing.expect(t,valid) do return
    source:=field(bundle,"source_revision")
    value,_:=contracts.owner_request_document(field(bundle,"facets"));items,_:=value.(json.Array)
    for item in items {
        text,_:=item.(json.String);original:=string(text)
        facet,ok:=contracts.owner_parse(original,"native_history_facet")
        if !testing.expect(t,ok) do return
        key:=encode([3]string{field(facet,"attempt_no"),"placement",field(facet,"v")})
        fetched:=native_fetch_call(f,"facet",key,"0",source)
        if !testing.expect_value(t,fetched.code,"ok") do return
        value,_:=contracts.owner_request_document(fetched.body);page,_:=value.(json.Object)
        testing.expect_value(t,field(page,"record"),original)
        testing.expect_value(t,field(facet,"writer"),"hub")
        rows,_:=query(f.store.db,"SELECT parent_kind,parent_key FROM native_history_records WHERE source_revision=? AND record_kind='facet' AND record_key=?",source,key)
        if !testing.expect_value(t,len(rows),1) do return
        if field(facet,"attempt_no")=="0" {
            testing.expect(t,rows[0][0]=="" && rows[0][1]=="")
        } else { testing.expect(t,rows[0][0]=="attempt" && rows[0][1]==field(facet,"attempt_no")) }
    }
}

@(test)
native_placement_history_preserves_zero_and_later_versions_without_work_grants :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    before:=string(NATIVE_PLACEMENT_PREGRANT);after:=string(NATIVE_PLACEMENT_LATER)
    if !testing.expect_value(t,native_import_call(f,before,"native_pregrant","1").code,"ok") do return
    native_placement_verify(t,f,before)
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_history_records WHERE record_kind='attempt'),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM local_submissions)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="0")
    state,ok:=attempt_view(&f.store,"chain","task")
    testing.expect(t,ok && state.attempt_no==0 && state.counting_attempts==0 && state.grants==0)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,after)}))
    c:=command(f,"native.history.import","native_later","task",p,"2")
    accepted:=invoke(f,c,p)
    if !testing.expect_value(t,accepted.code,"ok") do return
    retry:=invoke(f,c,p,4000000)
    testing.expect(t,retry.code=="ok" && retry.replay && retry.body==accepted.body)
    native_placement_verify(t,f,after)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    native_placement_verify(t,f,before);native_placement_verify(t,f,after)
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM native_history_records WHERE record_kind='attempt' AND attempt_no='0'),(SELECT count(*) FROM native_history_records WHERE record_kind='attempt' AND attempt_no='1'),(SELECT count(*) FROM local_work_attempts)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="1" && rows[0][2]=="0")
    state,ok=attempt_view(&f.store,"chain","task")
    testing.expect(t,ok && state.attempt_no==0 && state.counting_attempts==0 && state.grants==0)
}

@(test)
native_placement_history_rejection_and_transaction_rollback_preserve_pregrant_boundary :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=string(NATIVE_PLACEMENT_PREGRANT)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER placement_event_fail BEFORE INSERT ON local_events WHEN NEW.kind='native.history.import' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,native_import_call(f,raw,"placement_rollback","1").code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_history_records),(SELECT count(*) FROM command_receipts),(SELECT revision FROM tasks)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="2" && rows[0][2]=="1")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER placement_event_fail"))
    testing.expect(t,exec(f.store.db,`CREATE TABLE placement_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE placement_ref(id INTEGER REFERENCES placement_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER placement_commit_fail AFTER INSERT ON native_history_records BEGIN INSERT INTO placement_ref VALUES(1); END;`))
    testing.expect_value(t,native_import_call(f,raw,"placement_commit_rollback","1").code,"storage_error")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM native_history_records),(SELECT count(*) FROM command_receipts),(SELECT revision FROM tasks)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="2" && rows[0][2]=="1")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER placement_commit_fail"))
    bundle,_:=contracts.owner_parse(raw,"native_history_bundle")
    value,_:=contracts.owner_request_document(field(bundle,"facets"));items,_:=value.(json.Array)
    text,_:=items[0].(json.String);facet,_:=contracts.owner_parse(string(text),"native_history_facet")
    facet["kind"]=json.String("handoff")
    bundle["facets"]=json.String(encode([1]string{encode(facet)}))
    testing.expect_value(t,native_import_call(f,encode(bundle),"not_placement_zero","1").code,"invalid_content")
    facet["kind"]=json.String("placement");facet["attempt_no"]=json.String("1")
    bundle["facets"]=json.String(encode([1]string{encode(facet)}))
    testing.expect_value(t,native_import_call(f,encode(bundle),"missing_positive_attempt","1").code,"invalid_content")
    testing.expect_value(t,native_import_call(f,raw,"valid_pregrant","1").code,"ok")
    native_placement_verify(t,f,raw)
    testing.expect(t,!exec(f.store.db,`INSERT INTO native_history_records SELECT chain_id,task_id,source_revision,record_kind,'missing_parent',owner_user_id,completeness,'1',facet_kind,'99',writer,record_json,accepted_seq,NULL,NULL FROM native_history_records WHERE record_kind='facet' LIMIT 1`))
    testing.expect(t,!exec(f.store.db,`INSERT INTO native_history_records SELECT chain_id,task_id,source_revision,record_kind,'invalid_zero',owner_user_id,completeness,'0','handoff','99','agent',record_json,accepted_seq,NULL,NULL FROM native_history_records WHERE record_kind='facet' LIMIT 1`))
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
