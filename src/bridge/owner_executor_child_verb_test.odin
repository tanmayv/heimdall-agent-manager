#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// G1: a remote (executor-launched) child's ordinary agent verbs, as the owner
// Bridge receives them after execution_child proved the exact child. The
// worker heartbeats, comments and submits on its own task; a verb naming
// another task is refused with a reason and changes nothing.
@(test)
test_owner_executor_child_verbs_scoped_to_own_task :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    bridge_owner_review_effects=Owner_Review_Effects{nudge=review_test_nudge,start=review_test_start};bridge_owner_review_sync_effects=true
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    review_test_nudged=make([dynamic]string,context.temp_allocator)
    review_test_started=make([dynamic]string,context.temp_allocator)
    defer {
        bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil
        bridge_owner_review_effects={};bridge_owner_review_sync_effects=false
        review_test_live=nil;review_test_nudged=nil;review_test_started=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-child-verbs-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    chain:="chain_remote_verbs"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("remote verbs",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_remote_verbs",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker:=review_test_child("inst_remote","agt_w")
    append(&review_test_live,coord,worker)
    {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,worker.instance,worker.agent_id,"worker",true,worker).code,"ok")
    }
    tasks:[2]string
    for title,i in ([2]string{"own","other"}) {
        out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"%s","brief":{{"goal":"Ship %s","acceptance":["Tests pass"]}},"assignee":"agt_w"}}`,chain,title,title))
        tasks[i]=contracts.owner_string(review_test_data(out),"task_id")
        if !testing.expectf(t,tasks[i]!="","task create: %v",out) do return
    }
    // The owner's placement grants the child its lease (the remote child
    // never claims one through this path).
    next,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    lease,_:=review_test_data(next)["lease"].(json.Object)
    own,lease_id,revision:=contracts.owner_string(lease,"task_id"),contracts.owner_string(lease,"lease_id"),contracts.owner_string(lease,"requirements_revision")
    if !testing.expectf(t,own!="" && lease_id!="","worker holds a lease: %v",next) do return
    other:=tasks[1] if own==tasks[0] else tasks[0]
    st,_,_:=owner.agent_task_state(&r.store,chain,own)

    verb :: proc(r:^Review_Test,child:owner.Child,chain,task,lease,configuration,method,params:string,f:^Owner_Executor_Child_Followup) -> (json.Object,string) {
        doc:=map[string]string{"protocol_version"="1","chain_id"=chain,"task_id"=task,"lease_id"=lease,"configuration_revision"=configuration,"method"=method,"params"=params}
        raw:=bridge_owner_json(doc)
        input,valid:=contracts.executor_parse(raw,"agent_verb")
        if !valid do return nil,"invalid agent_verb input"
        result:owner.Result
        if json.unmarshal_string(bridge_owner_executor_child_verb(&r.store,input,child,r.key,&r.kr,f),&result,.JSON,context.temp_allocator)!=nil do return nil,"bad result"
        return bridge_owner_result_object(result.body),result.code
    }
    configuration:=st.configuration_revision if st.configuration_revision!="" else "1"
    f:Owner_Executor_Child_Followup

    hb,code:=verb(r,worker,chain,own,lease_id,configuration,"agent.lease.heartbeat",fmt.tprintf(`{{"acknowledge_requirements_revision":"%s"}}`,revision),&f)
    testing.expect_value(t,code,"ok")
    testing.expectf(t,contracts.owner_string(review_test_data(hb),"acknowledged_requirements_revision")==revision,"remote heartbeat acknowledges: %v",hb)

    commented,_:=verb(r,worker,chain,own,lease_id,configuration,"agent.task.comment",`{"body":"remote progress"}`,&f)
    testing.expectf(t,review_test_ok(commented),"remote comment on its own task: %v",commented)
    shown,_:=verb(r,worker,chain,own,lease_id,configuration,"agent.task.comments","{}",&f)
    testing.expectf(t,strings.contains(bridge_owner_json(shown),"remote progress"),"the comment is on the own task: %v",shown)

    // Cross-task: refused with a reason, nothing written on the other task.
    crossed,_:=verb(r,worker,chain,own,lease_id,configuration,"agent.task.comment",fmt.tprintf(`{{"task_id":"%s","body":"sneaky"}}`,other),&f)
    e,_:=crossed["error"].(json.Object)
    testing.expectf(t,contracts.owner_string(e,"code")=="invalid_scope" && strings.contains(contracts.owner_string(e,"message"),"own task") &&
        strings.contains(contracts.owner_string(e,"message"),other),"cross-task comment refused with a reason: %v",crossed)
    other_read,_:=review_test_exec(r,coord,"agent.task.comments",fmt.tprintf(`{{"task_id":"%s"}}`,other))
    testing.expectf(t,!strings.contains(bridge_owner_json(other_read),"sneaky"),"nothing reached the other task: %v",other_read)
    crossed_chain,_:=verb(r,worker,chain,own,lease_id,configuration,"agent.task.show",`{"chain_id":"chain_elsewhere"}`,&f)
    testing.expectf(t,strings.contains(bridge_owner_json(crossed_chain),"invalid_scope"),"cross-chain read refused: %v",crossed_chain)
    crossed_lease,_:=verb(r,worker,chain,own,lease_id,configuration,"agent.lease.heartbeat",`{"lease_id":"lease_someone_else"}`,&f)
    testing.expectf(t,strings.contains(bridge_owner_json(crossed_lease),"own lease"),"another lease refused: %v",crossed_lease)

    submitted,_:=verb(r,worker,chain,own,lease_id,configuration,"agent.lease.submit",`{"summary":"remote tests pass"}`,&f)
    testing.expectf(t,review_test_ok(submitted),"remote submit: %v",submitted)
    testing.expect_value(t,review_test_state(r,own),"done")
    testing.expect_value(t,review_test_state(r,other),"ready")
    testing.expect_value(t,f.match_chain,chain)
}

review_test_ok :: proc(o:json.Object) -> bool {
    ok,_:=o["ok"].(json.Boolean)
    return bool(ok)
}

// G1 review round 1: a remote worker's `lease next` brings the presented
// requirements, and the executor Bridge rewrites TASK.md before reporting
// success, including after a requirements change. A remote reviewer's
// `lease next` brings the rendered review (written as its TASK.md), and its
// `review post` settles the task. The context never reaches the agent's reply.
@(test)
test_owner_executor_child_lease_next_delivers_context_and_review_post :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    saved_runs:=bridge_cfg().local_endpoint_run_dir
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    bridge_owner_review_effects=Owner_Review_Effects{nudge=review_test_nudge,start=review_test_start};bridge_owner_review_sync_effects=true
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    review_test_nudged=make([dynamic]string,context.temp_allocator)
    review_test_started=make([dynamic]string,context.temp_allocator)
    defer {
        bridge_cfg().daemon_id=old_daemon;bridge_cfg().local_endpoint_run_dir=saved_runs
        bridge_owner_test_signer={};bridge_owner_live_probe=nil
        bridge_owner_review_effects={};bridge_owner_review_sync_effects=false
        review_test_live=nil;review_test_nudged=nil;review_test_started=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-child-context-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    // B's endpoint run dir: TASK.md lands in <runs>/instances/<instance>.
    runs:=fmt.tprintf("%s/runs",r.root)
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/instances",runs))==nil)
    bridge_cfg().local_endpoint_run_dir=runs
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    chain:="chain_remote_context"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("remote context",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_remote_context",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,reviewer:=review_test_child("inst_remote_w","agt_w"),review_test_child("inst_remote_r","agt_a")
    append(&review_test_live,coord,worker,reviewer)
    for m in ([2]owner.Child{worker,reviewer}) {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code,"ok")
    }
    out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"ctx","brief":{{"goal":"Ship the first goal","acceptance":["Tests pass"]}},"assignee":"agt_w","reviewers":["agt_a"]}}`,chain))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","task create: %v",out) do return
    first,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    lease,_:=review_test_data(first)["lease"].(json.Object)
    lease_id:=contracts.owner_string(lease,"lease_id")
    if !testing.expectf(t,lease_id!="","worker holds a lease: %v",first) do return
    st,_,_:=owner.agent_task_state(&r.store,chain,task)
    configuration:=st.configuration_revision if st.configuration_revision!="" else "1"

    // The verb path as B sees it: the owner's reply, then B's delivery.
    remote :: proc(t:^testing.T,r:^Review_Test,child:owner.Child,chain,task,lease,configuration,method,params:string) -> (json.Object,string) {
        raw:=bridge_owner_json(map[string]string{"protocol_version"="1","chain_id"=chain,"task_id"=task,"lease_id"=lease,"configuration_revision"=configuration,"method"=method,"params"=params})
        input,_:=contracts.executor_parse(raw,"agent_verb")
        result:owner.Result
        _=json.unmarshal_string(bridge_owner_executor_child_verb(&r.store,input,child,r.key,&r.kr,nil),&result,.JSON,context.temp_allocator)
        delivered,reason:=bridge_executor_verb_deliver(child.instance,result.body)
        testing.expectf(t,reason=="","%s delivered on B: %s",method,reason)
        md,_:=os.read_entire_file(fmt.tprintf("%s/runs/instances/%s/TASK.md",r.root,child.instance),context.temp_allocator)
        return bridge_owner_result_object(delivered),string(md)
    }
    next,md:=remote(t,r,worker,chain,task,lease_id,configuration,"agent.lease.next","{}")
    testing.expectf(t,contracts.owner_string(review_test_data(next),"status")=="current" && strings.contains(md,"Ship the first goal"),"remote lease next writes TASK.md: %v\n%s",next,md)
    testing.expect(t,!strings.contains(bridge_owner_json(next),"task_context"),"the context is not in the agent's reply")

    // The coordinator changes the requirements: the next remote lease next
    // rewrites TASK.md with them.
    edited,_:=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","brief":{{"goal":"Ship the amended goal","acceptance":["Tests pass"]}}}}`,chain,task))
    testing.expectf(t,review_test_ok(edited),"requirements edit: %v",edited)
    next,md=remote(t,r,worker,chain,task,lease_id,configuration,"agent.lease.next","{}")
    revision:=contracts.owner_string(review_test_data(next)["lease"].(json.Object),"requirements_revision")
    testing.expectf(t,strings.contains(md,"Ship the amended goal") && !strings.contains(md,"Ship the first goal"),"TASK.md carries the amended requirements:\n%s",md)

    hb,_:=remote(t,r,worker,chain,task,lease_id,configuration,"agent.lease.heartbeat",fmt.tprintf(`{{"acknowledge_requirements_revision":"%s"}}`,revision))
    testing.expectf(t,review_test_ok(hb),"acknowledge: %v",hb)
    submitted,_:=remote(t,r,worker,chain,task,lease_id,configuration,"agent.lease.submit",`{"summary":"remote tests pass"}`)
    testing.expectf(t,review_test_ok(submitted),"remote submit: %v",submitted)
    testing.expect_value(t,review_test_state(r,task),"in_review")

    // The remote reviewer: its lease next brings the review as its TASK.md,
    // and its review post settles the task.
    reviewed,review_md:=remote(t,r,reviewer,chain,task,lease_id,configuration,"agent.lease.next","{}")
    testing.expectf(t,contracts.owner_string(review_test_data(reviewed),"status")=="granted" && strings.contains(review_md,"Role: reviewer") && strings.contains(review_md,"remote tests pass"),
        "the reviewer's TASK.md is the submitted review: %v\n%s",reviewed,review_md)
    testing.expect(t,!strings.contains(bridge_owner_json(reviewed),"review_context"),"the review text is not in the agent's reply")
    posted,_:=remote(t,r,reviewer,chain,task,lease_id,configuration,"agent.review.post",fmt.tprintf(`{{"task_id":"%s","verdict":"approve","summary":"looks right"}}`,task))
    testing.expectf(t,review_test_ok(posted),"remote review post: %v",posted)
    testing.expect_value(t,review_test_state(r,task),"done")

    // A delivery that cannot write TASK.md is reported, not a silent success.
    bridge_cfg().local_endpoint_run_dir=""
    bad,reason:=bridge_executor_verb_deliver("",bridge_local_response_data("",`{"review_context":"x"}`))
    testing.expect(t,bad=="" && strings.contains(reason,"run directory"),"no run dir: the delivery is refused with a reason")
}
