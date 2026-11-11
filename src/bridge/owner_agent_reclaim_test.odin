#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// M1 item 2: a worker restarted mid-lease (same instance and agent id, new
// launch epoch, run count and token) reclaims its task on lease next without
// coordinator action, and so does a restart before the claim. The earlier
// launch's lease is retired; another agent's instance never takes the task.
// A solo coordinator reclaims its own task after a restart too.
@(test)
test_owner_restarted_worker_reclaims_its_task :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_config.daemon_id;bridge_config.daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    defer {bridge_config.daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil;review_test_live=nil}
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-reclaim-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    chain:="chain_reclaim"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("reclaim chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_reclaim",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,other:=review_test_child("inst_w","agt_w"),review_test_child("inst_o","agt_o")
    append(&review_test_live,coord,worker,other)
    for m in ([2]owner.Child{worker,other}) {
        ctx:=review_test_ctx(r,coord)
        joined:=bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code
        testing.expectf(t,joined=="ok","%s joins the chain: %s",m.agent_id,joined)
    }
    lease_of :: proc(out:json.Object) -> (string,string) {
        lease,_:=review_test_data(out)["lease"].(json.Object)
        return contracts.owner_string(lease,"task_id"),contracts.owner_string(lease,"lease_id")
    }
    relaunch :: proc(child:owner.Child,run:i64) -> owner.Child {
        out:=child
        out.epoch=fmt.tprintf("%s_run%d",child.epoch,run);out.run_count=run
        out.token_generation=contracts.owner_payload_digest(fmt.tprintf("%s_run%d",child.instance,run))
        for &c in review_test_live do if c.instance==child.instance do c=out
        return out
    }

    assigned:=`,"brief":{"goal":"Ship it","acceptance":["Tests pass"]},"assignee":"agt_w"`
    created,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"first"%s}}`,chain,assigned))
    first:=contracts.owner_string(review_test_data(created),"task_id")
    if !testing.expectf(t,first!="","assigned task created: %v",created) do return
    granted,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    task,lease:=lease_of(granted)
    if !testing.expectf(t,task==first && lease!="","the worker leases its task: %v",granted) do return

    // Restart mid-lease: the new launch gets the same task under a new lease;
    // the earlier launch's lease is retired.
    restarted:=relaunch(worker,2)
    again,_:=review_test_exec(r,restarted,"agent.lease.next","{}")
    task2,lease2:=lease_of(again)
    testing.expectf(t,task2==first && lease2!="" && lease2!=lease,"the restarted worker reclaims its task: %v",again)
    old,_:=owner.query(r.store.db,"SELECT retired_seq IS NOT NULL FROM local_leases WHERE lease_id=?",lease)
    testing.expectf(t,len(old)==1 && old[0][0]=="1","the earlier launch's lease is retired: %v",old)
    held,_:=owner.query(r.store.db,"SELECT launch_epoch FROM local_leases WHERE task_id=? AND retired_seq IS NULL",first)
    testing.expectf(t,len(held)==1 && held[0][0]==restarted.epoch,"the live lease fences the new launch: %v",held)
    // Another agent's instance never takes the task over.
    stranger,_:=review_test_exec(r,other,"agent.lease.next","{}")
    testing.expectf(t,contracts.owner_string(review_test_data(stranger),"status")=="none","another agent gets no work: %v",stranger)

    // Restart before the claim: a task assigned to the earlier launch is
    // rebound and leased by the next launch.
    submitted,_:=review_test_submit(t,r,restarted)
    testing.expectf(t,review_test_state(r,first)=="done","no reviewer: done on submit: %v",submitted)
    created,_=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"second"%s}}`,chain,assigned))
    second:=contracts.owner_string(review_test_data(created),"task_id")
    if !testing.expectf(t,second!="","second task created: %v",created) do return
    third:=relaunch(restarted,3)
    claimed,_:=review_test_exec(r,third,"agent.lease.next","{}")
    task3,_:=lease_of(claimed)
    testing.expectf(t,task3==second,"a restart before the claim still gets the task: %v",claimed)

    // Solo: the coordinator works a task itself; after its restart it
    // reclaims that task the same way.
    created,_=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"solo","brief":{{"goal":"Solo","acceptance":["Done"]}},"assignee":"agt_c"}}`,chain))
    solo:=contracts.owner_string(review_test_data(created),"task_id")
    if !testing.expectf(t,solo!="","solo task created: %v",created) do return
    mine,_:=review_test_exec(r,coord,"agent.lease.next","{}")
    task4,_:=lease_of(mine)
    if !testing.expectf(t,task4==solo,"the coordinator leases its own task: %v",mine) do return
    coord2:=relaunch(coord,2)
    back,_:=review_test_exec(r,coord2,"agent.lease.next","{}")
    task5,_:=lease_of(back)
    testing.expectf(t,task5==solo,"the restarted coordinator reclaims its own task: %v",back)
}
