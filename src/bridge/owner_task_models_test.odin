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
    testing.expect(t,!bridge_owner_instance_serves(&r.store,chain,"inst_w","agt_w",tm),"a claude instance does not serve the codex task")
    task_models_test_launch["inst_w"]=Owner_Agent_Model{"codex","gpt-5.5"}
    testing.expect(t,bridge_owner_instance_serves(&r.store,chain,"inst_w","agt_w",tm),"a codex instance serves it")
    // Review finding 3: without an override the EFFECTIVE selection (the fleet
    // row: claude) decides, so the codex instance does not serve a fleet-default task.
    testing.expect(t,!bridge_owner_instance_serves(&r.store,chain,"inst_w","agt_w",nil),"a codex instance does not serve a fleet-default (claude) task")
    task_models_test_launch["inst_w"]=Owner_Agent_Model{"claude","claude-sonnet-5-5"}
    testing.expect(t,bridge_owner_instance_serves(&r.store,chain,"inst_w","agt_w",nil),"a claude instance serves it")

    // Review finding 1: create/update never binds a non-matching live instance.
    // inst_w runs claude; a codex task for agt_w is refused here (fleet ensure
    // launches a dedicated member before the route in production).
    refused,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"needs codex",%s,"assignee":"agt_w","agent_models":{{"agt_w":"codex/gpt-5.5"}}}}`,chain,brief))
    testing.expectf(t,strings.contains(fmt.tprint(refused),"agent_not_serving"),"no claude instance bound for a codex task: %v",refused)
    // A dedicated codex member of agt_w (inst_w2) is bound, not the claude one.
    codex_w:=review_test_child("inst_w2","agt_w")
    append(&review_test_live,codex_w)
    {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,codex_w.instance,codex_w.agent_id,"worker",true,codex_w).code,"ok")
    }
    task_models_test_launch["inst_w2"]=Owner_Agent_Model{"codex","gpt-5.5"}
    bound,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"codex bound",%s,"assignee":"agt_w","agent_models":{{"agt_w":"codex/gpt-5.5"}}}}`,chain,brief))
    testing.expectf(t,contracts.owner_string(review_test_data(bound),"assignee_instance_id")=="inst_w2","the codex member is bound: %v",bound)
    // A fleet-default task (claude) binds the claude member, not the codex one.
    plain,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"claude bound",%s,"assignee":"agt_w"}}`,chain,brief))
    testing.expectf(t,contracts.owner_string(review_test_data(plain),"assignee_instance_id")=="inst_w","the claude member is bound for the default: %v",plain)

    // Review finding 4: a device requirements edit (ticket UI) naming an unknown
    // provider/model is refused on the Bridge before the owner store.
    device_payload :: proc(r:^Review_Test,brief:string) -> string {
        sealed,_:=vault.seal_string(brief,&r.kr,context.temp_allocator)
        return bridge_owner_json(map[string]string{"requirements_revision"="2","body_cipher"=sealed})
    }
    testing.expect(t,bridge_owner_requirements_models_valid(device_payload(r,`{"goal":"g","agent_models":{"agt_w":{"provider":"codex","model":"gpt-5.5"}}}`),&r.kr),"a catalog model passes")
    testing.expect(t,!bridge_owner_requirements_models_valid(device_payload(r,`{"goal":"g","agent_models":{"agt_w":{"provider":"codx","model":""}}}`),&r.kr),"a typo is refused")
    testing.expect(t,!bridge_owner_requirements_models_valid(device_payload(r,`{"goal":"g","agent_models":{"agt_w":{"provider":"codex","model":"gpt-old"}}}`),&r.kr),"an inactive model is refused")
    testing.expect(t,bridge_owner_requirements_models_valid(device_payload(r,`{"goal":"g"}`),&r.kr),"no overrides: nothing to check")

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

@(thread_local) task_models_test_launches:[dynamic]string
task_models_test_launch_effect :: proc(body,agent:string,rec:Bridge_Local_Agent_Token_Record) -> (string,string) {
    append(&task_models_test_launches,fmt.aprintf("%s %s",agent,body,allocator=context.temp_allocator))
    return "","test: launch not completed"
}

// Review findings 2/6: the matcher launches ONE dedicated member for an
// overridden task when no member runs its selection, never again within the
// back-off (even on event runs), then assigns the matching member (two live
// members of the agent, no ambiguous_agent). Fleet ensure launches a dedicated
// member for an update naming the override; review dispatch nudges only a
// matching reviewer.
@(test)
test_owner_task_agent_model_dedicated_member :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    review_test_nudged=make([dynamic]string,context.temp_allocator)
    review_test_started=make([dynamic]string,context.temp_allocator)
    task_models_test_launches=make([dynamic]string,context.temp_allocator)
    bridge_owner_review_effects=Owner_Review_Effects{nudge=review_test_nudge,start=review_test_start,launch=task_models_test_launch_effect};bridge_owner_review_sync_effects=true
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{
        {provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"}}},
        {provider="codex",state="active",models=[]Bridge_Catalog_Model{{model_id="gpt-5.5",state="active"}}},
    }
    task_models_test_launch=make(map[string]Owner_Agent_Model,context.temp_allocator)
    bridge_owner_instance_serves_hook=task_models_test_serves
    defer {
        bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil;review_test_live=nil
        review_test_nudged=nil;review_test_started=nil;task_models_test_launches=nil
        bridge_owner_review_effects={};bridge_owner_review_sync_effects=false
        bridge_provider_catalog_default_hook=nil;bridge_owner_instance_serves_hook=nil;task_models_test_launch=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-task-models-ded-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=17
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)
    coord_instance:=fmt.tprintf("inst_tmd_%d",time.to_unix_nanoseconds(time.now()))
    {
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        append(&bridge_local_token_records,Bridge_Local_Agent_Token_Record{token_hash="hash_tmd",agent_instance_id=strings.clone(coord_instance,context.allocator),instance_token="token_tmd",run_count=1,role=.Agent})
    }
    defer {
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        for i:=len(bridge_local_token_records)-1;i>=0;i-=1 do if bridge_local_token_records[i].agent_instance_id==coord_instance { ordered_remove(&bridge_local_token_records,i);break }
    }
    chain:=fmt.tprintf("chain_tmd_%d",time.to_unix_nanoseconds(time.now()))
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("dedicated",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_tmd",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by=coord_instance).code,"ok") do return
    coord:=review_test_child(coord_instance,"agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,coord_instance,now).code,"ok") do return
    claude_w:=review_test_child("inst_dw","agt_w")
    append(&review_test_live,coord,claude_w)
    task_models_test_launch["inst_dw"]=Owner_Agent_Model{"claude","claude-sonnet-5-5"}
    {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,claude_w.instance,"agt_w","worker",true,claude_w).code,"ok")
    }
    row,_:=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_w","provider":"claude","model":"claude-sonnet-5-5","capacity":"2"}}`,chain))
    testing.expectf(t,bool(row["ok"].(json.Boolean)),"fleet row: %v",row)
    brief:=`"brief":{"goal":"Ship it","acceptance":["Tests pass"]}`
    // An unassigned codex task for agt_w.
    out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"codex work",%s,"agent_models":{{"agt_w":"codex/gpt-5.5"}}}}`,chain,brief))
    task:=contracts.owner_string(review_test_data(out),"task_id")
    if !testing.expectf(t,task!="","create: %v",out) do return
    plan :: proc(r:^Review_Test,chain:string,force:bool,now:i64) -> []Owner_Review_Wake {
        wakes:=make([dynamic]Owner_Review_Wake,context.temp_allocator)
        ctx:=review_test_ctx(r,{});ctx.now=now
        for d in bridge_owner_match_plan(&ctx,chain,force) {
            for w in d.wakes do append(&wakes,w)
            bridge_owner_review_dispatch(d)
        }
        return wakes[:]
    }
    // The claude member is not reused: one dedicated codex launch.
    // Plans run at the store's current time (an earlier clock marks it uncertain).
    now=time.to_unix_nanoseconds(time.now())/1000000
    wakes:=plan(r,chain,true,now)
    testing.expectf(t,len(wakes)==1 && wakes[0].action==.Launch && wakes[0].agent=="agt_w" && strings.contains(wakes[0].body,`"provider":"codex"`) && strings.contains(wakes[0].body,`"model":"gpt-5.5"`),"one codex launch: %v",wakes)
    st,_,_:=owner.agent_task_state(&r.store,chain,task)
    testing.expectf(t,st.fleet_instance=="","not bound to the claude member: %q",st.fleet_instance)
    // Pending: an event run within the back-off launches nothing more.
    wakes=plan(r,chain,true,now+1)
    for w in wakes do testing.expectf(t,w.action!=.Launch,"no second launch while pending: %v",w)
    testing.expect_value(t,len(task_models_test_launches),1)
    // The dedicated member is live: assigned to it, no ambiguous_agent with two live members.
    codex_w:=review_test_child("inst_dw2","agt_w")
    append(&review_test_live,codex_w)
    task_models_test_launch["inst_dw2"]=Owner_Agent_Model{"codex","gpt-5.5"}
    {
        ctx:=review_test_ctx(r,coord);ctx.now=max(time.to_unix_nanoseconds(time.now())/1000000,now+2)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,codex_w.instance,"agt_w","worker",true,codex_w).code,"ok")
    }
    wakes=plan(r,chain,true,max(time.to_unix_nanoseconds(time.now())/1000000,now+3))
    st,_,_=owner.agent_task_state(&r.store,chain,task)
    testing.expectf(t,st.fleet_instance=="inst_dw2","assigned to the codex member: %q (wakes %v)",st.fleet_instance,wakes)
    testing.expect_value(t,len(task_models_test_launches),1)

    // Fleet ensure: an update overriding agt_r (only a claude member) launches a dedicated codex member.
    claude_r:=review_test_child("inst_dr","agt_r")
    append(&review_test_live,claude_r)
    task_models_test_launch["inst_dr"]=Owner_Agent_Model{"claude","claude-sonnet-5-5"}
    {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,claude_r.instance,"agt_r","worker",true,claude_r).code,"ok")
    }
    row,_=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_r","provider":"claude","model":"claude-sonnet-5-5"}}`,chain))
    _,ectx:=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_r","ensure":"1","task_id":"%s","override_provider":"codex","override_model":"gpt-5.5"}}`,chain,task))
    testing.expectf(t,ectx.launch.active && strings.contains(ectx.launch.body,`"provider":"codex"`),"ensure launches a dedicated codex member: %v",ectx.launch)
    // ... but not for the fleet default (its claude member serves), nor for a clear.
    _,ectx=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_r","ensure":"1","task_id":"%s","override_clear":"1"}}`,chain,task))
    testing.expect(t,!ectx.launch.active,"a cleared override needs no dedicated member")

    // Review dispatch: the codex-overridden reviewer agt_r is not nudged on its claude member.
    rctx:=review_test_ctx(r,coord)
    _=rctx
    models:=map[string]Owner_Agent_Model{"agt_r"=Owner_Agent_Model{"codex","gpt-5.5"}}
    testing.expect(t,!bridge_owner_instance_serves(&r.store,chain,"inst_dr","agt_r",models),"the claude reviewer does not serve a codex review")

    // Review round 2 (major): a dedicated launch for an EXISTING row is rolled
    // back by stopping its instance only; the row stays enabled.
    ensure_test_r=r;ensure_test_coord=coord
    ensure_test_launched=make([dynamic]string,context.temp_allocator)
    ensure_test_stopped=make([dynamic]string,context.temp_allocator)
    bridge_owner_fleet_ensure_effects=Owner_Fleet_Ensure_Effects{set=ensure_test_set,launch=ensure_test_launch_ok,pause=ensure_test_pause,stop=ensure_test_stop}
    defer {bridge_owner_fleet_ensure_effects={};ensure_test_launched=nil;ensure_test_stopped=nil;ensure_test_r=nil}
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id=coord_instance,role=.Agent}
    refused,_,_,ensured:=bridge_owner_task_fleet_ensure("req_ded","agent.task.update",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","reviewers":["agt_r"],"agent_models":{{"agt_r":"codex/gpt-5.5"}}}}`,chain,task),rec)
    testing.expectf(t,refused=="" && len(ensure_test_launched)==1 && ensure_test_launched[0]=="agt_r","a dedicated member is launched: %q %v",refused,ensure_test_launched)
    testing.expectf(t,len(ensured.added)==0 && len(ensured.launched)==1 && ensured.launched[0]=="inst_l_agt_r","only the instance is recorded: %v %v",ensured.added,ensured.launched)
    bridge_owner_task_fleet_rollback("req_ded",ensured,rec)
    rpolicy,_,_:=owner.agent_fleet_policy(&r.store,chain,"agt_r")
    testing.expectf(t,!strings.contains(rpolicy.paused_roles_json,`"*"`),"the existing row stays enabled: %s",rpolicy.paused_roles_json)
    testing.expectf(t,len(ensure_test_stopped)==1 && ensure_test_stopped[0]=="inst_l_agt_r","the dedicated instance is stopped: %v",ensure_test_stopped)

    // Review round 2 (minor): a stopped member does not block the dedicated
    // launch for an overridden agent (it would restart with the old selection).
    stopped_r:=review_test_child("inst_dr_stopped","agt_r")
    {
        ctx:=review_test_ctx(r,coord)
        testing.expect_value(t,bridge_owner_fleet_member(&ctx,chain,stopped_r.instance,"agt_r","worker",true,stopped_r).code,"ok")
    }
    _,ectx=review_test_exec(r,coord,"agent.task_chain.fleet_set",fmt.tprintf(`{{"chain_id":"%s","agent_id":"agt_r","ensure":"1","task_id":"%s","override_provider":"codex","override_model":"gpt-5.5"}}`,chain,task))
    testing.expectf(t,ectx.launch.active && ectx.launch.dedicated,"stopped member ignored for an override: %v",ectx.launch)

}
