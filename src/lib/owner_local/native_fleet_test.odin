#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"

native_fleet_bundle :: proc(raw:string,source:="fleet_source_7") -> string {
    value,_:=contracts.owner_content_document(raw)
    bundle:=doc(map[string]string{"chain_id"="chain","owner_user_id"="native_owner","source_revision"=source,"kind"="fleet"})
    bundle["records"]=json.Array{value}
    return encode(bundle)
}
native_fleet_activate :: proc(f:^Fixture,raw,source,op,revision:string) -> Result {
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,raw),"source_revision"=source}))
    return invoke(f,command(f,"fleet.policy.set",op,"",p,revision),p)
}
native_fleet_state :: proc(f:^Fixture) -> string {
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM native_fleet_policies),(SELECT count(*) FROM native_fleet_snapshots),(SELECT count(*) FROM local_fleet_policy_sources),(SELECT count(*) FROM native_metadata_origins)")
    return encode([2]string{encode(rows),fleet_policy_test_state(f)})
}
@(test)
native_fleet_source_import_and_explicit_pinned_activation_preserve_history :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=string(FLEET_POLICY_FIXTURE)
    testing.expect_value(t,native_metadata_test_call(f,native_fleet_bundle(raw),"fleet_source","2").code,"ok")
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_fleet_policy_versions),(SELECT count(*) FROM local_fleet),(SELECT count(*) FROM local_leases)")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][3]string{{"0","0","0"}}))
    got:=native_metadata_test_read(f,"fleet","fleet_source_7")
    if !testing.expect_value(t,got.code,"ok") do return
    value,_:=contracts.owner_content_document(got.body);page,_:=value.(json.Object);items,_:=page["items"].(json.Array)
    policy,_:=contracts.owner_fleet_policy_parse(raw);actual,_:=contracts.owner_fleet_policy_parse(encode(items[0]))
    testing.expect_value(t,encode(actual),encode(policy))
    before:=native_fleet_state(f)
    testing.expect_value(t,native_fleet_activate(f,raw,"missing_source","missing","3").code,"invalid_scope")
    policy.capacity+=1
    testing.expect_value(t,native_fleet_activate(f,encode(policy),"fleet_source_7","mismatch","3").code,"operation_conflict")
    testing.expect_value(t,native_fleet_state(f),before)
    testing.expect_value(t,native_fleet_activate(f,raw,"fleet_source_7","activate","3").code,"ok")
    got=fleet_policy_test_read(f)
    value,_=contracts.owner_content_document(got.body);page,_=value.(json.Object);items,_=page["items"].(json.Array);item,_:=items[0].(json.Object)
    testing.expect_value(t,field(item,"source_revision"),"fleet_source_7")
    testing.expect_value(t,native_metadata_test_call(f,native_fleet_bundle(encode(policy),"fleet_source_8"),"later_source","4").code,"ok")
    rows,_=query(f.store.db,"SELECT capacity FROM local_fleet_policy_current")
    testing.expect_value(t,number(rows[0][0]),policy.capacity-1)
    testing.expect_value(t,native_fleet_activate(f,encode(policy),"fleet_source_8","later_activate","5").code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,native_metadata_test_read(f,"fleet","fleet_source_7").code,"ok")
    rows,_=query(f.store.db,"SELECT source_revision FROM local_fleet_policy_sources ORDER BY accepted_seq")
    testing.expect_value(t,encode(rows),encode([2][1]string{{"fleet_source_7"},{"fleet_source_8"}}))
    testing.expect(t,!exec(f.store.db,"UPDATE native_fleet_policies SET provider='forged'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_fleet_policy_sources"))
    rows,ok=query(f.store.db,"PRAGMA foreign_key_check");testing.expect(t,ok && len(rows)==0)
}
@(test)
native_fleet_import_and_activation_roll_back_statement_and_commit_failures :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    raw:=string(FLEET_POLICY_FIXTURE);before:=native_fleet_state(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fleet_source_fail BEFORE INSERT ON native_fleet_policies BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,native_metadata_test_call(f,native_fleet_bundle(raw),"source_statement","2").code,"storage_error")
    testing.expect_value(t,native_fleet_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fleet_source_fail; CREATE TABLE fleet_source_parent(id INTEGER PRIMARY KEY); CREATE TABLE fleet_source_ref(id INTEGER REFERENCES fleet_source_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fleet_source_fail AFTER INSERT ON native_fleet_policies BEGIN INSERT INTO fleet_source_ref VALUES(1); END"))
    testing.expect_value(t,native_metadata_test_call(f,native_fleet_bundle(raw),"source_commit","2").code,"storage_error")
    testing.expect_value(t,native_fleet_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fleet_source_fail"))
    testing.expect_value(t,native_metadata_test_call(f,native_fleet_bundle(raw),"source","2").code,"ok")
    before=native_fleet_state(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fleet_source_fail AFTER INSERT ON local_fleet_policy_sources BEGIN INSERT INTO fleet_source_ref VALUES(1); END"))
    testing.expect_value(t,native_fleet_activate(f,raw,"fleet_source_7","activation_commit","3").code,"storage_error")
    testing.expect_value(t,native_fleet_state(f),before)
}
