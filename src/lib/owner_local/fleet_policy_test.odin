#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"

FLEET_POLICY_FIXTURE :: #load("../../contracts/fixtures/owner-fleet-policy.json")

fleet_policy_test_call :: proc(f:^Fixture,raw,op,revision:string) -> Result {
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,raw)}))
    return invoke(f,command(f,"fleet.policy.set",op,"",p,revision),p)
}
fleet_policy_test_read :: proc(f:^Fixture,cursor:="",limit:="20") -> Result {
    p:=encode(doc(map[string]string{"cursor"=cursor,"limit"=limit}))
    return invoke(f,command(f,"fleet.policy.read","policy_read","",p,"0"),p)
}
fleet_policy_test_state :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_fleet_policy_versions),(SELECT count(*) FROM local_fleet_policy_roles),(SELECT count(*) FROM local_fleet_policy_models),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_events),(SELECT revision FROM task_chains),(SELECT revision FROM tasks),(SELECT commit_seq FROM runtime_database),(SELECT count(*) FROM runtime_intents)")
    return encode(rows)
}

@(test)
fleet_policy_round_trip_history_cas_and_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=string(FLEET_POLICY_FIXTURE)
    accepted:=fleet_policy_test_call(f,raw,"policy_first","2")
    if !testing.expect_value(t,accepted.code,"ok") do return
    state:=fleet_policy_test_state(f)
    testing.expect_value(t,fleet_policy_test_call(f,raw,"policy_stale","2").code,"stale_revision")
    testing.expect_value(t,fleet_policy_test_state(f),state)
    page:=fleet_policy_test_read(f)
    if !testing.expect_value(t,page.code,"ok") do return
    value,valid:=contracts.owner_content_document(page.body);root,obj:=value.(json.Object)
    items,_:=root["items"].(json.Array)
    if !testing.expect(t,valid && obj && len(items)==1) do return
    item,_:=items[0].(json.Object)
    policy_raw:=encode(item["policy"])
    policy,valid_policy:=contracts.owner_fleet_policy_parse(policy_raw)
    original,_:=contracts.owner_fleet_policy_parse(raw)
    testing.expect(t,valid_policy && policy==original)
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_fleet_policy_roles),(SELECT count(*) FROM local_fleet_policy_models),(SELECT count(*) FROM local_fleet),(SELECT count(*) FROM local_leases),(SELECT revision FROM tasks)")
    testing.expect_value(t,encode(rows),encode([1][5]string{{"3","1","0","0","1"}}))
    replay_payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,raw)}))
    exact_command:=command(f,"fleet.policy.set","policy_exact","",replay_payload,"3")
    second:=invoke(f,exact_command,replay_payload)
    testing.expect_value(t,second.code,"ok")
    replay:=invoke(f,exact_command,replay_payload,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==second.body)
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,fleet_policy_test_read(f).code,"ok")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_fleet_policy_versions),(SELECT schema_version FROM runtime_database),(SELECT version FROM schema_migrations)")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"2","27","27"}}))
    testing.expect(t,!exec(f.store.db,"UPDATE local_fleet_policy_versions SET provider='other'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_fleet_policy_models"))
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
}

@(test)
fleet_policy_scope_validation_and_statement_commit_rollback :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=string(FLEET_POLICY_FIXTURE)
    before:=fleet_policy_test_state(f)
    value,_:=contracts.owner_content_document(raw);policy,_:=value.(json.Object)
    policy["task_chain_id"]=json.String("other_chain")
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"scope","2").code,"invalid_scope")
    policy["task_chain_id"]=json.String("chain");policy["unknown"]=json.String("drop")
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"unknown","2").code,"invalid_content")
    testing.expect_value(t,fleet_policy_test_state(f),before)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER policy_fail BEFORE INSERT ON local_events WHEN NEW.kind='fleet.policy.set' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,fleet_policy_test_call(f,raw,"stmt","2").code,"storage_error")
    testing.expect_value(t,fleet_policy_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER policy_fail"))
    testing.expect(t,exec(f.store.db,"CREATE TABLE policy_parent(id INTEGER PRIMARY KEY); CREATE TABLE policy_ref(id INTEGER REFERENCES policy_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER policy_fail AFTER INSERT ON local_fleet_policy_versions BEGIN INSERT INTO policy_ref VALUES(1); END"))
    testing.expect_value(t,fleet_policy_test_call(f,raw,"commit","2").code,"storage_error")
    testing.expect_value(t,fleet_policy_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER policy_fail"))
    testing.expect_value(t,fleet_policy_test_call(f,raw,"accepted","2").code,"ok")
    policy["unknown"]=nil;delete_key(&policy,"unknown")
    policy["created_at"]=json.String("changed")
    before=fleet_policy_test_state(f)
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"identity","3").code,"operation_conflict")
    testing.expect_value(t,fleet_policy_test_state(f),before)
}

@(test)
fleet_policy_pagination_is_revision_bound_and_read_grants_are_enforced :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    value,_:=contracts.owner_content_document(string(FLEET_POLICY_FIXTURE));policy,_:=value.(json.Object)
    for i in 0..<3 {
        policy["agent_id"]=json.String(fmt.tprintf("agent:%d",i))
        testing.expect_value(t,fleet_policy_test_call(f,encode(policy),fmt.tprintf("policy_%d",i),fmt.tprintf("%d",i+2)).code,"ok")
    }
    first:=fleet_policy_test_read(f,"","1")
    root_value,_:=contracts.owner_content_document(first.body);root,_:=root_value.(json.Object)
    cursor:=field(root,"next_cursor")
    testing.expect(t,cursor!="")
    second:=fleet_policy_test_read(f,cursor,"1")
    testing.expect_value(t,second.code,"ok")
    policy["capacity"]=json.Integer(3)
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"changed","5").code,"ok")
    testing.expect_value(t,fleet_policy_test_read(f,cursor,"1").code,"stale_cursor")
    _,_=query(f.store.db,"UPDATE local_grants SET can_mutate=0,revision=revision+1")
    testing.expect_value(t,fleet_policy_test_read(f).code,"ok")
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"denied","6").code,"invalid_scope")
    _,_=query(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1")
    testing.expect_value(t,fleet_policy_test_read(f).code,"invalid_scope")
}

@(test)
fleet_policy_edits_preserve_live_child_authority_and_v16_migration_rollback :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    keep:="SELECT (SELECT json_group_array(json_array(lease_id,capability_json,retired_seq)) FROM local_leases),(SELECT json_group_array(json_array(seq,evidence_json)) FROM local_events),(SELECT json_group_array(json_array(principal_id,operation_id,result_json)) FROM command_receipts),(SELECT commit_seq FROM runtime_database)"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_016);prefix=prefix[:strings.index(prefix,"CREATE TABLE native_budget_baselines")]
    testing.expect(t,exec(db,V23_TEST_DROP))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS local_metadata_retirements; DROP TABLE IF EXISTS local_brief_inputs; DROP TABLE IF EXISTS local_coordinator_revocations; DROP TABLE IF EXISTS local_config_revocations; DROP TABLE IF EXISTS local_chain_directory_versions; DROP TABLE IF EXISTS local_chain_member_versions; DROP TABLE IF EXISTS local_member_chains; DROP TABLE IF EXISTS local_chain_defaults_versions; DROP TABLE IF EXISTS local_chain_summary_versions; DROP TRIGGER IF EXISTS native_history_origin; DROP TABLE IF EXISTS local_fleet_policy_sources; DROP TABLE IF EXISTS native_fleet_policies; DROP TABLE IF EXISTS native_fleet_snapshots; DROP TABLE IF EXISTS local_task_priority_versions; DROP TABLE IF EXISTS native_fact_chain; DROP TABLE IF EXISTS native_fact_task; DROP TABLE IF EXISTS native_fact_comment; DROP TABLE IF EXISTS native_fact_summary; DROP TABLE IF EXISTS native_fact_snapshots; DROP TABLE IF EXISTS native_metadata_members; DROP TABLE IF EXISTS native_metadata_directories; DROP TABLE IF EXISTS native_metadata_snapshots; DROP TABLE IF EXISTS native_metadata_origins; DROP VIEW local_fleet_policy_current; DROP TABLE local_fleet_policy_models; DROP TABLE local_fleet_policy_roles; DROP TABLE local_fleet_policy_versions"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=16; CREATE VIEW local_fleet_policy_versions AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="16" && rows[0][1]=="16")
    after,_:=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP VIEW local_fleet_policy_versions; CREATE TABLE fleet_migrate_parent(id INTEGER PRIMARY KEY); CREATE TABLE fleet_migrate_ref(id INTEGER REFERENCES fleet_migrate_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fleet_migrate_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=17 BEGIN INSERT INTO fleet_migrate_ref VALUES(1); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_fleet_policy_versions') FROM runtime_database")
    testing.expect(t,rows[0][0]=="16" && rows[0][1]=="16" && rows[0][2]=="0")
    after,_=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER fleet_migrate_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_=query(f.store.db,keep);testing.expect_value(t,encode(after),encode(before))
    chain,_:=query(f.store.db,"SELECT revision FROM task_chains")
    lease_before,_:=query(f.store.db,"SELECT * FROM local_leases")
    testing.expect_value(t,fleet_policy_test_call(f,string(FLEET_POLICY_FIXTURE),"live_policy",chain[0][0]).code,"ok")
    lease_after,_:=query(f.store.db,"SELECT * FROM local_leases")
    testing.expect_value(t,encode(lease_after),encode(lease_before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","policy_keeps_child","{\"requirements_revision\":\"1\"}",cap).code,"ok")
}
