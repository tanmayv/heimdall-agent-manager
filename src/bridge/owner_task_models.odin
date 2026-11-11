#+feature dynamic-literals
package main

// Per-task, per-agent provider/model override on owner chains (user
// 2026-11-11 12:51Z/13:07Z). A task's brief may carry
//   agent_models: {<agent_id>: {provider, model}}
// set by `task create/update --agent-model <agent_id>=<provider>[/<model>]`
// and cleared per agent id. It applies to whichever of the task's agents
// (assignee or any reviewer) it names. The effective selection for an agent of
// a task launching on a Bridge is, in order:
//   1. the task's agent_models[agent]   (an empty model: the provider's catalog default)
//   2. the fleet row's bridge_models[run Bridge]
//   3. the fleet row's provider/model
//   4. the catalog default (remote placement; local launches leave it to the Hub)
// origin/main has no task-level override (taskv2 placement.odin resolves 2-4).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"

Owner_Agent_Model :: struct { provider,model:string }

// An active catalog provider and (when named) one of its active models; an
// empty model picks the provider's first active model.
bridge_owner_agent_model_resolve :: proc(provider,model:string) -> (string,string,bool) {
    if provider=="" do return "","",false
    pick :: proc(providers:[]Bridge_Catalog_Provider,provider,model:string) -> (string,string,bool) {
        for entry in providers {
            if entry.state!="active" || entry.provider!=provider do continue
            for candidate in entry.models {
                if candidate.state!="active" || (model!="" && candidate.model_id!=model) do continue
                return strings.clone(entry.provider,context.temp_allocator),strings.clone(candidate.model_id,context.temp_allocator),true
            }
        }
        return "","",false
    }
    if bridge_provider_catalog_default_hook!=nil do return pick(bridge_provider_catalog_default_hook,provider,model)
    bridge_provider_catalog_init()
    sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
    defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
    if bridge_provider_catalog_snapshot==nil do return "","",false
    return pick(bridge_provider_catalog_snapshot.providers,provider,model)
}

// The agent_models param of task create/update: {agent: {provider, model}} or
// {agent: "provider[/model]"}; null, "" or an empty provider clears the
// agent's override. Unknown or inactive providers/models are refused.
bridge_owner_agent_models_param :: proc(p:json.Object) -> (changes:map[string]Owner_Agent_Model,present:bool,message:string) {
    raw,has:=p["agent_models"]
    if !has || raw==nil do return nil,false,""
    obj,is_obj:=raw.(json.Object)
    if !is_obj do return nil,true,"agent_models must be an object of agent id -> {provider, model}"
    changes=make(map[string]Owner_Agent_Model,context.temp_allocator)
    for agent,value in obj {
        id:=strings.trim_space(agent)
        if !contracts.owner_field_valid(id,"id") do return nil,true,fmt.tprintf("--agent-model: %q is not an agent id",agent)
        m:Owner_Agent_Model
        #partial switch v in value {
        case json.String:
            text:=strings.trim_space(string(v))
            if slash:=strings.index_byte(text,'/');slash>=0 {m.provider=text[:slash];m.model=text[slash+1:]} else do m.provider=text
        case json.Object:
            m.provider=strings.trim_space(contracts.owner_string(v,"provider"));m.model=strings.trim_space(contracts.owner_string(v,"model"))
        case json.Null:
        case: return nil,true,fmt.tprintf("--agent-model %s: expected <provider>[/<model>]",id)
        }
        if m.provider=="" && m.model!="" do return nil,true,fmt.tprintf("--agent-model %s: a model needs its provider (<provider>/<model>)",id)
        if m.provider!="" {
            if _,_,ok:=bridge_owner_agent_model_resolve(m.provider,m.model);!ok {
                if m.model=="" do return nil,true,fmt.tprintf("--agent-model %s: provider %q is not an active provider of this account's catalog",id,m.provider)
                return nil,true,fmt.tprintf("--agent-model %s: %s/%s is not an active provider model of this account's catalog",id,m.provider,m.model)
            }
        }
        changes[strings.clone(id,context.temp_allocator)]=m
    }
    return changes,true,""
}

// The task's overrides from its brief (agent id -> selection).
bridge_owner_brief_agent_models :: proc(brief:string) -> map[string]Owner_Agent_Model {
    out:=make(map[string]Owner_Agent_Model,context.temp_allocator)
    if brief=="" do return out
    v,ok:=contracts.owner_content_document(brief)
    o,obj:=v.(json.Object)
    if !ok || !obj do return out
    models,has:=o["agent_models"].(json.Object)
    if !has do return out
    for agent,value in models {
        entry,is_obj:=value.(json.Object)
        if !is_obj do continue
        provider:=contracts.owner_string(entry,"provider")
        if provider=="" do continue
        out[agent]=Owner_Agent_Model{provider,contracts.owner_string(entry,"model")}
    }
    return out
}

bridge_owner_brief_agent_model :: proc(brief,agent:string) -> (Owner_Agent_Model,bool) {
    models:=bridge_owner_brief_agent_models(brief)
    m,has:=models[agent]
    return m,has
}

// brief with the task's overrides: current's (the stored brief) merged with
// changes (an empty provider clears that agent).
bridge_owner_brief_with_agent_models :: proc(brief,current:string,changes:map[string]Owner_Agent_Model) -> string {
    v,ok:=contracts.owner_content_document(brief)
    o,obj:=v.(json.Object)
    if !ok || !obj do return brief
    merged:=bridge_owner_brief_agent_models(current)
    for agent,m in changes {
        if m.provider=="" do delete_key(&merged,agent)
        else do merged[agent]=m
    }
    out:=make(json.Object,context.temp_allocator)
    for agent,m in merged do out[agent]=json.Object{"provider"=json.String(m.provider),"model"=json.String(m.model)}
    o["agent_models"]=out
    return bridge_owner_json(o)
}

// A task's overrides read from the owner store (none when unreadable).
bridge_owner_task_models :: proc(s:^owner.Store,chain,task:string) -> map[string]Owner_Agent_Model {
    st,found,ok:=owner.agent_task_state(s,chain,task)
    if !ok || !found do return nil
    return bridge_owner_brief_agent_models(st.brief)
}

// The overrides a task verb leaves: the stored brief's merged with the verb's.
bridge_owner_plan_models :: proc(brief:string,changes:map[string]Owner_Agent_Model) -> map[string]Owner_Agent_Model {
    merged:=bridge_owner_brief_agent_models(brief)
    for agent,m in changes {
        if m.provider=="" do delete_key(&merged,agent)
        else do merged[agent]=m
    }
    return merged
}

// The Hub launch body fields of an agent of a task on bridge.
bridge_owner_launch_body_model :: proc(body:^map[string]string,policy:contracts.Owner_Fleet_Policy,bridge,agent:string,models:map[string]Owner_Agent_Model) {
    override,has:=models[agent]
    provider,model,profile:=bridge_owner_effective_model(policy,bridge,override,has)
    if provider!="" do body["provider"]=provider
    if model!="" do body["model"]=model
    if profile!="" do body["provider_profile"]=profile
}

// Whether a live instance may serve agent's work on a task: true unless the
// task overrides agent and the instance's launch record names another
// provider/model (an unknown launch is not second-guessed).
bridge_owner_instance_serves :: proc(instance,agent:string,models:map[string]Owner_Agent_Model) -> bool {
    override,has:=models[agent]
    if !has do return true
    if bridge_owner_instance_serves_hook!=nil do return bridge_owner_instance_serves_hook(instance,override)
    launch,known:=bridge_runtime_get_launch(instance)
    if !known || launch.provider=="" do return true
    if launch.provider!=override.provider do return false
    return override.model=="" || launch.model==override.model
}
@(thread_local)
bridge_owner_instance_serves_hook:proc(instance:string,want:Owner_Agent_Model) -> bool

// The provider, model and profile an agent of a task launches with on bridge:
// the task override (its empty model resolved from the catalog), else the
// fleet row's per-Bridge entry, else the row's own (bridge_owner_fleet_launch_model).
bridge_owner_effective_model :: proc(policy:contracts.Owner_Fleet_Policy,bridge:string,override:Owner_Agent_Model,has_override:bool) -> (provider,model,profile:string) {
    if has_override {
        provider,model=override.provider,override.model
        if model=="" {
            if p,m,ok:=bridge_owner_agent_model_resolve(provider,"");ok do provider,model=p,m
        }
        return provider,model,""
    }
    return bridge_owner_fleet_launch_model(policy,bridge)
}
