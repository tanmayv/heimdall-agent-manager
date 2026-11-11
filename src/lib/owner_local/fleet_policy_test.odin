#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:testing"
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
    testing.expect_value(t,encode(rows),encode([1][3]string{{"2","38","38"}}))
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
    testing.expect_value(t,fleet_policy_test_read(f).code,"ok")
    f.creator.revoked=true // the device itself is revoked (account-level trust; no per-chain grant)
    testing.expect_value(t,fleet_policy_test_read(f).code,"invalid_scope")
}
