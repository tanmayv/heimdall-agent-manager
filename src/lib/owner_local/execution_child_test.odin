#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

execution_child_test_request :: proc(x:^Execution_Test,b:json.Object,input:string,now:i64)->string {
    r:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("child_request") do r[entry.name]=b[entry.name]
    digest,_:=contracts.executor_digest("bootstrap",b)
    for pair in ([6][2]string{{"bootstrap_digest",digest},{"input_digest",contracts.owner_payload_digest(input)},
        {"issued_ms",fmt.tprintf("%d",now)},{"request_expires_ms",fmt.tprintf("%d",now+500)},
        {"key_id",x.host_key.key_id},{"signature",strings.repeat("0",128,context.temp_allocator)}}) {r[pair[0]]=json.String(pair[1])}
    return execution_test_signed(x.owner,r,"child_request",true)
}

@(test)
owner_execution_child_uses_native_journal_and_ordinary_capability_replay :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,claim:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    snapshot:=execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,1200,{&f.owner_priv,execution_test_sign})
    if !testing.expect_value(t,snapshot.code,"ok") do return
    bundle,_:=contracts.owner_content_document(snapshot.body);o,_:=bundle.(json.Object)
    b,_:=contracts.executor_parse(field(o,"bootstrap"),"bootstrap")
    caps,_:=query(f.store.db,"SELECT capability_json FROM local_leases WHERE lease_id='lease'")
    input:=encode(contracts.Owner_Lease_Input{"1","chain","task","lease","1","3","remote_hb","lease.heartbeat","2000",caps[0][0]})
    request:=execution_child_test_request(x,b,input,1300)
    before:=fleet_policy_test_state(f)
    child,valid:=execution_child(&f.store,request,input,x.host_key,f.owner,1300)
    if !testing.expect(t,valid) do return
    testing.expect_value(t,encode(child),encode(lease_child()))
    testing.expect(t,fleet_policy_test_state(f)==before,"verifying an executor attestation must not mutate authoritative state")
    command:=lease_request(f,child,"lease.heartbeat","remote_hb","lease",caps[0][0],"3")
    renewed:=execute_lease(&f.store,command,caps[0][0],child,f.owner,1300,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,renewed.code,"ok")
    replay:=execute_lease(&f.store,command,caps[0][0],child,f.owner,1400,{&f.owner_priv,execution_test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==renewed.body)
    // A fresh transport attestation carries the exact expired original input;
    // native receipt replay still precedes fresh mutation expiry checks.
    later:=execution_child_test_request(x,b,input,2100)
    replay_child,current:=execution_child(&f.store,later,input,x.host_key,f.owner,2100)
    testing.expect(t,current)
    replay=execute_lease(&f.store,command,caps[0][0],replay_child,f.owner,2100,{&f.owner_priv,execution_test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==renewed.body)
    fresh:=lease_request(f,child,"lease.heartbeat","new_expired_hb","lease",caps[0][0],"3")
    testing.expect_value(t,lease_invoke(f,fresh,caps[0][0],child,2100).code,"expired")
    counts,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts)")
    testing.expect(t,counts[0][0]=="1" && counts[0][1]=="1","no second task grant or work attempt")
}

@(test)
owner_execution_child_rejects_substitution_revocation_regrant_and_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,claim:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    snapshot:=execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,1200,{&f.owner_priv,execution_test_sign})
    if !testing.expect_value(t,snapshot.code,"ok") do return
    bundle,_:=contracts.owner_content_document(snapshot.body);o,_:=bundle.(json.Object)
    b,_:=contracts.executor_parse(field(o,"bootstrap"),"bootstrap")
    input:=encode(contracts.Owner_Lease_Input{"1","chain","task","lease","1","3","remote_hb","lease.heartbeat","2000","capability"})
    request:=execution_child_test_request(x,b,input,1300)
    _,valid:=execution_child(&f.store,request,input,x.host_key,f.owner,1300);testing.expect(t,valid)
    _,valid=execution_child(&f.store,request,strings.concatenate({input," "},context.temp_allocator),x.host_key,f.owner,1300);testing.expect(t,!valid)
    for pair in ([9][2]string{{"chain_id","other_chain"},{"task_id","other_task"},{"lease_id","other_lease"},
        {"reservation_id","other_reservation"},{"instance_id","other_instance"},{"launch_epoch","other_epoch"},
        {"grant_generation","2"},{"configuration_revision","2"},{"executor_incarnation","2"}}) {
        r,_:=contracts.executor_parse(request,"child_request");r[pair[0]]=json.String(pair[1])
        changed:=execution_test_signed(f,r,"child_request",true)
        _,valid=execution_child(&f.store,changed,input,x.host_key,f.owner,1300)
        testing.expectf(t,!valid,"signed substitution rejected: %s",pair[0])
    }
    revoked:=x.host_key;revoked.revoked=true
    _,valid=execution_child(&f.store,request,input,revoked,f.owner,1300);testing.expect(t,!valid)
    wrong_key:=x.host_key;wrong_key.key_id="other_key"
    _,valid=execution_child(&f.store,request,input,wrong_key,f.owner,1300);testing.expect(t,!valid)
    changed,_:=contracts.owner_parse(input,"lease_input");changed["method"]=json.String("lease.claim")
    regrant:=encode(changed)
    _,valid=execution_child(&f.store,execution_child_test_request(x,b,regrant,1300),regrant,x.host_key,f.owner,1300);testing.expect(t,!valid)
    _,valid=execution_child(&f.store,request,input,x.host_key,f.owner,1800);testing.expect(t,!valid)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    _,valid=execution_child(&f.store,request,input,x.host_key,f.owner,1400);testing.expect(t,!valid,"old owner incarnation is not fresh remote authority")
}


@(test)
owner_execution_child_lost_submit_reply_replays_after_native_lease_retirement :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    config:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer",
        "reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="",
        "worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    configured:=execute(&f.store,command(f,"lifecycle.configure","config","task",config,"2"),config,"",
        f.creator,f.owner,1,"head",1000,&f.kr,{&f.owner_priv,test_sign},{},Lifecycle_Proof{lease_child(),lifecycle_reviewer(),true})
    if !testing.expect_value(t,configured.code,"ok") do return
    lifecycle_edit(t,f,"1","3")
    x.lease=lease_request(f,lease_child(),"lease.claim","claim","lease","","4")
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    if !testing.expect_value(t,execution_test_commit(x).code,"ok") do return
    claim:=execution_test_claim(t,f)
    snapshot:=execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,1200,{&f.owner_priv,execution_test_sign})
    if !testing.expect_value(t,snapshot.code,"ok") do return
    bundle,_:=contracts.owner_content_document(snapshot.body);o,_:=bundle.(json.Object)
    b,_:=contracts.executor_parse(field(o,"bootstrap"),"bootstrap")
    caps,_:=query(f.store.db,"SELECT capability_json FROM local_leases WHERE lease_id='lease'")
    cap:=caps[0][0]
    ack:=`{"requirements_revision":"1"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","present",ack,cap,"4",{},1200).code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.ack","ack",ack,cap,"4",{},1200).code,"ok")
    payload:=`{"requirements_revision":"1","head":"","summary":"Checks pass"}`
    input:=encode(contracts.Owner_Lifecycle_Input{"1","chain","task","lease","1","4","remote_submit","lease.submit","2000",cap,payload})
    request:=execution_child_test_request(x,b,input,1300)
    child,valid:=execution_child(&f.store,request,input,x.host_key,f.owner,1300)
    if !testing.expect(t,valid) do return
    raw:=lifecycle_raw(f,child,"lease.submit","remote_submit",payload,cap,"4")
    submitted:=execute_lifecycle(&f.store,raw,payload,cap,child,f.owner,1300,{&f.owner_priv,test_sign},{"",true})
    if !testing.expect_value(t,submitted.code,"ok") do return
    retired,_:=query(f.store.db,"SELECT retired_seq FROM local_leases WHERE lease_id='lease'")
    testing.expect(t,retired[0][0]!="")
    before:=fleet_policy_test_state(f)
    retry:=execution_child_test_request(x,b,input,2100)
    replay_child,current:=execution_child(&f.store,retry,input,x.host_key,f.owner,2100)
    if !testing.expect(t,current,"a live exact child can still reach its committed submission receipt") do return
    replay:=execute_lifecycle(&f.store,raw,payload,cap,replay_child,f.owner,2100,{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==submitted.body)
    testing.expect_value(t,fleet_policy_test_state(f),before)
    fresh:=lifecycle_raw(f,child,"lease.submit","new_submit",payload,cap,"5")
    testing.expect(t,execute_lifecycle(&f.store,fresh,payload,cap,child,f.owner,2100,{&f.owner_priv,test_sign}).code!="ok")
}
