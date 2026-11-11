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

// task_18e6b219bcee55fa #9/#10: a coordinator assigning a task to an agent
// whose fleet policy names another account Bridge gets a placement for that
// Bridge (reserved after the locks, owner_remote_place.odin) instead of
// "not running on this Bridge"; no local fleet row is written for it. An
// agent placed here still needs a live child, and a remote placement needs
// a concrete provider and model (the consent binds them).
@(test)
test_owner_remote_assignee_is_placed_on_its_fleet_bridge :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    defer {bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil;review_test_live=nil}
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-remote-place-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=9
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    chain:="chain_remote_place"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("remote chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_remote_place",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    reviewer:=review_test_child("inst_a","agt_a")
    append(&review_test_live,coord,reviewer)
    {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,reviewer.instance,reviewer.agent_id,"worker",true,reviewer).code,"ok")
    }
    fleet_set :: proc(r:^Review_Test,coord:owner.Child,chain,extra:string) -> (json.Object,bool) {
        out,ctx:=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s"%s}}`,chain,extra))
        return out,ctx.launch.active
    }
    placed,launched:=fleet_set(r,coord,chain,`,"agent_id":"agt_r","bridge_id":"bridge_b","provider":"claude","model":"claude-sonnet-5-5"`)
    note:=contracts.owner_string(review_test_data(placed),"note")
    testing.expectf(t,!launched && strings.contains(note,"bridge_b"),"the placement is recorded, nothing launched here: %v",placed)
    _,bare_launched:=fleet_set(r,coord,chain,`,"agent_id":"agt_n","bridge_id":"bridge_b"`)
    testing.expect(t,!bare_launched,"a policy for another Bridge never launches here")
    // A policy on this Bridge plans a local launch (not run in this test).
    _,local_launched:=fleet_set(r,coord,chain,`,"agent_id":"agt_l","bridge_id":"bridge"`)
    testing.expect(t,local_launched,"a policy on this Bridge launches here")

    brief:=`"brief":{"goal":"Ship it","acceptance":["Tests pass"]}`
    out,ctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"remote",%s,"assignee":"agt_r","reviewers":["agt_a"]}}`,chain,brief))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","create with a remote assignee succeeds before placement: %v",out) do return
    testing.expect(t,ctx.remote.active,"the placement runs after the locks")
    testing.expect_value(t,ctx.remote.task,task)
    testing.expect_value(t,ctx.remote.agent,"agt_r")
    testing.expect_value(t,ctx.remote.executor_bridge,"bridge_b")
    testing.expect_value(t,ctx.remote.provider,"claude")
    testing.expect_value(t,ctx.remote.model,"claude-sonnet-5-5")
    // A chain with no repository sends no checkout hint (the executor runs
    // in its scratch directory); a git chain sends its repository.
    testing.expect_value(t,ctx.remote.repository,"")
    rows,_:=owner.query(r.store.db,"SELECT count(*) FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
    testing.expectf(t,len(rows)==1 && rows[0][0]=="0","no local fleet row before the reservation: %v",rows)

    // task update --assignee re-places an existing task.
    updated,uctx:=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","assignee":"agt_r","reviewers":["agt_a"]}}`,chain,task))
    testing.expectf(t,bool(updated["ok"].(json.Boolean)),"update with a remote assignee: %v",updated)
    testing.expect(t,uctx.remote.active && uctx.remote.task==task,"update places the same task")

    // No provider/model for the remote Bridge: refused before any task exists.
    refused,rctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"bare",%s,"assignee":"agt_n","reviewers":["agt_a"]}}`,chain,brief))
    testing.expectf(t,!rctx.remote.active && strings.contains(fmt.tprint(refused),"names no provider and model"),"remote placement needs provider and model: %v",refused)
    // A policy on this Bridge still needs a live child here.
    local,lctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"local",%s,"assignee":"agt_l","reviewers":["agt_a"]}}`,chain,brief))
    testing.expectf(t,!lctx.remote.active && strings.contains(fmt.tprint(local),"not a running"),"a local agent without a live child is refused: %v",local)
    // A worker (not the coordinator) never places.
    denied,dctx:=review_test_exec(r,reviewer,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"worker",%s,"assignee":"agt_r","reviewers":["agt_c"]}}`,chain,brief))
    testing.expectf(t,!dctx.remote.active && !bool(denied["ok"].(json.Boolean)),"only the coordinator creates and places: %v",denied)
}

// The Hub's Bridge id -> key routing hint: one key per Bridge, never guessed.
@(test)
test_executor_directory_bridge_key_parse :: proc(t:^testing.T) {
    body:=`{"data":{"owner":"account","root_device_id":"root","head_hash":"h","version":3,"current_epoch":1,"log":[],"devices":[],"bridge_keys":[{"bridge_id":"bridge_a","device_id":"key_a"},{"bridge_id":"bridge_b","device_id":"key_b"}]}}`
    dir,key,ok:=bridge_executor_directory_parse(body,"bridge_b")
    testing.expect(t,ok)
    testing.expect_value(t,key,"key_b")
    testing.expect_value(t,dir.owner,"account")
    testing.expect_value(t,dir.version,i64(3))
    _,_,missing:=bridge_executor_directory_parse(body,"bridge_c")
    testing.expect(t,!missing,"an unknown Bridge has no key")
    ambiguous:=`{"data":{"owner":"account","bridge_keys":[{"bridge_id":"bridge_b","device_id":"key_1"},{"bridge_id":"bridge_b","device_id":"key_2"}]}}`
    _,_,two:=bridge_executor_directory_parse(ambiguous,"bridge_b")
    testing.expect(t,!two,"two current keys for one Bridge are refused")
    old:=`{"data":{"owner":"account","version":3}}`
    _,_,legacy:=bridge_executor_directory_parse(old,"bridge_b")
    testing.expect(t,!legacy,"an older Hub without bridge_keys gives no key")
}
