#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"

priority_call :: proc(f:^Fixture,priority,op,revision:string) -> Result {
    p:=encode(doc(map[string]string{"priority"=priority}))
    return invoke(f,command(f,"task.priority",op,"task",p,revision),p)
}
priority_read :: proc(f:^Fixture,method,task:string,cursor:="") -> Result {
    p:=encode(doc(map[string]string{"cursor"=cursor,"limit"="1"}))
    return invoke(f,command(f,method,"read_priority",task,p,"0"),p)
}
@(test)
priority_signed_update_reads_history_replay_restart_and_scope :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    got:=priority_read(f,"task.read","task")
    value,_:=contracts.owner_content_document(got.body);row,_:=value.(json.Object)
    testing.expect_value(t,field(row,"priority"),"p2")
    p:=`{"priority":"p0"}`
    c:=command(f,"task.priority","raise","task",p,"1")
    accepted:=invoke(f,c,p)
    if !testing.expect_value(t,accepted.code,"ok") do return
    before:=native_metadata_test_state(f)
    replay:=invoke(f,c,p,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==accepted.body)
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect_value(t,priority_call(f,"p1","stale","1").code,"stale_revision")
    got=priority_read(f,"task.read","task")
    value,_=contracts.owner_content_document(got.body);row,_=value.(json.Object)
    testing.expect_value(t,field(row,"priority"),"p0")
    got=priority_read(f,"chain.read","")
    value,_=contracts.owner_content_document(got.body);row,_=value.(json.Object)
    items,_:=row["items"].(json.Array);item,_:=items[0].(json.Object)
    testing.expect_value(t,field(item,"priority"),"p0")
    testing.expect_value(t,priority_call(f,"p1","lower","2").code,"ok")
    rows,ok:=query(f.store.db,"SELECT priority FROM local_task_priority_versions ORDER BY accepted_seq")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([2][1]string{{"p0"},{"p1"}}))
    testing.expect(t,!exec(f.store.db,"UPDATE local_task_priority_versions SET priority='p2'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_task_priority_versions"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    got=priority_read(f,"task.read","task")
    value,_=contracts.owner_content_document(got.body);row,_=value.(json.Object)
    testing.expect_value(t,field(row,"priority"),"p1")
    testing.expect_value(t,invoke(f,command(f,"task.priority","missing","missing",p,"1"),p).code,"invalid_scope")
    _,_=query(f.store.db,"UPDATE local_grants SET can_mutate=0,revision=revision+1")
    testing.expect_value(t,priority_call(f,"p0","read_only","3").code,"invalid_scope")
    testing.expect_value(t,priority_read(f,"task.read","task").code,"ok")
}
@(test)
priority_statement_and_commit_failures_leave_revisions_history_and_receipts_unchanged :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    before:=native_metadata_test_state(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER priority_fail BEFORE INSERT ON local_events WHEN NEW.kind='task.priority' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,priority_call(f,"p0","statement","1").code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER priority_fail; CREATE TABLE priority_parent(id INTEGER PRIMARY KEY); CREATE TABLE priority_ref(id INTEGER REFERENCES priority_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER priority_fail AFTER INSERT ON local_task_priority_versions BEGIN INSERT INTO priority_ref VALUES(1); END"))
    testing.expect_value(t,priority_call(f,"p0","commit","1").code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    rows,ok:=query(f.store.db,"SELECT count(*) FROM local_task_priority_versions")
    testing.expect(t,ok && rows[0][0]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER priority_fail"))
    testing.expect_value(t,priority_call(f,"p0","retry","1").code,"ok")
}

@(test)
priority_preserves_live_capability_and_invalidates_listing_cursor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    before,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    testing.expect_value(t,priority_call(f,"p0","live_priority","4").code,"ok")
    after,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","priority_keeps_holder",`{"requirements_revision":"1"}`,cap,"5").code,"ok")
    revision,_:=query(f.store.db,"SELECT revision FROM task_chains")
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"second"),"body_cipher"=cipher(f,"second body")}))
    testing.expect_value(t,invoke(f,command(f,"task.create","second","task2",p,revision[0][0]),p).code,"ok")
    page:=priority_read(f,"chain.read","")
    value,_:=contracts.owner_content_document(page.body);row,_:=value.(json.Object)
    cursor:=field(row,"next_cursor")
    testing.expect(t,cursor!="")
    testing.expect_value(t,priority_call(f,"p1","next_priority","5").code,"ok")
    testing.expect_value(t,priority_read(f,"chain.read","",cursor).code,"stale_cursor")
}

@(test)
priority_v19_migration_collision_and_commit_rollback_preserve_rich_state :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    chain,_:=query(f.store.db,"SELECT revision FROM task_chains")
    testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_MEMBERS),"before_v20",chain[0][0]).code,"ok")
    keep:="SELECT (SELECT json_group_array(json_array(lease_id,capability_json,retired_seq)) FROM local_leases),(SELECT json_group_array(json_array(seq,evidence_json)) FROM local_events),(SELECT json_group_array(json_array(principal_id,operation_id,result_json)) FROM command_receipts),(SELECT commit_seq FROM runtime_database),(SELECT json_group_array(json_array(chain_id,source_revision,agent_instance_id,role)) FROM native_metadata_members)"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,V23_TEST_DROP))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS local_metadata_retirements; DROP TABLE IF EXISTS local_brief_inputs; DROP TABLE IF EXISTS local_coordinator_revocations; DROP TABLE IF EXISTS local_config_revocations; DROP TABLE IF EXISTS local_chain_directory_versions; DROP TABLE IF EXISTS local_chain_member_versions; DROP TABLE IF EXISTS local_member_chains; DROP TABLE IF EXISTS local_chain_defaults_versions; DROP TABLE IF EXISTS local_chain_summary_versions; DROP TRIGGER IF EXISTS native_history_origin; DROP TABLE IF EXISTS local_fleet_policy_sources; DROP TABLE IF EXISTS native_fleet_policies; DROP TABLE IF EXISTS native_fleet_snapshots; DROP TABLE local_task_priority_versions"))
    prefix:=string(MIGRATION_019);prefix=prefix[:strings.index(prefix,"CREATE TABLE native_fact_snapshots")]
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=19; CREATE VIEW local_task_priority_versions AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="19" && rows[0][1]=="19")
    after,_:=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP VIEW local_task_priority_versions; CREATE TABLE priority_migrate_parent(id INTEGER PRIMARY KEY); CREATE TABLE priority_migrate_ref(id INTEGER REFERENCES priority_migrate_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER priority_migrate_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=20 BEGIN INSERT INTO priority_migrate_ref VALUES(1); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_task_priority_versions') FROM runtime_database")
    testing.expect(t,rows[0][0]=="19" && rows[0][1]=="19" && rows[0][2]=="0")
    after,_=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER priority_migrate_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    after,_=query(f.store.db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,native_metadata_test_read(f,"member").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","v20_keeps_child",`{"requirements_revision":"1"}`,cap).code,"ok")
}
