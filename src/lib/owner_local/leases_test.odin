#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

lease_child :: proc() -> Child { return {"instance","epoch",strings.repeat("a",64,context.temp_allocator),1} }
fleet_seed :: proc(t:^testing.T,f:^Fixture,child:Child) {
    seed(t,f)
    p:=encode(doc(map[string]string{"instance_id"=child.instance,"configuration_revision"="1","enabled"="1"}))
    c:=command(f,"fleet.edit","fleet","task",p,"1")
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
}
lease_request :: proc(f:^Fixture,child:Child,method,op,lease,cap:string,revision:="2",expires:i64=2000) -> string {
    c:=doc(map[string]string{
        "protocol_version"="1","account_id"="account","owner_bridge_id"="bridge","chain_id"="chain","task_id"="task",
        "lease_id"=lease,"instance_id"=child.instance,"launch_epoch"=child.epoch,"run_count"=fmt.tprintf("%d",child.run_count),
        "token_generation"=child.token_generation,"configuration_revision"="1","expected_revision"=revision,
        "operation_id"=op,"method"=method,"request_expires_ms"=fmt.tprintf("%d",expires),
        "capability_digest"=contracts.owner_payload_digest(cap),"key_id"="bridge_key","signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
    return encode(c)
}
lease_invoke :: proc(f:^Fixture,raw,cap:string,child:Child,now:i64=1000) -> Result {
    return execute_lease(&f.store,raw,cap,child,f.owner,now,Signer{&f.owner_priv,test_sign})
}
result_cap :: proc(r:Result) -> string {
    v,_:=json.parse_string(r.body,.JSON,true,context.temp_allocator)
    o,_:=v.(json.Object)
    return field(o,"capability")
}
@(test)
lease_claim_heartbeat_replay_and_current_child_scope :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    raw:=lease_request(f,child,"lease.claim","claim","lease","")
    first:=lease_invoke(f,raw,"",child)
    if !testing.expect_value(t,first.code,"ok") do return
    cap:=result_cap(first)
    capdoc,valid:=contracts.owner_parse(cap,"capability")
    testing.expect(t,valid && contracts.owner_verify_signature("capability",capdoc,"signature",f.owner))
    testing.expect_value(t,field(capdoc,"instance_id"),child.instance)
    testing.expect_value(t,field(capdoc,"expires_ms"),"901000")
    testing.expect_value(t,field(capdoc,"hard_ms"),"3601000")
    hb:=lease_request(f,child,"lease.heartbeat","heartbeat","lease",cap)
    renewed:=lease_invoke(f,hb,cap,child,1100)
    testing.expect_value(t,renewed.code,"ok")
    replay:=lease_invoke(f,hb,cap,child,LEASE_HARD_MS+2000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==renewed.body,"expired original request replays historical renewal")
    changed:=lease_request(f,child,"lease.heartbeat","heartbeat","lease",cap,"0")
    testing.expect_value(t,lease_invoke(f,changed,cap,child,3000).code,"operation_conflict")
    changed_child:=child;changed_child.epoch="new_epoch"
    testing.expect_value(t,lease_invoke(f,raw,"",changed_child).code,"invalid_scope")
    changed_child=child;changed_child.token_generation=strings.repeat("b",64,context.temp_allocator)
    stale:=lease_request(f,changed_child,"lease.claim","stale","lease2","")
    testing.expect_value(t,lease_invoke(f,stale,"",changed_child).code,"invalid_scope")
    wrong_key:=f.owner;wrong_key.kind="content"
    testing.expect_value(t,execute_lease(&f.store,raw,"",child,wrong_key,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
    _,_=query(f.store.db,"UPDATE local_fleet SET enabled=0,configuration_revision=configuration_revision+1")
    testing.expect_value(t,lease_invoke(f,raw,"",child).code,"invalid_scope")
}
@(test)
lease_uniqueness_restart_and_expiry_retirement :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    raw:=lease_request(f,child,"lease.claim","claim","lease","")
    first:=lease_invoke(f,raw,"",child)
    if !testing.expect_value(t,first.code,"ok") do return
    duplicate:=lease_request(f,child,"lease.claim","other","another","")
    testing.expect_value(t,lease_invoke(f,duplicate,"",child).code,"operation_conflict")
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    replay:=lease_invoke(f,raw,"",child,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    expired_miss:=lease_request(f,child,"lease.claim","expired","other","")
    testing.expect_value(t,lease_invoke(f,expired_miss,"",child,3000).code,"expired")
    testing.expect(t,expire_leases(&f.store,901001))
    before,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    replay=lease_invoke(f,raw,"",child,901002)
    testing.expect(t,replay.code=="ok" && replay.replay)
    after,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    testing.expect_value(t,before[0][0],after[0][0])
    old_hb:=lease_request(f,child,"lease.heartbeat","late","lease",result_cap(first),"2",902000)
    testing.expect_value(t,lease_invoke(f,old_hb,result_cap(first),child,901002).code,"invalid_scope")
    next:=lease_request(f,child,"lease.claim","fresh","lease2","","2",902000)
    testing.expect_value(t,lease_invoke(f,next,"",child,901002).code,"ok")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL")
    testing.expect_value(t,rows[0][0],"1")
}
@(test)
lease_commit_failure_rolls_back_capability_receipt_and_changes :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    raw:=lease_request(f,child,"lease.claim","claim","lease","")
    testing.expect(t,exec(f.store.db,`CREATE TABLE lease_failure(id INTEGER PRIMARY KEY);
      CREATE TABLE lease_failure_ref(id INTEGER REFERENCES lease_failure(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER lease_commit_failure AFTER INSERT ON local_leases BEGIN INSERT INTO lease_failure_ref VALUES(1); END;`))
    testing.expect_value(t,lease_invoke(f,raw,"",child).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM lease_receipt_pins),(SELECT count(*) FROM command_receipts),commit_seq FROM runtime_database")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="3" && rows[0][3]=="3")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER lease_commit_failure"))
    testing.expect_value(t,lease_invoke(f,raw,"",child).code,"ok")
}
@(test)
active_lease_pins_receipts_and_stale_capability_cannot_renew :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    raw:=lease_request(f,child,"lease.claim","claim","lease","")
    first:=lease_invoke(f,raw,"",child)
    if !testing.expect_value(t,first.code,"ok") do return
    cap:=result_cap(first)
    hb:=lease_request(f,child,"lease.heartbeat","hb","lease",cap)
    testing.expect_value(t,lease_invoke(f,hb,cap,child,1100).code,"ok")
    stale:=lease_request(f,child,"lease.heartbeat","stale","lease",cap)
    testing.expect_value(t,lease_invoke(f,stale,cap,child,1200).code,"invalid_scope")
    // Retention must pin active execution evidence even if the periodic expiry
    // worker has not yet run; age alone is never proof of settlement.
    _,ok:=compact_receipts(&f.store,RECEIPT_RETENTION_MS+5000)
    testing.expect(t,ok)
    rows,_:=query(f.store.db,"SELECT count(*) FROM command_receipts WHERE principal_id='instance'")
    testing.expect_value(t,rows[0][0],"2")
    testing.expect(t,expire_leases(&f.store,RECEIPT_RETENTION_MS+5000))
    _,ok=compact_receipts(&f.store,RECEIPT_RETENTION_MS+5001)
    testing.expect(t,ok)
    rows,_=query(f.store.db,"SELECT count(*) FROM command_receipts WHERE principal_id='instance'")
    testing.expect_value(t,rows[0][0],"0")
}

@(test)
lease_renewal_caps_at_original_hard_deadline :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    r:=lease_invoke(f,lease_request(f,child,"lease.claim","claim","lease",""),"",child)
    if !testing.expect_value(t,r.code,"ok") do return
    cap:=result_cap(r)
    for i in 1..=4 {
        now:=i64(1000+i*14*60*1000)
        raw:=lease_request(f,child,"lease.heartbeat",fmt.tprintf("renew%d",i),"lease",cap,"2",now+1000)
        r=lease_invoke(f,raw,cap,child,now)
        if !testing.expect_value(t,r.code,"ok") do return
        cap=result_cap(r)
    }
    o,_:=contracts.owner_parse(cap,"capability")
    testing.expect_value(t,field(o,"expires_ms"),"3601000")
    testing.expect_value(t,field(o,"hard_ms"),"3601000")
    late:=lease_request(f,child,"lease.heartbeat","too_late","lease",cap,"2",3602000)
    testing.expect_value(t,lease_invoke(f,late,cap,child,3601000).code,"expired")
}
@(test)
fleet_receipt_replays_after_child_exit_and_cross_task_holder_is_unique :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    payload:=encode(doc(map[string]string{"instance_id"="instance","configuration_revision"="1","enabled"="1"}))
    stored,_:=query(f.store.db,"SELECT configuration_command,configuration_payload FROM local_fleet WHERE chain_id=?","chain")
    fleet_command:=stored[0][0]
    // No child proof is needed to read a historical device-authorized receipt.
    replay:=invoke(f,fleet_command,stored[0][1],3000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    first:=lease_request(f,child,"lease.claim","claim","lease","")
    testing.expect_value(t,lease_invoke(f,first,"",child).code,"ok")
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"second"),"body_cipher"=cipher(f,"second")}))
    testing.expect_value(t,invoke(f,command(f,"task.create","second","task2",p,"3"),p).code,"ok")
    c:=command(f,"fleet.edit","fleet2","task2",payload,"1")
    testing.expect_value(t,execute(&f.store,c,payload,f.genesis,f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
    raw:=lease_request(f,child,"lease.claim","second_claim","lease2","")
    o,_:=contracts.owner_parse(raw,"lease_command");o["task_id"]=json.String("task2")
    sig,_:=test_sign(&f.owner_priv,"lease_command",o);o["signature"]=json.String(sig)
    testing.expect_value(t,lease_invoke(f,encode(o),"",child).code,"operation_conflict")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_leases")
    testing.expect_value(t,rows[0][0],"1")
}

@(test)
lease_historical_replay_survives_new_configuration_for_same_authorized_child :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    raw:=lease_request(f,child,"lease.claim","claim","lease","")
    first:=lease_invoke(f,raw,"",child)
    if !testing.expect_value(t,first.code,"ok") do return
    testing.expect(t,expire_leases(&f.store,901001))
    p:=encode(doc(map[string]string{"instance_id"="instance","configuration_revision"="2","enabled"="1"}))
    c:=command(f,"fleet.edit","new_config","task",p,"2",902000)
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",901002,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
    replay:=lease_invoke(f,raw,"",child,901003)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body,"read scope is independent of retired mutation/config fence")
    miss:=lease_request(f,child,"lease.claim","stale_config","new_lease","","3",902000)
    testing.expect_value(t,lease_invoke(f,miss,"",child,901003).code,"invalid_scope")
}
