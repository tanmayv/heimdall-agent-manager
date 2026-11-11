#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

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

// Cross-Bridge placement end to end on the owner side (task_18e6bd3b4d699669):
// the chain's coordinator (not a device) reserves the task on executor Bridge
// B and pairs the reserved remote author with a reviewer; B's executor
// prepares and commits, the owner bootstraps, and B's child works the task
// over the signed child channel (agent.owner_local.lease ->
// execution_child): requirements, heartbeat-free submit, and the review is
// then owed to the paired reviewer.
@(test)
owner_execution_coordinator_placed_remote_worker_leases_submits_and_owes_review :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=new(Execution_Test);x.owner=fixture(t);f:=x.owner
    x.path=fmt.aprintf("%s.executor",f.path)
    defer execution_test_destroy(x)
    x.host_key=f.creator;x.host_key.kind="bridge";x.host_key.principal_id="executor";x.host_key.key_id="operator"
    seed(t,f);remote_test_policy(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    reviewer:=lifecycle_reviewer();agent_seat(t,f,reviewer,"reviewer")
    // fleet.reserve signed for the coordinator (agent mode), no device.
    payload:=remote_test_payload(f,x.host_key,remote_test_config(x.host_key))
    reserve:=agent_command(f,coord,"fleet.reserve","coord_reserve","task",payload,agent_task_revision(f,"task"))
    if !testing.expect_value(t,execute_agent(&f.store,reserve,payload,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},remote_key=x.host_key).code,"ok") do return
    if !testing.expect(t,executor.open(&x.host,x.path,"account","executor","operator")) do return
    policy:=execution_test_document("policy")
    testing.expect_value(t,executor.install_policy(&x.host,execution_test_signed(f,policy,"policy",true),x.host_key,1000).code,"ok")
    p:=execution_test_document("prepare")
    for pair in ([5][2]string{{"owner_bridge_id","bridge"},{"key_id","bridge_key"},{"launch_epoch","epoch"},{"lease_id","lease"},{"hard_ms","3601000"}}) do p[pair[0]]=json.String(pair[1])
    x.prepare=execution_test_signed(f,p,"prepare")
    // Pairing (bridge_owner_remote_configure): the reserved author is the
    // remote child, the reviewer a member here, merge_policy none.
    fleet,_:=query(f.store.db,"SELECT instance_id,launch_epoch,run_count,token_generation FROM local_fleet WHERE chain_id='chain' AND task_id='task'")
    if !testing.expect(t,len(fleet)==1) do return
    author:=Child{fleet[0][0],fleet[0][1],fleet[0][3],number(fleet[0][2]),"author"}
    config:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"=reviewer.agent_id,
        "reviewer_instance_id"=reviewer.instance,"directory_id"="owner_none","merge_policy"="none","repository"="",
        "worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    configure:=agent_command(f,coord,"lifecycle.configure","coord_config","task",config,agent_task_revision(f,"task"))
    if !testing.expect_value(t,execute_agent(&f.store,configure,config,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{author,reviewer,true}).code,"ok") do return
    lifecycle_edit(t,f,"1",agent_task_revision(f,"task"))
    rev:=agent_task_revision(f,"task")
    x.lease=lease_request(f,lease_child(),"lease.claim","claim","lease","",rev)
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    if !testing.expect_value(t,execution_test_commit(x).code,"ok") do return
    claim:=execution_test_claim(t,f)
    snapshot:=execution_bootstrap(&f.store,claim,"Worker","","[]",f.owner,1200,{&f.owner_priv,execution_test_sign})
    if !testing.expect_value(t,snapshot.code,"ok") do return
    bundle,_:=contracts.owner_content_document(snapshot.body);o,_:=bundle.(json.Object)
    b,_:=contracts.executor_parse(field(o,"bootstrap"),"bootstrap")
    caps,_:=query(f.store.db,"SELECT capability_json FROM local_leases WHERE lease_id='lease'")
    if !testing.expect(t,len(caps)==1,"the remote child holds the task's lease") do return
    cap:=caps[0][0]
    ack:=`{"requirements_revision":"1"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","present",ack,cap,rev,{},1200).code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.ack","ack",ack,cap,rev,{},1200).code,"ok")
    submit:=`{"requirements_revision":"1","head":"","summary":"Checks pass"}`
    input:=encode(contracts.Owner_Lifecycle_Input{"1","chain","task","lease","1",rev,"remote_submit","lease.submit","2000",cap,submit})
    request:=execution_child_test_request(x,b,input,1300)
    // Another executor key (another Bridge) cannot speak for B's child.
    stranger:=x.host_key;stranger.key_id="other_operator";stranger.principal_id="other_executor"
    _,forged:=execution_child(&f.store,request,input,stranger,f.owner,1300)
    testing.expect(t,!forged,"only the reserved executor's key attests its child")
    child,valid:=execution_child(&f.store,request,input,x.host_key,f.owner,1300)
    if !testing.expect(t,valid) do return
    testing.expect_value(t,encode(child),encode(author))
    raw:=lifecycle_raw(f,child,"lease.submit","remote_submit",submit,cap,rev)
    if !testing.expect_value(t,execute_lifecycle(&f.store,raw,submit,cap,child,f.owner,1300,{&f.owner_priv,test_sign},{"",true}).code,"ok") do return
    state,_:=query(f.store.db,"SELECT state FROM lifecycle_state WHERE chain_id='chain' AND task_id='task'")
    testing.expectf(t,len(state)==1 && state[0][0]=="in_review","the remote submission is in review: %v",state)
    _,task,found,ok:=review_pending(&f.store,reviewer)
    testing.expectf(t,ok && found && task=="task","the paired reviewer owes the review (found=%v task=%s)",found,task)
    _,_,coord_owes,_:=review_pending(&f.store,coord)
    testing.expect(t,!coord_owes,"the coordinator never reviews its own chain")
    // The reviewer runs on Bridge B too and reviews over the agent relay
    // (owner_remote_agent.odin): the owner admitted B's key and trusts the
    // relayed reviewer by agent id (user decision 2026-11-11). Its launch on B
    // is not the paired child here, so without the relay it is refused.
    remote_reviewer:=Child{"b_review_instance","b_review_epoch",strings.repeat("e",64,context.temp_allocator),1,reviewer.agent_id}
    verdict:=lifecycle_verdict()
    rev=agent_task_revision(f,"task")
    testing.expect_value(t,lifecycle_call(f,remote_reviewer,"review.open","b_open_local",verdict,"",rev,{},1400).code,"invalid_scope")
    f.store.relayed_from="bridge_b"
    defer f.store.relayed_from=""
    // Relayed: the author, the coordinator, a stranger and every non-review
    // verb stay refused.
    for impostor in ([3]Child{{"b_author","b_epoch",strings.repeat("e",64,context.temp_allocator),1,"author"},
        {"b_coord","b_epoch",strings.repeat("e",64,context.temp_allocator),1,coord.agent_id},agent_stranger()}) {
        testing.expect_value(t,lifecycle_call(f,impostor,"review.open","b_open_impostor",verdict,"",rev,{},1400).code,"invalid_scope")
    }
    testing.expect_value(t,lifecycle_call(f,remote_reviewer,"requirements.ack","b_ack",`{"requirements_revision":"1"}`,cap,rev,{},1400).code,"invalid_scope")
    opened:=lifecycle_call(f,remote_reviewer,"review.open","b_open",verdict,"",rev,{},1400)
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,lifecycle_call(f,remote_reviewer,"review.post","b_post",verdict,result_cap(opened),rev,{},1400).code,"ok")
    reviews,_:=query(f.store.db,"SELECT verdict FROM local_reviews WHERE chain_id='chain' AND task_id='task' AND reviewer_agent_id=? AND principal_kind='agent'",reviewer.agent_id)
    testing.expectf(t,len(reviews)==1 && reviews[0][0]=="approve","the relayed reviewer's verdict is recorded: %v",reviews)
}
