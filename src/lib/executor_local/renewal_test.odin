#+feature dynamic-literals
package executor_local

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
executor_renewal_requires_confirmed_exact_daemon_deadline_before_child_auth :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"ok")
    intent,_:=take_intent(&f.store,1300)
    child,ready:=launch_material(&f.store,intent,1300);testing.expect(t,ready)
    secret,created:=launch_control(&f.store,intent,1300)
    testing.expect(t,created && len(secret)==64 && secret!=child.token_secret && secret!=intent.launch_key)
    replay,reused:=launch_control(&f.store,intent,1300)
    testing.expect(t,reused && replay==secret)
    testing.expect(t,!strings.contains(child.bootstrap,secret) && !strings.contains(child.body,secret) &&
        !strings.contains(child.configuration,secret))
    testing.expect(t,begin_dispatch(&f.store,intent,1300))
    _,created=launch_control(&f.store,intent,1300);testing.expect(t,!created,"dispatch cannot mint another credential")
    live:=Child_Observation{intent.instance,intent.launch_key,f.store.incarnation,true}
    testing.expect(t,observe_child(&f.store,intent.reservation,live))
    renew,_:=contracts.executor_parse(x.action,"action")
    set(renew,"method","heartbeat");set(renew,"operation_id","renewal");set(renew,"deadline_version","2")
    set(renew,"expires_ms","8000");set(renew,"request_expires_ms","6000")
    raw:=signed(renew,"action",&f.owner1)
    testing.expect_value(t,action(&f.store,raw,f.owner1.public,1400).code,"owner_fence_not_current")
    testing.expect_value(t,action(&f.store,raw,f.owner1.public,1400,proof(renew)).code,"ok")
    _,authenticated:=child_bootstrap(&f.store,intent.instance,child.token_secret,1500)
    testing.expect(t,!authenticated,"accepted ledger deadline alone is not daemon confirmation")
    accepted:=action(&f.store,raw,f.owner1.public,1500)
    _,receipt_signed:=seal_receipt(&f.store,renew,"action",accepted,{&f.operator,sign_receipt})
    testing.expect(t,!receipt_signed,"generic replay must not emit a pending-only physical receipt")
    material,current:=renewal_material(&f.store,raw,1500)
    testing.expect(t,current && material.secret==secret && material.version==2)
    wrong:=material;wrong.launch_key="other"
    testing.expect(t,!renewal_confirm(&f.store,wrong,1500))
    testing.expect(t,renewal_confirm(&f.store,material,1500))
    _,receipt_signed=seal_receipt(&f.store,renew,"action",accepted,{&f.operator,sign_receipt})
    testing.expect(t,receipt_signed,"only confirmed delivery can emit a signed heartbeat receipt")
    retained:string;retained,authenticated=child_bootstrap(&f.store,intent.instance,child.token_secret,5100)
    testing.expect(t,authenticated && retained==x.raw,"confirmed renewal supplements, never replaces bootstrap")
    input:=executor_child_input(x)
    result:=attest_child_request(&f.store,intent.instance,child.token_secret,input,live,f.owner1.public,f.operator.public,5100,{&f.operator,sign_receipt})
    if !testing.expect_value(t,result.code,"ok") do return
    r,valid:=contracts.executor_parse(result.body,"child_request");testing.expect(t,valid)
    b,_:=contracts.executor_parse(x.raw,"bootstrap")
    testing.expect(t,contracts.executor_child_request_matches(r,b,input,f.operator.public,f.owner1.public,5100,renew))
    testing.expect(t,!contracts.executor_child_request_matches(r,b,input,f.operator.public,f.owner1.public,5100))
    testing.expect_value(t,field(r,"deadline_version"),"2")
    testing.expect_value(t,field(r,"expires_ms"),"8000")
    for name in ([5]string{"reservation_id","grant_generation","executor_incarnation","prepare_digest","hard_ms"}) {
        changed,_:=contracts.executor_parse(raw,"action")
        set(changed,name,"other" if name=="reservation_id" else "9999")
        if name=="prepare_digest" do set(changed,name,strings.repeat("b",64,context.temp_allocator))
        changed_raw:=signed(changed,"action",&f.owner1)
        changed,_=contracts.executor_parse(changed_raw,"action")
        testing.expect(t,!contracts.executor_child_request_matches(r,b,input,f.operator.public,f.owner1.public,5100,changed))
    }
    testing.expect(t,renewal_confirm(&f.store,material,5100),"exact local confirmation replay is idempotent")
    rows,_:=query(f.store.db,"SELECT document FROM executor_bootstraps")
    testing.expect_value(t,rows[0][0],x.raw)
    rows,_=query(f.store.db,"SELECT count(*) FROM executor_controls")
    testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_controls SET renewal_secret='changed'"))
    testing.expect(t,!exec(f.store.db,"UPDATE executor_renewals SET state='pending'"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    _,current=renewal_material(&f.store,raw,5200);testing.expect(t,!current,"restart fails closed on old serving incarnation")
    _,authenticated=child_bootstrap(&f.store,intent.instance,child.token_secret,5200);testing.expect(t,!authenticated)
    rows,_=query(f.store.db,"SELECT renewal_secret FROM executor_controls")
    testing.expect_value(t,rows[0][0],secret)
}

@(test)
executor_renewal_v5_migration_collision_rolls_back_without_replacing_child :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"ok")
    testing.expect(t,exec(f.store.db,local_schema_drop_for_test))
    testing.expect(t,exec(f.store.db,"PRAGMA legacy_alter_table=ON; DROP TABLE executor_renewals; DROP TABLE executor_controls; DROP TRIGGER runtime_immutable; DROP TRIGGER runtime_no_delete; ALTER TABLE executor_runtime RENAME TO executor_runtime_v6;"))
    schema:=string(#load("schema.sql"))
    old,_:=strings.replace_all(schema[:strings.index(schema,"CREATE TABLE executor_policies")],"schema_version=7","schema_version=5",context.temp_allocator)
    testing.expect(t,exec(f.store.db,old))
    testing.expect(t,exec(f.store.db,"INSERT INTO executor_runtime SELECT singleton,5,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v6; DROP TABLE executor_runtime_v6; CREATE VIEW executor_controls AS SELECT 1;"))
    close(&f.store);testing.expect(t,!open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&f.store.db),0)
    rows,_:=query(f.store.db,"SELECT schema_version,incarnation,(SELECT document FROM executor_bootstraps) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="5" && rows[0][1]=="1" && rows[0][2]==x.raw)
    testing.expect(t,exec(f.store.db,"DROP VIEW executor_controls"));close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    rows,_=query(f.store.db,"SELECT schema_version,incarnation,(SELECT document FROM executor_bootstraps),(SELECT count(*) FROM executor_controls) FROM executor_runtime")
    testing.expect(t,rows[0][0]=="7" && rows[0][1]=="2" && rows[0][2]==x.raw && rows[0][3]=="0")
}
