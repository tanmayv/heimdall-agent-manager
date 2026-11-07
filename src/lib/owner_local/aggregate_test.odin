#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

AGGREGATE_FIXTURE :: #load("../../contracts/fixtures/owner-native-aggregate.json",string)
aggregate_root :: proc()->json.Object {v,_:=contracts.owner_content_document(AGGREGATE_FIXTURE);o,_:=v.(json.Object);return o}
aggregate_equal :: proc(a,b:json.Value)->bool {
    #partial switch x in a {
    case json.Object:
        y,ok:=b.(json.Object);if !ok || len(x)!=len(y) do return false
        for k,v in x {other,exists:=y[k];if !exists || !aggregate_equal(v,other) do return false}
        return true
    case json.Array:
        y,ok:=b.(json.Array);if !ok || len(x)!=len(y) do return false
        for v,i in x {if !aggregate_equal(v,y[i]) do return false}
        return true
    case: return encode(a)==encode(b)
    }
}
aggregate_import :: proc(t:^testing.T,f:^Fixture) {
    seed(t,f)
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"Archived original"),"body_cipher"=cipher(f,"Source provenance")}))
    testing.expect_value(t,invoke(f,command(f,"task.create","archive_create","archive",p,summary_revision(f)),p).code,"ok")
    root:=aggregate_root();metadata,_:=root["metadata"].(json.Array)
    for value in metadata {
        entry,_:=value.(json.Object)
        got:=native_metadata_test_call(f,field(entry,"raw"),fmt.tprintf("rich_%s",field(entry,"kind")),summary_revision(f))
        if !testing.expect_value(t,got.code,"ok") do return
    }
    p=encode(doc(map[string]string{"body_cipher"=cipher(f,field(root,"history"))}))
    testing.expect_value(t,invoke(f,command(f,"native.history.import","rich_history","archive",p,"1"),p).code,"ok")
}
aggregate_export_compare :: proc(t:^testing.T,f:^Fixture) {
    root:=aggregate_root();metadata,_:=root["metadata"].(json.Array)
    for value in metadata {
        entry,_:=value.(json.Object);kind:=field(entry,"kind")
        expected,parsed:=contracts.owner_metadata_import_parse(field(entry,"raw"))
        if !testing.expect(t,parsed) do return
        cursor:="";seen:=make(map[string]bool,context.temp_allocator)
        for page in 0..<102 {
            p:=encode(doc(map[string]string{"source_revision"="rich_source_7","kind"=kind,"cursor"=cursor,"limit"="1"}))
            got:=invoke(f,command(f,"native.metadata.read","aggregate_read","",p,"0"),p)
            if !testing.expect_value(t,got.code,"ok") do return
            v,valid:=contracts.owner_content_document(got.body);o,_:=v.(json.Object);items,_:=o["items"].(json.Array)
            testing.expect(t,valid && field(o,"owner_user_id")=="original_user")
            for item in items {
                row,_:=item.(json.Object);matched:=false
                for original in expected.records {if aggregate_equal(row,original) {matched=true;break}}
                testing.expect(t,matched,fmt.tprintf("all canonical fields/types must match original %s source record",kind))
                key:=contracts.owner_metadata_record_key(row,kind)
                if key=="" {key=field(row,"agent_instance_id");if kind=="directory" do key=field(row,"directory_id");if kind=="fleet" do key=field(row,"agent_id")}
                testing.expect(t,!seen[key],"each original tuple appears exactly once");seen[key]=true
            }
            cursor=field(o,"next_cursor")
            if cursor=="" do break
            testing.expect(t,page<100,"bounded source page must advance")
        }
        testing.expect_value(t,len(seen),len(expected.records))
    }
    bundle,_:=native_content_parse(field(root,"history"),"native_history_bundle")
    multi_chunk:=false
    for kind in ([3]string{"attempt","event","facet"}) {
        v,_:=contracts.owner_content_document(field(bundle,fmt.tprintf("%ss",kind)));items,_:=v.(json.Array)
        for value in items {
            text,_:=value.(json.String);original:=string(text)
            record,_:=native_content_parse(original,fmt.tprintf("native_history_%s",kind))
            key:=field(record,"attempt_no")
            if kind=="event" do key=field(record,"event_id")
            if kind=="facet" do key=encode([3]string{field(record,"attempt_no"),field(record,"kind"),field(record,"v")})
            out:=strings.builder_make(context.temp_allocator);offset:="";chunks:=0
            for _ in 0..<32 {
                p:=encode(doc(map[string]string{"source_revision"="rich_source_7","kind"=kind,"key"=key,"offset"="0" if offset=="" else offset}))
                got:=invoke(f,command(f,"native.history.fetch","aggregate_fetch","archive",p,"0"),p)
                if !testing.expect_value(t,got.code,"ok") do return
                doc_value,valid:=contracts.owner_content_document(got.body);part,_:=doc_value.(json.Object)
                testing.expect(t,valid);strings.write_string(&out,field(part,"record"));chunks+=1
                offset=field(part,"next_offset");if offset=="" do break
            }
            testing.expect_value(t,strings.to_string(out),original)
            if chunks>1 do multi_chunk=true
        }
    }
    testing.expect(t,multi_chunk,"rich original Unicode evidence must cross bounded fetch chunks")
}
@(test)
aggregate_rich_all_structs_import_export_exact_restart_replay_and_no_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);aggregate_import(t,f)
    aggregate_export_compare(t,f)
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_workflow_runs),(SELECT count(*) FROM local_fleet),(SELECT count(*) FROM local_chain_member_versions),(SELECT count(*) FROM local_chain_directory_versions),(SELECT count(*) FROM local_fleet_policy_versions)")
    testing.expect_value(t,encode(rows),encode([1][6]string{{"0","0","0","0","0","0"}}))
    testing.expect(t,metadata_replay(f,"rich_lease").replay)
    testing.expect(t,metadata_replay(f,"rich_review").replay)
    testing.expect(t,!exec(f.store.db,"UPDATE native_record_values SET record_json='{}'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM native_record_snapshots"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    aggregate_export_compare(t,f)
    testing.expect(t,metadata_replay(f,"rich_history").replay)
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
@(test)
aggregate_rich_ordinary_brief_pins_output_human_gate_context_and_search :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);aggregate_import(t,f)
    root:=aggregate_root()
    testing.expect_value(t,language_test_define(f,"follow",`{"schema":"workflow.v1","stages":[{"key":"follow","brief":{"goal":"Follow output","acceptance":["Pass"]}}]}`).code,"ok")
    work_bind(t,f,"task")
    p:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,field(root,"operational_brief"))}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","rich_brief","task",p,work_task_revision(f,"task")),p).code,"ok")
    p=`{"priority":"p0"}`
    testing.expect_value(t,invoke(f,command(f,"task.priority","rich_priority","task",p,work_task_revision(f,"task")),p).code,"ok")
    p=encode(doc(map[string]string{"body_cipher"=cipher(f,"aggregate_live_needle original notes")}))
    testing.expect_value(t,invoke(f,command(f,"task.comment","rich_live_comment","task",p,work_task_revision(f,"task")),p).code,"ok")
    claimed:=dependency_claim(f,"task","rich_lease","rich_claim",work_task_revision(f,"task"))
    if !testing.expect_value(t,claimed.code,"ok") do return
    cap:=result_cap(claimed);revision:=work_task_revision(f,"task")
    p=`{"requirements_revision":"1"}`
    present:=dependency_lifecycle_call(f,"task","rich_lease",lease_child(),"requirements.present","rich_present",p,cap,revision)
    if !testing.expect_value(t,present.code,"ok") do return
    value,_:=contracts.owner_content_document(present.body);shown,_:=value.(json.Object)
    testing.expect(t,strings.contains(field(shown,"resolved_inputs"),"art_original") && strings.contains(field(shown,"resolved_inputs"),"import_pending"))
    testing.expect_value(t,dependency_lifecycle_call(f,"task","rich_lease",lease_child(),"requirements.ack","rich_ack",p,cap,revision).code,"ok")
    bad:=`{"requirements_revision":"1","head":"","summary":"Invalid output","output":"{}"}`
    before:=work_state(f)
    testing.expect_value(t,dependency_lifecycle_call(f,"task","rich_lease",lease_child(),"lease.submit","bad_output",bad,cap,revision).code,"invalid_content")
    testing.expect(t,work_state(f)==before,"invalid structured output cannot append history or release authority")
    submit:=encode(doc(map[string]string{"requirements_revision"="1","head"="","summary"="Rich checks","output"=`{"summary":"aggregate_output_needle","artifact_id":"art_original","message_id":"msg_original"}`}))
    testing.expect_value(t,dependency_lifecycle_call(f,"task","rich_lease",lease_child(),"lease.submit","rich_submit",submit,cap,revision).code,"ok")
    verdict:=lifecycle_verdict()
    revision=work_task_revision(f,"task")
    opened:=dependency_lifecycle_call(f,"task","rich_lease",lifecycle_reviewer(),"review.open","rich_review_open",verdict,"",revision)
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,dependency_lifecycle_call(f,"task","rich_lease",lifecycle_reviewer(),"review.post","rich_independent",verdict,result_cap(opened),revision).code,"ok")
    rows,_:=query(f.store.db,"SELECT state FROM lifecycle_state WHERE task_id='task'")
    testing.expect_value(t,rows[0][0],"in_review")
    testing.expect_value(t,invoke(f,command(f,"review.post","rich_human","task",verdict,work_task_revision(f,"task")),verdict).code,"ok")
    rows,_=query(f.store.db,"SELECT state FROM lifecycle_state WHERE task_id='task'")
    testing.expect_value(t,rows[0][0],"done")
    rows,_=query(f.store.db,"SELECT inputs_json FROM local_workflow_language_runs")
    testing.expect(t,len(rows)==1 && strings.contains(rows[0][0],"aggregate_output_needle"))
    testing.expect(t,strings.contains(search_for(f,"aggregate_live_needle").body,"comment"))
    testing.expect(t,strings.contains(search_for(f,"aggregate_output_needle").body,"output"))
    ctx:=context_call(f,"chain.read","aggregate_context","")
    testing.expect(t,ctx.code=="ok" && strings.contains(ctx.body,"context"))
    sources,source_ok:=context_sources(&f.store,"chain");pinned:=false
    for row in sources {if row[0]=="requirements" && strings.contains(row[2],"facet:archive:3:handoff:1") do pinned=true}
    testing.expect(t,source_ok && pinned,"context provenance must retain typed original input pins")
    aggregate_export_compare(t,f)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    cold:=context_call(f,"chain.read","aggregate_context_cold","")
    warm_value,_:=contracts.owner_content_document(ctx.body);warm,_:=warm_value.(json.Object)
    cold_value,_:=contracts.owner_content_document(cold.body);cold_object,_:=cold_value.(json.Object)
    testing.expect(t,cold.code=="ok" && aggregate_equal(warm["context"],cold_object["context"]),"restart must retain exact materialized context provenance")
    aggregate_export_compare(t,f)
}

@(test)
aggregate_new_record_rollback_owner_account_chain_cursor_and_read_revocation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);aggregate_import(t,f)
    root:=aggregate_root();metadata,_:=root["metadata"].(json.Array)
    review_raw:=""
    for value in metadata {entry,_:=value.(json.Object);if field(entry,"kind")=="review" do review_raw=field(entry,"raw")}
    v,_:=contracts.owner_content_document(review_raw);bundle,_:=v.(json.Object)
    bundle["source_revision"]=json.String("rich_source_8");raw:=encode(bundle)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER aggregate_fail BEFORE INSERT ON local_events WHEN NEW.kind='native.metadata.import' BEGIN SELECT RAISE(ABORT,'failure'); END"))
    before:=work_state(f)
    testing.expect_value(t,native_metadata_test_call(f,raw,"rich_statement_fail",summary_revision(f)).code,"storage_error")
    testing.expect(t,work_state(f)==before,"new source snapshot/value/origin/receipt must roll back together")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER aggregate_fail; CREATE TABLE aggregate_parent(id INTEGER PRIMARY KEY); CREATE TABLE aggregate_ref(id INTEGER REFERENCES aggregate_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER aggregate_fail AFTER INSERT ON native_record_values BEGIN INSERT INTO aggregate_ref VALUES(1); END"))
    before=work_state(f)
    testing.expect_value(t,native_metadata_test_call(f,raw,"rich_commit_fail",summary_revision(f)).code,"storage_error")
    testing.expect(t,work_state(f)==before,"deferred commit failure cannot preserve a partial aggregate snapshot")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER aggregate_fail"))
    testing.expect_value(t,native_metadata_test_call(f,raw,"rich_review_later",summary_revision(f)).code,"ok")
    page:=native_metadata_test_read(f,"review","rich_source_7","","1")
    if !testing.expect_value(t,page.code,"ok") do return
    page_value,_:=contracts.owner_content_document(page.body);first,_:=page_value.(json.Object);cursor:=field(first,"next_cursor")
    testing.expect(t,cursor!="" && len(cursor)<128,"long typed tuples use bounded opaque immutable-snapshot cursors")
    testing.expect_value(t,native_metadata_test_read(f,"definition","rich_source_7",cursor,"1").code,"stale_cursor")
    testing.expect_value(t,native_metadata_test_read(f,"review","rich_source_8",cursor,"1").code,"stale_cursor")
    second:=native_metadata_test_read(f,"review","rich_source_7",cursor,"1")
    testing.expect_value(t,second.code,"ok")
    expected,_:=contracts.owner_content_document(second.body);last,_:=expected.(json.Object)
    testing.expect_value(t,field(last,"next_cursor"),"")
    read:=encode(doc(map[string]string{"source_revision"="rich_source_7","kind"="review","cursor"="","limit"="1"}))
    c,_:=contracts.owner_parse(command(f,"native.metadata.read","cross_account","",read,"0"),"command")
    c["account_id"]=json.String("other_account")
    sig,_:=test_sign(&f.creator_priv,"command",c);c["signature"]=json.String(sig)
    other_key:=f.creator;other_key.account_id="other_account"
    before=work_state(f)
    got:=execute(&f.store,encode(c),read,"",other_key,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign})
    testing.expect(t,got.code!="ok","even an enrolled verified key cannot cross the immutable account boundary")
    testing.expect(t,work_state(f)==before)
    cross:=grant_command(f,f.creator,&f.creator_priv,"native.metadata.read","cross_chain","",read,"0",chain="other_chain")
    testing.expect_value(t,invoke(f,cross,read).code,"invalid_scope")
    testing.expect(t,exec(f.store.db,"UPDATE local_grants SET can_mutate=0,revision=revision+1"))
    testing.expect(t,metadata_replay(f,"rich_review").replay)
    testing.expect_value(t,native_metadata_test_read(f,"review","rich_source_7").code,"ok")
    testing.expect(t,exec(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1"))
    testing.expect_value(t,native_metadata_test_read(f,"review","rich_source_7").code,"invalid_scope")
    testing.expect_value(t,metadata_replay(f,"rich_review").code,"invalid_scope")
}
@(test)
aggregate_v23_upgrade_collision_commit_rollback_and_live_capability_recovery :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    before,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    close(&f.store);db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,string(#load("migration_025_test_drop.sql"))+"DROP TABLE IF EXISTS owner_execution_bootstraps; DROP TABLE IF EXISTS owner_execution_queries; DROP TABLE owner_execution_journal; DROP TABLE native_record_values; DROP TABLE native_record_snapshots"))
    prefix:=string(MIGRATION_023);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_work_chains")]
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=23; CREATE VIEW native_record_snapshots AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"23","23"}}))
    testing.expect(t,exec(db,"DROP VIEW native_record_snapshots; CREATE TABLE aggregate_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE aggregate_upgrade_ref(id INTEGER REFERENCES aggregate_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER aggregate_upgrade_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=24 BEGIN INSERT INTO aggregate_upgrade_ref VALUES(1); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='native_record_snapshots') FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"23","23","0"}}))
    testing.expect(t,exec(db,"DROP TRIGGER aggregate_upgrade_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","aggregate_upgraded",`{"requirements_revision":"1"}`,cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}

// Signed inventories must expose operational runs/sources, never activate the
// similarly named immutable source snapshots imported above.
@(test)
aggregate_signed_workflow_source_inventories_survive_restart_and_revoke :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);aggregate_import(t,f)
    testing.expect_value(t,advanced_call(f,"workflow.define","inventory_define",workflow_test_definition()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","inventory_run",`{"run_id":"live_run","workflow_id":"definition","version":"1"}`).code,"ok")
    p:=`{"cursor":"","limit":"100"}`
    for method,i in ([2]string{"workflow.read","source.read"}) {
        warm:=invoke(f,command(f,method,fmt.tprintf("inventory_warm_%d",i),"",p,"0"),p)
        if !testing.expect_value(t,warm.code,"ok") do return
        testing.expect(t,strings.contains(warm.body,"live_run"))
        testing.expect(t,!strings.contains(warm.body,"original_user"),"immutable source records cannot become operational inventories")
        close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
        cold:=invoke(f,command(f,method,fmt.tprintf("inventory_cold_%d",i),"",p,"0"),p)
        testing.expect_value(t,cold.code,"ok")
        testing.expect_value(t,cold.body,warm.body)
    }
    testing.expect(t,exec(f.store.db,"UPDATE local_grants SET can_read=0,revision=revision+1"))
    for method,i in ([2]string{"workflow.read","source.read"}) {
        testing.expect_value(t,invoke(f,command(f,method,fmt.tprintf("inventory_revoked_%d",i),"",p,"0"),p).code,"invalid_scope")
    }
}
