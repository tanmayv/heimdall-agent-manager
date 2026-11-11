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

@(thread_local) task_models_test_launch:map[string]Owner_Agent_Model
task_models_test_serves :: proc(instance:string,want:Owner_Agent_Model) -> bool {
    have,known:=task_models_test_launch[instance]
    return !known || (have.provider==want.provider && (want.model=="" || have.model==want.model))
}

// Per-task, per-agent provider/model override: set/clear on create/update,
// catalog refusal, task show, effective selection (task > per-Bridge > row >
// catalog) for local launches and remote placement, reuse vs dedicated.
@(test)
test_owner_task_agent_model_override :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{
        {provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"},{model_id="claude-opus-5-5",state="active"}}},
        {provider="codex",state="active",models=[]Bridge_Catalog_Model{{model_id="gpt-5.5",state="active"},{model_id="gpt-old",state="retired"}}},
        {provider="gone",state="retired",models=[]Bridge_Catalog_Model{{model_id="m",state="active"}}},
    }
    task_models_test_launch=make(map[string]Owner_Agent_Model,context.temp_allocator)
    bridge_owner_instance_serves_hook=task_models_test_serves
    defer {
        bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil;review_test_live=nil
        bridge_provider_catalog_default_hook=nil;bridge_owner_instance_serves_hook=nil;task_models_test_launch=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-task-models-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=13
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)
    chain:="chain_task_models"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("task models",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_task_models",tc,dc,now,signer)
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
    // Fleet: agt_w is claude here, claude-opus on bridge_b.
    models:=`{\"bridge_b\":{\"provider_profile\":\"\",\"provider\":\"claude\",\"model\":\"claude-opus-5-5\"}}`
    row,_:=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_w","provider":"claude","model":"claude-sonnet-5-5","bridge_models_json":"%s"}}`,chain,models))
    testing.expectf(t,bool(row["ok"].(json.Boolean)),"fleet row: %v",row)
    brief:=`"brief":{"goal":"Ship it","acceptance":["Tests pass"]}`
    shown :: proc(r:^Review_Test,coord:owner.Child,chain,task:string) -> json.Object {
        out,_:=review_test_exec(r,coord,"agent.task.show",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s"}}`,chain,task))
        task_obj,_:=review_test_data(out)["task"].(json.Object)
        models,_:=task_obj["agent_models"].(json.Object)
        return models
    }

    // Refusals: unknown/retired provider, inactive model, model without provider, no brief.
    for bad in ([4]string{`"agt_w":"nope"`,`"agt_w":"gone/m"`,`"agt_w":"codex/gpt-old"`,`"agt_w":{"model":"gpt-5.5"}`}) {
        out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"bad",%s,"assignee":"agt_w","agent_models":{{%s}}}}`,chain,brief,bad))
        testing.expectf(t,!bool(out["ok"].(json.Boolean)) && strings.contains(fmt.tprint(out),"--agent-model"),"refused %s: %v",bad,out)
    }
    nobrief,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"bare","assignee":"agt_w","agent_models":{{"agt_w":"codex"}}}}`,chain))
    testing.expectf(t,strings.contains(fmt.tprint(nobrief),"needs a brief"),"override needs a brief: %v",nobrief)

    // Create with codex for agt_w (fleet says claude): stored and shown.
    out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"codex",%s,"assignee":"agt_w","reviewers":["agt_a"],"agent_models":{{"agt_w":"codex/gpt-5.5","agt_a":{{"provider":"claude"}}}}}}`,chain,brief))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","create with overrides: %v",out) do return
    m:=shown(r,coord,chain,task)
    w,_:=m["agt_w"].(json.Object);a,_:=m["agt_a"].(json.Object)
    testing.expectf(t,contracts.owner_string(w,"provider")=="codex" && contracts.owner_string(w,"model")=="gpt-5.5" && contracts.owner_string(a,"provider")=="claude","task show: %v",m)

    // Effective selection: local launch body uses the override (fleet row claude).
    st,_,_:=owner.agent_task_state(&r.store,chain,task)
    tm:=bridge_owner_brief_agent_models(st.brief)
    policy,_,_:=owner.agent_fleet_policy(&r.store,chain,"agt_w")
    body:=map[string]string{}
    bridge_owner_launch_body_model(&body,policy,"bridge","agt_w",tm)
    testing.expectf(t,body["provider"]=="codex" && body["model"]=="gpt-5.5","local launch is codex: %v",body)
    // An override naming only a provider takes that provider's catalog default.
    body=map[string]string{}
    bridge_owner_launch_body_model(&body,policy,"bridge","agt_a",tm)
    testing.expectf(t,body["provider"]=="claude" && body["model"]=="claude-sonnet-5-5","provider-only override: %v",body)
    // Remote placement on bridge_b: task override beats the per-Bridge entry.
    place,code,_:=bridge_owner_remote_target(&r.store,chain,"agt_w","bridge_b",true,tm)
    testing.expectf(t,code=="ok" && place.provider=="codex" && place.model=="gpt-5.5","remote override: %v %s",place,code)
    place,code,_=bridge_owner_remote_target(&r.store,chain,"agt_w","bridge_b",true,nil)
    testing.expectf(t,code=="ok" && place.provider=="claude" && place.model=="claude-opus-5-5","per-Bridge default without override: %v %s",place,code)

    // Reuse vs dedicated: agt_w's live instance runs claude, so the codex task does not reuse it.
    task_models_test_launch["inst_w"]=Owner_Agent_Model{"claude","claude-sonnet-5-5"}
    testing.expect(t,!bridge_owner_instance_serves("inst_w","agt_w",tm),"a claude instance does not serve the codex task")
    task_models_test_launch["inst_w"]=Owner_Agent_Model{"codex","gpt-5.5"}
    testing.expect(t,bridge_owner_instance_serves("inst_w","agt_w",tm),"a codex instance serves it")
    testing.expect(t,bridge_owner_instance_serves("inst_w","agt_w",nil),"no override: any instance serves")

    // Update: clear agt_w's override, keep agt_a's.
    upd,_:=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","agent_models":{{"agt_w":""}}}}`,chain,task))
    testing.expectf(t,bool(upd["ok"].(json.Boolean)),"clear: %v",upd)
    m=shown(r,coord,chain,task)
    _,has_w:=m["agt_w"];_,has_a:=m["agt_a"]
    testing.expectf(t,!has_w && has_a,"agt_w cleared, agt_a kept: %v",m)
    st,_,_=owner.agent_task_state(&r.store,chain,task)
    body=map[string]string{}
    bridge_owner_launch_body_model(&body,policy,"bridge","agt_w",bridge_owner_brief_agent_models(st.brief))
    testing.expectf(t,body["provider"]=="claude" && body["model"]=="claude-sonnet-5-5","cleared: back to the fleet row: %v",body)
    // Update sets a new one for agt_w only.
    upd,_=review_test_exec(r,coord,"agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","agent_models":{{"agt_w":"codex"}}}}`,chain,task))
    testing.expectf(t,bool(upd["ok"].(json.Boolean)),"set: %v",upd)
    m=shown(r,coord,chain,task)
    w,_=m["agt_w"].(json.Object)
    _,has_a=m["agt_a"]
    testing.expectf(t,contracts.owner_string(w,"provider")=="codex" && has_a,"agt_w set again, agt_a kept: %v",m)
}
