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

    // No provider/model for the remote Bridge and none in the catalog:
    // refused before any task exists.
    retired:=[]Bridge_Catalog_Provider{{provider="codex",state="retired",models=[]Bridge_Catalog_Model{{model_id="gpt-5.5",state="active"}}}}
    bridge_provider_catalog_default_hook=retired;defer bridge_provider_catalog_default_hook=nil
    refused,rctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"bare",%s,"assignee":"agt_n","reviewers":["agt_a"]}}`,chain,brief))
    testing.expectf(t,!rctx.remote.active && strings.contains(fmt.tprint(refused),"nor the provider catalog names a provider and model"),"remote placement needs provider and model: %v",refused)
    // Gap 4: the catalog fills them like origin/main resolve_launch_model
    // (first active provider, its first active model).
    catalog:=[]Bridge_Catalog_Provider{
        {provider="claude",state="retired",models=[]Bridge_Catalog_Model{{model_id="claude-old",state="active"}}},
        {provider="codex",state="active",models=[]Bridge_Catalog_Model{{model_id="gpt-old",state="retired"},{model_id="gpt-5.5",state="active"}}},
    }
    bridge_provider_catalog_default_hook=catalog
    filled,fctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"catalog",%s,"assignee":"agt_n","reviewers":["agt_a"]}}`,chain,brief))
    testing.expectf(t,bool(filled["ok"].(json.Boolean)) && fctx.remote.active,"catalog default placed: %v",filled)
    testing.expectf(t,fctx.remote.provider=="codex" && fctx.remote.model=="gpt-5.5","catalog default model: %s/%s",fctx.remote.provider,fctx.remote.model)
    bridge_provider_catalog_default_hook=nil
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

// Per-task run Bridge (task_18e6b7c86af8423e): a task runs on the owner
// Bridge by default; --bridge <B> pins it (kept in the brief as
// run_bridge_id) and its assignee is placed on B with the fleet row's
// per-Bridge provider/model, even when a member of the agent runs here;
// --bridge "" (or the owner Bridge) returns it to the default; a pin needs a
// brief; moving a configured task re-places its worker; an unknown Bridge is
// refused before anything runs.
@(test)
test_owner_task_run_bridge_default_override_and_placement :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    defer {bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil;review_test_live=nil;bridge_owner_run_bridge_check_hook=nil}
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-run-bridge-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=9
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)
    chain:="chain_run_bridge"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("run bridge chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_run_bridge",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,reviewer:=review_test_child("inst_w","agt_w"),review_test_child("inst_a","agt_a")
    append(&review_test_live,coord,worker,reviewer)
    for m in ([2]owner.Child{worker,reviewer}) {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code,"ok")
    }
    // agt_w: claude here, codex on bridge_b (fleet set --bridge-models).
    models:=`{\"bridge_b\":{\"provider_profile\":\"\",\"provider\":\"codex\",\"model\":\"gpt-5.5\"}}`
    row,_:=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_w","provider":"claude","model":"claude-sonnet-5-5","bridge_models_json":"%s"}}`,chain,models))
    testing.expectf(t,bool(row["ok"].(json.Boolean)),"fleet row with per-Bridge models: %v",row)
    run_bridge :: proc(r:^Review_Test,chain,task:string) -> (string,bool) {
        st,_,_:=owner.agent_task_state(&r.store,chain,task)
        return bridge_owner_brief_run_bridge(st.brief)
    }
    brief:=`"brief":{"goal":"Ship it","acceptance":["Tests pass"]}`

    // Default: the owner Bridge; the local member is assigned.
    out,ctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"here",%s,"assignee":"agt_w","reviewers":["agt_a"]}}`,chain,brief))
    here:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,here!="","default create: %v",out) do return
    testing.expect_value(t,contracts.owner_string(review_test_data(out),"run_bridge_id"),"bridge")
    testing.expect(t,!ctx.remote.active,"runs here")
    _,pinned:=run_bridge(r,chain,here)
    testing.expect(t,!pinned,"no pin recorded for the default")
    // --bridge naming the owner Bridge is the default too.
    out,ctx=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"here2",%s,"assignee":"agt_w","reviewers":["agt_a"],"bridge_id":"bridge"}}`,chain,brief))
    testing.expectf(t,contracts.owner_string(review_test_data(out),"run_bridge_id")=="bridge" && !ctx.remote.active,"--bridge <owner> runs here: %v",out)

    // Override: pinned to bridge_b, placed there with codex although agt_w runs here.
    out,ctx=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"there",%s,"assignee":"agt_w","reviewers":["agt_a"],"bridge_id":"bridge_b"}}`,chain,brief))
    there:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,there!="","pinned create: %v",out) do return
    testing.expect_value(t,contracts.owner_string(review_test_data(out),"run_bridge_id"),"bridge_b")
    testing.expectf(t,ctx.remote.active && ctx.remote.executor_bridge=="bridge_b" && ctx.remote.agent=="agt_w","placed on bridge_b: %v",ctx.remote)
    testing.expectf(t,ctx.remote.provider=="codex" && ctx.remote.model=="gpt-5.5","per-Bridge model honored: %s/%s",ctx.remote.provider,ctx.remote.model)
    pin,has_pin:=run_bridge(r,chain,there)
    testing.expectf(t,has_pin && pin=="bridge_b","the pin is in the brief: %q %v",pin,has_pin)

    // task show reports the run Bridge: the pin, else the owner Bridge.
    shown_bridge :: proc(r:^Review_Test,coord:owner.Child,chain,task:string) -> string {
        shown,_:=review_test_exec(r,coord,"agent.task.show",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s"}}`,chain,task))
        task_obj,_:=review_test_data(shown)["task"].(json.Object)
        return contracts.owner_string(task_obj,"run_bridge_id")
    }
    testing.expect_value(t,shown_bridge(r,coord,chain,there),"bridge_b")
    testing.expect_value(t,shown_bridge(r,coord,chain,here),"bridge")

    // A pin needs a brief.
    refused,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"bare","assignee":"agt_w","bridge_id":"bridge_b"}}`,chain))
    testing.expectf(t,strings.contains(fmt.tprint(refused),"needs a brief"),"pin without a brief refused: %v",refused)

    // Clearing the pin returns the task to the owner Bridge.
    cleared,_:=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","bridge_id":""}}`,chain,there))
    testing.expectf(t,bool(cleared["ok"].(json.Boolean)),"clear: %v",cleared)
    pin,has_pin=run_bridge(r,chain,there)
    testing.expectf(t,has_pin && pin=="","cleared to the owner Bridge: %q",pin)

    // Moving the configured local task to bridge_b re-places its worker there.
    moved,mctx:=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","bridge_id":"bridge_b"}}`,chain,here))
    testing.expectf(t,bool(moved["ok"].(json.Boolean)),"move: %v",moved)
    testing.expectf(t,mctx.remote.active && mctx.remote.task==here && mctx.remote.agent=="agt_w" && mctx.remote.executor_bridge=="bridge_b","the worker is re-placed: %v",mctx.remote)

    // An unknown / other-account / revoked Bridge is refused by the check
    // that runs before the task route (here: no Hub directory names it).
    code,message:=bridge_owner_run_bridge_check("bridge_unknown")
    testing.expectf(t,code!="ok","unverifiable Bridge refused: %s %s",code,message)
}

// Gap 6: every local launch (fleet set, matcher JIT, reviewer dispatch) uses
// the row's per-Bridge entry for this Bridge, else the row's own model.
@(test)
test_owner_fleet_launch_model_honors_bridge_models :: proc(t:^testing.T) {
    policy:=contracts.Owner_Fleet_Policy{provider="claude",model="claude-sonnet-5-5",
        bridge_models_json=`{"bridge_b":{"provider_profile":"p_b","provider":"codex","model":"gpt-5.5"}}`}
    provider,model,profile:=bridge_owner_fleet_launch_model(policy,"bridge_b")
    testing.expectf(t,provider=="codex" && model=="gpt-5.5" && profile=="p_b","per-Bridge entry: %s %s %s",provider,model,profile)
    provider,model,profile=bridge_owner_fleet_launch_model(policy,"bridge_a")
    testing.expectf(t,provider=="claude" && model=="claude-sonnet-5-5" && profile=="","row default elsewhere: %s %s %s",provider,model,profile)
}

// Acceptance 4: a primary --reviewer placed on another account Bridge (fleet
// policy) is set by agent id with no local process: the task is configured
// with no instance-bound reviewer and the agent is a brief reviewer, which the
// gate requires and the relay trusts by agent id (relayed_reviewer_authorized;
// the relayed approve is covered in owner_local execution_child_test).
// Replacing a configured local reviewer reconfigures the task; no brief, or an
// agent neither running here nor placed elsewhere, is refused.
@(test)
test_owner_primary_reviewer_on_another_bridge :: proc(t:^testing.T) {
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
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-remote-primary-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=9
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)
    chain:="chain_remote_primary"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("remote primary chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_remote_primary",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,reviewer:=review_test_child("inst_w","agt_w"),review_test_child("inst_a","agt_a")
    append(&review_test_live,coord,worker,reviewer)
    for m in ([2]owner.Child{worker,reviewer}) {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code,"ok")
    }
    // agt_r runs on bridge_b only (no process here).
    row,_:=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_r","bridge_id":"bridge_b","provider":"claude","model":"claude-sonnet-5-5"}}`,chain))
    testing.expectf(t,bool(row["ok"].(json.Boolean)),"remote reviewer policy: %v",row)
    configured_reviewer :: proc(r:^Review_Test,chain,task:string) -> (author,reviewer:string,reviewers:[]string) {
        config,_,_:=owner.lifecycle_config(&r.store,chain,task)
        return contracts.owner_string(config,"author_agent_id"),contracts.owner_string(config,"reviewer_agent_id"),owner.task_reviewers(&r.store,chain,task,config)
    }
    brief:=`"brief":{"goal":"Ship it","acceptance":["Tests pass"]}`

    // Primary reviewer on bridge_b: configured with no instance-bound reviewer, required by the gate.
    out,ctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"remote review",%s,"assignee":"agt_w","reviewers":["agt_r"]}}`,chain,brief))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","create with a remote primary reviewer: %v",out) do return
    testing.expect(t,!ctx.remote.active,"the worker runs here")
    author,primary,reviewers:=configured_reviewer(r,chain,task)
    testing.expectf(t,author=="agt_w" && primary=="" && len(reviewers)==1 && reviewers[0]=="agt_r","author agt_w, no bound reviewer, gate requires agt_r: %s %q %v",author,primary,reviewers)

    // Replacing a configured local reviewer with the remote one reconfigures the task.
    out,_=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"local review",%s,"assignee":"agt_w","reviewers":["agt_a"]}}`,chain,brief))
    local:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,local!="","create with a local reviewer: %v",out) do return
    _,primary,_=configured_reviewer(r,chain,local)
    testing.expect_value(t,primary,"agt_a")
    moved,_:=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","reviewers":["agt_r"]}}`,chain,local))
    testing.expectf(t,bool(moved["ok"].(json.Boolean)),"re-target to the remote reviewer: %v",moved)
    author,primary,reviewers=configured_reviewer(r,chain,local)
    testing.expectf(t,author=="agt_w" && primary=="" && len(reviewers)==1 && reviewers[0]=="agt_r","reconfigured: %s %q %v",author,primary,reviewers)

    // No brief: refused, nothing created.
    bare,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"bare","assignee":"agt_w","reviewers":["agt_r"]}}`,chain))
    testing.expectf(t,strings.contains(fmt.tprint(bare),"needs a brief"),"remote primary reviewer without a brief refused: %v",bare)
    // An agent neither running here nor placed on another Bridge: refused.
    unknown,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"unknown",%s,"assignee":"agt_w","reviewers":["agt_x"]}}`,chain,brief))
    testing.expectf(t,strings.contains(fmt.tprint(unknown),"not a running"),"unplaced reviewer refused: %v",unknown)
    // The coordinator never reviews, even when placed elsewhere.
    self,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"self",%s,"assignee":"agt_w","reviewers":["agt_c"]}}`,chain,brief))
    testing.expectf(t,!bool(self["ok"].(json.Boolean)),"coordinator as reviewer refused: %v",self)
}

// Gap 4: a task assigned to an agent placed on another Bridge whose placement
// did not land (no fleet row here) is placed again by the matcher, as the
// coordinator, never handed to a local member; event runs do not repeat it
// within the back-off and the periodic run retries it after.
@(thread_local) matcher_place_calls:[dynamic]string
matcher_place_test_effect :: proc(chain,task,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    append(&matcher_place_calls,fmt.aprintf("%s|%s|%s",task,agent,rec.agent_instance_id,allocator=context.temp_allocator))
    return "Bridge bridge_b did not answer the placement request"
}

@(test)
test_owner_matcher_retries_remote_placement :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    bridge_owner_review_effects=Owner_Review_Effects{nudge=review_test_nudge,start=review_test_start,place=matcher_place_test_effect};bridge_owner_review_sync_effects=true
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    review_test_nudged=make([dynamic]string,context.temp_allocator)
    review_test_started=make([dynamic]string,context.temp_allocator)
    matcher_place_calls=make([dynamic]string,context.temp_allocator)
    // No catalog default: only agt_w (its row names a model for bridge_b) can
    // run there, whatever catalog this process holds.
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{{provider="none",state="retired"}}
    defer {
        bridge_provider_catalog_default_hook=nil
        bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil
        bridge_owner_review_effects={};bridge_owner_review_sync_effects=false
        review_test_live=nil;review_test_nudged=nil;review_test_started=nil;matcher_place_calls=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-match-place-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=11
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    // The coordinator's Hub credential (unique id: token records are process-global).
    coord_instance:=fmt.tprintf("inst_mp_%d",time.to_unix_nanoseconds(time.now()))
    {
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        append(&bridge_local_token_records,Bridge_Local_Agent_Token_Record{token_hash="hash_mp",agent_instance_id=strings.clone(coord_instance,context.allocator),instance_token="token_mp",run_count=1,role=.Agent})
    }
    defer {
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        for i:=len(bridge_local_token_records)-1;i>=0;i-=1 do if bridge_local_token_records[i].agent_instance_id==coord_instance { ordered_remove(&bridge_local_token_records,i);break }
    }
    chain:=fmt.tprintf("chain_match_place_%d",time.to_unix_nanoseconds(time.now()))
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("placement chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_match_place",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by=coord_instance).code,"ok") do return
    coord:=review_test_child(coord_instance,"agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,coord_instance,now).code,"ok") do return
    worker,reviewer:=review_test_child("inst_pw","agt_w"),review_test_child("inst_pa","agt_a")
    append(&review_test_live,coord,worker,reviewer)
    for m in ([2]owner.Child{worker,reviewer}) {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code,"ok")
    }
    models:=`{\"bridge_b\":{\"provider_profile\":\"\",\"provider\":\"codex\",\"model\":\"gpt-5.5\"}}`
    row,_:=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_w","provider":"claude","model":"claude-sonnet-5-5","bridge_models_json":"%s"}}`,chain,models))
    testing.expectf(t,bool(row["ok"].(json.Boolean)),"fleet row: %v",row)
    brief:=`"brief":{"goal":"Ship it","acceptance":["Tests pass"]}`
    // Pinned to bridge_b: the route's placement never ran here (no fleet row).
    out,ctx:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"there",%s,"assignee":"agt_w","reviewers":["agt_a"],"bridge_id":"bridge_b"}}`,chain,brief))
    there:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,there!="" && ctx.remote.active,"pinned create: %v",out) do return

    plan :: proc(r:^Review_Test,chain:string,force:bool,now:i64) -> []Owner_Review_Wake {
        wakes:=make([dynamic]Owner_Review_Wake,context.temp_allocator)
        ctx:=review_test_ctx(r,{});ctx.now=now
        for d in bridge_owner_match_plan(&ctx,chain,force) {
            for w in d.wakes do append(&wakes,w)
            bridge_owner_review_dispatch(d)
        }
        return wakes[:]
    }
    // First run: placed again as the coordinator; the local member is not assigned.
    wakes:=plan(r,chain,true,now)
    testing.expectf(t,len(wakes)==1 && wakes[0].action==.Place && wakes[0].task==there && wakes[0].agent=="agt_w","one placement: %v",wakes)
    testing.expectf(t,len(matcher_place_calls)==1 && matcher_place_calls[0]==fmt.tprintf("%s|agt_w|%s",there,coord_instance),"placed with the coordinator's credential: %v",matcher_place_calls)
    st,_,_:=owner.agent_task_state(&r.store,chain,there)
    testing.expectf(t,st.fleet_instance=="","not handed to the local member: %q",st.fleet_instance)
    // A forced (event) run within the back-off does not place it again.
    wakes=plan(r,chain,true,now+1000)
    testing.expectf(t,len(wakes)==0,"no repeat within the back-off: %v",wakes)
    // The periodic run after the back-off retries the failed placement.
    wakes=plan(r,chain,false,now+BRIDGE_OWNER_MATCH_RETRY_MS+1)
    testing.expectf(t,len(wakes)==1 && wakes[0].action==.Place,"retried after the back-off: %v",wakes)
    testing.expect_value(t,len(matcher_place_calls),2)

    // The agent the route asked for (pending) is the one placed. Simulated
    // clock throughout: each plan passes its own now, nothing sleeps.
    bridge_owner_place_pending_set(chain,there,"agt_w");defer bridge_owner_place_pending_set(chain,there,"")
    agent,remote:=bridge_owner_match_remote_assignee(&r.store,chain,there)
    testing.expectf(t,agent=="agt_w" && remote,"pending placement: %q %v",agent,remote)
    wakes=plan(r,chain,false,now+2*BRIDGE_OWNER_MATCH_RETRY_MS+2)
    testing.expectf(t,len(wakes)==1 && wakes[0].action==.Place && wakes[0].agent=="agt_w","pending agent placed: %v",wakes)

    // Cleared pin: agt_w runs here (its fleet row names no Bridge), so the
    // matcher never places it remotely; the local member gets the task.
    cleared,_:=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","bridge_id":""}}`,chain,there))
    testing.expectf(t,bool(cleared["ok"].(json.Boolean)),"clear: %v",cleared)
    agent,remote=bridge_owner_match_remote_assignee(&r.store,chain,there)
    testing.expectf(t,agent=="agt_w" && !remote,"local after the pin is cleared: %q %v",agent,remote)
    places:=len(matcher_place_calls)
    for w in plan(r,chain,false,now+3*BRIDGE_OWNER_MATCH_RETRY_MS+3) do testing.expectf(t,w.action!=.Place,"no remote placement once local: %v",w)
    testing.expect_value(t,len(matcher_place_calls),places)
}

@(test)
test_provider_catalog_pick_fills_only_what_is_empty :: proc(t:^testing.T) {
    catalog:=[]Bridge_Catalog_Provider{
        {provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"},{model_id="claude-opus-5-5",state="active"}}},
        {provider="codex",state="active",models=[]Bridge_Catalog_Model{{model_id="gpt-5.5",state="active"}}},
    }
    p,m,ok:=bridge_provider_catalog_pick(catalog,"","")
    testing.expectf(t,ok && p=="claude" && m=="claude-sonnet-5-5","catalog order: %s/%s %v",p,m,ok)
    p,m,ok=bridge_provider_catalog_pick(catalog,"codex","")
    testing.expectf(t,ok && p=="codex" && m=="gpt-5.5","an explicit provider is kept: %s/%s",p,m)
    p,m,ok=bridge_provider_catalog_pick(catalog,"","claude-opus-5-5")
    testing.expectf(t,ok && p=="claude" && m=="claude-opus-5-5","an explicit model is kept: %s/%s",p,m)
    p,m,ok=bridge_provider_catalog_pick(catalog,"gemini","")
    testing.expectf(t,!ok,"an unknown provider is not replaced: %s/%s",p,m)
    p,m,ok=bridge_provider_catalog_pick(nil,"claude","x")
    testing.expectf(t,ok && p=="claude" && m=="x","an explicit pair needs no catalog: %s/%s",p,m)
}
