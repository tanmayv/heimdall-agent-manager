package contracts

import "core:encoding/json"

// Ordinary source shape: domain.Task_Chain_Fleet and Fleet_Bridge_Model.
// This is durable future-dispatch policy, distinct from a launched local_fleet
// child assignment. No policy edit can grant a child capability.
Owner_Fleet_Policy :: struct {
    provider_profile: string,
    task_chain_id: string,
    agent_id: string,
    capacity: i64,
    min_warm: i64,
    idle_ttl_seconds: i64,
    bridge_models_json: string,
    provider: string,
    model: string,
    roles_json: string,
    bridge_id: string,
    paused_roles_json: string,
    created_at: string,
    updated_at: string,
}
Owner_Fleet_Bridge_Model :: struct {
    provider_profile: string,
    provider: string,
    model: string,
}

owner_fleet_role_valid :: proc(role: string) -> bool {
    if len(role)==0 || len(role)>32 do return false
    for c,i in role {
        if c>='a' && c<='z' do continue
        if i>0 && ((c>='0' && c<='9') || c=='_' || c=='-') do continue
        return false
    }
    return true
}
owner_fleet_roles :: proc(raw: string, paused: bool) -> ([]string, bool) {
    result:=make([dynamic]string,context.temp_allocator)
    if raw=="" {
        if !paused do append(&result,"worker")
        return result[:],true
    }
    value,ok:=owner_content_document(raw)
    items,array:=value.(json.Array)
    if !ok || !array || len(items)>100 || (!paused && len(items)==0) do return nil,false
    seen:=make(map[string]bool,context.temp_allocator)
    for item in items {
        name,str:=item.(json.String)
        role:=string(name)
        if !str || role in seen || (!owner_fleet_role_valid(role) && !(paused && role=="*" && len(items)==1)) do return nil,false
        seen[role]=true
        append(&result,role)
    }
    return result[:],true
}
owner_fleet_models :: proc(raw: string) -> (map[string]Owner_Fleet_Bridge_Model, bool) {
    models:=make(map[string]Owner_Fleet_Bridge_Model,context.temp_allocator)
    if raw=="" do return models,true
    value,ok:=owner_content_document(raw)
    object,obj:=value.(json.Object)
    if !ok || !obj || len(object)>100 do return nil,false
    for bridge,entry in object {
        row,valid:=entry.(json.Object)
        if !owner_field_valid(bridge,"id") || !valid || len(row)!=3 do return nil,false
        for name in ([3]string{"provider_profile","provider","model"}) {
            text,str:=row[name].(json.String)
            if !str || len(text)>256 do return nil,false
        }
        model:=Owner_Fleet_Bridge_Model{owner_string(row,"provider_profile"),owner_string(row,"provider"),owner_string(row,"model")}
        if model.provider=="" || model.model=="" do return nil,false
        models[bridge]=model
    }
    return models,true
}
owner_fleet_policy_parse :: proc(raw: string) -> (Owner_Fleet_Policy, bool) {
    if len(raw)>8192 do return {},false
    value,ok:=owner_content_document(raw)
    row,obj:=value.(json.Object)
    if !ok || !obj || len(row)!=14 do return {},false
    for name in ([11]string{"provider_profile","task_chain_id","agent_id","bridge_models_json","provider","model","roles_json","bridge_id","paused_roles_json","created_at","updated_at"}) {
        if _,str:=row[name].(json.String); !str do return {},false
    }
    capacity,ci:=row["capacity"].(json.Integer)
    warm,wi:=row["min_warm"].(json.Integer)
    ttl,ti:=row["idle_ttl_seconds"].(json.Integer)
    if !ci || !wi || !ti || capacity<1 || warm<0 || ttl<0 do return {},false
    result:=Owner_Fleet_Policy{
        provider_profile=owner_string(row,"provider_profile"),
        task_chain_id=owner_string(row,"task_chain_id"),agent_id=owner_string(row,"agent_id"),
        capacity=i64(capacity),min_warm=i64(warm),idle_ttl_seconds=i64(ttl),
        bridge_models_json=owner_string(row,"bridge_models_json"),
        provider=owner_string(row,"provider"),model=owner_string(row,"model"),
        roles_json=owner_string(row,"roles_json"),bridge_id=owner_string(row,"bridge_id"),
        paused_roles_json=owner_string(row,"paused_roles_json"),
        created_at=owner_string(row,"created_at"),updated_at=owner_string(row,"updated_at"),
    }
    if !owner_field_valid(result.task_chain_id,"id") || !owner_field_valid(result.agent_id,"id") || !owner_field_valid(result.bridge_id,"optional") do return {},false
    if len(result.provider)>256 || len(result.model)>256 || len(result.provider_profile)>256 || (result.provider_profile!="" && result.provider=="") do return {},false
    if len(result.created_at)>128 || len(result.updated_at)>128 do return {},false
    if _,valid:=owner_fleet_roles(result.roles_json,false); !valid do return {},false
    if _,valid:=owner_fleet_roles(result.paused_roles_json,true); !valid do return {},false
    if _,valid:=owner_fleet_models(result.bridge_models_json); !valid do return {},false
    return result,true
}
