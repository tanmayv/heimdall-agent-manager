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

// F2: owner-chain coordinator verbs a New-conversation coordinator hit on .13
// (task-chain propose/publish, task list/publish, task update --title,
// bridge providers) work through the owner Bridge.
@(test)
test_owner_coordinator_verbs_on_an_owner_chain :: proc(t:^testing.T) {
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
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-verbs-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=9
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)
    chain:="chain_verbs"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("verbs chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_verbs",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker:=review_test_child("inst_w","agt_w")
    append(&review_test_live,coord,worker)
    {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,worker.instance,worker.agent_id,"worker",true,worker).code,"ok")
    }
    brief:=`"brief":{"goal":"Ship it","acceptance":["Tests pass"]}`
    ok :: proc(o:json.Object) -> bool { b,_:=o["ok"].(json.Boolean);return bool(b) }
    code :: proc(o:json.Object) -> string { e,_:=o["error"].(json.Object);return contracts.owner_string(e,"code") }
    message :: proc(o:json.Object) -> string { e,_:=o["error"].(json.Object);return contracts.owner_string(e,"message") }
    out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"first",%s,"assignee":"agt_w"}}`,chain,brief))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","create: %v",out) do return

    // (5) task update --title/--description on an assigned (configured) task.
    out,_=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","title":"renamed","description":"new body"}}`,chain,task))
    testing.expectf(t,ok(out),"rename an assigned task: %v",out)
    titles,_:=owner.query(r.store.db,"SELECT title FROM tasks WHERE task_id=?",task)
    testing.expectf(t,len(titles)==1 && titles[0][0]!="",`title stored (sealed): %v`,titles)
    shown,_:=review_test_exec(r,coord,"agent.task.show",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s"}}`,chain,task))
    testing.expectf(t,strings.contains(fmt.tprint(shown),"renamed") || ok(shown),"task show after rename: %v",shown)
    // A started task still cannot be deleted.
    deleted,_:=review_test_exec(r,coord,"agent.task.delete",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s"}}`,chain,task))
    testing.expectf(t,!ok(deleted),"an assigned task is not deleted: %v",deleted)

    // (4) task-chain publish of a published chain is a no-op, not operation_conflict.
    out,_=review_test_exec(r,coord,"agent.task_chain.publish",fmt.tprintf(`{{"chain_id":"%s"}}`,chain))
    testing.expectf(t,ok(out) && contracts.owner_string(review_test_data(out),"already_published")=="1","chain publish is idempotent: %v",out)

    // (2) task publish of a task create published: already_published.
    out,_=review_test_exec(r,coord,"agent.task.publish",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s"}}`,chain,task))
    testing.expectf(t,ok(out) && contracts.owner_string(review_test_data(out),"already_published")=="1","task publish is idempotent: %v",out)
    out,_=review_test_exec(r,coord,"agent.task.publish",fmt.tprintf(`{{"chain_id":"%s","task_id":"task_missing"}}`,chain))
    testing.expect(t,!ok(out))

    // (1) task-chain propose in ham-ctl's shape (no kind, auto-approve default).
    out,_=review_test_exec(r,coord,"agent.task_chain.propose",fmt.tprintf(`{{"chain_id":"%s","auto_approve":true,"tasks":[{{"title":"proposed","goal":"g","acceptance":["a"]}}]}}`,chain))
    testing.expectf(t,ok(out),"auto-approved proposal: %v",out)
    // An unsupported task field is named, not a bare refusal.
    out,_=review_test_exec(r,coord,"agent.task_chain.propose",fmt.tprintf(`{{"chain_id":"%s","tasks":[{{"title":"p","assignee":"agt_w"}}]}}`,chain))
    testing.expectf(t,code(out)=="invalid_content" && strings.contains(message(out),"assignee"),"unsupported field named: %v",out)
    // The skill's proposal shape (assignee/reviewers inside brief) works with
    // member reviewers; a reviewer that is not a chain member is named.
    out,_=review_test_exec(r,coord,"agent.task_chain.propose",fmt.tprintf(`{{"chain_id":"%s","tasks":[{{"id":"t_api","title":"skill","brief":{{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_x"]}}}}]}}`,chain))
    testing.expectf(t,code(out)=="invalid_scope" && strings.contains(message(out),"reviewer agt_x is not an enabled member"),"non-member reviewer named: %v",out)
    out,_=review_test_exec(r,coord,"agent.task_chain.propose",fmt.tprintf(`{{"chain_id":"%s","tasks":[{{"id":"t_api2","title":"skill2","brief":{{"goal":"g","acceptance":["a"],"assignee":"agt_w"}}}}]}}`,chain))
    testing.expectf(t,ok(out),"brief assignee accepted: %v",out)
    // --require-decision keeps it pending; publish then waits for the decision.
    out,_=review_test_exec(r,coord,"agent.task_chain.propose",fmt.tprintf(`{{"chain_id":"%s","require_decision":true,"tasks":[{{"title":"pending","goal":"g","acceptance":["a"]}}]}}`,chain))
    testing.expectf(t,ok(out),"pending proposal: %v",out)
    out,_=review_test_exec(r,coord,"agent.task_chain.publish",fmt.tprintf(`{{"chain_id":"%s"}}`,chain))
    testing.expectf(t,code(out)=="operation_conflict" && strings.contains(message(out),"decision"),"publish waits for the decision: %v",out)
    // A worker cannot propose.
    out,_=review_test_exec(r,worker,"agent.task_chain.propose",fmt.tprintf(`{{"chain_id":"%s","tasks":[{{"title":"w"}}]}}`,chain))
    testing.expectf(t,code(out)=="invalid_scope" && strings.contains(message(out),"coordinator"),"worker refused with a reason: %v",out)

    // (2) task list: the chain's tasks from the owner store.
    out,_=review_test_exec(r,coord,"agent.task.list",fmt.tprintf(`{{"chain_id":"%s"}}`,chain))
    listed,_:=review_test_data(out)["tasks"].(json.Array)
    testing.expectf(t,ok(out) && len(listed)>=2,"task list: %v",out)
    out,_=review_test_exec(r,coord,"agent.task.list","{}")
    listed,_=review_test_data(out)["tasks"].(json.Array)
    testing.expectf(t,ok(out) && len(listed)>=2 && contracts.owner_string(review_test_data(out),"chain_id")==chain,"task list defaults to the caller's chain: %v",out)
    testing.expect(t,bridge_owner_routable("agent.task.list") && bridge_owner_routable("agent.task.publish"),"both route to the owner Bridge")
}

// F2 (3): `bridge providers --bridge <id>` reads the Hub's provider matrix
// for that Bridge (provider-status); `.../providers` is no Hub GET route.
@(test)
test_bridge_providers_routes_to_provider_status :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    r:=bridge_agent_route("agent.bridge.providers",`{"bridge_id":"brg_x"}`)
    testing.expect_value(t,r.kind,Bridge_Agent_Route_Kind.Raw)
    testing.expect_value(t,strings.join(r.path,"/"),"api/v1/bridges/brg_x/provider-status")
    all:=bridge_agent_route("agent.bridge.providers","{}")
    testing.expect_value(t,strings.join(all.path,"/"),"api/v1/bridges")
}
