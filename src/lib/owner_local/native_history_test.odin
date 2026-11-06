#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

NATIVE_HISTORY_FIXTURE :: #load("../../contracts/fixtures/owner-native-history.json")
native_history_fixture :: proc()->string { return string(NATIVE_HISTORY_FIXTURE) }
native_import_call :: proc(f:^Fixture,body,op,revision:string)->Result {
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
    return invoke(f,command(f,"native.history.import",op,"task",p,revision),p)
}
native_fetch_call :: proc(f:^Fixture,kind,key:string,offset:="0",source:="snapshot_7")->Result {
    p:=encode(doc(map[string]string{"source_revision"=source,"kind"=kind,"key"=key,"offset"=offset}))
    return invoke(f,command(f,"native.history.fetch","native_read","task",p,"0"),p)
}

@(test)
native_history_rich_import_exact_facets_replay_restart_and_auth :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=native_history_fixture()
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,raw)}))
    c:=command(f,"native.history.import","original_import","task",p,"1")
    result:=invoke(f,c,p)
    if !testing.expect_value(t,result.code,"ok") do return
    replay:=invoke(f,c,p,4000000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==result.body)
    rows,_:=query(f.store.db,"SELECT count(*),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM local_submissions) FROM native_history_records")
    testing.expect(t,rows[0][0]=="26" && rows[0][1]=="0" && rows[0][2]=="0")
    bundle,_:=contracts.owner_parse(raw,"native_history_bundle")
    for kind in ([3]string{"attempt","event","facet"}) {
        value,_:=contracts.owner_request_document(field(bundle,fmt.tprintf("%ss",kind)));items,_:=value.(json.Array)
        for item in items {
            text,_:=item.(json.String);original:=string(text)
            record,_:=contracts.owner_parse(original,fmt.tprintf("native_history_%s",kind))
            key:=field(record,"attempt_no")
            if kind=="event" do key=field(record,"event_id")
            if kind=="facet" do key=encode([3]string{field(record,"attempt_no"),field(record,"kind"),field(record,"v")})
            got:=native_fetch_call(f,kind,key)
            if !testing.expect_value(t,got.code,"ok") do return
            value,_:=contracts.owner_request_document(got.body);body,_:=value.(json.Object)
            testing.expect_value(t,field(body,"record"),original)
        }
    }
    before,_:=query(f.store.db,"SELECT json_group_array(record_json) FROM native_history_records ORDER BY record_kind,record_key")
    testing.expect(t,!exec(f.store.db,"UPDATE native_history_records SET owner_user_id='forged'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM native_history_records"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_:=query(f.store.db,"SELECT json_group_array(record_json) FROM native_history_records ORDER BY record_kind,record_key")
    testing.expect_value(t,encode(after),encode(before))
    _,_=query(f.store.db,"UPDATE local_grants SET can_mutate=0,revision=revision+1")
    testing.expect_value(t,native_fetch_call(f,"attempt","3").code,"ok")
    testing.expect_value(t,native_import_call(f,raw,"read_only_import","2").code,"invalid_scope")
    _,_=query(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1")
    testing.expect_value(t,native_fetch_call(f,"attempt","3").code,"invalid_scope")
    testing.expect_value(t,invoke(f,c,p).code,"invalid_scope")
}

@(test)
native_archival_unicode_content_retains_bytes_and_strict_metadata_grammar :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    b,_:=contracts.owner_parse(native_history_fixture(),"native_history_bundle")
    value,_:=contracts.owner_request_document(field(b,"facets"));items,_:=value.(json.Array)
    text,_:=items[0].(json.String);facet,_:=native_content_parse(string(text),"native_history_facet")
    body:=`{ "text":"世界😀", "number":9007199254740993 }`
    facet["body_json"]=json.String(body)
    record:=encode(facet);b["facets"]=json.String(encode([1]string{record}))
    testing.expect_value(t,native_import_call(f,encode(b),"unicode_original","1").code,"ok")
    key:=encode([3]string{"3",field(facet,"kind"),field(facet,"v")})
    got:=native_fetch_call(f,"facet",key)
    if !testing.expect_value(t,got.code,"ok") do return
    value,_=contracts.owner_request_document(got.body);page,_:=value.(json.Object)
    testing.expect_value(t,field(page,"record"),record)
    decoded,valid:=native_content_parse(field(page,"record"),"native_history_facet")
    testing.expect(t,valid);testing.expect_value(t,field(decoded,"body_json"),body)
    for raw in ([5]string{`{"a":"x","a":"y"}`,`{"a":"x","\u0061":"y"}`,`{"a":"\ud800"}`,`{"a":"\udc00"}`,`{"a":"x",}`}) {
        testing.expect(t,!native_content_grammar(raw,true))
    }
    testing.expect(t,!native_content_grammar(`["x",]`,false))
}

@(test)
native_history_import_rollback_conflicts_and_missing_attempt_are_explicit :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=native_history_fixture()
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER import_event_fail BEFORE INSERT ON local_events WHEN NEW.kind='native.history.import' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,native_import_call(f,raw,"rollback","1").code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_history_records),(SELECT count(*) FROM command_receipts),(SELECT revision FROM tasks)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="2" && rows[0][2]=="1")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER import_event_fail"))
    b,_:=contracts.owner_parse(raw,"native_history_bundle")
    b["attempts"]=json.String("[]")
    testing.expect_value(t,native_import_call(f,encode(b),"orphan_facet","1").code,"invalid_content")
    rows,_=query(f.store.db,"SELECT count(*) FROM native_history_records");testing.expect_value(t,rows[0][0],"0")
    testing.expect_value(t,native_import_call(f,raw,"valid_import","1").code,"ok")
    changed,_:=strings.replace_all(raw,"original_instance","forged_instance",context.temp_allocator)
    testing.expect_value(t,native_import_call(f,changed,"conflicting_snapshot","2").code,"operation_conflict")
    testing.expect_value(t,native_fetch_call(f,"attempt","4").code,"invalid_scope")
    rows,_=query(f.store.db,"SELECT count(*) FROM native_history_records");testing.expect_value(t,rows[0][0],"26")
    view,ok:=attempt_view(&f.store,"chain","task")
    testing.expect(t,ok && view.attempt_no==0,"native source snapshots never masquerade as local lease grants")
}

@(test)
native_history_typed_reference_writer_and_original_owner_validation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=native_history_fixture()
    testing.expect_value(t,native_import_call(f,raw,"original","1").code,"ok")
    b,_:=contracts.owner_parse(raw,"native_history_bundle")
    values,_:=contracts.owner_request_document(field(b,"facets"));facets,_:=values.(json.Array)
    text,_:=facets[0].(json.String);facet,_:=contracts.owner_parse(string(text),"native_history_facet")
    facet["v"]=json.String("3");facet["writer"]=json.String("bridge")
    b["facets"]=json.String(encode([1]string{encode(facet)}))
    testing.expect_value(t,native_import_call(f,encode(b),"writer_conflict","2").code,"operation_conflict")
    facet["writer"]=json.String("agent")
    facet["references_json"]=json.String(`[{"kind":"artifact","id":"art_original","revision":"7","provenance":"original","state":"resolved"}]`)
    b["facets"]=json.String(encode([1]string{encode(facet)}))
    testing.expect_value(t,native_import_call(f,encode(b),"invented_resolution","2").code,"invalid_content")
    changed,_:=strings.replace_all(raw,"original_user","another_original_owner",context.temp_allocator)
    changed,_=strings.replace_all(changed,"snapshot_7","snapshot_8",context.temp_allocator)
    testing.expect_value(t,native_import_call(f,changed,"immutable_original_owner","2").code,"operation_conflict")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_history_records),(SELECT revision FROM tasks)")
    testing.expect(t,rows[0][0]=="26" && rows[0][1]=="2")
}

@(test)
native_history_pages_chunks_scope_and_partial_snapshots :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    b,_:=contracts.owner_parse(native_history_fixture(),"native_history_bundle")
    b["completeness"]=json.String("incomplete")
    values,_:=contracts.owner_request_document(field(b,"facets"));facets,_:=values.(json.Array)
    first,_:=facets[0].(json.String)
    facet,_:=contracts.owner_parse(string(first),"native_history_facet")
    facet["body_json"]=json.String(fmt.tprintf(`{{"body":"%s"}}`,strings.repeat("x",9000,context.temp_allocator)))
    b["facets"]=json.String(encode([1]string{encode(facet)}))
    testing.expect_value(t,native_import_call(f,encode(b),"large_partial","1").code,"ok")
    p:=encode(doc(map[string]string{"source_revision"="snapshot_7","kind"="attempt","cursor"="","limit"="1"}))
    page:=invoke(f,command(f,"native.history.read","page","task",p,"0"),p)
    if !testing.expect_value(t,page.code,"ok") do return
    v,_:=contracts.owner_request_document(page.body);o,_:=v.(json.Object)
    cursor:=field(o,"next_cursor")
    testing.expect(t,cursor!="")
    p=encode(doc(map[string]string{"source_revision"="snapshot_7","kind"="attempt","cursor"=cursor,"limit"="100"}))
    page=invoke(f,command(f,"native.history.read","page2","task",p,"0"),p)
    v,_=contracts.owner_request_document(page.body);o,_=v.(json.Object);items,_:=o["items"].(json.Array)
    testing.expect_value(t,len(items),2)
    p=encode(doc(map[string]string{"source_revision"="another_snapshot","kind"="attempt","cursor"=cursor,"limit"="100"}))
    testing.expect_value(t,invoke(f,command(f,"native.history.read","bad_cursor","task",p,"0"),p).code,"stale_cursor")
    key:=encode([3]string{"3",field(facet,"kind"),field(facet,"v")})
    all:=strings.builder_make(context.temp_allocator);offset:="0";chunks:=0
    for _ in 0..<8 {
        got:=native_fetch_call(f,"facet",key,offset)
        if !testing.expect_value(t,got.code,"ok") do return
        testing.expect(t,len(got.body)<=MAX_PAGE)
        v,_:=contracts.owner_request_document(got.body);part,_:=v.(json.Object)
        testing.expect_value(t,field(part,"source_completeness"),"incomplete")
        strings.write_string(&all,field(part,"record"));chunks+=1
        offset=field(part,"next_offset")
        if offset=="" do break
    }
    testing.expect(t,chunks>1)
    testing.expect_value(t,strings.to_string(all),encode(facet))
    testing.expect_value(t,native_fetch_call(f,"facet",key,"999999").code,"malformed")
    testing.expect_value(t,native_fetch_call(f,"facet",key,"-1").code,"malformed")
}

@(test)
native_history_inventory_orders_native_attempts_and_facet_versions_numerically :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    b,_:=contracts.owner_parse(native_history_fixture(),"native_history_bundle")
    b["completeness"]=json.String("incomplete");b["events"]=json.String("[]")
    value,_:=contracts.owner_request_document(field(b,"attempts"));items,_:=value.(json.Array)
    attempts:=make([dynamic]string,context.temp_allocator)
    for item,i in items {
        text,_:=item.(json.String);record,_:=contracts.owner_parse(string(text),"native_history_attempt")
        if i==2 do record["attempt_no"]=json.String("10")
        append(&attempts,encode(record))
    }
    b["attempts"]=json.String(encode(attempts))
    value,_=contracts.owner_request_document(field(b,"facets"));items,_=value.(json.Array)
    text,_:=items[0].(json.String);facet,_:=contracts.owner_parse(string(text),"native_history_facet")
    facet["attempt_no"]=json.String("10")
    facet["v"]=json.String("10");last:=encode(facet)
    facet["v"]=json.String("2");first:=encode(facet)
    b["facets"]=json.String(encode([2]string{last,first}))
    testing.expect_value(t,native_import_call(f,encode(b),"numeric_inventory","1").code,"ok")
    for kind in ([2]string{"attempt","facet"}) {
        p:=encode(doc(map[string]string{"source_revision"="snapshot_7","kind"=kind,"cursor"="","limit"="100"}))
        result:=invoke(f,command(f,"native.history.read","numeric_page","task",p,"0"),p)
        if !testing.expect_value(t,result.code,"ok") do return
        value,_:=contracts.owner_request_document(result.body);page,_:=value.(json.Object);rows,_:=page["items"].(json.Array)
        first_row,_:=rows[0].(json.Object);last_row,_:=rows[len(rows)-1].(json.Object)
        if kind=="attempt" {
            testing.expect(t,field(first_row,"key")=="1" && field(last_row,"key")=="10")
            middle,_:=rows[1].(json.Object);testing.expect_value(t,field(middle,"key"),"2")
        } else { testing.expect(t,field(first_row,"v")=="2" && field(last_row,"v")=="10") }
    }
}

@(test)
native_history_survives_task_deletion_with_current_read_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"retained","1").code,"ok")
    before:=native_fetch_call(f,"attempt","3")
    p:=`{"protocol_version":"1"}`
    testing.expect_value(t,invoke(f,command(f,"task.delete","delete_task","task",p,"2"),p).code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after:=native_fetch_call(f,"attempt","3")
    testing.expect_value(t,before.code,"ok")
    testing.expect_value(t,after.code,"ok")
    prior_value,_:=contracts.owner_request_document(before.body);prior,_:=prior_value.(json.Object)
    current_value,_:=contracts.owner_request_document(after.body);current,_:=current_value.(json.Object)
    testing.expect_value(t,field(current,"record"),field(prior,"record"))
    testing.expect_value(t,field(current,"source_completeness"),"full")
    p=encode(doc(map[string]string{"source_revision"="snapshot_7","kind"="facet","cursor"="","limit"="100"}))
    testing.expect_value(t,invoke(f,command(f,"native.history.read","read_deleted","task",p,"0"),p).code,"ok")
    _,_=query(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1")
    testing.expect_value(t,native_fetch_call(f,"attempt","3").code,"invalid_scope")
}

@(test)
native_history_import_of_retired_workflow_execution_cannot_reactivate_it :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"workflow.define","old_definition",workflow_test_definition()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","old_run",`{"run_id":"old_run","workflow_id":"definition","version":"1"}`).code,"ok")
    task:=workflow_task_id("chain","old_run","1","first")
    testing.expect_value(t,advanced_call(f,"workflow.retry","new_execution",`{"run_id":"old_run","execution":"1"}`).code,"ok")
    testing.expect(t,!workflow_task_current(&f.store,"chain",task))
    bundle,_:=contracts.owner_parse(native_history_fixture(),"native_history_bundle")
    for kind in ([3]string{"attempt","event","facet"}) {
        plural:=fmt.tprintf("%ss",kind)
        values,_:=contracts.owner_request_document(field(bundle,plural));items,_:=values.(json.Array)
        replaced:=make([dynamic]string,context.temp_allocator)
        for item in items {
            text,_:=item.(json.String);record,_:=contracts.owner_parse(string(text),fmt.tprintf("native_history_%s",kind))
            record["task_id"]=json.String(task);append(&replaced,encode(record))
        }
        bundle[plural]=json.String(encode(replaced))
    }
    testing.expect_value(t,advanced_call(f,"native.history.import","old_native_history",encode(bundle),task).code,"ok")
    testing.expect(t,!workflow_task_current(&f.store,"chain",task))
    rows,_:=query(f.store.db,"SELECT mode,(SELECT count(*) FROM local_leases WHERE task_id=? AND retired_seq IS NULL),(SELECT count(*) FROM native_history_records WHERE task_id=?) FROM local_controls WHERE task_id=?",task,task,task)
    testing.expect(t,len(rows)==1 && rows[0][0]=="cancelled" && rows[0][1]=="0" && rows[0][2]=="26")
}

@(test)
native_v14_upgrade_collision_deferred_commit_and_live_history_preservation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    keep:="SELECT (SELECT json_group_array(evidence_json) FROM local_events),(SELECT json_group_array(result_json) FROM command_receipts),(SELECT capability_json FROM local_leases WHERE retired_seq IS NULL LIMIT 1)"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_014);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_task_retirements")]
    testing.expect(t,exec(db,V23_TEST_DROP))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS local_metadata_retirements; DROP TABLE IF EXISTS local_brief_inputs; DROP TABLE IF EXISTS local_coordinator_revocations; DROP TABLE IF EXISTS local_config_revocations; DROP TABLE IF EXISTS local_chain_directory_versions; DROP TABLE IF EXISTS local_chain_member_versions; DROP TABLE IF EXISTS local_member_chains; DROP TABLE IF EXISTS local_chain_defaults_versions; DROP TABLE IF EXISTS local_chain_summary_versions; DROP TRIGGER IF EXISTS native_history_origin; DROP TABLE IF EXISTS local_fleet_policy_sources; DROP TABLE IF EXISTS native_fleet_policies; DROP TABLE IF EXISTS native_fleet_snapshots; DROP TABLE IF EXISTS local_task_priority_versions; DROP TABLE IF EXISTS native_fact_chain; DROP TABLE IF EXISTS native_fact_task; DROP TABLE IF EXISTS native_fact_comment; DROP TABLE IF EXISTS native_fact_summary; DROP TABLE IF EXISTS native_fact_snapshots; DROP TABLE IF EXISTS native_metadata_members; DROP TABLE IF EXISTS native_metadata_directories; DROP TABLE IF EXISTS native_metadata_snapshots; DROP TABLE IF EXISTS native_metadata_origins; DROP VIEW IF EXISTS local_fleet_policy_current; DROP TABLE IF EXISTS local_fleet_policy_models; DROP TABLE IF EXISTS local_fleet_policy_roles; DROP TABLE IF EXISTS local_fleet_policy_versions; DROP TABLE IF EXISTS native_budget_overlap; DROP TABLE IF EXISTS budget_control_owners; DROP TABLE IF EXISTS local_dependency_retirements; DROP TABLE IF EXISTS local_budget_evidence; DROP TABLE IF EXISTS native_budget_baselines; DROP TRIGGER deferred_prepared_merge_no_invalidation; DROP TABLE deferred_workflow_dispositions; DROP TABLE deferred_workflow_retirements; DROP TABLE native_history_records"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=14; CREATE VIEW native_history_records AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="14" && rows[0][1]=="14")
    testing.expect(t,exec(db,`DROP VIEW native_history_records;
      CREATE TABLE v15_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE v15_ref(id INTEGER REFERENCES v15_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER v15_commit_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=15 BEGIN INSERT INTO v15_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='native_history_records') FROM runtime_database")
    testing.expect(t,rows[0][0]=="14" && rows[0][1]=="14" && rows[0][2]=="0")
    after,_:=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER v15_commit_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_=query(f.store.db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","after_v15",`{"requirements_revision":"1"}`,cap).code,"ok")
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"after_upgrade","4").code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
