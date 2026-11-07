package executor_local

import "core:strings"
import "core:testing"

@(test)
executor_readiness_exact_current_child_idempotent_and_stale_replay_denied :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"ok")
    intent,taken:=take_intent(&f.store,1300);testing.expect(t,taken)
    material,available:=launch_material(&f.store,intent,1300);testing.expect(t,available)
    live:=Child_Observation{intent.instance,intent.launch_key,f.store.incarnation,true}
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,f.operator.public,1300).code,"invalid_scope")
    testing.expect(t,begin_dispatch(&f.store,intent,1300))
    testing.expect(t,observe_child(&f.store,intent.reservation,live))
    for i in 0..<4 {
        wrong:=live
        switch i {case 0:wrong.instance="other";case 1:wrong.launch_key="wrong";case 2:wrong.executor_incarnation+=1;case 3:wrong.present=false}
        testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,wrong,f.owner1.public,f.operator.public,1400).code,"child_not_current")
    }
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER readiness_fail BEFORE INSERT ON executor_readiness BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,f.operator.public,1400).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT count(*) FROM executor_readiness");testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER readiness_fail; CREATE TABLE readiness_parent(id INTEGER PRIMARY KEY); CREATE TABLE readiness_deferred(id INTEGER REFERENCES readiness_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER readiness_fail AFTER INSERT ON executor_readiness BEGIN INSERT INTO readiness_deferred VALUES(1); END"))
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,f.operator.public,1400).code,"storage_error")
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_readiness");testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER readiness_fail"))
    ready:=child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,f.operator.public,1400)
    testing.expect(t,ready.code=="ok" && !ready.replay && strings.contains(ready.body,"\"ready_ms\":\"1400\""))
    again:=child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,f.operator.public,1500)
    testing.expect(t,again.code=="ok" && again.replay && again.body==ready.body)
    rows,_=query(f.store.db,"SELECT count(*),min(ready_ms),min(token_generation) FROM executor_readiness")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="1400" && rows[0][2]==field(x.b,"token_generation"))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_readiness SET ready_ms=1500"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM executor_readiness"))
    bad_owner:=f.owner1.public;bad_owner.revoked=true
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,live,bad_owner,f.operator.public,1500).code,"invalid_scope")
    bad_executor:=f.operator.public;bad_executor.enrolled=false
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,bad_executor,1500).code,"invalid_scope")
    testing.expect_value(t,child_ready(&f.store,intent.instance,"wrong",live,f.owner1.public,f.operator.public,1500).code,"invalid_scope")
    absent:=live;absent.present=false
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,absent,f.owner1.public,f.operator.public,1500).code,"child_not_current")
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,f.operator.public,5000).code,"invalid_scope")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    live.executor_incarnation=f.store.incarnation
    testing.expect(t,observe_child(&f.store,intent.reservation,live))
    testing.expect(t,complete_recovery(&f.store,1500))
    testing.expect_value(t,child_ready(&f.store,intent.instance,material.token_secret,live,f.owner1.public,f.operator.public,1500).code,"invalid_scope")
    rows,_=query(f.store.db,"SELECT count(*),min(ready_ms) FROM executor_readiness")
    testing.expect(t,rows[0][0]=="1" && rows[0][1]=="1400","restart retains evidence but cannot replay an old credential generation")
}

@(test)
executor_readiness_v4_migration_collision_rolls_back_preserving_bootstrap_and_identity :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"ok")
    testing.expect(t,exec(f.store.db,local_schema_drop_for_test))
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_renewals; DROP TABLE executor_controls; DROP TABLE executor_readiness; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO executor_runtime_v5;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=8","schema_version=4",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,4,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v5; DROP TABLE executor_runtime_v5; CREATE TABLE executor_readiness(collision TEXT);"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db)==0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT document FROM executor_bootstraps) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="4" && rows[0][1]=="1" && rows[0][2]=="active" && rows[0][3]==x.raw)
    testing.expect(t,exec(f.store.db,"DROP TABLE executor_readiness"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT state FROM executor_reservations),(SELECT document FROM executor_bootstraps),(SELECT count(*) FROM executor_readiness) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="8" && rows[0][1]=="2" && rows[0][2]=="active" && rows[0][3]==x.raw && rows[0][4]=="0")
}
