#+feature dynamic-literals
package main

import "base:runtime"
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

review_durable_failures:int
review_durable_fail_start :: proc(instance,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    review_durable_failures+=1
    return "the Hub refused the start"
}

// What a Bridge restart does to the matcher: its in-memory back-off is gone.
review_durable_forget :: proc() {
    sync.mutex_lock(&bridge_owner_match_seen_mutex);defer sync.mutex_unlock(&bridge_owner_match_seen_mutex)
    for key in bridge_owner_match_seen do delete(key,runtime.heap_allocator())
    clear(&bridge_owner_match_seen)
}

// The review wakes a matcher run at now plans for the chain.
review_durable_plan :: proc(r:^Review_Test,chain:string,now:i64) -> [dynamic]Owner_Review_Wake {
    ctx:=Owner_Agent_Ctx{request_id=bridge_owner_fresh_id("match"),store=&r.store,key=r.key,kr=&r.kr,now=now}
    out:=make([dynamic]Owner_Review_Wake,context.temp_allocator)
    for d in bridge_owner_match_plan(&ctx,chain,false) do for w in d.wakes do if !w.worker do append(&out,w)
    return out
}

// G2: an owed review never depends on one dispatch. A submit whose dispatch
// was lost (a remote lifecycle submit plans none; a Bridge that died before
// dispatching) gets its reviewers from the matcher once the back-off allows,
// immediately after a restart; a failed reviewer start is retried after the
// back-off, not before; a reviewer already reviewing is not nagged; and a
// remote worker's submit owes its reviewers and runs the matcher.
@(test)
test_owner_owed_reviews_dispatched_durably :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    bridge_owner_review_effects=Owner_Review_Effects{nudge=review_test_nudge,start=review_durable_fail_start};bridge_owner_review_sync_effects=true
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    review_test_nudged=make([dynamic]string,context.temp_allocator)
    review_test_started=make([dynamic]string,context.temp_allocator)
    review_durable_failures=0
    defer {
        bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil
        bridge_owner_review_effects={};bridge_owner_review_sync_effects=false
        review_test_live=nil;review_test_nudged=nil;review_test_started=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-review-durable-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    chain:=fmt.tprintf("chain_durable_%d",time.to_unix_nanoseconds(time.now()))
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("durable reviews",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_durable",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,first,second:=review_test_child("inst_w","agt_w"),review_test_child("inst_a","agt_a"),review_test_child("inst_b","agt_b")
    append(&review_test_live,coord,worker,first,second)
    for m in ([3]owner.Child{worker,first,second}) {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code,"ok")
    }
    // The coordinator's Hub credential (starts use it).
    sync.mutex_lock(&bridge_local_token_mutex)
    saved_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,context.temp_allocator)
    append(&bridge_local_token_records,Bridge_Local_Agent_Token_Record{agent_instance_id="inst_c",role=.Agent,instance_token="token_inst_c"})
    sync.mutex_unlock(&bridge_local_token_mutex)
    defer {sync.mutex_lock(&bridge_local_token_mutex);bridge_local_token_records=saved_records;sync.mutex_unlock(&bridge_local_token_mutex)}

    out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"durable","brief":{{"goal":"Ship durable","acceptance":["Tests pass"]}},"assignee":"agt_w","reviewers":["agt_a","agt_b"]}}`,chain))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","task create: %v",out) do return

    // B stops before the submit.
    for c,i in review_test_live do if c.instance=="inst_b" { ordered_remove(&review_test_live,i);break }
    // The submit plans both reviewers; its dispatch is lost.
    submitted,sctx:=review_test_submit(t,r,worker)
    testing.expectf(t,len(sctx.reviews.wakes)==2,"submit plans both reviewers: %v",submitted)
    testing.expect_value(t,review_test_state(r,task),"in_review")
    // Within the back-off the matcher does not dispatch the same attempt again.
    testing.expect_value(t,len(review_durable_plan(r,chain,time.to_unix_nanoseconds(time.now())/1000000)),0)

    // Bridge restart: the matcher finds the owed review and dispatches it.
    review_durable_forget()
    wakes:=review_durable_plan(r,chain,time.to_unix_nanoseconds(time.now())/1000000)
    testing.expectf(t,len(wakes)==2,"after a restart both owed reviewers are planned: %v",wakes)
    actions:=map[string]Owner_Review_Action{}
    for w in wakes do actions[w.agent]=w.action
    testing.expect(t,actions["agt_a"]==.Nudge && actions["agt_b"]==.Start,"the live reviewer is woken, the stopped one started")
    clear(&review_test_nudged)
    plans:=make([dynamic]Owner_Review_Dispatch,context.temp_allocator)
    {
        ctx:=Owner_Agent_Ctx{request_id="match",store=&r.store,key=r.key,kr=&r.kr,now=time.to_unix_nanoseconds(time.now())/1000000}
        review_durable_forget()
        plans=bridge_owner_match_plan(&ctx,chain,false)
    }
    for d in plans do bridge_owner_review_dispatch(d)
    testing.expect_value(t,review_durable_failures,1)
    testing.expectf(t,len(review_test_nudged)==1 && strings.has_prefix(review_test_nudged[0],"inst_a") && strings.contains(review_test_nudged[0],task),"reviewer A woken: %v",review_test_nudged)

    // The failed start is not retried within the back-off...
    testing.expect_value(t,len(review_durable_plan(r,chain,time.to_unix_nanoseconds(time.now())/1000000)),0)
    // ...A opens its review (it is now reviewing)...
    next,_:=review_test_exec(r,first,"agent.lease.next","{}")
    testing.expectf(t,contracts.owner_string(review_test_data(next),"status")=="granted","reviewer A opens its review: %v",next)

    // ...and after the back-off only B is retried; A, reviewing, is not nagged.
    // (Read-only plan at a later clock: nothing is written after this.)
    later:=review_durable_plan(r,chain,time.to_unix_nanoseconds(time.now())/1000000+BRIDGE_OWNER_MATCH_RETRY_MS+1000)
    testing.expectf(t,len(later)==1 && later[0].agent=="agt_b" && later[0].action==.Start,"the failed start is retried after the back-off: %v",later)
}

// G2: a remote worker's submit (the G1 agent-verb path) owes its reviewers
// their review leases and runs the matcher for the chain.
@(test)
test_owner_remote_submit_dispatches_reviews :: proc(t:^testing.T) {
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
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-remote-submit-review-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)
    chain:=fmt.tprintf("chain_remote_submit_%d",time.to_unix_nanoseconds(time.now()))
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("remote submit",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_remote_submit",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,reviewer:=review_test_child("inst_remote_w","agt_w"),review_test_child("inst_a","agt_a")
    append(&review_test_live,coord,worker,reviewer)
    for m in ([2]owner.Child{worker,reviewer}) {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code,"ok")
    }
    out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"remote","brief":{{"goal":"Ship remote","acceptance":["Tests pass"]}},"assignee":"agt_w","reviewers":["agt_a"]}}`,chain))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","task create: %v",out) do return
    next,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    lease,_:=review_test_data(next)["lease"].(json.Object)
    st,_,_:=owner.agent_task_state(&r.store,chain,task)
    configuration:=st.configuration_revision if st.configuration_revision!="" else "1"
    run :: proc(r:^Review_Test,child:owner.Child,chain,task,lease,configuration,method,params:string,f:^Owner_Executor_Child_Followup) -> json.Object {
        raw:=bridge_owner_json(map[string]string{"protocol_version"="1","chain_id"=chain,"task_id"=task,"lease_id"=lease,"configuration_revision"=configuration,"method"=method,"params"=params})
        input,_:=contracts.executor_parse(raw,"agent_verb")
        result:owner.Result
        _=json.unmarshal_string(bridge_owner_executor_child_verb(&r.store,input,child,r.key,&r.kr,f),&result,.JSON,context.temp_allocator)
        return bridge_owner_result_object(result.body)
    }
    f:Owner_Executor_Child_Followup
    _=run(r,worker,chain,task,contracts.owner_string(lease,"lease_id"),configuration,"agent.lease.heartbeat",fmt.tprintf(`{{"acknowledge_requirements_revision":"%s"}}`,contracts.owner_string(lease,"requirements_revision")),&f)
    f={}
    submitted:=run(r,worker,chain,task,contracts.owner_string(lease,"lease_id"),configuration,"agent.lease.submit",`{"summary":"remote tests pass"}`,&f)
    testing.expectf(t,review_test_ok(submitted),"remote submit: %v",submitted)
    testing.expect_value(t,review_test_state(r,task),"in_review")
    testing.expectf(t,len(f.reviews.wakes)==1 && f.reviews.wakes[0].agent=="agt_a" && f.match_chain==chain,"the remote submit owes its reviewer and runs the matcher: %v",f)
    bridge_owner_review_dispatch(f.reviews)
    testing.expectf(t,len(review_test_nudged)==1 && strings.has_prefix(review_test_nudged[0],"inst_a"),"reviewer woken: %v",review_test_nudged)

    // The reviewer runs on another Bridge: its review.post is relayed here
    // and, like a local one, runs the matcher for the chain (the task is
    // ready again for its worker).
    relayed:=review_test_ctx(r,review_test_child("inst_b_reviewer","agt_a"))
    params:=bridge_owner_params(fmt.tprintf(`{{"task_id":"%s","verdict":"request_changes","summary":"the zero case crashes"}}`,task))
    response,refused:=bridge_owner_remote_agent_exec(&relayed,"agent.review.post",params,"brg_b")
    testing.expectf(t,refused=="" && bridge_owner_response_ok(response),"relayed review.post: %s %s",refused,response)
    testing.expect_value(t,review_test_state(r,task),"ready")
    after:=bridge_owner_remote_agent_followup(&relayed,"agent.review.post",params,response)
    testing.expect_value(t,after.match_chain,chain)
    refused_after:=bridge_owner_remote_agent_followup(&relayed,"agent.review.post",params,bridge_local_response_error("x","invalid_scope","no"))
    testing.expect_value(t,refused_after.match_chain,"")
}
