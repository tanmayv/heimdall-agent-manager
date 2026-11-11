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

matcher_test_store:^owner.Store
matcher_test_blocked:[dynamic]string

matcher_test_start_fails :: proc(instance,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    append(&review_test_started,fmt.tprintf("%s %s %s",instance,agent,rec.agent_instance_id))
    return "HTTP 409: agent archived"
}
matcher_test_block :: proc(task,agent,failure:string) -> bool {
    append(&matcher_test_blocked,fmt.tprintf("%s %s",task,agent))
    st,_,_:=owner.agent_task_state(matcher_test_store,"",task)
    blocked,_:=owner.block_agent_not_running(matcher_test_store,st.chain_id,task,agent,fmt.tprintf("Agent %s is not running: %s",agent,failure),time.to_unix_nanoseconds(time.now())/1000000)
    return blocked
}

// M1 item 1 (origin/main pick_instance, for an assigned task): the matcher
// wakes the live worker of a ready task; a periodic run backs off while a
// forced (event) run wakes again; a stopped worker is restarted with the
// coordinator's credential and then woken; a worker that cannot be started
// blocks its task agent_not_running (item 5), which leaves the matcher's
// targets. A leased task and a solo (coordinator) task are never targets.
@(test)
test_owner_matcher_wakes_restarts_or_blocks_the_assigned_worker :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    bridge_owner_review_effects=Owner_Review_Effects{nudge=review_test_nudge,start=review_test_start,block=matcher_test_block};bridge_owner_review_sync_effects=true
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    review_test_nudged=make([dynamic]string,context.temp_allocator)
    review_test_started=make([dynamic]string,context.temp_allocator)
    matcher_test_blocked=make([dynamic]string,context.temp_allocator)
    defer {
        bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil
        bridge_owner_review_effects={};bridge_owner_review_sync_effects=false
        review_test_live=nil;review_test_nudged=nil;review_test_started=nil;matcher_test_blocked=nil;matcher_test_store=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-matcher-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    matcher_test_store=&r.store
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    // The coordinator's Hub credential (starts use it). Unique ids: the token
    // records are process-global.
    coord_instance:=fmt.tprintf("inst_mc_%d",time.to_unix_nanoseconds(time.now()))
    {
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        append(&bridge_local_token_records,Bridge_Local_Agent_Token_Record{token_hash="hash_mc",agent_instance_id=strings.clone(coord_instance,context.allocator),instance_token="token_mc",run_count=1,role=.Agent})
    }
    defer {
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        for i:=len(bridge_local_token_records)-1;i>=0;i-=1 do if bridge_local_token_records[i].agent_instance_id==coord_instance { ordered_remove(&bridge_local_token_records,i);break }
    }

    chain:="chain_matcher"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("matcher chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_matcher",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by=coord_instance).code,"ok") do return
    coord:=review_test_child(coord_instance,"agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,coord_instance,now).code,"ok") do return
    worker,other:=review_test_child("inst_mw","agt_w"),review_test_child("inst_mo","agt_o")
    append(&review_test_live,coord,worker,other)
    for m in ([2]owner.Child{worker,other}) {
        ctx:=review_test_ctx(r,coord)
        joined:=bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code
        testing.expectf(t,joined=="ok","%s joins the chain: %s",m.agent_id,joined)
    }
    create :: proc(t:^testing.T,r:^Review_Test,coord:owner.Child,chain,title,assignee:string) -> string {
        out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"%s","brief":{{"goal":"Ship %s","acceptance":["Tests pass"]}},"assignee":"%s"}}`,chain,title,title,assignee))
        task:=contracts.owner_string(review_test_data(out),"task_id")
        testing.expectf(t,task!="","task %s created: %v",title,out)
        return task
    }
    plan :: proc(r:^Review_Test,chain:string,force:bool) -> []Owner_Review_Wake {
        wakes:=make([dynamic]Owner_Review_Wake,context.temp_allocator)
        for d in bridge_owner_match_plan(&r.store,chain,force,time.to_unix_nanoseconds(time.now())/1000000) {
            for w in d.wakes do append(&wakes,w)
            bridge_owner_review_dispatch(d)
        }
        return wakes[:]
    }
    task:=create(t,r,coord,chain,"live","agt_w")
    solo:=create(t,r,coord,chain,"solo","agt_c")
    if task=="" || solo=="" do return

    // Live worker: woken with the work line; the solo task is never a target.
    wakes:=plan(r,chain,false)
    if !testing.expectf(t,len(wakes)==1,"one wake (solo tasks are pulled by the coordinator): %v",wakes) do return
    testing.expect(t,wakes[0].action==.Nudge && wakes[0].worker && wakes[0].instance==worker.instance && wakes[0].task==task)
    testing.expectf(t,len(review_test_nudged)==1 && strings.contains(review_test_nudged[0],task) && strings.contains(review_test_nudged[0],"lease next"),"the worker is told to lease: %v",review_test_nudged)
    // A periodic run backs off; an event run wakes again.
    testing.expect_value(t,len(plan(r,chain,false)),0)
    testing.expect_value(t,len(plan(r,chain,true)),1)

    // A leased task is not a target.
    granted,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    lease,_:=review_test_data(granted)["lease"].(json.Object)
    testing.expectf(t,contracts.owner_string(lease,"task_id")==task,"the worker leases its task: %v",granted)
    testing.expect_value(t,len(plan(r,chain,true)),0)
    submitted,_:=review_test_submit(t,r,worker)
    testing.expectf(t,review_test_state(r,task)=="done","no reviewer: done on submit: %v",submitted)

    // Stopped worker: restarted with the coordinator's credential, then woken.
    second:=create(t,r,coord,chain,"stopped","agt_w")
    if second=="" do return
    for i:=len(review_test_live)-1;i>=0;i-=1 do if review_test_live[i].instance==worker.instance do ordered_remove(&review_test_live,i)
    clear(&review_test_nudged)
    wakes=plan(r,chain,true)
    if !testing.expectf(t,len(wakes)==1 && wakes[0].action==.Start && wakes[0].task==second,"the stopped worker is started: %v",wakes) do return
    testing.expectf(t,len(review_test_started)==1 && strings.contains(review_test_started[0],coord_instance),"started with the coordinator's credential: %v",review_test_started)
    testing.expectf(t,len(review_test_nudged)==1 && strings.contains(review_test_nudged[0],second),"then woken: %v",review_test_nudged)

    // Unstartable worker: the task is blocked agent_not_running and leaves the
    // matcher's targets.
    for i:=len(review_test_live)-1;i>=0;i-=1 do if review_test_live[i].instance==worker.instance do ordered_remove(&review_test_live,i)
    bridge_owner_review_effects.start=matcher_test_start_fails
    wakes=plan(r,chain,true)
    testing.expectf(t,len(wakes)==1 && wakes[0].action==.Start,"one start attempt: %v",wakes)
    testing.expectf(t,len(matcher_test_blocked)==1 && strings.has_prefix(matcher_test_blocked[0],second),"the task is blocked: %v",matcher_test_blocked)
    rows,_:=owner.query(r.store.db,"SELECT mode,waiting_on FROM local_controls WHERE chain_id=? AND task_id=?",chain,second)
    testing.expectf(t,len(rows)==1 && rows[0][0]=="blocked" && rows[0][1]=="agent_not_running","blocked waiting on agent_not_running: %v",rows)
    testing.expect_value(t,len(plan(r,chain,true)),0)
}
