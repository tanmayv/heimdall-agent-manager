package main

import "base:runtime"
import "core:crypto/ecdsa"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import executor "odin_test:lib/executor_local"

// G4 (REQ-EXEC-NEVER-BLOCK): one model-acceptance rule on every path. This
// Bridge has observed claude's aliases only ('sonnet'); the account catalog
// has claude-sonnet-5-5 active and claude-old retired. Every launch,
// issuance and prepare check accepts the active catalog model and refuses the
// retired one with a logged reason the activation reports to the owner.
@(test)
test_model_acceptance_observed_list_never_hides_the_catalog :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator=context.temp_allocator
    sync.mutex_lock(&bridge_models_mu)
    saved_cache,saved_loaded:=bridge_models_cache,bridge_models_loaded
    bridge_models_cache=make([dynamic]Bridge_Provider_Models,context.temp_allocator)
    bridge_models_loaded=true
    append(&bridge_models_cache,Bridge_Provider_Models{provider="claude",has_snapshot=true,models=[]Bridge_Discovered_Model{{model_id="sonnet"},{model_id="claude-sonnet-5"}}})
    append(&bridge_models_cache,Bridge_Provider_Models{provider="claude",profile_id="claude_work",has_snapshot=true,models=[]Bridge_Discovered_Model{{model_id="opus"}}})
    sync.mutex_unlock(&bridge_models_mu)
    saved_hook:=bridge_provider_catalog_default_hook
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{{provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"},{model_id="claude-old",state="retired"}}}}
    defer {
        bridge_provider_catalog_default_hook=saved_hook
        sync.mutex_lock(&bridge_models_mu);bridge_models_cache,bridge_models_loaded=saved_cache,saved_loaded;sync.mutex_unlock(&bridge_models_mu)
    }

    default_profile:=Provider_Profile{provider="claude"}
    work_profile:=Provider_Profile{provider="claude",profile_id="claude_work"}
    work_profile.config.custom_models=[]string{"claude-private"}
    Path :: struct {name:string,check:proc(model:string,p:^Provider_Profile)->bool}
    paths:=[]Path{
        // local launch, local native launch, remote launch pin and spawn all check the profile
        {"profile (local/native/remote launch, spawn)",proc(model:string,p:^Provider_Profile)->bool {return profile_has_model(p,"claude",model)}},
        // remote issuance and prepare
        {"executor issuance/prepare",proc(model:string,p:^Provider_Profile)->bool {return bridge_executor_model_allowed(p,"claude",model)}},
        // Hub-driven launch (remote reviewer) and wake runnability
        {"hub launch / wake",proc(model:string,_:^Provider_Profile)->bool {return bridge_provider_catalog_has_model("claude",model)}},
    }
    for path in paths {
        for profile in ([2]^Provider_Profile{&default_profile,&work_profile}) {
            testing.expectf(t,path.check("claude-sonnet-5-5",profile),"%s accepts an active catalog model it has not observed (%s)",path.name,profile.profile_id)
            testing.expectf(t,path.check("sonnet",profile) || profile.profile_id!="","%s accepts an observed alias",path.name)
            bridge_model_last_refusal=""
            testing.expectf(t,!path.check("claude-old",profile),"%s refuses a retired catalog model",path.name)
            testing.expectf(t,strings.contains(bridge_model_last_refusal,"claude/claude-old") && strings.contains(bridge_model_last_refusal,"not an active catalog model"),
                "%s records the refusal reason: %q",path.name,bridge_model_last_refusal)
            testing.expectf(t,!path.check("claude-unknown",profile),"%s refuses an unknown model",path.name)
        }
    }
    // A profile's own snapshot and custom models count; a custom profile
    // never borrows the default profile's observed aliases.
    testing.expect(t,profile_has_model(&work_profile,"claude","opus") && profile_has_model(&work_profile,"claude","claude-private"))
    testing.expect(t,!profile_has_model(&work_profile,"claude","sonnet"),"the default profile's observed alias is not borrowed")
    testing.expect(t,!profile_has_model(&default_profile,"claude","opus"),"another profile's observed model is not borrowed")
    bridge_model_last_refusal=""
    testing.expect(t,!bridge_model_accepted("claude",""))
    testing.expect(t,bridge_model_last_refusal=="no provider or model selected")
}

// G4 round 1: the rule at the real boundaries. A work profile observed only
// 'opus-work' and has the custom model 'claude-private'; the default profile
// observed only 'sonnet'; the catalog has claude-sonnet-5-5 active and
// claude-old retired. Explicit issuance (which prepare re-runs) for the work
// profile accepts its own observed and custom models and refuses the
// default's alias; spawn and the Hub-driven launch (remote reviewer) pass the
// model gate for an active catalog model and refuse a retired one with the
// recorded reason; the owner logs the executor's refusal code.
@(test)
test_model_acceptance_at_launch_and_issuance_boundaries :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    saved_hook:=bridge_provider_catalog_default_hook
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{{provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"},{model_id="claude-old",state="retired"}}}}
    defer bridge_provider_catalog_default_hook=saved_hook
    work:=Provider_Profile{provider="claude",profile_id="claude_work",enabled=true}
    work.config.custom_models=[]string{"claude-private"}
    testing.expect_value(t,profile_upsert(&work,nil,1),Profile_Error.None)
    sync.mutex_lock(&bridge_models_mu)
    append(&bridge_models_cache,bridge_models_clone(Bridge_Provider_Models{provider="claude",has_snapshot=true,models=[]Bridge_Discovered_Model{{model_id="sonnet"}}},runtime.default_allocator()))
    append(&bridge_models_cache,bridge_models_clone(Bridge_Provider_Models{provider="claude",profile_id="claude_work",has_snapshot=true,models=[]Bridge_Discovered_Model{{model_id="opus-work"}}},runtime.default_allocator()))
    sync.mutex_unlock(&bridge_models_mu)

    // Explicit issuance and prepare (bridge_executor_resolve_issuance).
    saved_root:=bridge_fs_root
    root:=bridge_fs_canonicalize_existing(st.dir);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=saved_root}
    directory:=fmt.tprintf("%s/work",root)
    if !testing.expect(t,os.make_directory(directory)==nil) do return
    private,key:=bridge_executor_test_key("executor","operator",7);defer ecdsa.private_key_clear(&private)
    store:executor.Store
    if !testing.expect(t,executor.open(&store,fmt.tprintf("%s/executor.sqlite",root),"account","executor","operator")) do return
    defer executor.close(&store)
    record:=bridge_executor_test_doc("directory")
    bridge_executor_test_set(record,"directory_path",directory)
    testing.expect_value(t,bridge_executor_install_directory(&store,bridge_executor_test_sign(record,"directory",&private),key,1000).code,"ok")
    selected:=bridge_executor_test_doc("issuance_selection")
    bridge_executor_test_set(selected,"provider","claude");bridge_executor_test_set(selected,"provider_profile","claude_work")
    for model in ([4]string{"opus-work","claude-private","claude-sonnet-5-5","seed"}) {
        bridge_executor_test_set(selected,"model",model)
        why:=""
        testing.expectf(t,bridge_executor_resolve_issuance(&store,executor.encode(selected),&why).resolved,"work-profile issuance accepts %s: %s",model,why)
    }
    for model in ([2]string{"sonnet","claude-old"}) {
        bridge_executor_test_set(selected,"model",model)
        why:=""
        testing.expectf(t,!bridge_executor_resolve_issuance(&store,executor.encode(selected),&why).resolved && strings.has_prefix(why,"model: claude/"),
            "work-profile issuance refuses %s (the default profile's alias is not borrowed; a retired model): %s",model,why)
    }

    // Spawn (local, native and remote launches all build it with the profile)
    // and the Hub-driven launch (remote reviewer): the model gate.
    gate :: proc(build:proc(model:string)) -> (refusals:[2]string) {
        for model,i in ([2]string{"claude-sonnet-5-5","claude-old"}) {
            bridge_model_last_refusal=""
            build(model)
            refusals[i]=bridge_model_last_refusal
        }
        return
    }
    spawn:=gate(proc(model:string) {
        p:=Provider_Profile{provider="claude",profile_id="claude",enabled=true}
        request,built:=bridge_pty_host_build_spawn("inst_gate","/tmp","claude",model,"tok",nil,pp=&p)
        if built do bridge_pty_host_spawn_request_delete(request)
    })
    testing.expectf(t,spawn[0]=="" && strings.contains(spawn[1],"claude/claude-old"),"spawn passes the active catalog model and refuses the retired one: %v",spawn)
    hub:=gate(proc(model:string) {
        _=bridge_runtime_agent_command(fmt.tprintf(`{{"provider":"claude","model":"%s"}}`,model),"tok","inst_gate")
    })
    testing.expectf(t,hub[0]=="" && strings.contains(hub[1],"claude/claude-old"),"the Hub-driven launch passes the active catalog model and refuses the retired one: %v",hub)

    // The owner records the executor's refusal and logs its code.
    result,line:=bridge_owner_executor_refusal("executor.activate","intent_1","brg_b","model_unavailable")
    testing.expect_value(t,result,"executor_rejected")
    testing.expect(t,strings.contains(line,"refused by executor brg_b: model_unavailable"))
}
