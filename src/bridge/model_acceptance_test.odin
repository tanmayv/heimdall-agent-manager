package main

import "core:strings"
import "core:sync"
import "core:testing"

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
        {"executor issuance/prepare",proc(model:string,_:^Provider_Profile)->bool {return bridge_executor_model_allowed("claude",model)}},
        // Hub-driven launch (remote reviewer) and wake runnability
        {"hub launch / wake",proc(model:string,_:^Provider_Profile)->bool {return bridge_provider_catalog_has_model("claude",model)}},
    }
    for path in paths {
        for profile in ([2]^Provider_Profile{&default_profile,&work_profile}) {
            testing.expectf(t,path.check("claude-sonnet-5-5",profile),"%s accepts an active catalog model it has not observed (%s)",path.name,profile.profile_id)
            testing.expectf(t,path.check("sonnet",profile) || profile.profile_id!="" ,"%s accepts an observed alias",path.name)
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
