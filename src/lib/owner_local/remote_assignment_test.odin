#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

remote_test_policy :: proc(t:^testing.T,f:^Fixture) {
    policy:=contracts.Owner_Fleet_Policy{task_chain_id="chain",agent_id="author",capacity=2,
        provider_profile="default",provider="codex",model="model",bridge_id="executor",roles_json=`["worker"]`}
    chain,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"remote_policy",chain[0][0]).code,"ok")
}
remote_test_config :: proc(key:contracts.Owner_Verified_Key)->json.Object {
    p:=execution_test_document("prepare")
    c:=doc(map[string]string{"protocol_version"="1","account_id"="account","owner_bridge_id"="bridge","executor_bridge_id"="executor",
        "executor_key_id"=key.key_id,"chain_id"="chain","task_id"="task","instance_id"="instance","agent_id"="author",
        "launch_epoch"="epoch","run_count"="1","token_generation"=strings.repeat("a",64,context.temp_allocator),
        "configuration_revision"="1","executor_incarnation"="1","policy_revision"="1","slot_id"="slot1",
        "provider_profile"="default","provider"="codex","model"="model","directory_id"="remote_dir",
        "directory_key"=field(p,"directory_key"),"directory_path"="/repo"})
    return c
}
remote_test_payload :: proc(f:^Fixture,key:contracts.Owner_Verified_Key,c:json.Object)->string {
    raw:=encode(c)
    a:=doc(map[string]string{"protocol_version"="1","account_id"=field(c,"account_id"),"executor_bridge_id"=field(c,"executor_bridge_id"),
        "owner_bridge_id"=field(c,"owner_bridge_id"),"chain_id"=field(c,"chain_id"),"task_id"=field(c,"task_id"),
        "instance_id"=field(c,"instance_id"),"configuration_revision"=field(c,"configuration_revision"),
        "configuration_digest"=contracts.owner_payload_digest(raw),"issued_ms"="1000","request_expires_ms"="2000",
        "key_id"=key.key_id,"signature"=strings.repeat("0",128,context.temp_allocator)})
    attestation:=execution_test_signed(f,a,"enrollment",true)
    reservation:=encode(doc(map[string]string{"configuration"=raw,"attestation"=attestation}))
    return encode(doc(map[string]string{"instance_id"=field(c,"instance_id"),"configuration_revision"=field(c,"configuration_revision"),
        "enabled"="1","body_cipher"=cipher(f,reservation)}))
}
remote_test_call :: proc(f:^Fixture,payload,op:string,key:contracts.Owner_Verified_Key,revision:="1",now:i64=1000)->Result {
    c:=command(f,"fleet.reserve",op,"task",payload,revision)
    return execute(&f.store,c,payload,"",f.creator,f.owner,1,"head",now,&f.kr,{&f.owner_priv,test_sign},{},{},nil,key)
}
remote_test_seed :: proc(t:^testing.T,f:^Fixture,key:contracts.Owner_Verified_Key) {
    seed(t,f);remote_test_policy(t,f)
    payload:=remote_test_payload(f,key,remote_test_config(key))
    testing.expect_value(t,remote_test_call(f,payload,"remote_enroll",key).code,"ok")
}

@(test)
remote_assignment_signed_reserve_round_trip_replay_and_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f);remote_test_policy(t,f)
    key:=f.creator;key.kind="bridge";key.principal_id="executor";key.key_id="operator"
    payload:=remote_test_payload(f,key,remote_test_config(key))
    accepted:=remote_test_call(f,payload,"remote_enroll",key)
    if !testing.expect_value(t,accepted.code,"ok") do return
    rows,ok:=query(f.store.db,`SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM owner_execution_journal),
      (SELECT count(*) FROM local_chain_member_versions),payload_json FROM local_assignment_history`)
    testing.expect(t,ok);testing.expect_value(t,rows[0][0],"0");testing.expect_value(t,rows[0][1],"0")
    testing.expect_value(t,rows[0][2],"1")
    snapshot,s_ok:=contracts.owner_parse(rows[0][3],"remote_assignment_snapshot")
    testing.expect(t,s_ok);testing.expect_value(t,field(snapshot,"signed_payload"),payload)
    testing.expect(t,!strings.contains(payload,"/repo") && !strings.contains(payload,"token_generation"))
    before:=fleet_policy_test_state(f)
    replay:=remote_test_call(f,payload,"remote_enroll",key,"1",3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==accepted.body)
    testing.expect_value(t,fleet_policy_test_state(f),before)
    // Exact remote child facts are not local live-child proof. Only the
    // verified host-reservation journal may admit the first remote grant.
    raw:=lease_request(f,lease_child(),"lease.claim","direct","lease","")
    testing.expect_value(t,lease_invoke(f,raw,"",lease_child()).code,"invalid_scope")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    replay=remote_test_call(f,payload,"remote_enroll",key,"1",3000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    testing.expect(t,!exec(f.store.db,"UPDATE local_assignment_history SET payload_json='{}'"))
    testing.expect_value(t,remote_test_call(f,payload,"other_op",key,"2").code,"stale_revision")
}

@(test)
remote_assignment_rejects_unapproved_key_binding_policy_and_changed_bytes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f);remote_test_policy(t,f)
    key:=f.creator;key.kind="bridge";key.principal_id="executor";key.key_id="operator"
    config:=remote_test_config(key);payload:=remote_test_payload(f,key,config)
    before:=fleet_policy_test_state(f)
    for i in 0..<5 {
        wrong:=key
        switch i {case 0:wrong.revoked=true
        case 1:wrong.enrolled=false
        case 2:wrong.kind="device"
        case 3:wrong.principal_id="other_executor"
        case 4:wrong.key_id="other_key"}
        testing.expect_value(t,remote_test_call(f,payload,fmt.tprintf("wrong_%d",i),wrong).code,"invalid_scope")
        testing.expect_value(t,fleet_policy_test_state(f),before)
    }
    for pair in ([7][2]string{{"provider","other"},{"model","other"},{"provider_profile","other"},{"account_id","other"},
        {"owner_bridge_id","other"},{"executor_bridge_id","other"},{"executor_key_id","other"}}) {
        changed:=remote_test_config(key);changed[pair[0]]=json.String(pair[1])
        testing.expect_value(t,remote_test_call(f,remote_test_payload(f,key,changed),fmt.tprintf("config_%s",pair[0]),key).code,"invalid_scope")
    }
    p,_:=contracts.owner_parse(payload,"fleet_reserve_payload")
    opened,_:=vault.open(field(p,"body_cipher"),&f.kr,context.temp_allocator)
    reservation,_:=contracts.owner_parse(opened,"remote_reservation")
    reservation["configuration"]=json.String(fmt.tprintf("%s ",field(reservation,"configuration")))
    p["body_cipher"]=json.String(cipher(f,encode(reservation)))
    testing.expect_value(t,remote_test_call(f,encode(p),"changed_bytes",key).code,"invalid_scope")
    testing.expect_value(t,remote_test_call(f,payload,"expired",key,"1",2000).code,"expired")
    testing.expect_value(t,fleet_policy_test_state(f),before)
}

@(test)
remote_assignment_statement_and_commit_failure_roll_back_enrollment :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f);remote_test_policy(t,f)
    key:=f.creator;key.kind="bridge";key.principal_id="executor";key.key_id="operator"
    payload:=remote_test_payload(f,key,remote_test_config(key));before:=fleet_policy_test_state(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER remote_fail BEFORE INSERT ON local_assignment_history BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,remote_test_call(f,payload,"statement_failure",key).code,"operation_conflict")
    testing.expect_value(t,fleet_policy_test_state(f),before)
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_member_chains");testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER remote_fail; CREATE TABLE remote_parent(id INTEGER PRIMARY KEY); CREATE TABLE remote_ref(id INTEGER REFERENCES remote_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER remote_fail AFTER INSERT ON local_assignment_history BEGIN INSERT INTO remote_ref VALUES(1); END"))
    testing.expect_value(t,remote_test_call(f,payload,"commit_failure",key).code,"storage_error")
    testing.expect_value(t,fleet_policy_test_state(f),before)
    rows,_=query(f.store.db,"SELECT count(*) FROM local_member_chains");testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER remote_fail"))
    testing.expect_value(t,remote_test_call(f,payload,"accepted",key).code,"ok")
}

@(test)
remote_assignment_prepare_revalidates_exact_configuration_and_current_policy :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    for pair in ([6][2]string{{"slot_id","other_slot"},{"provider_profile","other_profile"},{"executor_bridge_id","other_bridge"},
        {"directory_key",strings.repeat("c",64,context.temp_allocator)},{"executor_incarnation","2"},{"policy_revision","2"}}) {
        p,_:=contracts.executor_parse(x.prepare,"prepare");p[pair[0]]=json.String(pair[1])
        testing.expect_value(t,execution_prepare_start(&f.store,execution_test_signed(f,p,"prepare"),x.lease,f.owner,1000).code,"invalid_scope")
    }
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    // A policy edit is future dispatch policy, not an implicit task grant.
    policy:=contracts.Owner_Fleet_Policy{task_chain_id="chain",agent_id="author",capacity=2,
        provider_profile="default",provider="codex",model="model",bridge_id="executor",roles_json=`["worker"]`,paused_roles_json=`["worker"]`}
    current,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"pause_remote",current[0][0]).code,"ok")
    replay:=execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    testing.expect_value(t,execution_test_commit(x).code,"invalid_scope")
    y:=execution_test_fixture(t);defer execution_test_destroy(y)
    testing.expect_value(t,member_call(y.owner,lease_child(),"worker","0","remove_remote").code,"ok")
    testing.expect_value(t,execution_prepare_start(&y.owner.store,y.prepare,y.lease,y.owner.owner,1000).code,"invalid_scope")
}

@(test)
remote_assignment_cannot_relabel_an_observed_local_child_as_remote :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);fleet_seed(t,f,lease_child());remote_test_policy(t,f)
    key:=f.creator;key.kind="bridge";key.principal_id="executor";key.key_id="operator"
    config:=remote_test_config(key);config["configuration_revision"]=json.String("2")
    testing.expect_value(t,remote_test_call(f,remote_test_payload(f,key,config),"cannot_relabel",key,"2").code,"operation_conflict")
}

@(test)
remote_assignment_membership_and_directory_changes_disable_pending_dispatch :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    // The ordinary directory command remains owner-local. Explicitly selecting
    // that ID for a different device invalidates the remote assignment.
    value,valid:=contracts.owner_content_document(directory_body("/other"));d,obj:=value.(json.Object)
    testing.expect(t,valid && obj)
    d["directory_id"]=json.String("remote_dir")
    body:=encode(d)
    p:=encode(doc(map[string]string{"directory_id"="remote_dir","enabled"="1","body_cipher"=cipher(f,body)}))
    chain,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    result:=invoke(f,command(f,"chain.directory.set","replace_directory","",p,chain[0][0]),p)
    if !testing.expect_value(t,result.code,"ok") do return
    rows,_:=query(f.store.db,"SELECT enabled FROM local_fleet WHERE chain_id='chain' AND task_id='task'")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"invalid_scope")
}

@(test)
remote_assignment_preserves_native_defaults_and_enforces_capacity :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    policy:=contracts.Owner_Fleet_Policy{task_chain_id="chain",agent_id="author",capacity=1,model="模型🚀"}
    testing.expect_value(t,fleet_policy_test_call(f,encode(policy),"default_policy","2").code,"ok")
    key:=f.creator;key.kind="bridge";key.principal_id="executor";key.key_id="operator"
    config:=remote_test_config(key);config["model"]=json.String("模型🚀")
    enrollment:=remote_test_payload(f,key,config)
    p,p_ok:=contracts.owner_parse(enrollment,"fleet_reserve_payload")
    plain,_:=vault.open(field(p,"body_cipher"),&f.kr,context.temp_allocator)
    reservation,r_ok:=contracts.owner_parse(plain,"remote_reservation")
    a,a_ok:=contracts.executor_parse(field(reservation,"attestation"),"enrollment")
    testing.expect(t,p_ok && r_ok && a_ok && contracts.executor_enrollment_matches(a,field(reservation,"configuration"),key,1000),"Unicode exact configuration attestation")
    testing.expect(t,remote_assignment_policy(&f.store,config),"native default policy matching")
    testing.expect_value(t,remote_test_call(f,enrollment,"first_slot",key).code,"ok")
    payload:=encode(doc(map[string]string{"title_cipher"=cipher(f,"second"),"body_cipher"=cipher(f,"second body")}))
    chain,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    testing.expect_value(t,invoke(f,command(f,"task.create","second_task","second",payload,chain[0][0]),payload).code,"ok")
    config["task_id"]=json.String("second");config["instance_id"]=json.String("second_instance")
    config["launch_epoch"]=json.String("second_epoch");config["slot_id"]=json.String("slot2")
    payload=remote_test_payload(f,key,config)
    command_raw:=command(f,"fleet.reserve","over_capacity","second",payload,"1")
    testing.expect_value(t,execute(&f.store,command_raw,payload,"",f.creator,f.owner,1,"head",1000,&f.kr,{&f.owner_priv,test_sign},{},{},nil,key).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_assignment_history")
    testing.expect_value(t,rows[0][0],"1")
}
